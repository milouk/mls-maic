#!/bin/sh
# Stage 5 (v4.4.145) conflict resolutions. Run inside the tree after `git merge v4.4.145`.
#
# Reproduces trial commit 3b7dcb12c exactly (build-verified, see logs/stage-v4.4.145.md).
#
# This stage pulls in the Fastmap attach rework (6fdca47fc + friends) and the Spectre v4 /
# SSB prctl infrastructure. CONFIG_MTD_UBI_FASTMAP and CONFIG_MTK_SLC_BUFFER_SUPPORT are
# both off on this board, but the UBI auto-merge had already woven fastmap plumbing (the
# `ai->fastmap` list, `erase_aeb()`, balanced `fm_eba_sem` locking) through large
# UNconflicted parts of wl.c/attach.c. Every pick below was made by reading the surrounding
# already-merged code -- NOT by the v4.4.50 precedent ("keep vendor whole file"), which does
# not hold here: several choices are compile / lock-balance requirements, not preferences.
#
# Two lessons this stage cost a build each:
#  * `both` is NOT safe when git split a block mid-construct (a `\`-continued #define, a
#    `.macro` whose `.endm` sat in the shared suffix, a `case:` with its `break;` in the
#    suffix, an `if {` whose `}` was shared). Read the shared prefix/suffix before picking
#    `both`; the fix-ups in the PY block below are exactly those cases.
#  * A marker grep filtered to *.c/*.h/*.S misses Kconfig. The gate at the end is
#    tree-wide, no extension filter.
set -e
R=/t/resolve.py

python3 $R kernel/sys.c both,both
python3 $R kernel/auditsc.c theirs
python3 $R kernel/sched/rt.c theirs+ours
python3 $R drivers/staging/android/ion/ion_heap.c ours
python3 $R drivers/usb/gadget/u_f.c ours
python3 $R drivers/usb/gadget/composite.c ours
# wl.c block 3 stays vendor: upstream's text names locals (vol_id, lnum) this vendor
# function doesn't have, and its `if (err1) {` consumes the single shared `}` leaving the
# outer `if` open (cascaded into "invalid storage class for function" for the rest of the
# file). Blocks 2 and 6 MUST be theirs: 2 balances four already-merged up_read()s, 6 closes
# the already-merged fastmap loop.
python3 $R drivers/mtd/ubi/wl.c theirs,theirs,ours,theirs,theirs,theirs
python3 $R drivers/mtd/ubi/ubi.h both
python3 $R drivers/mtd/ubi/attach.c ours,both,both,both,ours
python3 $R include/uapi/linux/prctl.h both
python3 $R include/linux/sched.h both,both
python3 $R arch/x86/include/asm/thread_info.h theirs
python3 $R arch/arm64/include/asm/assembler.h both,ours,both
# memory.h: take upstream's overflow-safe VA_START/PAGE_OFFSET form (28dae08f1; numerically
# identical at every VA_BITS), then restore the vendor LAYOUT below it in the PY block --
# this tree carries a backported 4.6-style layout (KIMAGE_VADDR = MODULES_END, modules at
# VA_START + KASAN) that arch/arm64/kernel/setup.c and aee/mrdump depend on.
python3 $R arch/arm64/include/asm/memory.h theirs
python3 $R arch/arm64/include/asm/bug.h theirs
python3 $R arch/arm64/include/asm/cputype.h both,both
python3 $R arch/arm64/mm/mmu.c both
python3 $R fs/proc/base.c theirs
python3 $R net/xfrm/xfrm_user.c theirs
python3 $R net/ipv6/route.c both
python3 $R net/ipv4/netfilter/arp_tables.c ours
# Kconfig: independent additive symbols. HAVE_EBPF_JIT is mandatory (arch/arm64/Kconfig
# already auto-merged a `select HAVE_EBPF_JIT`); ARM64_ERRATUM_1024718 pairs with the
# cpu_midr_match macro taken in assembler.h.
python3 $R arch/arm64/Kconfig both
python3 $R net/Kconfig both

python3 - <<'PY'
import re
def rd(p): return open(p, encoding='utf-8', errors='surrogateescape').read()
def wr(p, s): open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
def sub(path, old, new, count=1):
    s = rd(path); n = s.count(old)
    assert n == count, f"{path}: expected {count} x {old[:60]!r}, found {n}"
    wr(path, s.replace(old, new)); print(f"  {path}: edit ok")
def resub(path, pat, new):
    s = rd(path); m = re.findall(pat, s, flags=re.M)
    assert len(m) == 1, f"{path}: regex {pat[:50]!r} matched {len(m)}x"
    wr(path, re.sub(pat, new, s, flags=re.M)); print(f"  {path}: regex edit ok")

# ion_heap.c: keep vendor's diagnostic log, adopt upstream 58fcaeb30's ERR_PTR return.
sub('drivers/staging/android/ion/ion_heap.c',
    '\tif (!pages) {\n\t\tIONMSG("%s vmalloc failed pages is null.\\n", __func__);\n\t\treturn NULL;\n\t}\n',
    '\tif (!pages) {\n\t\tIONMSG("%s vmalloc failed pages is null.\\n", __func__);\n\t\treturn ERR_PTR(-ENOMEM);\n\t}\n')

# u_f.c: 'ours' kept the vendor #if/#else/#endif GFP_DMA skeleton (its #endif is shared and
# orphans otherwise). Add upstream 3b48ece37's OUT-endpoint alignment ahead of it.
sub('drivers/usb/gadget/u_f.c',
    '\t\treq->length = len ?: default_len;\n#if defined(CONFIG_64BIT) && defined(CONFIG_MTK_LM_MODE)\n',
    '\t\treq->length = len ?: default_len;\n\t\tif (usb_endpoint_dir_out(ep->desc))\n\t\t\treq->length = usb_ep_align(ep, req->length);\n#if defined(CONFIG_64BIT) && defined(CONFIG_MTK_LM_MODE)\n')

# composite.c: same skeleton reason; USB_COMP_EP0_OS_DESC_BUFSIZ == 4096 (825c1ae06).
sub('drivers/usb/gadget/composite.c',
    'cdev->os_desc_req->buf = kmalloc(4096, GFP_KERNEL | GFP_DMA);\n#else\n\tcdev->os_desc_req->buf = kmalloc(4096, GFP_KERNEL);\n#endif\n',
    'cdev->os_desc_req->buf = kmalloc(USB_COMP_EP0_OS_DESC_BUFSIZ, GFP_KERNEL | GFP_DMA);\n#else\n\tcdev->os_desc_req->buf = kmalloc(USB_COMP_EP0_OS_DESC_BUFSIZ, GFP_KERNEL);\n#endif\n')

# attach.c block 2: vendor SLC preamble (inert, config off) + upstream's fastmap branch.
sub('drivers/mtd/ubi/attach.c',
    '#ifdef CONFIG_MTK_SLC_BUFFER_SUPPORT\n\tif (istlc && ubi->mtbl == NULL)\n\t\tubi_change_empty_ec(ubi, pnum, (int)ec, vol_id, 1);\n#endif\n\terr = ubi_add_to_av(ubi, ai, pnum, ec, vidh, bitflips);\n',
    '#ifdef CONFIG_MTK_SLC_BUFFER_SUPPORT\n\tif (istlc && ubi->mtbl == NULL)\n\t\tubi_change_empty_ec(ubi, pnum, (int)ec, vol_id, 1);\n#endif\n\tif (ubi_is_fm_vol(vol_id))\n\t\terr = add_fastmap(ai, pnum, vidh, ec);\n\telse\n\t\terr = ubi_add_to_av(ubi, ai, pnum, ec, vidh, bitflips);\n')

# attach.c block 3: scan_peb()'s real signature is (ubi, ai, pnum, bool fast) -- the vendor
# 5-arg call no longer compiles.
sub('drivers/mtd/ubi/attach.c', 'err = scan_peb(ubi, ai, pnum, NULL, NULL);\n', 'err = scan_peb(ubi, ai, pnum, false);\n')

# wl.c erase_aeb() (auto-merged upstream code): 2-arg wl_tree_add vs vendor 3-arg (ubi, e, root).
sub('drivers/mtd/ubi/wl.c', 'wl_tree_add(e, &ubi->free);', 'wl_tree_add(ubi, e, &ubi->free);')

# cputype.h: upstream renamed MIDR_CPU_MODEL -> MIDR_CPU_PART (identical body) and git split
# the block on the `\`-continued first line, so `both` glued it onto the next #define. Drop
# the dangling line; alias the vendor name (three MIDR_CORTEX_* users remain).
sub('arch/arm64/include/asm/cputype.h',
    '#define MIDR_CPU_MODEL(imp, partnum) \\\n#define MIDR_CPU_VAR_REV(var, rev) \\\n',
    '#define MIDR_CPU_VAR_REV(var, rev) \\\n')
sub('arch/arm64/include/asm/cputype.h',
    '#define MIDR_CPU_MODEL_MASK (',
    '/* vendor name for upstream MIDR_CPU_PART (renamed in 4.4.145, identical body) */\n#define MIDR_CPU_MODEL(imp, partnum) MIDR_CPU_PART(imp, partnum)\n\n#define MIDR_CPU_MODEL_MASK (')

# sys.c: the shared suffix held PR_SET_VMA's break; `both` made it fall through into the new
# SSB cases and clobber `error`.
sub('kernel/sys.c',
    '\tcase PR_SET_VMA:\n\t\terror = prctl_set_vma(arg2, arg3, arg4, arg5);\n\tcase PR_GET_SPECULATION_CTRL:\n',
    '\tcase PR_SET_VMA:\n\t\terror = prctl_set_vma(arg2, arg3, arg4, arg5);\n\t\tbreak;\n\tcase PR_GET_SPECULATION_CTRL:\n')

# assembler.h: shared prefix was the `/*` opener, shared suffix the `.endm` -- so `both` left
# post_ttbr0_update_workaround unterminated and upstream's comment body without its `/*`.
sub('arch/arm64/include/asm/assembler.h',
    'alternative_endif\n#endif\n * Check the MIDR_EL1 of the current CPU',
    'alternative_endif\n#endif\n\t.endm\n\n/*\n * Check the MIDR_EL1 of the current CPU')

# memory.h: restore vendor layout under upstream's overflow-safe VA_START/PAGE_OFFSET.
resub('arch/arm64/include/asm/memory.h',
      r'^#define MODULES_END\s+\(PAGE_OFFSET\)\n#define MODULES_VADDR\s+\(MODULES_END - SZ_64M\)\n#define PCI_IO_END\s+\(MODULES_VADDR - SZ_2M\)\n',
      '#define KIMAGE_VADDR\t\t(MODULES_END)\n#define MODULES_END\t\t(MODULES_VADDR + MODULES_VSIZE)\n#define MODULES_VADDR\t\t(VA_START + KASAN_SHADOW_SIZE)\n#define MODULES_VSIZE\t\t(SZ_128M)\n#define PCI_IO_END\t\t(PAGE_OFFSET - SZ_2M)\n')
PY

# Gate: tree-wide, NO extension filter (Kconfig files carry markers too).
n=$(grep -rl '^<<<<<<< HEAD' . | wc -l)
echo "conflict markers remaining (tree-wide): $n"
[ "$n" -eq 0 ] || { grep -rl '^<<<<<<< HEAD' .; exit 1; }
# Structural sanity that the compiler would only report late:
am=$(grep -c '^\s*\.macro' arch/arm64/include/asm/assembler.h); ae=$(grep -c '^\s*\.endm' arch/arm64/include/asm/assembler.h)
echo "assembler.h .macro=$am .endm=$ae (expect macro = endm+1: the regs_to_64 BE/LE pair share one .endm)"
[ "$am" -eq $((ae + 1)) ] || exit 1
