#!/bin/sh
# Stage 7 (v4.4.210) conflict resolutions. Run inside the tree after `git merge v4.4.210`.
# 12 files. Not built on this board: arch/arm (3 files), userfaultfd (CONFIG off) -- those still
# get a compilable, correct resolution. See logs/stage-v4.4.210.md for per-block rationale.
set -e
R=/t/resolve.py

python3 $R arch/arm/include/asm/cputype.h theirs
python3 $R arch/arm/kernel/smp.c theirs
python3 $R arch/arm/mm/fault.c theirs
# afd3db1ca: the auto-merged body is already the jiffies-bounded do/while (vendor TIMESTAMP_REC
# retained inside it) and `int i` is gone -> the vendor `for` header cannot stand.
python3 $R arch/arm64/kernel/psci.c theirs
# bf0313653: cpuid_feature_extract_field() is now (features, field, sign); vendor's 2-arg call no
# longer compiles. Take the _unsigned_field form, but with the vendor SYS_-encoded register name
# (this tree's read_cpuid() is the mrs_s variant; bare ID_AA64MMFR0_EL1 is undefined) -- PY below.
python3 $R arch/arm64/mm/context.c theirs
# c53c1a821/5280efe44 %p -> %pK: apply to both branches of the vendor BINDER_MONITOR block (PY).
python3 $R drivers/android/binder.c ours
# 8e0a4c101 SMCCC rewrite auto-merged (arm-smccc.h, smccc-call.S, conduit all present); only the
# include lines conflicted.
python3 $R drivers/firmware/psci.c both
# 05d90b19b moved put_mtd_device() after the frees; the relocated call already auto-merged, so
# the vendor's early call must go or the ref is dropped twice (PY).
python3 $R drivers/mtd/ubi/build.c ours
# b30c56ee0 UAF on unregister: cancel_delayed_work_sync() over a vendor commented-out line.
python3 $R drivers/thermal/thermal_core.c theirs
# a6af40896: wrappers, spin_lock_init and gi->unbind all auto-merged. Struct fields: both. Driver
# template: keep the vendor CONFIG_USB_CONFIGFS_UEVENT structure but route BOTH paths through the
# locked configfs_composite_* wrappers (the UEVENT android_setup/android_disconnect call them
# instead of composite_*), as AOSP did. UEVENT is off here, so the compiled path == upstream's.
python3 $R drivers/usb/gadget/configfs.c both,ours
# 858cfbe83 still_valid block, with the vendor 7th vma_merge() argument (anon-vma name) (PY).
python3 $R fs/userfaultfd.c theirs
# 3d45ad0bc check_target(e, net, name): keep the vendor-retained check_entry() helper (still
# called twice), drop the old check_target signature line (PY).
python3 $R net/ipv4/netfilter/arp_tables.c both

python3 - <<'PY'
import re
def rd(p): return open(p, encoding='utf-8', errors='surrogateescape').read()
def wr(p, s): open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
def sub(path, old, new, count=1):
    s = rd(path); n = s.count(old)
    assert n == count, f"{path}: expected {count} x {old[:60]!r}, found {n}"
    wr(path, s.replace(old, new)); print(f"  {path}: edit ok")
def resub(path, pat, new, flags=re.M):
    s = rd(path); m = re.findall(pat, s, flags=flags)
    assert len(m) == 1, f"{path}: regex {pat[:50]!r} matched {len(m)}x"
    wr(path, re.sub(pat, new, s, count=1, flags=flags)); print(f"  {path}: regex edit ok")

sub('arch/arm64/mm/context.c', 'read_cpuid(ID_AA64MMFR0_EL1)', 'read_cpuid(SYS_ID_AA64MMFR0_EL1)')

sub('drivers/android/binder.c', 'data %p auf %d start', 'data %pK auf %d start')
sub('drivers/android/binder.c', 'seq_printf(m, " size %zd:%zd data %p\\n",', 'seq_printf(m, " size %zd:%zd data %pK\\n",')

sub('drivers/mtd/ubi/build.c',
    '\tput_mtd_device(ubi->mtd);\n#ifdef CONFIG_MTD_UBI_LOWPAGE_BACKUP\n',
    '#ifdef CONFIG_MTD_UBI_LOWPAGE_BACKUP\n')

# configfs: template ops
resub('drivers/usb/gadget/configfs.c',
      r'\.setup\s*=\s*composite_setup,\n(\s*)\.reset\s*=\s*composite_disconnect,\n(\s*)\.disconnect\s*=\s*composite_disconnect,\n#endif\n(\s*)\.suspend\s*=\s*composite_suspend,\n(\s*)\.resume\s*=\s*composite_resume,\n',
      r'.setup          = configfs_composite_setup,\n\1.reset          = configfs_composite_disconnect,\n\2.disconnect     = configfs_composite_disconnect,\n#endif\n\3.suspend\t= configfs_composite_suspend,\n\4.resume\t\t= configfs_composite_resume,\n')
# configfs: the UEVENT android_* wrappers go through the locked wrappers too
sub('drivers/usb/gadget/configfs.c', 'value = composite_setup(gadget, c);', 'value = configfs_composite_setup(gadget, c);')
resub('drivers/usb/gadget/configfs.c',
      r'(static void android_disconnect\(struct usb_gadget \*gadget\)\n\{.*?)\tcomposite_disconnect\(gadget\);',
      r'\1\tconfigfs_composite_disconnect(gadget);', flags=re.S)

sub('fs/userfaultfd.c',
    '\t\t\t\t\t NULL_VM_UFFD_CTX);\n',
    '\t\t\t\t\t NULL_VM_UFFD_CTX,\n\t\t\t\t\t vma_get_anon_name(vma));\n')

sub('net/ipv4/netfilter/arp_tables.c',
    'static inline int check_target(struct arpt_entry *e, const char *name)\n', '')
PY

# Gates (tree-wide, no extension filter) + structural checks the compiler reports late.
n=$(grep -rl '^<<<<<<< HEAD' . | wc -l); echo "conflict markers remaining (tree-wide): $n"
[ "$n" -eq 0 ] || { grep -rl '^<<<<<<< HEAD' .; exit 1; }
[ "$(grep -c 'put_mtd_device(ubi->mtd)' drivers/mtd/ubi/build.c)" -eq 1 ] || { echo "ubi put_mtd_device count != 1"; exit 1; }
[ "$(grep -c '^static.*check_target(' net/ipv4/netfilter/arp_tables.c)" -eq 1 ] || { echo "arp_tables check_target defs != 1"; exit 1; }
grep -q 'configfs_composite_setup(gadget, c)' drivers/usb/gadget/configfs.c || exit 1
grep -q 'SYS_ID_AA64MMFR0_EL1), *$' arch/arm64/mm/context.c || grep -q 'SYS_ID_AA64MMFR0_EL1),' arch/arm64/mm/context.c || exit 1
echo "stage-210 resolve: all gates passed"
