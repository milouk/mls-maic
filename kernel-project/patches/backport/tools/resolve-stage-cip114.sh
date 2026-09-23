#!/bin/sh
# Stage 11 (linux-4.4.y-cip @ cip114): merge the CIP SLTS continuation on top of v4.4.302,
# the last upstream 4.4 release. Run after:
#   git remote add cip https://git.kernel.org/pub/scm/linux/kernel/git/cip/linux-cip.git
#   git fetch cip linux-4.4.y-cip
#   git merge cip/linux-4.4.y-cip   # ~6900 commits, ~2700 files touched vs our tree
#
# Unlike prior stages (small point-release bumps), this is CIP's whole *stable continuation*
# of 4.4 -- effectively 4.4.303+ that upstream never shipped. Nearly all of it auto-merges
# clean (our tree only ever touched a handful of files CIP also touches). This script covers
# ONLY the files that needed a real decision; the rest is a plain `git merge`.
# See logs/stage-cip114.md.
set -e
R=/t/resolve.py

# --- take CIP outright (our manual work is superseded by the maintained fix) --------------
# rm10's hand-backported CVE-2025-38556 (s32ton) is exactly CIP's own fix; same for the
# CVE-2024-53197 usb-audio quirk. No conflict marker (auto-merged); noted for the record.

# --- merge: keep BOTH vendor and CIP tracepoints, not one or the other --------------------
# CIP's kernel/kthread.c gained trace_sched_kthread_work_{queue_work,execute_start,execute_end}
# (upstream commit 22597dc3d) which include/trace/events/sched.h must also define; the vendor
# tree carries its own unrelated Android-side tracepoints in the same file. Union, not a pick.
python3 $R include/trace/events/sched.h both

# --- keep vendor (CIP change is out of scope or actively wrong for this board) ------------
# arch/arm64/mm/proc.S, drivers/watchdog/mtk_wdt.c: vendor MTK-specific; no upstream 4.4.y-cip
# equivalent to merge into.
python3 $R arch/arm64/mm/proc.S ours
python3 $R drivers/watchdog/mtk_wdt.c ours
# net/ipv4/tcp.c, tcp_timer.c: vendor's configurable sysctl_tcp_rto_max (replaces upstream's
# hardcoded TCP_RTO_MAX) is a real, intentional feature -- keep it. NOTE tcp.c still picks up
# CIP's OTHER, unrelated fixes in the same file via the normal merge (out_of_order_queue ->
# RB_ROOT, a splice-read fix) since those don't touch the defer_accept lines; only the
# rskq_defer_accept hunk itself needs the vendor side.
python3 $R net/ipv4/tcp.c ours
python3 $R net/ipv4/tcp_timer.c ours
# drivers/mtd/ubi/wl.c: CIP's version needs a fastmap "fast_attach" struct member and a wider
# ubi_eba_copy_leb() signature that span drivers/mtd/ubi/{ubi.h,eba.c,...} -- a real upstream
# feature we would have to also pull those files for. This device has no raw NAND (eMMC only,
# CONFIG_MTD_UBI=y is unused generic-defconfig cruft), so it is not worth the blast radius.
python3 $R drivers/mtd/ubi/wl.c ours
# drivers/usb/gadget/function/{u_ether.c,rndis.c}: CIP's u_ether.c moved struct eth_dev out of
# the public u_ether.h (which our vendor tree still uses, extended, unchanged) -- a redefinition
# conflict. rndis.c's vendor version adds rndis_set_max_pkt_xfer(), an MTK throughput knob
# f_rndis.c calls directly; CIP has no equivalent. Keep the whole vendor USB-gadget-RNDIS
# pair together (android.c, f_rndis.c, u_ether.h are all still vendor/untouched by CIP here,
# so this keeps that cluster internally consistent rather than a version mix).
python3 $R drivers/usb/gadget/function/u_ether.c ours
python3 $R drivers/usb/gadget/function/rndis.c ours

# --- surgical: take CIP for the file, but hand-restore one vendor feature ------------------
# fs/ext4/mballoc.c: vendor threads a `blkdev_flags` (secure-discard) argument through
# ext4_trim_fs -> ext4_trim_all_free -> ext4_trim_extent -> ext4_issue_discard -> the final
# sb_issue_discard() flags arg. CIP's mballoc.c drops it (2-arg ext4_trim_fs). Taking CIP
# outright would desync fs/ext4/ext4.h's declaration and fs/ext4/ioctl.c's caller (both stay
# vendor/3-arg, unmodified) -- a silent cross-file break the merge itself won't flag, because
# ext4.h/ioctl.c don't conflict textually. Take CIP for the whole file (every other CIP fix in
# it, incl. a genuine count -> count_clusters overflow-fix rename at a second, unrelated
# ext4_issue_discard call site), then restore just these 4 signatures/bodies to the vendor
# 5-argument-deep threading below.
python3 $R fs/ext4/mballoc.c theirs
python3 - <<'PY'
def rd(p): return open(p, encoding='utf-8', errors='surrogateescape').read()
def wr(p, s): open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
def sub(path, old, new, count=1):
    s = rd(path); n = s.count(old)
    assert n == count, f"{path}: expected {count} x {old[:60]!r}, found {n}"
    wr(path, s.replace(old, new)); print(f"  {path}: edit ok")

sub('fs/ext4/mballoc.c',
    'static inline int ext4_issue_discard(struct super_block *sb,\n'
    '\t\text4_group_t block_group, ext4_grpblk_t cluster, int count)\n'
    '{\n'
    '\text4_fsblk_t discard_block;\n\n'
    '\tdiscard_block = (EXT4_C2B(EXT4_SB(sb), cluster) +\n'
    '\t\t\t ext4_group_first_block_no(sb, block_group));\n'
    '\tcount = EXT4_C2B(EXT4_SB(sb), count);\n'
    '\ttrace_ext4_discard_blocks(sb,\n'
    '\t\t\t(unsigned long long) discard_block, count);\n'
    '\treturn sb_issue_discard(sb, discard_block, count, GFP_NOFS, 0);\n'
    '}',
    'static inline int ext4_issue_discard(struct super_block *sb,\n'
    '\t\text4_group_t block_group, ext4_grpblk_t cluster, int count,\n'
    '\t\tunsigned long flags)\n'
    '{\n'
    '\text4_fsblk_t discard_block;\n\n'
    '\tdiscard_block = (EXT4_C2B(EXT4_SB(sb), cluster) +\n'
    '\t\t\t ext4_group_first_block_no(sb, block_group));\n'
    '\tcount = EXT4_C2B(EXT4_SB(sb), count);\n'
    '\ttrace_ext4_discard_blocks(sb,\n'
    '\t\t\t(unsigned long long) discard_block, count);\n'
    '\treturn sb_issue_discard(sb, discard_block, count, GFP_NOFS, flags);\n'
    '}')
sub('fs/ext4/mballoc.c',
    '\t\terr = ext4_issue_discard(sb, entry->efd_group,\n'
    '\t\t\t\t\t entry->efd_start_cluster,\n'
    '\t\t\t\t\t entry->efd_count);',
    '\t\terr = ext4_issue_discard(sb, entry->efd_group,\n'
    '\t\t\t\t\t entry->efd_start_cluster,\n'
    '\t\t\t\t\t entry->efd_count, 0);')
sub('fs/ext4/mballoc.c',
    '\t\t\terr = ext4_issue_discard(sb, block_group, bit,\n'
    '\t\t\t\t\t\t count_clusters);',
    '\t\t\terr = ext4_issue_discard(sb, block_group, bit,\n'
    '\t\t\t\t\t\t count_clusters, 0);')
sub('fs/ext4/mballoc.c',
    'static int ext4_trim_extent(struct super_block *sb, int start, int count,\n'
    '\t\t\t     ext4_group_t group, struct ext4_buddy *e4b)\n'
    '__releases(bitlock)\n'
    '__acquires(bitlock)\n'
    '{',
    'static int ext4_trim_extent(struct super_block *sb, int start, int count,\n'
    '\t\t\t    ext4_group_t group, struct ext4_buddy *e4b,\n'
    '\t\t\t    unsigned long blkdev_flags)\n'
    '__releases(bitlock)\n'
    '__acquires(bitlock)\n'
    '{')
sub('fs/ext4/mballoc.c',
    '\tret = ext4_issue_discard(sb, group, start, count);',
    '\tret = ext4_issue_discard(sb, group, start, count, blkdev_flags);')
sub('fs/ext4/mballoc.c',
    'ext4_trim_all_free(struct super_block *sb, ext4_group_t group,\n'
    '\t\t   ext4_grpblk_t start, ext4_grpblk_t max,\n'
    '\t\t   ext4_grpblk_t minblocks)\n'
    '{',
    'ext4_trim_all_free(struct super_block *sb, ext4_group_t group,\n'
    '\t\t   ext4_grpblk_t start, ext4_grpblk_t max,\n'
    '\t\t   ext4_grpblk_t minblocks, unsigned long blkdev_flags)\n'
    '{')
sub('fs/ext4/mballoc.c',
    '\t\t\tret = ext4_trim_extent(sb, start,\n'
    '\t\t\t\t\t       next - start, group, &e4b);',
    '\t\t\tret = ext4_trim_extent(sb, start,\n'
    '\t\t\t\t\t       next - start, group, &e4b,\n'
    '\t\t\t\t\t       blkdev_flags);')

# fs/ext4/mballoc.c took CIP's 2-arg ext4_trim_fs() too (the outer function, the top of the
# chain): same minimal-diff treatment as the other 3 -- add the @blkdev_flags doc line + the
# 3rd parameter, and thread it into the one internal ext4_trim_all_free() call. The rest of
# the (long) function body is byte-identical between vendor and CIP; nothing else to touch.
sub('fs/ext4/mballoc.c',
    ' * ext4_trim_fs() -- trim ioctl handle function\n'
    ' * @sb:\t\t\tsuperblock for filesystem\n'
    ' * @range:\t\tfstrim_range structure\n'
    ' *\n',
    ' * ext4_trim_fs() -- trim ioctl handle function\n'
    ' * @sb:\t\t\tsuperblock for filesystem\n'
    ' * @range:\t\tfstrim_range structure\n'
    ' * @blkdev_flags:\tflags for the block device\n'
    ' *\n')
sub('fs/ext4/mballoc.c',
    'int ext4_trim_fs(struct super_block *sb, struct fstrim_range *range)\n{',
    'int ext4_trim_fs(struct super_block *sb, struct fstrim_range *range,\n'
    '\t\t\tunsigned long blkdev_flags)\n{')
sub('fs/ext4/mballoc.c',
    '\t\t\tcnt = ext4_trim_all_free(sb, group, first_cluster,\n'
    '\t\t\t\t\t\tend, minlen);',
    '\t\t\tcnt = ext4_trim_all_free(sb, group, first_cluster,\n'
    '\t\t\t\t\t\tend, minlen, blkdev_flags);')
PY

# --- GCC-5.4 toolchain compatibility (not a merge conflict; a build-env fix) ---------------
# include/linux/overflow.h's check_{add,sub,mul}_overflow() (COMPILER_HAS_GENERIC_BUILTIN_
# OVERFLOW branch) use `(void) (&__a == &__b)` as a deliberate compile-time type-mismatch
# warning. GCC 5.4 has no per-diagnostic flag name for it (-Werror=compare-distinct-pointer-
# types is rejected outright, unlike on gcc7+), and legitimate callers this pulls in (e.g.
# lib/ts_kmp.c mixing size_t/unsigned) trip it. Strip just the 6 diagnostic-only lines (2 per
# macro x 3 macros); the actual __builtin_*_overflow() safety call is untouched, zero runtime
# effect. Leaves the #else fallback branch (6 macros, unsigned+signed variants) alone.
python3 - <<'PY'
def rd(p): return open(p, encoding='utf-8', errors='surrogateescape').read()
def wr(p, s): open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
p = 'include/linux/overflow.h'
s = rd(p)
for name in ('add', 'sub', 'mul'):
    old = (f"#define check_{name}_overflow(a, b, d) ({{\t\t\\\n"
           f"\ttypeof(a) __a = (a);\t\t\t\\\n"
           f"\ttypeof(b) __b = (b);\t\t\t\\\n"
           f"\ttypeof(d) __d = (d);\t\t\t\\\n"
           f"\t(void) (&__a == &__b);\t\t\t\\\n"
           f"\t(void) (&__a == __d);\t\t\t\\\n"
           f"\t__builtin_{name}_overflow(__a, __b, __d);\t\\\n"
           f"}})")
    new = old.replace("\t(void) (&__a == &__b);\t\t\t\\\n", "").replace("\t(void) (&__a == __d);\t\t\t\\\n", "")
    assert s.count(old) == 1, f"check_{name}_overflow anchor not found"
    s = s.replace(old, new)
wr(p, s)
print("overflow.h: stripped 6 GCC5-incompatible diagnostic lines")
PY

# --- excluded-directory desync: a header CIP touched, a vendor .c file outside our merge scope
# didn't ------------------------------------------------------------------------------------
# drivers/scsi/* was excluded from the whole-tree merge (SCSI is USB-mass-storage glue here,
# not primary storage), but shared headers under include/ were NOT excluded. CIP widened
# scsi_host_lookup()'s hostnum from u16 to u32 in include/scsi/scsi_host.h; drivers/scsi/
# hosts.c (still vendor/untouched) kept the old u16 signature AND a local pointer cast to
# `const unsigned short *` in __scsi_host_match() that would silently truncate the wider
# value -- a real latent bug, not just a compile error. Widen both call sites to u32.
python3 - <<'PY'
def rd(p): return open(p, encoding='utf-8', errors='surrogateescape').read()
def wr(p, s): open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
def sub(path, old, new, count=1):
    s = rd(path); n = s.count(old)
    assert n == count, f"{path}: expected {count} x {old[:60]!r}, found {n}"
    wr(path, s.replace(old, new)); print(f"  {path}: edit ok")
sub('drivers/scsi/hosts.c', 'const unsigned short *hostnum = data;', 'const unsigned int *hostnum = data;')
sub('drivers/scsi/hosts.c', 'struct Scsi_Host *scsi_host_lookup(unsigned short hostnum)', 'struct Scsi_Host *scsi_host_lookup(unsigned int hostnum)')
PY

# Gates
n=$(grep -rl '^<<<<<<< HEAD' . 2>/dev/null | wc -l); echo "conflict markers remaining (tree-wide): $n"
[ "$n" -eq 0 ] || { grep -rl '^<<<<<<< HEAD' .; exit 1; }
grep -q 'sysctl_tcp_rto_max' net/ipv4/tcp.c || exit 1
grep -q 'sysctl_tcp_rto_max' net/ipv4/tcp_timer.c || exit 1
[ "$(grep -c 'blkdev_flags' fs/ext4/mballoc.c)" -ge 6 ] || { echo "mballoc.c: vendor discard-flags chain incomplete"; exit 1; }
grep -q 'ext4_trim_fs(struct super_block \*sb, struct fstrim_range \*range,' fs/ext4/mballoc.c || exit 1
! grep -q '(void) (&__a == &__b)' <(sed -n '1,68p' include/linux/overflow.h) || { echo "overflow.h: diagnostic lines still in the active branch"; exit 1; }
grep -q 'scsi_host_lookup(unsigned int hostnum)' drivers/scsi/hosts.c || exit 1
grep -c 'trace_sched_kthread_work' /dev/null >/dev/null 2>&1; grep -q 'sched_kthread_work_execute_start' include/trace/events/sched.h || exit 1
echo "stage-cip114 resolve: all gates passed"
