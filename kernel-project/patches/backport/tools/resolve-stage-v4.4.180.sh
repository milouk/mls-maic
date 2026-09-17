#!/bin/sh
# Stage 6 (v4.4.180) conflict resolutions. Run inside the tree after `git merge v4.4.180`.
# 19 files. Not built on this board (arm64, no UFS, no KDB): arch/arm, arch/x86, ufshcd.c,
# kdb_io.c -- those take upstream (kdb keeps a compilable hybrid since vendor uses last_crlf).
# See logs/stage-v4.4.180.md for per-block rationale.
set -e
R=/t/resolve.py

python3 $R arch/arm/kernel/smp.c theirs
# cap numbering: vendor 8,9,10,12 has a gap at 11 -> ARM64_HAS_32BIT_EL0 = 11, NCAPS stays 13.
python3 $R arch/arm64/include/asm/cpufeature.h ours
# both entries of arm64_features[]; the shared prefix is the opening `{`, so the 32-bit EL0
# entry needs its own `{` re-inserted (PY below).
python3 $R arch/arm64/kernel/cpufeature.c both
# keep vendor hook_fault_code(); take a930f8ce2's renamed parameter (body already uses it).
python3 $R arch/arm64/mm/fault.c ours
# vendor has the newer sync_icache_aliases() structure; apply 029b5be50's intent (drop the
# page_mapping early-out -- anon pages can be executable) in the PY block, not its 4.4 text.
python3 $R arch/arm64/mm/flush.c ours
# vendor pfn_valid already checks the upper PAGE_SHIFT bits AND uses the NOMAP-aware
# memblock_is_map_memory(); upstream 355cccb65 is the older memblock_is_memory() form.
python3 $R arch/arm64/mm/init.c ours
python3 $R arch/x86/include/asm/uaccess.h theirs
python3 $R arch/x86/include/asm/uaccess_32.h theirs
python3 $R arch/x86/include/asm/uaccess_64.h theirs
python3 $R drivers/base/power/main.c both
python3 $R drivers/scsi/ufs/ufshcd.c theirs
# ion.c: both UAF fixes (2c155709e, b84ec04ba) -- helpers auto-merged. The shared suffix after
# each block is the `}` of the vendor's braced `if`, so upstream's brace-less text leaves a
# stray brace; take vendor form and graft the fix in (PY below).
python3 $R drivers/staging/android/ion/ion.c ours
# 3c29ae7ce: spin_lock(&cdev->lock) already landed above -> the unlock is mandatory; unlock
# first, then the vendor INFO.
python3 $R drivers/usb/gadget/composite.c theirs+ours
# init-at-declaration is the safe superset; vendor's later `pool = &port->write_pool;` stays.
python3 $R drivers/usb/gadget/function/u_serial.c theirs
python3 $R fs/ext4/ioctl.c both
python3 $R include/linux/cpu.h both
python3 $R kernel/cpu.c both
python3 $R kernel/debug/kdb/kdb_io.c ours
# c37215a94 VRF oif logic + the vendor 6-arg (uid-aware) ip6_update_pmtu() (PY below).
python3 $R net/ipv6/route.c theirs

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

resub('arch/arm64/include/asm/cpufeature.h',
      r'^#define ARM64_WORKAROUND_CAVIUM_27456\s+12\n',
      '#define ARM64_HAS_32BIT_EL0\t\t\t11\n#define ARM64_WORKAROUND_CAVIUM_27456\t\t12\n')

sub('arch/arm64/kernel/cpufeature.c',
    '#endif /* CONFIG_ARM64_UAO */\n\t\t.desc = "32-bit EL0 Support",\n',
    '#endif /* CONFIG_ARM64_UAO */\n\t{\n\t\t.desc = "32-bit EL0 Support",\n')

sub('arch/arm64/mm/fault.c',
    'asmlinkage int __exception do_debug_exception(unsigned long addr,\n',
    'asmlinkage int __exception do_debug_exception(unsigned long addr_if_watchpoint,\n')

sub('arch/arm64/mm/flush.c',
    '\t/* no flushing needed for anonymous pages */\n\tif (!page_mapping(page))\n\t\treturn;\n\n',
    '')

# ion.c block 1: __ion_share_dma_buf_fd() must honour lock_client (the fix's whole point).
sub('drivers/staging/android/ion/ion.c',
    '\tdmabuf = ion_share_dma_buf(client, handle);\n\tif (IS_ERR(dmabuf)) {\n\t\tIONMSG("%s dmabuf is err 0x%p.\\n", __func__, dmabuf);\n',
    '\tdmabuf = __ion_share_dma_buf(client, handle, lock_client);\n\tif (IS_ERR(dmabuf)) {\n\t\tIONMSG("%s dmabuf is err 0x%p.\\n", __func__, dmabuf);\n')
# ion.c block 2: ION_IOC_SHARE/MAP hold client->lock across lookup/share/put.
sub('drivers/staging/android/ion/ion.c',
    '\t\thandle = ion_handle_get_by_id(client, data.handle.handle);\n\t\tif (IS_ERR(handle)) {\n\t\t\tret = PTR_ERR(handle);\n\t\t\tIONMSG("ION_IOC_SHARE handle is invalid. handle = %d, ret = %d.\\n", data.handle.handle, ret);\n\t\t\treturn ret;\n\t\t}\n\t\tdata.fd.fd = ion_share_dma_buf_fd(client, handle);\n\t\tion_handle_put(handle);\n',
    '\t\tmutex_lock(&client->lock);\n\t\thandle = ion_handle_get_by_id_nolock(client, data.handle.handle);\n\t\tif (IS_ERR(handle)) {\n\t\t\tret = PTR_ERR(handle);\n\t\t\tmutex_unlock(&client->lock);\n\t\t\tIONMSG("ION_IOC_SHARE handle is invalid. handle = %d, ret = %d.\\n", data.handle.handle, ret);\n\t\t\treturn ret;\n\t\t}\n\t\tdata.fd.fd = ion_share_dma_buf_fd_nolock(client, handle);\n\t\tion_handle_put_nolock(handle);\n\t\tmutex_unlock(&client->lock);\n')

sub('kernel/debug/kdb/kdb_io.c',
    '\tint key;\n\tstatic int last_crlf;\n',
    '\tint key, buf_size, ret;\n\tstatic int last_crlf;\n')

sub('net/ipv6/route.c',
    '\tip6_update_pmtu(skb, sock_net(sk), mtu, oif, sk->sk_mark);\n',
    '\tip6_update_pmtu(skb, sock_net(sk), mtu, oif, sk->sk_mark, sock_i_uid(sk));\n')
PY

# Files that did NOT conflict but auto-merged inconsistently (gup_flags series callers in
# vendor code; struct global_attr in the interactive governor). Idempotent, has its own gates.
python3 /t/fixups-stage-v4.4.180.py

# Gates (tree-wide, no extension filter) + structural checks the compiler reports late.
n=$(grep -rl '^<<<<<<< HEAD' . | wc -l); echo "conflict markers remaining (tree-wide): $n"
[ "$n" -eq 0 ] || { grep -rl '^<<<<<<< HEAD' .; exit 1; }
grep -q 'system_supports_32bit_el0' arch/arm64/include/asm/cpufeature.h || { echo "system_supports_32bit_el0 missing"; exit 1; }
grep -q 'lock_client);' drivers/staging/android/ion/ion.c || exit 1
grep -q 'sock_i_uid(sk));' net/ipv6/route.c || exit 1
echo "stage-180 resolve: all gates passed"
