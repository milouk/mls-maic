#!/bin/sh
# Stage 2 (v4.4.50) conflict resolutions. Run inside /src/linux after `git merge v4.4.50`.
set -e
R=/t/resolve.py
python3 $R arch/arm64/include/asm/futex.h ours
python3 $R arch/arm64/include/asm/processor.h theirs
python3 $R drivers/android/binder.c ours
git checkout --ours drivers/mtd/ubi/wl.c
python3 $R drivers/usb/gadget/function/u_ether.c theirs
python3 $R drivers/usb/host/xhci.h both
python3 $R drivers/usb/host/xhci-mem.c ours
python3 $R fs/namespace.c theirs
python3 $R net/wireless/scan.c theirs
python3 - <<'PY'
import re
def sub(path, old, new, count=1):
    s = open(path).read()
    n = s.count(old)
    assert n == count, f"{path}: expected {count} of {old!r}, found {n}"
    open(path, 'w').write(s.replace(old, new)); print(f"  {path}: {old.strip()[:50]!r} -> {new.strip()[:50]!r}")
# arm64: vendor already has the 4.10-style uaccess_enable()/uaccess_disable(); upstream 55e15b2f4's
# inline PAN toggles were auto-merged inside that pair in futex_atomic_cmpxchg_inatomic -> drop them.
p='arch/arm64/include/asm/futex.h'; s=open(p).read()
s2=re.sub(r'\nALTERNATIVE\("nop", SET_PSTATE_PAN\([01]\), ARM64_HAS_PAN, CONFIG_ARM64_PAN\)\n', '\n', s)
dropped = s.count('SET_PSTATE_PAN') - s2.count('SET_PSTATE_PAN')
assert dropped == 1, f"expected to drop exactly 1 PAN line (PAN(1) was inside the conflict block resolved to ours), dropped {dropped}"
open(p,'w').write(s2); print("  futex.h: dropped redundant inline SET_PSTATE_PAN(0) (vendor uaccess_* already toggles PAN)")
# arm64: upstream da643dc17 makes capability enable() return int (called via stop_machine);
# vendor's backported UAO enable must follow or stop_machine reads a garbage return value.
sub('arch/arm64/include/asm/processor.h', 'int cpu_enable_pan(void *__unused);\n', 'int cpu_enable_pan(void *__unused);\nint cpu_enable_uao(void *__unused);\n')
sub('arch/arm64/mm/fault.c', 'void cpu_enable_uao(void *__unused)\n{\n\tasm(SET_PSTATE_UAO(1));\n}', 'int cpu_enable_uao(void *__unused)\n{\n\tasm(SET_PSTATE_UAO(1));\n\treturn 0;\n}')
# xhci (not built): keep vendor MTK SRAM structure but honour upstream b07b4fa72 (use passed-in GFP flags)
p='drivers/usb/host/xhci-mem.c'; s=open(p).read()
for a in ('xhci->dcbaa = dma_alloc_coherent(dev, sizeof(*xhci->dcbaa), &dma,\n\t\t\tGFP_KERNEL);',
          'sizeof(struct xhci_erst_entry) * ERST_NUM_SEGS, &dma,\n\t\t\tGFP_KERNEL);'):
    k = s.count(a); s = s.replace(a, a.replace('GFP_KERNEL', 'flags')); print(f"  xhci-mem.c: GFP_KERNEL->flags x{k}")
open(p,'w').write(s)
# namespace.c: upstream race fix structure, keep vendor GFP_NOFS (callers hold the inode lock)
sub('fs/namespace.c', '\t\tnew = kmalloc(sizeof(struct mountpoint), GFP_KERNEL);',
    '\t\t/* MAIC: GFP_NOFS kept from the vendor tree: callers hold i_mutex, so do not\n\t\t * recurse into filesystem code (lockdep). */\n\t\tnew = kmalloc(sizeof(struct mountpoint), GFP_NOFS);')
# cfg80211 scan.c: take upstream bss_entries_limit (DoS fix), keep vendor 7s scan-result expiry
sub('net/wireless/scan.c', '#define IEEE80211_SCAN_RESULT_EXPIRE\t(30 * HZ)', '#define IEEE80211_SCAN_RESULT_EXPIRE\t(7 * HZ)\t/* MAIC: vendor value kept */')
PY
