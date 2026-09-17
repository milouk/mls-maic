# USB OTG host class drivers (MAIC MT8167) — canonical set

Status: **prepared and compile-verified, NOT deployed.** This directory is the single canonical USB OTG workstream.

> **`kernel-project/patches/usb/` is superseded by this directory** (produced by a parallel agent from another session; kept for reference, not deleted). Its option list is identical to `defconfig.fragment` here, and its independent build agrees in size (unpatched Image.gz 7,198,144 B there vs 7,198,135 B here). Its useful test ideas and integration notes are merged below.

Candidate image, **for size/fit verification only**: `kernel-project/out/candidates/usb-otg/boot_usb-otg.img`, md5 `814fee2dce955232d5e20b12a528503f`. All 13 gating checks pass (`CHECKS.txt`).
**⚠️ Do not flash that image.** It lacks the camera fix that has since landed in the live tree (`kd_camera_hw.c`). Deploy by applying `defconfig.fragment` to the live tree and rebuilding there.

## What this is

The tablet's only data port is a USB-A socket on the musb controller. With the parity kernel (`boot_PARITY_USB_77bf6b99`), that port already comes up as a USB host with 5 V on VBUS ~7 s after boot (`CONFIG_MTK_MUSB_SW_WITCH_MODE` off, like stock). A legacy A-to-C cable carries the 56 kΩ pull-up, so USB-C devices see an ordinary USB 2.0 host. **No OTG/role-switch work is needed.**

What was missing is class drivers. This workstream enables them, built-in (`CONFIG_MODULES` is off). It is **config-only**: `usb-otg.patch` is intentionally empty, and `diff -rq` of the source against the live tree shows no USB-related change.

## What gets enabled (`defconfig.fragment`, resolved delta in `config.diff-vs-parity.txt`)

| Group | Options | What you can plug in |
|---|---|---|
| Wired Ethernet | `USB_RTL8152`, `USB_NET_CDC_EEM`, `USB_NET_SMSC95XX`, `USB_NET_DM9601` | Most USB-C/USB-A Gigabit dongles (RTL8152/8153), LAN95xx and DM9601 dongles, CDC-EEM |
| Tethering | `USB_NET_RNDIS_HOST`, `USB_IPHETH` | Android phone USB tethering, iPhone Personal Hotspot over USB |
| Modems | `USB_NET_CDC_MBIM`, `USB_NET_QMI_WWAN` (+ auto `USB_WDM`) | LTE sticks, M.2 modems in USB enclosures |
| Storage | `USB_UAS` | UAS SSD enclosures (usb-storage was already on) |
| Serial | `USB_ACM`, `USB_SERIAL_GENERIC`, `_FTDI_SIO`, `_CP210X`, `_CH341`, `_PL2303` | Arduino, ESP32/ESP8266, USB-UART cables, modems |
| Input | `HID_MULTITOUCH`, `INPUT_JOYSTICK`, `JOYSTICK_XPAD`, `HID_SONY` | USB touch panels, Xbox (and clone) pads, DualShock 3/4 |
| Diagnostics | `USB_ANNOUNCE_NEW_DEVICES` | Logs VID/PID/strings of every device |

Already on in parity: usb-storage, generic + vendor HID, hubs, ASIX and CDC-ECM/NCM Ethernet, USB audio, UVC webcams, `USB_SERIAL` core.
Deliberately **off**: `USB_OTG`, `USB_OTG_WHITELIST` (would restrict what enumerates), `MTK_MUSB_SW_WITCH_MODE` (would break host-at-boot).

## Verification (clean build, sole writer)

- Clean GCC 4.9 build in `maic-wt-usb` (`UTS #1 SMP PREEMPT Tue Sep 15 12:03:10 UTC 2026`): no errors in the log.
- All 21 added options resolved `=y` after `olddefconfig`; nothing removed vs parity.
- All 20 driver objects are non-empty, including `smsc95xx.o` and `dm9601.o`.
- All 19 driver registration structs are present in `System.map`: `rtl8152_driver`, `rndis_driver`, `cdc_driver`, `eem_driver`, `smsc95xx_driver`, `dm9601_driver`, `ipheth_driver`, `cdc_mbim_driver`, `qmi_wwan_driver`, `wdm_driver`, `uas_driver`, `acm_driver`, `ftdi_sio_device`, `cp210x_device`, `ch341_device`, `pl2303_device`, `mt_driver`, `xpad_driver`, `sony_driver`.
- No object newer than `vmlinux` (no stale link).

**Incident, recorded for honesty:** a duplicate agent built in the same `maic-wt-usb` output directory at the same time. That produced a GCC segfault / "file in wrong format" on its side, and it silently added SMSC95XX/DM9601 to the shared `.config`. My first image (md5 `74d9aac5…`, Image 16,278,736 B) was linked from that racy tree and **is superseded**, as is the duplicate's `36e847c7…`. All 658 build outputs written during the overlap were deleted and rebuilt with a single writer. The numbers here are from that clean build.

## Size and boot-image fit (clean build)

| | parity (77bf6b99) | usb-otg candidate | delta |
|---|---|---|---|
| Image | 16,085,936 B | 16,295,632 B | +209,696 B |
| Image.gz, Magisk-patched (as packed) | 7,119,823 B | 7,204,867 B | +85,044 B |
| kernel fit below ATF reserve (0x43000000) | 42,631,965 B | 42,546,921 B | −85,044 B |
| ramdisk fit below ram_console (0x44400000) | 1,638,026 B | 1,638,026 B | unchanged (ramdisk byte-identical) |

The boot partition stays 16 MiB; there is no size risk.

## Android side

Observed read-only on 2026-09-15, before device access was restricted. **Re-confirm on flash day (test plan §0).**
- `/system/etc/permissions/android.hardware.usb.host.xml` is **present**, and `feature:android.hardware.usb.host` is listed. USB host API apps need no module.
- `android.hardware.ethernet.xml` is **absent**, but the `ethernet` system service is **already running** (Android 7 starts EthernetService when the usb.host feature exists). The optional module `magisk/maic-ethernet-feature.zip` only matters for apps that check `FEATURE_ETHERNET`.
- Interface names, from source: `r8152` → `eth%d` (`alloc_etherdev`); `rndis_host` has `FLAG_POINTTOPOINT` → usbnet names it `usb%d`. EthernetService normally manages only `eth\d`, so expect dongles to DHCP automatically and phone tethering (`usb0`) to possibly need manual IP setup.
- Props observed: `sys.usb.config=mtp,adb`, `ro.sys.usb.charging.only=yes`, `sys.usb.configfs=0` (gadget side irrelevant on this host-only port).

## What users get / don't get

**Gets:** wired Ethernet via USB-C/USB-A dongles (a stable connection for the kitchen TV box), phone tethering over a cable, keyboards, mice, gamepads, touch panels, USB sticks and SSDs (FAT32 now; exFAT/NTFS depend on the filesystems workstream), USB DACs and headsets, webcams, and serial access to microcontrollers.
**Doesn't get:** charging the tablet over USB (it charges from the DC jack), or using the tablet as a USB device toward a PC (no adb or MTP by cable; adb stays over Wi-Fi).

## Safety

- **Electrically this is what stock already does.** Host mode with VBUS on is stock behaviour; the drivers are additive and dormant until matching hardware is attached.
- **⚠️ NEVER connect the tablet's USB-A port to a PC/Mac USB-A port with an A-to-A cable, or to anything that is also a host driving 5 V.** The ID pin is tied low, so the tablet is **always host and always drives VBUS** (`drvvbus_high`). Two hosts means two 5 V supplies back-feeding each other, which is out of spec and can damage either side. An A-to-C cable into a Mac's USB-C port is fine: the Mac becomes the device (observed 2026-09-15, `1-1/product: Mac`).
- **VBUS budget ≈ 500 mA** (`drivers/misc/mediatek/usb20/musb_core.c:2337`: `hcd->power_budget = 2 * (plat->power ? : 250)`; no higher DT limit). Bus-powered spinning HDDs, dongles behind hubs, or phone charging may strain it. Use a **powered hub**. Phones enumerate and trickle-charge at best.
- **Do not raise the power budget** in software to "fix" brown-outs; it reflects the board's VBUS switch.

## Integration (at the integration step, not here)

1. Append `defconfig.fragment` to `kernel-project/config/maic_defconfig`, `/src/linux/arch/arm64/configs/maic_defconfig`, and the build's `.config` (the same three places as the SW_WITCH_MODE fix).
2. Build the **live** tree with `build-m49.sh`, **one build at a time per output directory**. Never share an `out_*` dir between concurrent makes. Parallel emulated amd64 GCC builds have also segfaulted; if one does, rebuild with lower `JOBS` (4–6).
3. Re-apply the Magisk `skip_initramfs`→`want_initramfs` patch (exactly 1 occurrence, 4 bytes), `gzip -9 -n`, pack with `mkboot.py` on the current known-good base, and gate on the checks from `CHECKS.txt` plus the camera fix being present.
4. Flash p9 with read-back md5 compare before reboot. Keep the stock rescue armed. Follow `test-plan.md`.

## Risk and effort

- **Risk: low.** Config-only, clean compile, +85 KB compressed, ramdisk and boot path untouched. The realistic failure is a driver misbehaving when its device is plugged in, recovered by unplugging, a reboot, or the rescue path.
- **Effort:** preparation done. Remaining: one integration build and flash, plus the plug-in tests (~30–60 min depending on devices on hand).

## Files

- `defconfig.fragment`: canonical option list
- `config.diff-vs-parity.txt`: exact resolved `.config` additions (clean build)
- `usb-otg.patch`: empty by design (config-only), with explanation
- `test-plan.md`: owner pre-checks, flash steps, per-device tests, pass/fail, rollback
- `magisk/maic-ethernet-feature/` and `.zip`: optional `FEATURE_ETHERNET` declaration
- Candidate (verification only): `kernel-project/out/candidates/usb-otg/` (`boot_usb-otg.img`, `CHECKS.txt`, `mkboot.log`, `config.full`, `System.map`, `Image*`)
