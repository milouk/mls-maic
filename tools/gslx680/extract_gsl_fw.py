#!/usr/bin/env python3
"""Extract the GSL touchscreen firmware blob from the device's STOCK kernel.

Why: the GSL controller has no firmware in a file -- the driver carries it as a C array
and downloads it over I2C at probe. That blob is PER-PANEL. The array shipped in the
upstream kernel tree is for a different GSL variant entirely (4,554 entries / 138 pages,
built "Aug 26 2016"), while this device's is 15,213 entries / 461 pages, built
"Aug 12 2015". Using the wrong one means a dead touchscreen.

Capturing it over I2C was the first idea (the trick that worked for the ad82584f amp), but
unbinding the gslx68x driver does not re-probe cleanly on this MTK tpd stack, so the blob
is lifted straight out of the stock kernel binary instead.

Layout: MTK boot image -> 512-byte MTK header ("KERNEL") -> gzip -> arm64 Image, with the
DTB appended after the gzip stream. Inside, the firmware is an array of
    struct fw_data { u32 offset:8; u32:0; u32 val; }   /* 8 bytes LE per entry */
written as repeating pages: {0xf0, page} followed by 32 entries at offsets 0x00..0x7c.
That cadence is the signature this script locks onto.

Usage:  extract_gsl_fw.py <boot.img> [out.h]
"""
import struct, sys, zlib

def load_kernel(path):
    d = open(path, "rb").read()
    if d[:8] != b"ANDROID!":
        sys.exit("not an Android boot image")
    kernel_size, _, _, _, _, _, _, page_size = struct.unpack("<8I", d[8:40])
    blob = d[page_size:page_size + kernel_size]
    # MediaTek prepends a 512-byte header (magic 0x58881688, name "KERNEL")
    magic, size = struct.unpack("<II", blob[:8])
    if magic == 0x58881688:
        name = blob[8:40].split(b"\x00")[0].decode("ascii", "replace")
        print(f"  MTK header: {name}, payload {size} bytes")
        blob = blob[512:512 + size]
    if blob[:2] != b"\x1f\x8b":
        sys.exit(f"expected gzip, got {blob[:4].hex()}")
    dec = zlib.decompressobj(16 + zlib.MAX_WBITS)
    img = dec.decompress(blob)
    print(f"  Image {len(img)} bytes, appended dtb {len(dec.unused_data)} bytes")
    return img

def entry(img, p):
    return (int.from_bytes(img[p:p+4], "little"),
            int.from_bytes(img[p+4:p+8], "little"))

def find_fw(img):
    """Locate the first {0xf0,page} that starts a valid page-cadence run."""
    i = 0
    while i + 8 * 33 <= len(img):
        off, _ = entry(img, i)
        if off == 0xf0 and all(entry(img, i + 8 * (k + 1))[0] == k * 4 for k in range(32)):
            return i
        i += 4
    sys.exit("firmware pattern not found")

def read_fw(img, start):
    out, p = [], start
    while p + 8 <= len(img):
        off, val = entry(img, p)
        if off != 0xf0:
            break
        page = [(off, val)]
        p += 8
        ok = True
        for k in range(32):
            o, v = entry(img, p)
            if o != k * 4:
                ok = False
                break
            page.append((o, v))
            p += 8
        if not ok:
            break
        out += page
    return out

def stamp(entries):
    """The blob ends with an ASCII build date; useful to tell variants apart."""
    b = b"".join(struct.pack("<I", v) for _, v in entries[-12:])
    return "".join(chr(c) if 32 <= c < 127 else "." for c in b)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    img = load_kernel(sys.argv[1])
    start = find_fw(img)
    fw = read_fw(img, start)
    pages = sum(1 for o, _ in fw if o == 0xf0)
    print(f"  firmware at 0x{start:08x}: {len(fw)} entries, {pages} pages, {len(fw)*8} bytes")
    print(f"  build stamp (raw): {stamp(fw)}")
    out = sys.argv[2] if len(sys.argv) > 2 else "gslx680_fw_maic.h"
    with open(out, "w") as f:
        f.write("/* GSL touchscreen firmware extracted from this device's STOCK kernel by\n")
        f.write(" * tools/gslx680/extract_gsl_fw.py. The array the upstream tree ships is for a\n")
        f.write(" * different GSL variant and would leave the touchscreen dead.\n")
        f.write(f" * entries: {len(fw)}  pages: {pages}  bytes: {len(fw)*8}\n */\n")
        f.write("static const struct fw_data GSLX680_FW[] = {\n")
        for o, v in fw:
            f.write(f"\t{{0x{o:02x}, 0x{v:08x}}},\n")
        f.write("};\n")
    print(f"  wrote {out}")
