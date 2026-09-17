#!/bin/sh
# Stage 9 (v4.4.270) conflict resolutions. Run inside the tree after `git merge v4.4.270`.
# 3 files, all on boot-critical hardware paths. See logs/stage-v4.4.270.md.
set -e
R=/t/resolve.py

# head.S: the vendor __mmap_switched is a backported 4.6-style version (CONFIG_RELOCATABLE
# relocation loop, kimage_vaddr) that upstream 4.4's BSS-clear tail must not replace. But
# 51a5438ce made adr_l a 2-argument macro (auto-merged into assembler.h), and the vendor's
# `adr_l sp, initial_sp, x4` is the tree's only 3-argument use -> apply upstream's exact
# replacement for that one line inside the vendor structure (PY below).
python3 $R arch/arm64/kernel/head.S ours
# mmc.c: keep the vendor 4x partition-switch margin ("extra 4 times for some timeout cases").
# bf67be879's real fix -- fall back to generic_cmd6_time when PART_SWITCH_TIME is 0, then clamp
# to MMC_MIN_PART_SWITCH_TIME -- already auto-merged below; the vendor's early clamp is
# merely redundant with it.
python3 $R drivers/mmc/core/mmc.c ours
# mtk-sd.c (this board's eMMC host): faac963f9 is the proper fix for the timeout-vs-IRQ race;
# `bool ret` is gone from the auto-merged prefix so the vendor guard cannot compile, and with
# the claim-under-lock in msdc_cmd_done()/msdc_data_xfer_done() (auto-merged) the vendor's
# in_interrupt() early return could leave a claimed request never completed. All three
# msdc_request_done() callers are the upstream ones (checked).
python3 $R drivers/mmc/host/mtk-sd.c theirs

python3 - <<'PY'
def rd(p): return open(p, encoding='utf-8', errors='surrogateescape').read()
def wr(p, s): open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
def sub(path, old, new, count=1):
    s = rd(path); n = s.count(old)
    assert n == count, f"{path}: expected {count} x {old[:60]!r}, found {n}"
    wr(path, s.replace(old, new)); print(f"  {path}: edit ok")
sub('arch/arm64/kernel/head.S',
    '\tadr_l\tsp, initial_sp, x4\n',
    '\tadrp\tx4, initial_sp\n\tadd\tsp, x4, :lo12:initial_sp\n')
PY

# Files that did NOT conflict but auto-merged inconsistently (zram pages_compacted became an
# atomic_long_t; the vendor /proc/zraminfo reader still used the raw field). Idempotent.
python3 /t/fixups-stage-v4.4.270.py

# Gates
n=$(grep -rl '^<<<<<<< HEAD' . | wc -l); echo "conflict markers remaining (tree-wide): $n"
[ "$n" -eq 0 ] || { grep -rl '^<<<<<<< HEAD' .; exit 1; }
# no 3-argument adr_l anywhere (the macro is 2-argument now)
if grep -rn '^\s*adr_l\s' --include='*.S' arch/arm64 | grep -E 'adr_l[^,]*,[^,]*,'; then echo "3-arg adr_l remains"; exit 1; fi
grep -q 'part_time = 40 \* ext_csd\[EXT_CSD_PART_SWITCH_TIME\]' drivers/mmc/core/mmc.c || exit 1
grep -q 'card->ext_csd.part_time = card->ext_csd.generic_cmd6_time' drivers/mmc/core/mmc.c || { echo "mmc.c: upstream generic_cmd6_time fallback missing"; exit 1; }
# the vendor guard was `if (!ret && in_interrupt())` in msdc_request_done(); other vendor code
# in this file legitimately uses in_interrupt() elsewhere, so check the guard text itself.
! grep -q 'if (!ret && in_interrupt())' drivers/mmc/host/mtk-sd.c || { echo "mtk-sd.c: vendor in_interrupt guard still present"; exit 1; }
grep -q 'No need check the return value of cancel_delayed_work' drivers/mmc/host/mtk-sd.c || { echo "mtk-sd.c: upstream request_done fix missing"; exit 1; }
echo "stage-270 resolve: all gates passed"
