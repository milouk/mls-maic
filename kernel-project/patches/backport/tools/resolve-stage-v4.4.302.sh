#!/bin/sh
# Stage 10 (v4.4.302, end of the 4.4.y line) conflict resolutions. Run after `git merge v4.4.302`.
# 3 files. See logs/stage-v4.4.302.md.
set -e
R=/t/resolve.py

# af21211c3 (CVE-2021-39685 family): ep0 buffers must be zero-allocated. Keep the vendor
# GFP_DMA branching, kzalloc in every branch -- including the os_desc buffer pair the vendor
# branched at stage 145, which git could not see (PY below).
python3 $R drivers/usb/gadget/composite.c ours
# c8b75d33e moved the discard_granularity clamp into ext4_trim_fs() (auto-merged in mballoc.c);
# drop it here, keep the vendor 3-arg secure-discard call (PY below).
python3 $R fs/ext4/ioctl.c theirs
# 5ae5ce36f removed block_dump from mark_inode_dirty; the callee is gone, vendor's `> 1` tweak with it.
python3 $R fs/fs-writeback.c theirs

python3 - <<'PY'
def rd(p): return open(p, encoding='utf-8', errors='surrogateescape').read()
def wr(p, s): open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
def sub(path, old, new, count=1):
    s = rd(path); n = s.count(old)
    assert n == count, f"{path}: expected {count} x {old[:60]!r}, found {n}"
    wr(path, s.replace(old, new)); print(f"  {path}: edit ok")
sub('drivers/usb/gadget/composite.c', 'cdev->req->buf = kmalloc(USB_COMP_EP0_BUFSIZ,', 'cdev->req->buf = kzalloc(USB_COMP_EP0_BUFSIZ,', count=2)
sub('drivers/usb/gadget/composite.c', 'cdev->os_desc_req->buf = kmalloc(USB_COMP_EP0_OS_DESC_BUFSIZ,', 'cdev->os_desc_req->buf = kzalloc(USB_COMP_EP0_OS_DESC_BUFSIZ,', count=2)
sub('fs/ext4/ioctl.c', '\t\tret = ext4_trim_fs(sb, &range);\n', '\t\tret = ext4_trim_fs(sb, &range, flags);\n')
PY

# Gates
n=$(grep -rl '^<<<<<<< HEAD' . | wc -l); echo "conflict markers remaining (tree-wide): $n"
[ "$n" -eq 0 ] || { grep -rl '^<<<<<<< HEAD' .; exit 1; }
! grep -q 'kmalloc(USB_COMP_EP0' drivers/usb/gadget/composite.c || { echo "composite.c: an ep0 buffer is still kmalloc'd"; exit 1; }
[ "$(grep -c 'ext4_trim_fs(sb, &range, flags)' fs/ext4/ioctl.c)" -eq 1 ] || exit 1
! grep -q 'discard_granularity' fs/ext4/ioctl.c || { echo "ioctl.c: clamp still present (belongs in ext4_trim_fs now)"; exit 1; }
grep -q 'discard_granularity' fs/ext4/mballoc.c || exit 1
! grep -rq 'block_dump___mark_inode_dirty' --include='*.c' --include='*.h' . || { echo "block_dump___mark_inode_dirty still referenced"; exit 1; }
echo "stage-302 resolve: all gates passed"
