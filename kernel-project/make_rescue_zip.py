#!/usr/bin/env python3
"""Build and sign the MAIC rescue package that restores the boot partition.

Produces a zip that STOCK, UNMODIFIED recovery will verify and install:

    boot.img                                        (STORED, first entry, 16 MiB)
    META-INF/com/google/android/update-binary       (rescue_update, ~4 KB)

then whole-file-signs it with the AOSP test key, which is the key this device's
recovery actually trusts (verified word-for-word against its /res/keys).

Layout is not cosmetic. rescue_update.c has no inflate and no zip directory
walker -- it reads the local file header at offset 0 -- so boot.img MUST be the
first entry and MUST be STORED. Both facts are asserted here and re-checked on
the device before anything is written.

Usage:
    make_rescue_zip.py --boot backups/boot_magisk_p9.img \\
                       --binary rescue/rescue_update \\
                       --out maic_rescue.zip \\
                       --cert testkey.x509.pem --key testkey.pem \\
                       --keys <recovery res/keys>     # self-verify target
"""
import argparse
import hashlib
import os
import struct
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PART_SIZE = 16777216


def check_boot_image(path):
    """Refuse on the host what the device would refuse anyway -- but sooner."""
    b = open(path, "rb").read()
    if len(b) != PART_SIZE:
        sys.exit(f"{path}: {len(b)} bytes, expected exactly {PART_SIZE}")
    if b[:8] != b"ANDROID!":
        sys.exit(f"{path}: not an Android boot image")
    ks, _, rs, _, ss, _, _, ps, dt, _ = struct.unpack("<10I", b[8:48])
    if ps == 0:
        sys.exit(f"{path}: page_size is 0")
    roff = ps + ((ks + ps - 1) // ps) * ps
    if b[roff:roff + 4] != bytes.fromhex("88168858"):
        sys.exit(f"{path}: no MTK blob at the ramdisk offset {roff}")
    name = b[roff + 8:roff + 40].rstrip(b"\x00").decode("ascii", "replace")
    if name != "ROOTFS":
        sys.exit(f"{path}: ramdisk blob is named {name!r}, not 'ROOTFS'. A RECOVERY "
                 f"image on the boot partition gives a kernel with no initramfs.")
    return dict(md5=hashlib.md5(b).hexdigest(), kernel=ks, ramdisk=rs, page=ps,
                ramdisk_off=roff, blob=name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--boot", required=True, help="the 16 MiB boot image to restore")
    ap.add_argument("--binary", required=True, help="built rescue_update (aarch64, static)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--keys", help="recovery's res/keys, to self-verify the signature")
    a = ap.parse_args()

    info = check_boot_image(a.boot)
    print(f"boot image    : {a.boot}")
    print(f"  md5         : {info['md5']}")
    print(f"  kernel {info['kernel']}  ramdisk {info['ramdisk']} ({info['blob']}) "
          f"@ {info['ramdisk_off']}  page {info['page']}")

    ub = open(a.binary, "rb").read()
    if ub[:4] != b"\x7fELF" or ub[4] != 2 or ub[18:20] != b"\xb7\x00":
        sys.exit(f"{a.binary}: not a 64-bit AArch64 ELF")
    print(f"update-binary : {a.binary}  {len(ub)} bytes  (aarch64 ELF64)")

    unsigned = a.out + ".unsigned"
    with zipfile.ZipFile(unsigned, "w") as z:
        # boot.img FIRST and STORED -- rescue_update reads the local header at
        # offset 0 and has no inflate.
        zi = zipfile.ZipInfo("boot.img")
        zi.compress_type = zipfile.ZIP_STORED
        z.writestr(zi, open(a.boot, "rb").read())
        z.writestr("META-INF/com/google/android/update-binary", ub)

    # Prove the layout the device assumes, rather than trusting zipfile.
    d = open(unsigned, "rb").read()
    if d[:4] != b"PK\x03\x04":
        sys.exit("no local file header at offset 0")
    if struct.unpack("<H", d[8:10])[0] != 0:
        sys.exit("first entry is not STORED")
    if struct.unpack("<H", d[6:8])[0] & 0x08:
        sys.exit("first entry uses a data descriptor; sizes must be in the header")
    nlen = struct.unpack("<H", d[26:28])[0]
    if d[30:30 + nlen] != b"boot.img":
        sys.exit(f"first entry is {d[30:30+nlen]!r}, not boot.img")
    if struct.unpack("<I", d[18:22])[0] != PART_SIZE:
        sys.exit("first entry's compressed size is not 16 MiB")

    sys.path.insert(0, HERE)
    import ota_sign
    ota_sign.sign(unsigned, a.out, a.cert, a.key)
    os.unlink(unsigned)
    out = open(a.out, "rb").read()
    print(f"package       : {a.out}  {len(out)} bytes")
    print(f"  md5         : {hashlib.md5(out).hexdigest()}")

    if a.keys:
        ok, msg = ota_sign.verify(a.out, a.keys)
        print(f"  self-verify : {'OK - ' if ok else 'FAILED - '}{msg}")
        if not ok:
            sys.exit(1)


if __name__ == "__main__":
    main()
