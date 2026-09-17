#!/bin/sh
# Stage 3 (v4.4.88) conflict resolutions. Run inside the tree after `git merge v4.4.88`.
set -e
R=/t/resolve.py
python3 $R arch/arm64/kernel/armv8_deprecated.c ours
python3 $R arch/arm64/kernel/entry.S both
python3 $R drivers/android/binder.c ours
python3 $R drivers/base/core.c theirs
python3 $R drivers/block/zram/zram_drv.c ours
python3 $R drivers/iommu/iommu.c theirs+ours
python3 $R drivers/irqchip/irq-gic-v3.c theirs+ours
python3 $R drivers/media/tuners/tuner-xc2028.c theirs
python3 $R drivers/staging/android/ion/ion.c ours
python3 $R drivers/usb/core/hcd.c theirs
python3 $R drivers/usb/gadget/function/f_mass_storage.c theirs
python3 $R fs/ext4/crypto.c theirs
python3 $R fs/ext4/namei.c ours
python3 $R kernel/fork.c ours
python3 $R kernel/printk/printk.c ours
python3 $R kernel/sched/sched.h ours
python3 $R mm/gup.c ours
python3 $R mm/vmscan.c ours
git show v4.4.88:drivers/usb/gadget/function/f_mass_storage.c > /tmp/fms88.c
python3 - <<'PY'
def sub(path, old, new, count=1):
    s = open(path).read(); n = s.count(old)
    assert n == count, f"{path}: expected {count} x {old[:60]!r}, found {n}"
    open(path, 'w').write(s.replace(old, new)); print(f"  {path}: edit ok")
# armv8_deprecated: vendor uaccess_* form + upstream 01ce16f40 zero-extension cast of addr
sub('arch/arm64/kernel/armv8_deprecated.c',
    '\t: "r" (addr), "i" (-EAGAIN), "i" (-EFAULT)\t\t\\\n',
    '\t: "r" ((unsigned long)addr), "i" (-EAGAIN),\t\t\\\n\t  "i" (-EFAULT)\t\t\t\t\t\t\\\n')
# binder: keep MTK RT_PRIO_INHERIT wake loop; apply upstream 1792d6c17 sync-wake hint in the #else path
sub('drivers/android/binder.c',
    '#else\n\tif (target_wait)\n\t\twake_up_interruptible(target_wait);\n#endif\n',
    '#else\n\tif (target_wait) {\n\t\tif (reply || !(t->flags & TF_ONE_WAY))\n\t\t\twake_up_interruptible_sync(target_wait);\n\t\telse\n\t\t\twake_up_interruptible(target_wait);\n\t}\n#endif\n')
# core.c: upstream class->shutdown (5c9a29729), vendor always-log style kept
sub('drivers/base/core.c', '\t\t\tif (initcall_debug)\n\t\t\t\tdev_info(dev, "shutdown\\n");\n',
    '\t\t\tif (1)\n\t\t\t\tdev_info(dev, "shutdown\\n");\n', count=2)
# zram: upstream 9286385a3 memcpy instead of copy_page, keep vendor MTK_ENG_BUILD guard bytes
sub('drivers/block/zram/zram_drv.c', '\tif (size == PAGE_SIZE)\n\t\tcopy_page(mem, cmem);\n#ifndef CONFIG_MTK_ENG_BUILD\n',
    '\tif (size == PAGE_SIZE)\n\t\tmemcpy(mem, cmem, PAGE_SIZE);\n#ifndef CONFIG_MTK_ENG_BUILD\n')
# ion: keep vendor diagnostics, but ret is not the error there -> print PTR_ERR(handle)
sub('drivers/staging/android/ion/ion.c',
    'IONMSG("ION_IOC_FREE handle is invalid. handle = %d, ret = %d.\\n", data.handle.handle, ret);',
    'IONMSG("ION_IOC_FREE handle is invalid. handle = %d, ret = %d.\\n", data.handle.handle, (int)PTR_ERR(handle));')
# f_mass_storage: auto-merged wakeup_thread is upstream lock-free smp_mb(); take upstream sleep_thread whole
s = open('drivers/usb/gadget/function/f_mass_storage.c').read()
u = open('/tmp/fms88.c').read()
def fn(t, name):
    a = t.index('static int sleep_thread(struct fsg_common *common, bool can_freeze)')
    b = t.index('\n}\n', a) + 3
    return a, b
a, b = fn(s, 1); ua, ub = fn(u, 1)
s = s[:a] + u[ua:ub] + s[b:]; open('drivers/usb/gadget/function/f_mass_storage.c', 'w').write(s)
print("  f_mass_storage.c: sleep_thread replaced with v4.4.88 version")
# fork.c: upstream 6052eb871 node-local idle task + vendor failure log
sub('kernel/fork.c', '\tp = dup_task_struct(current);\n\tif (!p) {\n', '\tp = dup_task_struct(current, node);\n\tif (!p) {\n')
# printk: upstream efa061998 rcuidle tracepoint, vendor CONSOLE_LOCK_DURATION_DETECT locals kept
sub('kernel/printk/printk.c', '\ttrace_console(text, len);\n', '\ttrace_console_rcuidle(text, len);\n')
# sched.h: upstream 62208707b removes account_reset_rq(); keep vendor MTK helpers around it
p = 'kernel/sched/sched.h'; s = open(p).read()
a = s.index('static inline void account_reset_rq(struct rq *rq)\n{'); b = s.index('\n}\n', a) + 3
s = s[:a] + s[b:]; open(p, 'w').write(s); print("  sched.h: account_reset_rq() removed")
# gup.c: Stack Clash 4b3594306 removes the stack guard page check; keep vendor FOLL_DURABLE
sub('mm/gup.c', '\t/* For mm_populate(), just skip the stack guard page. */\n\tif ((*flags & FOLL_POPULATE) &&\n\t\t\t(stack_guard_page_start(vma, address) ||\n\t\t\t stack_guard_page_end(vma, address + PAGE_SIZE)))\n\t\treturn -ENOENT;\n', '')
# vmscan.c: upstream 78f20db86 classzone underflow fix, vendor ZONE_MOVABLE skip kept
sub('mm/vmscan.c', '\t\tclasszone_idx = requested_highidx;\n', '\t\tclasszone_idx = gfp_zone(sc->gfp_mask);\n')
PY
