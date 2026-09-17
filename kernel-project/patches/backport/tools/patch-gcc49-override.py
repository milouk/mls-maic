#!/usr/bin/env python3
"""Tree patch (NOT a conflict resolution), applied as its own "maic:" commit after the
v4.4.270 merge.

Upstream 6eedcd638 ("compiler.h: Raise minimum version of GCC to 5.1 for arm64", 4.4.y
backport of dca5244d2f5b) turns include/linux/compiler-gcc.h into a hard #error for
GCC < 5.1 on arm64, because GCC 4.9.x can emit stack references beyond an already-adjusted
stack pointer (GCC bug 63293) -- subtle data corruption if an interrupt lands in that
window; reported upstream as ext4 corruption.

This project's only known-bootable toolchain is the AOSP aarch64-linux-android-4.9
(4.9.x 20150123 prerelease); the stock kernel was built with the same GCC and carries the
same exposure. The check is kept intact; it is bypassed ONLY when the build explicitly
passes -DMAIC_ALLOW_GCC49 (build-m49.sh does, and says why). Remove the define and the
#error bites again. Idempotent.
"""
P = 'include/linux/compiler-gcc.h'
OLD = '#elif defined(CONFIG_ARM64) && GCC_VERSION < 50100 && !defined(__clang__)\n'
NEW = ('#elif defined(CONFIG_ARM64) && GCC_VERSION < 50100 && !defined(__clang__) && \\\n'
       '\t!defined(MAIC_ALLOW_GCC49)\n'
       '/*\n'
       ' * MAIC: the AOSP GCC 4.9 is the only toolchain known to produce a bootable kernel\n'
       ' * for this board (stock was built with it too). -DMAIC_ALLOW_GCC49 is an explicit,\n'
       ' * build-time acknowledgement of the GCC bug 63293 exposure described below.\n'
       ' */\n')
s = open(P, encoding='utf-8', errors='surrogateescape').read()
if NEW in s:
    print(f"  {P}: already applied")
else:
    assert s.count(OLD) == 1, f"{P}: expected the arm64 GCC<5.1 check exactly once"
    open(P, 'w', encoding='utf-8', errors='surrogateescape').write(s.replace(OLD, NEW))
    print(f"  {P}: GCC 4.9 override hook applied")
