# Filesystems & compression

Prepared and compile-verified, **not deployed**. Source of the plan:
`docs/research/filesystems-compression.md`.

## What this adds (all built-in; `CONFIG_MODULES` is off)

| feature | config | why |
|---|---|---|
| zram with LZ4 | `ZRAM_LZ4_COMPRESS` | faster, cheaper compressed swap than lzo |
| NTFS, read-only | `NTFS_FS`, no `NTFS_RW` | read Windows drives; write would need ntfs-3g (FUSE) |
| exFAT, read-write | `EXFAT_FS` (new `fs/exfat`) | modern USB sticks / SD cards |
| overlayfs | `OVERLAY_FS` | Docker overlay2, layered mounts |
| squashfs (lz4, xz, zlib, lzo) | `SQUASHFS_*` | compact read-only images |
| SMB/CIFS client | `CIFS`, `CIFS_SMB2` | network shares (use `vers=2.1`/`3.0`) |
| F2FS | `F2FS_FS` (+xattr/security) | mounting F2FS **external** media only |

Pulled in by Kconfig dependencies: `LZ4_COMPRESS`, `CRYPTO_MD4`, `CRYPTO_CMAC`,
`DNS_RESOLVER`, `FSCACHE` (selected by upstream `CIFS_SMB2`), `FS_POSIX_ACL`,
`F2FS_STAT_FS`/`F2FS_FS_POSIX_ACL`, squashfs defaults. Kept off on purpose:
`NTFS_RW`, `CIFS_WEAK_PW_HASH`, `CIFS_POSIX`, `CIFS_FSCACHE`, NFS/Ceph/Coda/AFS.
4.4 CIFS cannot be built without its SMB1 code; only mount with `vers=2.1` or `3.0`.

## exFAT port

Vendored from `namjaejeon/linux-exfat-oot`, branch `for-kernel-version-from-4.1.0`,
commit `68072a2dc3bf9d73e8bda9b82fa3f93a7e9ff0a5` (2023-12-30), copy in
`kernel-project/vendor-refs/exfat/linux-exfat-oot`. The `.c`/`.h` files are **unmodified**:
the driver's own version guards already handle 4.4.22 (e.g. it uses `i_blkbits` because
`i_blocksize()` only arrived in 4.4.72). Integration changes only:

- `fs/exfat/Kconfig`: dropped `select BUFFER_HEAD` and `select LEGACY_DIRECT_IO` (symbols
  that don't exist on 4.4, where both are always available). Default iocharset `utf8`.
- `fs/exfat/Makefile`: kept only the in-tree kbuild lines.
- `fs/Kconfig`: `source "fs/exfat/Kconfig"` after FAT; `fs/Makefile`: `obj-$(CONFIG_EXFAT_FS) += exfat/`.
- No in-tree exfat/sdfat existed to clash with.

Result with AOSP GCC 4.9: 12 objects, 0 warnings, `init_exfat_fs`/`exfat_fill_super` in `System.map`.

## Files

- `defconfig.fragment` — the only config input; apply on top of the current `.config`
  (don't edit `maic_defconfig` blindly; merge the fragment when this is accepted).
- `filesystems.patch` — source diff vs the live tree, scoped to `fs/Kconfig`, `fs/Makefile`,
  `fs/exfat/*` (16 files); dry-run applies cleanly.
- `test-plan.md` — flash-day checks, pass/fail criteria, rollback.
- `make-test-images.sh` — builds exfat/ntfs/f2fs/squashfs-lz4 test images in a Debian
  container and self-verifies them (output: `out/candidates/filesystems/testimages/`).
- `magisk/maic-zram-lz4.zip` (`magisk/zram-lz4/`) — sets up an LZ4 zram swap (512 MiB default,
  `/data/adb/maic-zram.conf`), or switches an existing zram0 to LZ4. **Evidence:** the boot
  ramdisk's `fstab.mt8167` has no zram entry, so this ROM runs without zram swap today; a
  "switch-only" module would have been a no-op. Optional; changes memory behaviour.
- `magisk/maic-usbmount.zip` (`magisk/usbmount/`) — `maic-usbmount mount|umount|status` for
  exFAT (rw) and NTFS (ro) USB sticks, which Android 7 vold can't mount. Reuses stock's
  `/mnt/media_rw/usbotg` and `fuse_usbotg` service from `init.project.rc`. Manual command,
  no background service. App visibility of `/storage/usbotg` is **unverified** on device.

Candidate: `out/candidates/filesystems/boot_filesystems.img`, md5 `459d0a9b017715dbf8e926cdadfc0d92`,
see `CHECKS.txt` there (all 8 gates pass; kernel re-parsed from the packed image is
byte-identical to the patched Image; DTB identical).

## Size

| | baseline (live) | with this | delta |
|---|---|---|---|
| Image | 16,085,936 B | 16,888,984 B | +803,048 B |
| Image.gz (Magisk-patched) | 7,114,304 B | 7,480,339 B | +366,035 B |
| kernel margin below ATF @0x43000000 | 42,631,965 B | 42,271,449 B | ample |
| ramdisk | unchanged | unchanged | 1,638,026 B below the 4 MiB ceiling |

## Risks

- **Low boot risk:** kernel-only change, gzip kernel (LK is zlib-only), ramdisk untouched,
  fits with >40 MB margin. Regressions would most likely show as memory pressure from
  larger kernel text (~0.8 MB), not boot failure.
- **exFAT driver** is out-of-tree code on an old kernel: test writes on the loop image before
  trusting a real card; always unmount before unplugging.
- **zram module** changes memory behaviour (adds swap). Optional and reversible.
- **usbmount helper** runs as root and mounts in the global namespace; app visibility unverified.
- **Never** LZ4-compress the kernel/ramdisk, and **never** convert `/data` to F2FS (wipes
  `/data/maic_rescue`).
- Build note: the first compile attempts failed with `fixdep` errors because a second agent was
  concurrently building in the same volume; the final result comes from a full clean rebuild
  (all objects deleted first) with a regenerated `.config`.
