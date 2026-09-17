#!/usr/bin/env python3
"""Whole-file-sign an OTA zip so stock recovery on this device accepts it.

Why this exists: this tablet has no usable rescue path. Its USB port is a USB-A
*receptacle* -- a host port that sources VBUS (measured: it feeds a connected Mac
3 W) -- so the device can never be a USB peripheral. No fastboot, no adb over
USB, and no BROM without an A-to-A cable. There is no SD slot. The recovery
ramdisk cannot be extended either, because a boot/recovery ramdisk on this board
has a hard 4 MiB ceiling (see mkboot.py) that stock recovery already fills to
within 560 KB.

What is left is the vendor's own path, and it turns out to be wide open:
recovery's /res/keys is the **AOSP test key**, verified here word-for-word
(n0inv 0xc926ad21, all 64 modulus words, all 64 rr words). Its private half ships
in AOSP. So we can sign a package that unmodified, stock recovery will verify and
install -- no device modification at all, and the zip is staged on /sdcard
(/data/media/0, plain ext4) from a working Android.

The format is the pre-Android-9 "whole-file signature", implemented to match
bootable/recovery/verifier.cpp at android-7.0.0_r1:

    [zip data + central directory][EOCD 22B][comment: PKCS#7 DER][6-byte footer]

    footer = <u16 signature_start> $ff $ff <u16 comment_size>

with, from verify_file():

    comment_size    = footer[4] | footer[5]<<8
    signature_start = footer[0] | footer[1]<<8      (bytes back from EOF)
    eocd_size       = comment_size + 22
    signed_len      = length - eocd_size + 22 - 2   ==  length - comment_size - 2

signed_len is the whole file except the comment and the 2-byte comment-length
field -- i.e. everything up to and including the first 20 bytes of the EOCD.
That is independent of the comment, so there is no chicken-and-egg: we sign
zip[0 : X+20] and only afterwards learn how long the signature is.

TWO TRAPS, both load-bearing:

  * read_pkcs7() skips exactly four fields of SignerInfo (version,
    issuerAndSerialNumber, digestAlgorithm, digestEncryptionAlgorithm) and then
    expects the signature OCTET STRING. If the signature carries authenticated
    attributes, that [0] block occupies one of those slots and the parser reads
    the wrong element. **-noattr is mandatory**, and it also means the RSA
    signature is over the content digest directly, which is what RSA_verify()
    is given.
  * verify_file() rejects the package if the bytes $50 $4b $05 $06 appear
    anywhere in the EOCD *after* its start -- a real exploit guard, since a
    second EOCD marker would make the zip reader and the verifier disagree about
    which archive they are looking at. A DER signature is effectively random
    bytes, so this can happen by chance. We check, and refuse rather than ship a
    package that fails at the device.

verify() below re-implements verify_file() and read_pkcs7() independently, so a
package is proven acceptable here rather than discovered to be bad while the
device is unbootable.
"""
import argparse
import hashlib
import os
import struct
import subprocess
import sys
import tempfile

EOCD_MAGIC = b"PK\x05\x06"
EOCD_HEADER_SIZE = 22
FOOTER_SIZE = 6


# --------------------------------------------------------------------------
# Minimal DER walker -- deliberately mirrors system/core/libmincrypt-era
# asn1_decoder.cpp, so that what we accept is what recovery accepts.
# --------------------------------------------------------------------------
def _tlv(buf, pos):
    """Return (tag, content_start, content_len, next_pos)."""
    if pos + 2 > len(buf):
        raise ValueError("truncated DER")
    tag = buf[pos]
    n = buf[pos + 1]
    pos += 2
    if n & 0x80:
        k = n & 0x7F
        if k == 0 or pos + k > len(buf):
            raise ValueError("bad DER length")
        n = int.from_bytes(buf[pos:pos + k], "big")
        pos += k
    if pos + n > len(buf):
        raise ValueError("DER element overruns buffer")
    return tag, pos, n, pos + n


def read_pkcs7(der):
    """Extract the raw RSA signature exactly the way recovery's read_pkcs7 does."""
    tag, cs, cl, _ = _tlv(der, 0)                      # ContentInfo SEQUENCE
    if tag != 0x30:
        raise ValueError(f"PKCS#7: expected SEQUENCE, got tag 0x{tag:02x}")
    p, end = cs, cs + cl

    _, _, _, p = _tlv(der, p)                          # skip contentType OID

    tag, cs2, cl2, _ = _tlv(der, p)                    # [0] EXPLICIT content
    if tag & 0xE0 != 0xA0:
        raise ValueError(f"PKCS#7: expected constructed [0], got 0x{tag:02x}")

    tag, cs3, cl3, _ = _tlv(der, cs2)                  # SignedData SEQUENCE
    if tag != 0x30:
        raise ValueError("PKCS#7: SignedData is not a SEQUENCE")
    p, end3 = cs3, cs3 + cl3

    for _ in range(3):                                 # version, digestAlgs, contentInfo
        _, _, _, p = _tlv(der, p)

    while p < end3:                                    # asn1_constructed_skip_all
        tag = der[p]
        if tag & 0xC0 == 0x80 and tag & 0x20:          # context-specific, constructed
            _, _, _, p = _tlv(der, p)
        else:
            break

    tag, cs4, cl4, _ = _tlv(der, p)                    # signerInfos SET
    if tag != 0x31:
        raise ValueError(f"PKCS#7: expected SET of SignerInfo, got 0x{tag:02x}")

    tag, cs5, cl5, _ = _tlv(der, cs4)                  # SignerInfo SEQUENCE
    if tag != 0x30:
        raise ValueError("PKCS#7: SignerInfo is not a SEQUENCE")
    p = cs5
    for _ in range(4):                                 # version, issuerAndSerial,
        _, _, _, p = _tlv(der, p)                      # digestAlg, sigAlg

    tag, cs6, cl6, _ = _tlv(der, p)
    if tag != 0x04:
        raise ValueError(
            f"PKCS#7: expected OCTET STRING signature after 4 skips, got tag 0x{tag:02x}. "
            "This is the -noattr trap: authenticated attributes shift the layout.")
    return der[cs6:cs6 + cl6]


# --------------------------------------------------------------------------
def _run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, **kw)
    if r.returncode != 0:
        sys.exit(f"command failed: {' '.join(cmd)}\n{r.stderr.decode(errors='replace')}")
    return r.stdout


def sign(unsigned, out, cert, key, digest="sha1"):
    data = bytearray(open(unsigned, "rb").read())

    # The unsigned zip must have an empty comment, or X is not where we think.
    if len(data) < EOCD_HEADER_SIZE or data[-EOCD_HEADER_SIZE:-EOCD_HEADER_SIZE + 4] != EOCD_MAGIC:
        sys.exit("input does not end in a 22-byte EOCD; rebuild it with no archive comment")
    if struct.unpack("<H", data[-2:])[0] != 0:
        sys.exit("input zip already has an archive comment; refusing")

    X = len(data) - EOCD_HEADER_SIZE
    signed_content = bytes(data[:X + 20])

    with tempfile.TemporaryDirectory() as td:
        cpath = os.path.join(td, "content.bin")
        open(cpath, "wb").write(signed_content)
        # -noattr: no authenticated attributes (see module docstring).
        # -binary: no MIME canonicalisation of the content.
        # detached (no -nodetach): the content is not embedded; recovery only
        # needs the signature, and a 16 MB copy would double the package.
        sig = _run(["openssl", "smime", "-sign", "-binary", "-noattr",
                    "-md", digest, "-outform", "DER",
                    "-signer", cert, "-inkey", key, "-in", cpath])

    signature_size = len(sig)
    comment_size = signature_size + FOOTER_SIZE
    signature_start = comment_size          # signature begins at the comment's first byte
    if comment_size > 0xFFFF:
        sys.exit(f"signature+footer is {comment_size} bytes; the zip comment field holds 65535")

    footer = struct.pack("<H", signature_start) + b"\xff\xff" + struct.pack("<H", comment_size)
    out_data = bytes(data[:X + 20]) + struct.pack("<H", comment_size) + sig + footer

    # Guard the exploit check in verify_file() before we ship anything.
    eocd = out_data[len(out_data) - (comment_size + EOCD_HEADER_SIZE):]
    for i in range(4, len(eocd) - 3):
        if eocd[i:i + 4] == EOCD_MAGIC:
            sys.exit("the DER signature happens to contain the bytes 50 4b 05 06, which "
                     "verify_file() rejects as a second EOCD marker. Perturb the package "
                     "(e.g. change a file by one byte) and sign again.")

    open(out, "wb").write(out_data)
    return out_data


def verify(path, keyfile):
    """Independent re-implementation of verify_file() + read_pkcs7()."""
    data = open(path, "rb").read()
    length = len(data)
    if length < FOOTER_SIZE:
        return False, "not big enough to contain footer"

    footer = data[-FOOTER_SIZE:]
    if footer[2] != 0xFF or footer[3] != 0xFF:
        return False, "footer is wrong"

    comment_size = footer[4] | (footer[5] << 8)
    signature_start = footer[0] | (footer[1] << 8)
    if signature_start <= FOOTER_SIZE:
        return False, "signature start is in the footer"

    eocd_size = comment_size + EOCD_HEADER_SIZE
    if length < eocd_size:
        return False, "not big enough to contain EOCD"

    signed_len = length - eocd_size + EOCD_HEADER_SIZE - 2
    eocd = data[length - eocd_size:]
    if eocd[:4] != EOCD_MAGIC:
        return False, "signature length doesn't match EOCD marker"
    for i in range(4, eocd_size - 3):
        if eocd[i:i + 4] == EOCD_MAGIC:
            return False, "EOCD marker occurs after start of EOCD"

    digest = hashlib.sha1(data[:signed_len]).digest()
    sig_der = read_pkcs7(data[length - signature_start:length - FOOTER_SIZE])

    # RSA PKCS#1 v1.5 verify against the key recovery actually trusts.
    n, e = parse_mincrypt_keys(keyfile)
    m = pow(int.from_bytes(sig_der, "big"), e, n)
    em = m.to_bytes(256, "big")
    # EMSA-PKCS1-v1_5 with SHA-1: 00 01 FF..FF 00 <DigestInfo>
    di = bytes.fromhex("3021300906052b0e03021a05000414") + digest
    expect = b"\x00\x01" + b"\xff" * (256 - 3 - len(di)) + b"\x00" + di
    if em != expect:
        return False, "failed to verify whole-file signature"
    return True, (f"whole-file signature verified against RSA key 0 "
                  f"(signed_len={signed_len}, comment={comment_size}, sig={len(sig_der)})")


def parse_mincrypt_keys(path):
    """Parse recovery's /res/keys mincrypt v1 format -> (modulus, exponent)."""
    import re
    txt = open(path).read()
    nums = [int(x) for x in re.findall(r"\d+", re.sub(r"0x[0-9a-fA-F]+", "", txt))]
    if nums[0] != 64:
        raise ValueError(f"expected a 2048-bit key (64 words), got {nums[0]}")
    words = nums[1:65]
    n = sum(w << (32 * i) for i, w in enumerate(words))
    return n, 65537 if "v2" in txt or "v3" in txt else 3


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sign")
    s.add_argument("--in", dest="inp", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--cert", required=True)
    s.add_argument("--key", required=True)
    v = sub.add_parser("verify")
    v.add_argument("--in", dest="inp", required=True)
    v.add_argument("--keys", required=True, help="recovery's res/keys file")
    a = ap.parse_args()

    if a.cmd == "sign":
        d = sign(a.inp, a.out, a.cert, a.key)
        print(f"signed  : {a.out}  {len(d)} bytes")
    else:
        ok, msg = verify(a.inp, a.keys)
        print(("OK   : " if ok else "FAIL : ") + str(msg))
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
