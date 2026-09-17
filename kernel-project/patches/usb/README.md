# USB host class drivers (USB-A / A-to-C "OTG")

Config-only. Enables common USB host-side device classes so the tablet's USB-A port
(already a powered host since the `SW_WITCH_MODE` stock-parity fix) works with USB sticks,
keyboards/mice, gamepads, **USB-C Ethernet dongles, phone tethering, and USB-serial** via a
legacy A-to-C cable. Derived from `docs/research/usb-otg.md`.

## What each option adds
See `config.fragment` (inline comments). Highlights: `USB_RTL8152` (the chip in most USB-C
Ethernet dongles), `USB_NET_RNDIS_HOST` (Android phone tethering), `USB_ACM` + the four
USB-serial drivers (FTDI/CP210x/CH341/PL2303), `USB_UAS` (USB-C SSDs), `USB_ANNOUNCE_NEW_DEVICES`
(logs VID/PID on every plug). Storage, HID, ASIX/CDC Ethernet, USB audio and webcams were
already `=y`. **Not** enabling `USB_OTG`/`USB_OTG_WHITELIST` (they would *restrict* devices).

## Verified build (isolated volume `maic-work-usb`, GCC 4.9)
- Build exit 0. `olddefconfig` kept all 20 options `=y` — no dependency drops.
  (`USB_WDM` was auto-selected by `CDC_MBIM`.)
- **Image.gz: 7,198,144 B vs baseline 7,114,306 B → +83,838 B (~82 KB).**
  Boot partition is 16 MiB and mkboot showed ~42 MB kernel-fit headroom → no concern.
- Driver presence confirmed by unique strings in `vmlinux` (proof they compiled in, since
  `=y` alone isn't): RTL8152, rndis_host, cdc_mbim (47), qmi_wwan (36), ipheth (53),
  smsc95xx (108), cdc_acm, ftdi_sio (26), cp210x (38), ch341 (47), pl2303 (62),
  hid-multitouch (4), "Xbox 360" (15). Serial drivers use `*_sio_driver`/`*_driver` symbol
  names, so grep for `<name>_driver` misses them — the strings are the authoritative check.

## Integration (done at the integration step, not here)
Append `config.fragment` to `kernel-project/config/maic_defconfig` (and mirror into
`/src/linux/arch/arm64/configs/maic_defconfig` + the build's `.config`, same 3-place pattern
as the SW_WITCH_MODE fix), rebuild with `build-m49.sh`, re-apply the Magisk `skip_initramfs`
patch, repack with `mkboot.py`, flash p9 with read-back verify, keep the stock rescue armed.

## Device test plan (after flashing)
Read-only, no device plugged:
```sh
grep "device: musb" /sys/kernel/debug/pinctrl/pinctrl-handles   # expect drvvbus_high
cat /sys/bus/usb/devices/usb*/product                            # MUSB/MUSBFSH host driver
```
Plug one device at a time with `dmesg -w` running (now prints VID/PID/product):
1. USB-A vfat flash drive → `/dev/block/sd*`, vold mounts it.
2. A-to-C flash drive / SSD → storage; note UAS vs BOT in dmesg.
3. Keyboard/mouse → `/proc/bus/input/devices`, typing works.
4. Phone via A-to-C, enable USB tethering → `rndis0`/`usb0` appears (RNDIS_HOST).
5. USB-C Ethernet dongle (RTL8153) → `eth0` in `ip link` (RTL8152).
6. USB-C headset/DAC → new card in `/proc/asound/cards`.
7. Powered USB-C hub with several of the above → confirms hub + power headroom.

## Safety
- **Power budget is ~500 mA** (`hcd->power_budget = 2*250`, no DT boost limit). Phones
  trickle-charge only; hungry SSDs/HDDs may brown out — use a **powered hub**, not a kernel
  change.
- **⚠️ Never connect this USB-A port to a PC** with an A-to-A cable, or an A-to-C cable into a
  PC's USB-C port: the port drives 5 V (`drvvbus_high`), so you'd fight two 5 V sources —
  out of spec, can damage hardware. adb stays over Wi-Fi.
- Android extras (independent of kernel, ~15 min Magisk module if wanted): apps using the
  `UsbManager` host API need `android.hardware.usb.host.xml`; USB Ethernet auto-config needs
  `android.hardware.ethernet`. Keyboards/storage/audio work without either. exFAT/NTFS
  sticks depend on the filesystems work.

## Risk: LOW
Additive drivers, dormant until matching hardware is attached; ~82 KB image growth; boot
path untouched.
