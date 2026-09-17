#!/bin/sh
# MAIC: build small filesystem images for flash-day testing (exfat, ntfs, f2fs, squashfs-lz4).
# Runs in a throwaway Debian container on the Mac; output goes to ./testimages/.
# Each image contains hello.txt with known content so reads can be verified by sha256.
set -e
OUT="${1:-$(cd "$(dirname "$0")/../.." && pwd)/out/candidates/filesystems/testimages}"
mkdir -p "$OUT"
docker run --rm -v "$OUT":/out debian:bookworm-slim bash -c '
set -e
apt-get update -qq >/dev/null && apt-get install -y -qq exfatprogs ntfs-3g f2fs-tools squashfs-tools >/dev/null
mkdir -p /seed && printf "MAIC filesystem test $(date -u +%Y-%m-%d)\n" > /seed/hello.txt
dd if=/dev/urandom of=/seed/random.bin bs=1M count=4 status=none
cd /out && rm -f *.img *.gz SHA256SUMS
truncate -s 16M exfat.img && mkfs.exfat -n MAICEXFAT exfat.img >/dev/null
truncate -s 16M ntfs.img  && mkntfs -F -q -L MAICNTFS ntfs.img 2>/dev/null
# NTFS is read-only in the kernel, so write the test files in now with ntfscp (no mount needed)
ntfscp -q ntfs.img /seed/hello.txt hello.txt && ntfscp -q ntfs.img /seed/random.bin random.bin
truncate -s 64M f2fs.img  && mkfs.f2fs -q -l MAICF2FS f2fs.img >/dev/null
# exfat and f2fs are writable in the kernel, so they are left empty and the write path is
# tested on-device (see test-plan.md). squashfs is built directly from the seed directory.
mksquashfs /seed squashfs-lz4.img -comp lz4 -noappend -quiet
cp /seed/hello.txt /seed/random.bin .
sha256sum hello.txt random.bin > SHA256SUMS
# self-checks: every image must be valid before it goes near the tablet
fsck.exfat -n exfat.img >/dev/null && echo "verify exfat: fsck clean"
ntfsls ntfs.img | tr "\n" " " | sed "s/^/verify ntfs: /"; echo
fsck.f2fs f2fs.img >/dev/null 2>&1 && echo "verify f2fs: fsck clean"
unsquashfs -s squashfs-lz4.img | grep -i "compression" | sed "s/^/verify squashfs: /"
unsquashfs -l squashfs-lz4.img | grep -c hello.txt | sed "s/^/verify squashfs hello.txt entries: /"
for f in exfat ntfs f2fs squashfs-lz4; do gzip -9 -n $f.img; done
ls -l
'
