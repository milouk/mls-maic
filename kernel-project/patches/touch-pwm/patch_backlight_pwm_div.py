#!/usr/bin/env python3
"""Patch the LCD backlight PWM clock divider in a compiled MAIC device tree blob.

Changes exactly one 4-byte field: pwm_config[1] (clockdiv) on the /soc/led@6 node
(compatible = "mediatek,lcd-backlight"). Nothing else in the DTB is touched -- no
decompile/recompile round trip, which on this device has previously reintroduced a
completely different bug (a recompiled DTB's phandles/clock nodes silently diverging
from the device's actual captured DTB, unrelated to this backlight change but a
standing reason to always binary-patch this DTB rather than regenerate it from source).

Why: see README.md. Short version -- the LP8557 backlight driver's documented PWM input
range tops out at 25000 Hz; this board's stock config (clockdiv=0) computes to ~25390 Hz,
already fractionally over spec, and it has been that way since the factory (verified
byte-identical against the stock DTB). Raising the divider by one step (0 -> 1) halves
the frequency to ~12.7 kHz -- comfortably inside spec, and per the datasheet's own
resolution table (PWM_RES), a *better*-characterized operating point than the stock one.

Usage:
    python3 patch_backlight_pwm_div.py our_device.dtb our_device_pwmfix.dtb [DIV]

DIV defaults to 1. Any value 1-1023 is accepted; the frequency is (very likely, see
README.md) 26MHz / (DIV+1) / 1024 -- so higher DIV = lower frequency. Do not set DIV
high enough to leave the LP8557's 75 Hz floor (division by a very large DIV can).
"""
import struct
import sys

FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def find_pwm_config(data, target_compatible):
    """Walk the FDT struct block and return the byte offset of `pwm_config`'s data
    for the node whose `compatible` property equals target_compatible.

    Standard fdtget/fdtput refuse to touch this DTB at all -- even for trivially
    present paths -- so this reimplements just enough of the FDT struct-block walk
    (matching the flattened devicetree spec) to locate one property precisely.
    """
    magic, totalsize, off_dt_struct, off_dt_strings = struct.unpack(">4I", data[0:16])
    assert magic == 0xd00dfeed, f"not a DTB (magic {magic:#x})"

    def get_string(off):
        end = data.index(b"\x00", off_dt_strings + off)
        return data[off_dt_strings + off:end].decode()

    pos = off_dt_struct
    path_stack = []
    last_compatible = {}
    found = None
    while True:
        tag = struct.unpack(">I", data[pos:pos + 4])[0]
        if tag == FDT_BEGIN_NODE:
            name_end = data.index(b"\x00", pos + 4)
            path_stack.append(data[pos + 4:name_end].decode())
            pos = ((name_end + 1) + 3) & ~3
        elif tag == FDT_END_NODE:
            path_stack.pop()
            pos += 4
        elif tag == FDT_PROP:
            length, nameoff = struct.unpack(">II", data[pos + 4:pos + 12])
            propname = get_string(nameoff)
            data_off = pos + 12
            cur_path = "/" + "/".join(path_stack)
            if propname == "compatible":
                last_compatible[cur_path] = data[data_off:data_off + length].rstrip(b"\x00").decode(errors="replace")
            if propname == "pwm_config" and last_compatible.get(cur_path) == target_compatible:
                found = (cur_path, data_off, length)
            pos = data_off + ((length + 3) & ~3)
        elif tag == FDT_NOP:
            pos += 4
        elif tag == FDT_END:
            break
        else:
            raise ValueError(f"unknown FDT tag {tag} at offset {pos}")
    return found


def main():
    if len(sys.argv) not in (3, 4):
        print(__doc__)
        sys.exit(1)
    src, dst = sys.argv[1], sys.argv[2]
    div = int(sys.argv[3]) if len(sys.argv) == 4 else 1

    data = bytearray(open(src, "rb").read())
    found = find_pwm_config(data, "mediatek,lcd-backlight")
    if not found:
        print("ERROR: no /soc/.../led node with compatible=mediatek,lcd-backlight and a "
              "pwm_config property found. This tool is specific to this board's DTB layout.")
        sys.exit(1)

    path, off, length = found
    before = struct.unpack(">5I", data[off:off + length])
    print(f"found pwm_config at {path} (byte offset {off}, {length} bytes): {before}")
    assert before[1] in (0, div), f"clockdiv is already non-default ({before[1]}) -- check before overwriting"

    after = (before[0], div, before[2], before[3], before[4])
    data[off:off + 4 * 5] = struct.pack(">5I", *after)
    open(dst, "wb").write(data)

    changed = sum(1 for a, b in zip(open(src, "rb").read(), data) if a != b)
    print(f"wrote {dst}: pwm_config {before} -> {after}  ({changed} byte(s) changed total)")
    assert changed == 1, "expected exactly 1 changed byte (clockdiv is a single-byte value 0-255 here)"


if __name__ == "__main__":
    main()
