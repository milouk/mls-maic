#!/usr/bin/env python3
"""Replace the GSL touchscreen firmware array with the one from THIS device.

The upstream tree ships a GSLX680_FW array for a different GSL variant (4,554 entries /
138 pages, "Aug 26 2016"). This device's controller wants 15,213 entries / 461 pages,
"Aug 12 2015", lifted out of the stock kernel by tools/gslx680/extract_gsl_fw.py.
Wrong firmware here means the touchscreen does not work at all.

Idempotent.
"""
import re, sys

HDR = "/src/linux/drivers/input/touchscreen/mediatek/gslX680/mtk_gslX680.h"
NEW = "/refs/gslx680/gslx680_fw_maic.h"
MARK = "extracted from this device's STOCK kernel"

src = open(HDR).read()
if MARK in src:
    print("  -> GSL firmware: already the MAIC blob")
    sys.exit(0)

new = open(NEW).read().strip()

pat = re.compile(r'static\s+const\s+struct\s+fw_data\s+GSLX680_FW\s*\[\]\s*=\s*\{.*?\n\};', re.S)
m = pat.search(src)
if not m:
    sys.exit("FAILED: GSLX680_FW[] not found in mtk_gslX680.h")

n_old = len(re.findall(r'\{0x[0-9a-fA-F]{1,2},\s*0x[0-9a-fA-F]+\}', m.group(0)))
n_new = len(re.findall(r'\{0x[0-9a-fA-F]{1,2},\s*0x[0-9a-fA-F]+\}', new))

open(HDR, "w").write(src[:m.start()] + new + src[m.end():])
print(f"  -> GSL firmware: replaced {n_old} upstream entries with {n_new} from this device")
