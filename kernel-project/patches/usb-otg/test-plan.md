# USB OTG test plan

Canonical USB OTG test plan (supersedes the plan in `patches/usb/README.md`).
Verification candidate: `kernel-project/out/candidates/usb-otg/boot_usb-otg.img`, md5 `814fee2dce955232d5e20b12a528503f`.
**⚠️ Do not flash that candidate:** it lacks the live tree's camera fix. Flash the integration build made from the live tree with `defconfig.fragment` applied; the steps below apply to that image.
Everything below runs over adb/SSH over **Wi-Fi**. The USB port is host-only and cannot carry adb.

## 0. Pre-checks for the device owner (read-only, before flashing)

The preparation agent could not run these: device access was restricted to the owning session. Values marked *observed* were seen read-only on 2026-09-15 before that restriction, so re-confirm them.

Run as root (`kernel-project/out/work/tr.sh '<cmd>'`):

| Check | Command | Expected |
|---|---|---|
| Running our parity kernel | `cut -c1-40 /proc/version` | `root@...` build, not `zesheng@build-70` |
| Host + VBUS on | `grep "device: musb" /sys/kernel/debug/pinctrl/pinctrl-handles` | `current state: drvvbus_high` |
| Rescue armed and still stock | `md5sum /data/maic_rescue/boot_restore.img; ls /data/maic_rescue/DO_RESTORE` | `4c65df18406167aba3bf4b1e33565cfd`, file present |
| Current p9 (for rollback) | `dd if=/dev/block/mmcblk0p9 bs=1048576 count=16 2>/dev/null \| md5sum` | note the value |
| USB host permission file | `ls /system/etc/permissions/ \| grep -iE "usb\|ethernet"` | *observed:* `android.hardware.usb.accessory.xml`, `android.hardware.usb.host.xml` (no ethernet.xml) |
| Features | `pm list features \| grep -iE "usb\|ethernet"` | *observed:* `feature:android.hardware.usb.accessory`, `feature:android.hardware.usb.host` |
| Ethernet service running | `service list \| grep -i ethernet` | *observed:* `ethernet: [android.net.IEthernetManager]` |
| USB props | `getprop \| grep -iE "usb\|otg"` | *observed:* `sys.usb.config=mtp,adb`, `ro.sys.usb.charging.only=yes`, `sys.usb.configfs=0` |
| Tools available | `which ip ifconfig` | *observed:* `/system/bin/ip`, `/system/bin/ifconfig` |

Stop if the rescue image is not stock `4c65df18`. If `usb.host.xml` has disappeared, the app-level USB host API won't work until a permission overlay is added; kernel-level devices (storage, HID, Ethernet) still work.

## 1. Flash day

1. Build the **integration image** from the live tree with `defconfig.fragment` applied (not the verification candidate). Gate it on the same checks as `kernel-project/out/candidates/usb-otg/CHECKS.txt` (want_initramfs=1, skip_initramfs=0, DSP driver, External I2S out, stock touch cfg, swmode absent, all USB driver structs in System.map, DTB and ramdisk identical to base), **plus** the live camera fix being present. Record its md5.
2. Push the image to `/data/local/tmp/`. Verify md5 on the device. `dd` it to `/dev/block/mmcblk0p9`, `sync`, read back 16 MiB and compare md5. **Only reboot if they match.**
3. Reboot. Wait for SSH (~40–60 s).
4. Confirm our kernel booted: `cut -c1-40 /proc/version`.
5. **Regression pass for today's parity features** (must all still pass):
   - `grep "device: musb" /sys/kernel/debug/pinctrl/pinctrl-handles` → `drvvbus_high` (after ~7 s uptime)
   - speaker plays (user confirms), and `device: synaptics` → `dsp_pwr_high`
   - touch lands correctly (user confirms)
   - Wi-Fi/adb OK, Bluetooth untouched
6. `dmesg | grep -iE "usbcore: registered new interface driver" | sort` should now also list `r8152`, `rndis_host`, `cdc_ether`, `cdc_eem`, `ipheth`, `cdc_mbim`, `qmi_wwan`, `uas`, `cdc_acm`, `usbserial_generic`, `ftdi_sio`, `cp210x`, `ch341`, `pl2303`, `xpad`.

## 2. Plug-in tests (one device at a time, via A-to-C or A-to-A-device cable)

For each: `dmesg -c >/dev/null`, plug in, wait 5 s, then capture `dmesg` and `ls /sys/bus/usb/devices/; cat /sys/bus/usb/devices/1-*/product 2>/dev/null`.
With `USB_ANNOUNCE_NEW_DEVICES`, every device should log `New USB device found, idVendor=..., idProduct=...` plus `Product:`/`Manufacturer:` lines.

| Device | Expected dmesg | Expected state | Pass criterion |
|---|---|---|---|
| USB stick (FAT32) | `usb-storage 1-1:1.0: USB Mass Storage device detected`, `sd 0:0:0:0: [sda] ...` | `/dev/block/sda*` exists | Android shows the stick, or `mount -t vfat /dev/block/sda1 /mnt/...` works read-only |
| UAS SSD enclosure | `uas` binds (`scsi host0: uas`) or falls back to usb-storage | `/dev/block/sda` | Readable; `dd if=/dev/block/sda of=/dev/null bs=1M count=64` completes |
| USB-C headset / USB DAC | `usb 1-1: New USB device found...`, `snd-usb-audio` binds | new card in `/proc/asound/cards` | Card listed; playback selectable (audio routing is Android's job) |
| A-to-C flash drive / SSD | as USB stick; note whether `uas` or `usb-storage` (BOT) binds | `/dev/block/sd*` | Readable; record UAS vs BOT |
| USB keyboard / mouse | `input: ... as /devices/.../input/inputN`, `hid-generic ...` | new `/dev/input/eventN` | Typing/pointer works in UI |
| Realtek Ethernet dongle (RTL8152/8153) | `r8152 1-1:1.0 eth0: v1.08... `, then link up on cable | `ip link` shows `eth0` | `ip addr show eth0` gets an IPv4 from DHCP; `ping -I eth0 -c3 <gateway>` succeeds |
| Android phone, USB tethering on | `rndis_host 1-1:1.0 usb0: register 'rndis_host'` | `usb0` | Interface appears. If no auto IP: `ip link set usb0 up`, then manual DHCP/static. Record whether EthernetService picks it up (expected: no, it matches `eth\d`) |
| iPhone hotspot over USB | `ipheth 1-1:2.0: Apple iPhone USB Ethernet device attached` | `eth`/`usb` iface | Interface appears (needs trust prompt on the phone) |
| Arduino / ESP32 (CH340, CP2102, FTDI, or native CDC) | `ch341-uart converter now attached to ttyUSB0` / `cp210x ... ttyUSB0` / `ftdi_sio ... ttyUSB0` / `cdc_acm 1-1:1.0: ttyACM0` | `/dev/ttyUSB0` or `/dev/ttyACM0` | Node exists; `stty -F /dev/ttyUSB0 115200` succeeds |
| Xbox-style gamepad | `input: Microsoft X-Box 360 pad ...` (xpad) | new event node | `getevent -l` shows button events |
| DualShock 4 (cable) | `sony 0003:054C:05C4...: input,hidraw` | new event node | `getevent -l` shows events |
| LTE stick (MBIM/QMI) | `cdc_mbim ... wwan0` or `qmi_wwan ... wwan0` | `wwan0` | Interface appears (bring-up needs userspace; enumeration is the pass) |
| SMSC LAN95xx or DM9601 dongle | `smsc95xx 1-1:1.0 eth0: register 'smsc95xx'` / `dm9601 ... eth0: register 'dm9601'` | `eth0` | Interface appears; DHCP as for RTL8152 |
| Powered USB-C hub with several devices above | hub enumerates, children follow | multiple `1-1.N` entries | All children enumerate; no over-current messages |
| Phone for charging | device enumerates | — | Enumerates; charging indicator may or may not show (~500 mA budget). **Not a failure if it does not charge.** |

**Power check:** during each test, watch `dmesg` for `over-current`, `rejected 1 configuration due to insufficient available bus power`, or repeated disconnect/reconnect. If seen, retry through a **powered hub**. Do not change the power budget.

**Negative test:** unplug each device and confirm a clean `USB disconnect, device number N` with no oops/panic in `dmesg`.

## 3. Pass / fail

- **PASS:** section 1 regression pass OK, all loaded drivers registered, and every device actually available enumerates with its class driver bound and no kernel warnings/oops.
- **FAIL (rollback):** boot failure, any regression in speaker/touch/Wi-Fi/USB-host, or a kernel oops/panic on plug-in.
- **Not a fail:** a phone not charging, `usb0` needing manual IP, bus-power errors that go away with a powered hub.

## 4. Rollback

- **Booted but something regressed:** re-flash the parity image `kernel-project/out/boot_PARITY_USB_77bf6b99.img` (md5 `77bf6b99ea9e03c06078bc837594e50a`) the same way (push, dd, read back, compare md5, reboot).
- **Does not boot / bootloops:** boot to recovery. `maic_rescue` sees `/data/maic_rescue/DO_RESTORE` and restores the stock image (`4c65df18`) to p9, then re-flash parity from there.
- Never write preloader/lk/nvram.

## 5. Optional: Ethernet feature flag module

Only if an app refuses to use wired Ethernet because `FEATURE_ETHERNET` is missing:

```
push magisk/maic-ethernet-feature.zip to /data/local/tmp/
su -c 'magisk --install-module /data/local/tmp/maic-ethernet-feature.zip'
reboot
pm list features | grep ethernet   # expect feature:android.hardware.ethernet
```

Remove it with `touch /data/adb/modules/maic-ethernet-feature/remove` and a reboot.
