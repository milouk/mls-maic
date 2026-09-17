# Filesystems/compression — flash-day test plan

Candidate: `kernel-project/out/candidates/filesystems/boot_filesystems.img`
md5 `459d0a9b017715dbf8e926cdadfc0d92`, built on base `boot_PARITY_USB_77bf6b99.img`
(the current known-good: speaker, mic, touch, USB VBUS parity). Only the kernel differs;
the ramdisk is byte-identical to the base.

All commands run in a root shell on the tablet. `BB=/data/adb/magisk/busybox` is used for
loop mounts and `sha256sum`: its `losetup`/`mount -o loop` are more reliable than toybox on
Android 7, whose toybox may not ship `sha256sum` at all.

## 0. Before flashing

- [ ] Rescue armed and pointing at STOCK:
      `md5sum /data/maic_rescue/boot_restore.img` → `4c65df18406167aba3bf4b1e33565cfd`, and
      `/data/maic_rescue/DO_RESTORE` exists.
- [ ] Known-good image on device for instant rollback:
      `md5sum /data/local/tmp/ours.img` → `77bf6b99ea9e03c06078bc837594e50a`.
- [ ] Push candidate, verify md5 on device, `dd` to p9, read p9 back and compare md5 **before** rebooting.

## 1. Regression gate (must all pass, otherwise roll back immediately)

| check | command | pass |
|---|---|---|
| our kernel booted | `cut -c1-40 /proc/version` | `root@<container>` not `zesheng@build-70` |
| Magisk root | `su -c id` | `uid=0` |
| Wi-Fi / SSH | you are logged in | — |
| speaker | play audio, tablet speaker | audible |
| amp enable follows playback | `grep "device: sound" /sys/kernel/debug/pinctrl/pinctrl-handles` while playing | `extamp_on` |
| DSP | `grep "device: synaptics" /sys/kernel/debug/pinctrl/pinctrl-handles` | `dsp_pwr_high` |
| touch | tap icons | lands correctly |
| USB VBUS | `grep "device: musb" /sys/kernel/debug/pinctrl/pinctrl-handles` (after ~10 s) | `drvvbus_high` |

## 2. Kernel registered the filesystems

```sh
grep -wE "exfat|ntfs|overlay|squashfs|f2fs|cifs" /proc/filesystems
```
Pass: `exfat`, `ntfs`, `overlay`, `squashfs`, `f2fs`, `cifs` all listed (no separate `smb3`
type on 4.4; SMB3 is `mount -t cifs -o vers=3.0`). `dmesg | grep -iE "exfat|ntfs|f2fs|squashfs|cifs"`
must show no errors.

## 3. zram LZ4

Evidence from the boot ramdisk: `fstab.mt8167` defines **no** zram, so on the current kernel
zram0 exists but is unused. First check the kernel side:

```sh
cat /sys/block/zram0/comp_algorithm      # pass: lists lz4, e.g. "[lzo] lz4"
cat /sys/block/zram0/disksize            # expected 0 (unused) unless /system/etc/init sets it
cat /proc/swaps
```

Then (optional) install `magisk/maic-zram-lz4.zip` via `magisk --install-module`, reboot, wait ~1 min:

```sh
cat /sys/block/zram0/comp_algorithm      # pass: "lzo [lz4]"
cat /proc/swaps                          # pass: /dev/block/zram0 ... 524284 ...
cat /data/local/tmp/maic-zram-lz4.log
```
Tune or disable in `/data/adb/maic-zram.conf` (`ENABLE=0`, `SIZE=...`, `SWAPPINESS=...`).
Watch for a day: no app kills getting worse, no UI stutter. Remove the module to undo.

## 4. exFAT (read-write) — loop image

On the Mac: `kernel-project/patches/filesystems/make-test-images.sh` (already run once;
outputs in `out/candidates/filesystems/testimages/`, each image self-verified in a
container: exfat/f2fs fsck clean, ntfs contains the files, squashfs is lz4).

Push `exfat.img.gz`, `ntfs.img.gz`, `f2fs.img.gz`, `squashfs-lz4.img.gz`, `hello.txt`,
`random.bin`, `SHA256SUMS` to `/data/local/tmp/fst/`, then:

```sh
cd /data/local/tmp/fst && for f in *.img.gz; do gunzip -f $f; done
BB=/data/adb/magisk/busybox; mkdir -p /mnt/t
$BB mount -t exfat -o loop exfat.img /mnt/t
cp hello.txt random.bin /mnt/t/ && sync
$BB umount /mnt/t && $BB mount -t exfat -o loop exfat.img /mnt/t
cd /mnt/t && $BB sha256sum hello.txt random.bin; cd - >/dev/null
$BB umount /mnt/t
```
Pass: both hashes equal `SHA256SUMS` after the remount (proves write + read-back).
Also try a name with Greek/emoji characters (`touch "/mnt/t/Καλημέρα.txt"`) → listed correctly (utf8 iocharset).

## 5. NTFS (read-only)

```sh
$BB mount -t ntfs -o loop,ro ntfs.img /mnt/t
cd /mnt/t && $BB sha256sum hello.txt random.bin; cd - >/dev/null
touch /mnt/t/x 2>&1 | head -1        # pass: fails with "Read-only file system"
$BB umount /mnt/t
```

## 6. F2FS (external media only), squashfs-LZ4, overlayfs

```sh
$BB mount -t f2fs -o loop f2fs.img /mnt/t && cp hello.txt /mnt/t/ && sync && $BB sha256sum /mnt/t/hello.txt && $BB umount /mnt/t
$BB mount -t squashfs -o loop,ro squashfs-lz4.img /mnt/t && $BB sha256sum /mnt/t/hello.txt /mnt/t/random.bin && $BB umount /mnt/t
mkdir -p /data/local/tmp/ov/lower /data/local/tmp/ov/upper /data/local/tmp/ov/work /data/local/tmp/ov/merged
echo lower > /data/local/tmp/ov/lower/a && mount -t overlay overlay \
  -o lowerdir=/data/local/tmp/ov/lower,upperdir=/data/local/tmp/ov/upper,workdir=/data/local/tmp/ov/work /data/local/tmp/ov/merged
echo changed > /data/local/tmp/ov/merged/a && cat /data/local/tmp/ov/lower/a /data/local/tmp/ov/upper/a
umount /data/local/tmp/ov/merged
```
Pass: hashes match; overlay shows `lower` in lowerdir and `changed` in upperdir.
**Never** format or mount `/data` as F2FS (wipes `/data/maic_rescue`).

## 7. Real USB stick (needs USB VBUS parity — already in the base)

- exFAT stick: install `magisk/maic-usbmount.zip`, reboot, plug in, then
  `su -mm -c 'maic-usbmount mount'` → `su -mm -c 'maic-usbmount status'`.
  Pass: mounted at `/mnt/media_rw/usbotg`, `fuse_usbotg` running, files visible in
  `/storage/usbotg`. **Not yet verified:** whether regular apps see `/storage/usbotg` without a
  reboot (Android 7 per-app mount namespaces). If not, a root file manager can use
  `/mnt/media_rw/usbotg`. Record the result.
- NTFS stick: same, read-only.
- vfat stick: unchanged — Android mounts it itself; the helper refuses by design.
- Always `su -mm -c 'maic-usbmount umount'` before unplugging.

## 8. SMB/CIFS (optional, needs a share on the LAN)

```sh
mkdir -p /mnt/smb && mount -t cifs //<server>/<share> /mnt/smb -o vers=3.0,username=<user>,password=<pw>,uid=1023,gid=1023
ls /mnt/smb && umount /mnt/smb
```
Use `vers=2.1` or `vers=3.0`; avoid `vers=1.0`. Weak LANMAN hashing is compiled out.

## 9. Rollback

- Boots but something regressed: `dd if=/data/local/tmp/ours.img of=/dev/block/mmcblk0p9 bs=1048576; sync`,
  read back md5 `77bf6b99…`, reboot.
- Does not boot: rescue path restores stock p9 (`/data/maic_rescue`), then reflash `ours.img`.
- Modules: `magisk --remove-modules` or delete `/data/adb/modules/maic-zram-lz4` / `maic-usbmount`, reboot.
- Nothing in this change writes persistent state outside the two optional modules and `/data/adb/maic-zram.conf`.
