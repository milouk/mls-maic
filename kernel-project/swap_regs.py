#!/usr/bin/env python3
"""Replace the ad82584f driver's Amlogic power-up register table with the MAIC values.

The vendored driver ships a 134-entry table tuned for Amlogic boards. This device uses the
same chip and the same 134 registers -- 117 of the values already agree -- but the
remaining 17 are board tuning (State_Control, volumes, DRC coefficients). Those came off
the live device by ftrace, so they are what this hardware actually wants.

Idempotent: does nothing if the MAIC table is already in place.
"""
import re, sys

DRV = "/src/linux/sound/soc/codecs/ad82584f.c"
TBL = "/refs/ad82584f/ad82584f_reg_defaults_maic.h"
MARK = "Captured from the live MAIC device"

src = open(DRV).read()
if MARK in src:
    print("  -> ad82584f register table: already MAIC values")
    sys.exit(0)

new_tbl = open(TBL).read().strip()

# match the existing table: from its declaration through the closing "};"
pat = re.compile(
    r'(?:/\*[^*]*\*/\s*)?static\s+const\s*\n?\s*struct\s+reg_default\s+ad82584f_reg_defaults\s*'
    r'\[\s*AD82584F_REGISTER_COUNT\s*\]\s*=\s*\{.*?\n\};',
    re.S)
m = pat.search(src)
if not m:
    sys.exit("FAILED: could not locate ad82584f_reg_defaults[] in the driver")

old = m.group(0)
n_old = len(re.findall(r'\{0x[0-9a-fA-F]{2},\s*0x[0-9a-fA-F]{2}\}', old))
n_new = len(re.findall(r'\{0x[0-9a-fA-F]{2},\s*0x[0-9a-fA-F]{2}\}', new_tbl))
if n_old != n_new:
    sys.exit(f"FAILED: entry count mismatch, driver has {n_old}, MAIC table has {n_new}")

open(DRV, "w").write(src[:m.start()] + new_tbl + src[m.end():])
print(f"  -> ad82584f register table: swapped {n_old} Amlogic defaults for MAIC captured values")
