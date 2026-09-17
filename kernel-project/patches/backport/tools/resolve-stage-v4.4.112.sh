#!/bin/sh
# Stage 4 (v4.4.112) conflict resolutions. Run inside the tree after `git merge v4.4.112`.
set -e
R=/t/resolve.py
python3 $R arch/arm/mm/init.c theirs
python3 $R drivers/base/cpu.c both
python3 $R drivers/mmc/host/mtk-sd.c ours
python3 $R drivers/mtd/nand/nand_base.c ours
python3 $R drivers/usb/gadget/function/f_mass_storage.c theirs
python3 $R kernel/power/process.c both
python3 $R net/ipv4/raw.c ours
python3 - <<'PY'
def sub(path, old, new, count=1):
    s = open(path).read(); n = s.count(old)
    assert n == count, f"{path}: expected {count} x {old[:60]!r}, found {n}"
    open(path, 'w').write(s.replace(old, new)); print(f"  {path}: edit ok")
# nand: upstream c8ea49b69 moved the ready-wait after select_chip (auto-merged); keep MTK clock enable, drop early wait
sub('drivers/mtd/nand/nand_base.c',
    '#ifdef CONFIG_MTK_MTD_NAND\n\tnand_enable_clock();\n#endif\n\t/* Wait for the device to get ready */\n\tpanic_nand_wait(mtd, chip, 400);\n\n',
    '#ifdef CONFIG_MTK_MTD_NAND\n\tnand_enable_clock();\n#endif\n')
# raw.c: upstream be27b620a READ_ONCE(hdrincl) race fix + vendor Android UID routing arg
sub('net/ipv4/raw.c', '(inet->hdrincl ? FLOWI_FLAG_KNOWN_NH : 0),', '(hdrincl ? FLOWI_FLAG_KNOWN_NH : 0),')
PY
