#!/usr/bin/env python3
"""Build an MTK/Android boot image by swapping ONLY the kernel of an existing image.

Everything else -- the ANDROID! header fields, the load addresses, the cmdline, and the
whole ramdisk (MTK 'ROOTFS' header + gzip payload, Magisk patching included) -- is copied
verbatim from the base image. That keeps the number of changed variables at exactly one,
which is the point: when a test image fails to boot we know the kernel is the only thing
that differed.

Image layout on this device (MT8167, verified against mmcblk0p9):

    offset 0          ANDROID! header, page_size 2048, dt_size 0
    offset 2048       kernel  = MTK header(512B) + gzip(arm64 Image) + appended DTB
    offset 2048+K     ramdisk = MTK header(512B) + gzip(cpio)

    MTK header: 88 16 88 58 | u32 payload_size LE | name[32] NUL-padded | 0xFF filler to 512

dt_size is 0 because the DTB is appended AFTER the kernel's gzip stream rather than
carried in its own boot-image section -- so the kernel payload is literally
`cat Image.gz our_device.dtb`.

Usage:
    mkboot.py --base boot_magisk_p9.img --kernel Image.gz --dtb our_device.dtb \
              --out test.img [--part-size 16777216]
"""
import argparse
import hashlib
import re
import struct
import sys
import zlib

MTK_MAGIC = bytes.fromhex("88168858")
MTK_HDR_LEN = 512


def reserved_ceiling(dtb: bytes, load_addr: int):
    """Lowest /reserved-memory region that sits ABOVE load_addr, or None.

    LK copies each blob to the address in the boot header and does no bounds
    checking whatsoever, so a blob that runs long simply lands on top of whatever
    is next in DRAM. On this board what is next is the diagnostic region:

        ram_console-reserved-memory@44400000   0x44400000 + 0x10000
        pstore-reserved-memory@44410000        0x44410000 + 0xe0000
        minirdump-reserved-memory@444f0000     0x444f0000 + 0x10000

    with the ramdisk loading at 0x44000000 -- a ceiling of exactly 4 MiB.

    That overlap is silent and it is NOT a straight overwrite of the ramdisk by
    something else; the ordering makes it worse. ramoops_init() is a
    postcore_initcall and populate_rootfs() is a rootfs_initcall, so ramoops
    zaps its zones BEFORE the kernel ever decompresses the initramfs living at
    those addresses. The gzip stream is then corrupt from the overlap point on,
    and since gzip is a stream every file decoded after it is lost -- always the
    TAIL of the cpio. /sepolicy is ~95% into this ramdisk, so it disappears,
    init reports "Could not open sepolicy", and Android init's response to a
    policy load failure is android_reboot(..., "recovery"). That reboots into
    the same broken image: an unbreakable loop, with nothing in any log naming
    the real cause. Cost: one bootloop that took a hardware LK-menu rescue.

    Addresses come from the node NAMES in the DTB being packed rather than being
    hardcoded, so this stays correct if the reserved map ever moves. Regions
    below load_addr (here atf@43000000) are irrelevant and skipped.
    """
    addrs = []
    for m in re.finditer(rb"[-\w]+-reserved-memory@([0-9a-fA-F]{6,16})\x00", dtb):
        a = int(m.group(1), 16)
        if a > load_addr:
            addrs.append((a, m.group(0)[:-1].decode("ascii", "replace")))
    if not addrs:
        return None
    return min(addrs)


def mtk_wrap(payload: bytes, name: str) -> bytes:
    """Rebuild MTK's 512-byte blob header exactly as the stock image has it."""
    hdr = bytearray(b"\xff" * MTK_HDR_LEN)
    hdr[0:4] = MTK_MAGIC
    hdr[4:8] = struct.pack("<I", len(payload))
    nm = name.encode("ascii")
    if len(nm) > 32:
        sys.exit(f"MTK blob name too long: {name}")
    hdr[8:40] = nm + b"\x00" * (32 - len(nm))
    return bytes(hdr) + payload


def mtk_unwrap(blob: bytes):
    if blob[:4] != MTK_MAGIC:
        sys.exit(f"not an MTK blob: magic={blob[:4].hex()}")
    size = struct.unpack("<I", blob[4:8])[0]
    name = blob[8:40].rstrip(b"\x00").decode("ascii", "replace")
    return name, size, blob[MTK_HDR_LEN:MTK_HDR_LEN + size]


def pages(n, ps):
    return (n + ps - 1) // ps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="existing boot image to take ramdisk+header from")
    ap.add_argument("--kernel", required=True, help="Image.gz (gzip-compressed arm64 Image)")
    ap.add_argument("--dtb", required=True, help="DTB to append after the gzip stream")
    ap.add_argument("--out", required=True)
    ap.add_argument("--ramdisk", default=None,
                    help="replace the ramdisk with this gzip (raw gzip of a newc cpio, NOT "
                         "MTK-wrapped -- the 512-byte MTK header is added here). Default is to "
                         "keep the base image's ramdisk byte-for-byte.")
    ap.add_argument("--ramdisk-name", default=None,
                    help="rename the ramdisk's MTK blob (ROOTFS for the boot partition, "
                         "RECOVERY for the recovery partition). LK matches on this name and "
                         "silently skips a blob named for the other partition -- the kernel "
                         "then boots with no initramfs and panics with "
                         "'VFS: Unable to mount root fs on unknown-block(1,0)'.")
    ap.add_argument("--cmdline-append", default=None,
                    help="append to the boot image header's cmdline. KEEP IT SHORT: MTK's LK "
                         "copies the header cmdline through a 100-byte buffer "
                         "(CMDLINE_TMP_CONCAT_SIZE) and silently truncates at 99 bytes, then "
                         "appends its OWN args after ours. Linux 4.4 parse_args is last-wins, "
                         "so LK beats us on any key it also sets (printk.disable_uart, "
                         "boot_reason, androidboot.*). Only add keys LK does not set.")
    ap.add_argument("--part-size", type=int, default=16777216,
                    help="pad output to exactly this size (0 = no padding)")
    a = ap.parse_args()

    base = open(a.base, "rb").read()
    if base[:8] != b"ANDROID!":
        sys.exit("base is not an Android boot image")

    ks, ka, rs, ra, ss, sa, tags, ps, dt, _unused = struct.unpack("<10I", base[8:48])
    if dt != 0:
        sys.exit(f"base has dt_size={dt}; this packer assumes an appended DTB (dt_size 0)")
    if ss != 0:
        # We lay out header|kernel|ramdisk only. A non-zero second stage would be dropped
        # while its header field stayed set, mis-locating the ramdisk.
        sys.exit(f"base has second_size={ss}; this packer does not carry a second stage")
    cmdline = base[64:576].rstrip(b"\x00").decode("ascii", "replace")

    ko = ps
    ro = ko + pages(ks, ps) * ps
    old_kernel = base[ko:ko + ks]
    ramdisk = base[ro:ro + rs]

    # Validate what we are replacing and what we are preserving.
    kname, _, old_payload = mtk_unwrap(old_kernel)
    rname, _, _ = mtk_unwrap(ramdisk)
    if kname != "KERNEL":
        sys.exit(f"unexpected kernel blob name {kname!r}")

    gz = open(a.kernel, "rb").read()
    if gz[:2] != b"\x1f\x8b":
        sys.exit(f"--kernel is not gzip (magic {gz[:2].hex()})")
    dtb = open(a.dtb, "rb").read()
    if dtb[:4] != bytes.fromhex("d00dfeed"):
        sys.exit(f"--dtb is not an FDT (magic {dtb[:4].hex()})")
    if struct.unpack(">I", dtb[4:8])[0] != len(dtb):
        sys.exit("DTB totalsize field does not match file length")

    # The gzip must decompress to a valid arm64 Image, or we would be flashing garbage.
    o = zlib.decompressobj(16 + zlib.MAX_WBITS)
    img = o.decompress(gz)
    if o.unused_data:
        sys.exit("--kernel has trailing data; pass a bare Image.gz (the DTB goes in --dtb)")
    # A TRUNCATED gzip passes every other check here: decompress() returns partial output
    # without raising, unused_data stays empty, and the arm64 magic at 0x38 is near the
    # start so it still matches -- i.e. we would happily flash an unbootable kernel.
    # o.eof is the only thing that proves the stream actually ended.
    if not o.eof:
        sys.exit("--kernel gzip stream is truncated (no end-of-stream marker)")
    if img[0x38:0x3C] != b"ARM\x64":
        sys.exit(f"decompressed kernel lacks arm64 magic (got {img[0x38:0x3C].hex()})")

    new_kernel = mtk_wrap(gz + dtb, "KERNEL")

    if a.ramdisk:
        rgz = open(a.ramdisk, "rb").read()
        if rgz[:2] != b"\x1f\x8b":
            sys.exit(f"--ramdisk is not gzip (magic {rgz[:2].hex()})")
        # Same truncation trap as the kernel: a short gzip decompresses partially without
        # raising, so check for the end-of-stream marker explicitly.
        ro_ = zlib.decompressobj(16 + zlib.MAX_WBITS)
        cpio = ro_.decompress(rgz)
        if not ro_.eof:
            sys.exit("--ramdisk gzip stream is truncated (no end-of-stream marker)")
        if cpio[:6] != b"070701":
            sys.exit(f"--ramdisk does not contain a newc cpio (magic {cpio[:6]!r})")
        keep = a.ramdisk_name or rname
        ramdisk = mtk_wrap(rgz, keep)
        rs = len(ramdisk)
        print(f"ramdisk       : REPLACED from {a.ramdisk}")
        print(f"                gzip {len(rgz)} -> cpio {len(cpio)} bytes, blob name {keep!r}")
        rname = keep

    if a.ramdisk_name and a.ramdisk_name != rname:
        _, _, rpayload = mtk_unwrap(ramdisk)
        ramdisk = mtk_wrap(rpayload, a.ramdisk_name)
        assert len(ramdisk) == rs, "renaming must not change the blob length"
        print(f"ramdisk blob  : renamed {rname!r} -> {a.ramdisk_name!r} (payload untouched)")
        rname = a.ramdisk_name

    # ---- DRAM placement: the blobs must not reach the reserved diagnostic region ----
    # See reserved_ceiling(). Both blobs are checked because both are copied to fixed
    # addresses by LK with no bounds check; the ramdisk is the one that actually has
    # headroom to lose (stock recovery leaves only 560 KB of it).
    for what, addr, size in (("kernel", ka, len(new_kernel)), ("ramdisk", ra, len(ramdisk))):
        ceil = reserved_ceiling(dtb, addr)
        if ceil is None:
            continue
        limit, node = ceil
        end = addr + size
        if end > limit:
            sys.exit(
                f"{what} does not fit: loads at 0x{addr:08x}, is {size} bytes, ends at "
                f"0x{end:08x},\n"
                f"  which runs {end - limit} bytes into '{node}' at 0x{limit:08x}.\n"
                f"  Budget is {limit - addr} bytes. This does NOT fail loudly on the device:\n"
                f"  ramoops zaps that memory (postcore_initcall) before the initramfs is\n"
                f"  unpacked (rootfs_initcall), so the gzip tail decodes to garbage, /sepolicy\n"
                f"  goes missing, and init reboots to recovery forever. Shrink the {what}."
            )
        headroom = limit - end
        note = "  *** TIGHT ***" if headroom < 128 * 1024 else ""
        print(f"{what+' fit':<14}: ends 0x{end:08x}, {headroom} bytes below "
              f"0x{limit:08x} ({node}){note}")

    hdr = bytearray(base[:ps])

    if a.cmdline_append:
        newcmd = (cmdline + " " + a.cmdline_append).strip()
        raw = newcmd.encode("ascii")
        if len(raw) > 511:
            sys.exit(f"cmdline {len(raw)} bytes exceeds the 512-byte header field")
        # MTK LK copies this through snprintf(buf, CMDLINE_TMP_CONCAT_SIZE=100, ...), so
        # anything past 99 bytes is dropped silently, with nothing in any log.
        if len(raw) > 99:
            sys.exit(f"cmdline is {len(raw)} bytes; MTK LK truncates at 99 and says nothing.\n"
                     f"  {newcmd!r}\n"
                     f"Put long options in CONFIG_CMDLINE with CONFIG_CMDLINE_EXTEND=y instead.")
        hdr[64:576] = raw + b"\x00" * (512 - len(raw))
        print(f"cmdline       : {cmdline!r}\n              -> {newcmd!r}  ({len(raw)}/99 bytes)")
        cmdline = newcmd

    hdr[8:12] = struct.pack("<I", len(new_kernel))
    # ramdisk_size lives at offset 16. It only changes when --ramdisk replaced it, but write
    # it unconditionally: leaving a stale size here would have LK hand the kernel a ramdisk of
    # the wrong length, which fails the same silent way the ROOTFS/RECOVERY name bug did.
    hdr[16:20] = struct.pack("<I", rs)
    out = bytes(hdr) + new_kernel + b"\x00" * (pages(len(new_kernel), ps) * ps - len(new_kernel))
    out += ramdisk + b"\x00" * (pages(len(ramdisk), ps) * ps - len(ramdisk))

    if a.part_size:
        if len(out) > a.part_size:
            sys.exit(f"image {len(out)} exceeds partition {a.part_size}")
        out += b"\x00" * (a.part_size - len(out))

    open(a.out, "wb").write(out)

    # Read the result back and prove the ramdisk survived byte-for-byte.
    chk = open(a.out, "rb").read()
    nks = struct.unpack("<I", chk[8:12])[0]
    nro = ps + pages(nks, ps) * ps
    assert chk[nro:nro + rs] == ramdisk, "ramdisk corrupted during packing"

    print(f"base          : {a.base}")
    print(f"  cmdline     : {cmdline!r}   page_size={ps}")
    print(f"  kernel      : {ks} bytes  -> replaced")
    how = "REPLACED from --ramdisk" if a.ramdisk else "preserved from base"
    print(f"  ramdisk     : {rs} bytes ({rname})  -> {how}, read back and verified")
    print(f"new kernel    : Image.gz {len(gz)} + dtb {len(dtb)} = {len(new_kernel)} (with MTK hdr)")
    print(f"  decompresses to arm64 Image, {len(img)} bytes")
    print(f"output        : {a.out}  {len(out)} bytes")
    print(f"  md5         : {hashlib.md5(out).hexdigest()}")


if __name__ == "__main__":
    main()
