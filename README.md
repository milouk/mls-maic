# MAIC: a custom kernel and rooted Android for the MLS MAIC smart hub

Turning an **MLS MAIC** (`iQR70`) desktop hub, from the defunct Greek maker MLS
Innovation, into a fully rooted, hardened, custom-kernel Android tablet. It runs
streaming TV and doubles as a small always-on home server.

<p align="center"><img src="assets/maic-device.png" alt="MLS MAIC iQR70 smart hub" width="340"></p>

The MAIC is a locked-down MediaTek smart display for a company that no longer
exists. There are no firmware updates, no published kernel source, and no Google
services. The goal is to own it completely: root it for good, strip the bloat, fix
what MLS left broken, and replace the frozen stock kernel with a maintained,
hardened build. All of it cable-free, and above all **without ever bricking it**.

📝 **Full writeup:** [My mini kitchen TV runs Docker now](https://medium.com/@mloukeris/my-mini-kitchen-tv-runs-docker-now-5dffad481fa7), on Medium.

## Table of contents

- [Device](#device)
- [Part 1: Root and userspace](#part-1-root-and-userspace)
  - [Permanent root and recovery](#permanent-root-and-recovery)
  - [Debloat](#debloat)
  - [TLS and ad-blocking](#tls-and-ad-blocking)
  - [UI fixes](#ui-fixes)
  - [Access](#access)
- [Part 2: The custom kernel](#part-2-the-custom-kernel)
  - [What we built and how it went](#what-we-built-and-how-it-went)
  - [Kernel features](#kernel-features)
  - [Docker](#docker)
  - [Building the kernel](#building-the-kernel)
  - [The auto-rescue](#the-auto-rescue)
- [Repository layout](#repository-layout)
- [Known limitations](#known-limitations)
- [Disclaimer](#disclaimer)

## Device

| | |
|---|---|
| Model / board | MLS MAIC (`iQR70`), ODM Emdoor |
| SoC | MediaTek **MT8167**, quad Cortex-A35 |
| GPU | IMG **PowerVR GE8300** (Rogue), not Mali |
| RAM / storage | 2 GB, 7.3 GB eMMC (about 3.3 GB userdata) |
| OS | Android **7.0** (`IQR70_V5.0`), SELinux enforcing |
| Ports | 1x USB-A host, 3.5 mm, DC barrel (mains powered) |

---

## Part 1: Root and userspace

What you need to run the MAIC as a daily rooted device: permanent root, the
certificate fix that makes HTTPS work again, debloat, and the UI repairs. All of it
works on the stock kernel.

### Permanent root and recovery

- **Magisk 25.2** patched boot on `mmcblk0p9`, survives reboots. Newer Magisk (26 and
  up) cannot patch this legacy `skip_initramfs` boot, so 25.2 is the ceiling.
- **Cable-free recovery.** MediaTek's `mtk-su` kernel exploit grants temp root over
  plain wireless ADB no matter what state Magisk is in. A bad root patch is always
  fixable without a USB-A-to-A cable or BROM.

### Debloat

Removed MLS, Emdoor (the ODM), and unused MediaTek packages: the history and
global-action apps, the engineer, ATCI and SIM services (there is no radio at all),
and the redundant music and recorder apps. System packages went from 51 to 42, and
every removal is reversible with `cmd package install-existing`.

### TLS and ad-blocking

- The ROM shipped without Let's Encrypt's roots, so every HTTPS stream failed.
  **ISRG Root X1 and X2** are injected into the system trust store on boot, which
  brought back TV, browser and F-Droid.
- The cert overlay is a bind-mount, not a Magisk module (a module corrupts file
  attributes here on every boot). It enforces `0644 root:root` and the right SELinux
  context on all 150 certs each boot.
- **Ad-blocking** runs through AdAway in systemless mode plus Pi-hole on the LAN.

### UI fixes

- **Status bar restored.** MLS had set `status_bar_height` to `0dp` in
  `framework-res.apk`, so SystemUI drew a zero-height bar. It is patched to `24dp` and
  re-signed with the AOSP platform key, so the clock, icons and pull-down shade work.
- **Night screen.** The always-on daydream clock kept the panel lit around the clock.
  A schedule darkens it overnight and runs a nightly `fstrim`, which reclaimed 1.14 GB
  on its first pass.

### Access

- **ADB** over Wi-Fi and **SSH** (SimpleSSHD, key auth), both auto-enabled on boot.
  Root is permanent. If it ever breaks, `mtk-su` restores it over wireless ADB.

---

## Part 2: The custom kernel

The stock 4.4.22 was a dead end, so this rebuilds the kernel from the vendor base and
adds real capabilities. The shipping build is **`maic-4.4.302`** (rm8), built with
GCC 5.4.

### What we built and how it went

- **Bumped to Linux 4.4.302** and fixed the hardware along the way: the front camera
  (GC5024 MIPI settle timing plus a mirror), the speaker (Emdoor DSP, I2S, and an AFE
  SRAM `memset_io` fault), and touch and USB-host parity.
- **It bit back, and the safety net held.** Two hardening builds (rm5 and rm6) turned
  on `DEBUG_RODATA` and software PAN, which fault on this A35 vendor kernel and never
  boot. The [auto-rescue](#the-auto-rescue) caught both, restored stock from recovery
  on its own, and the device never bricked. The shipping kernel drops those two
  options and keeps everything else.
- **Then the good builds.** rm7 added hardware crypto and the USB security fixes, and
  rm8 added in-kernel WireGuard. Each was flashed supervised with the rescue armed.

```mermaid
flowchart LR
    rm4["rm4 (daily): camera, audio, overclock"] --> rm7["rm7: + crypto CE, USB CVEs"]
    rm4 -.->|hardening attempt| rm56["rm5 / rm6: DEBUG_RODATA + SW PAN"]
    rm56 -->|"did not boot"| rescue["auto-rescue restored stock"]
    rm7 --> rm8["rm8 (shipping): + WireGuard"]
```

### Kernel features

| Area | Feature |
|---|---|
| Camera | GC5024 MIPI settle fix (`14` to `85`) plus horizontal mirror, so the front camera captures |
| Audio | Emdoor Synaptics DSP (CX2092x), AFE external amp and I2S, plus an AFE SRAM `memset_io` fix |
| CPU | Interactive governor, overclock **598 to 1500 MHz**, and a thermal throttle that actually lowers the frequency (validated over a 4-day soak, 85 C peak) |
| Crypto | ARMv8 Crypto Extensions (AES, GHASH/PMULL, SHA-1, SHA-2) for hardware dm-crypt, TLS and WireGuard |
| VPN | **WireGuard** in-kernel, backported via `wireguard-linux-compat` |
| Security | The 2024 USB exploit-chain fixes CVE-2024-53104 (uvcvideo), CVE-2024-50302 (HID) and CVE-2024-53197 (usb-audio), plus stack protector and `dmesg_restrict` |
| Filesystems | exFAT, NTFS, ext4, f2fs, vfat and iso9660 built in |
| Network | `fq_codel` as the default qdisc (bufferbloat) |
| Container | overlayfs and full cgroup and namespace support for Docker |
| Memory | tuned `dirty_ratio`, `page-cluster` and `extra_free_kbytes` for the 2 GB target |

Left out on purpose: `DEBUG_RODATA` and `ARM64_SW_TTBR0_PAN` (they do not boot on this
SoC), KASLR (no bootloader entropy), and anything that bumps the GPU DDK or the
Wi-Fi/BT firmware ABI (those are blob-locked).

### Docker

The stock kernel could not run Docker, since it had no overlayfs, cgroups or
namespaces. The custom kernel adds all three, so real Docker runs on-device with
three Android-host workarounds: a private-namespace `/run` and resolv overlay, a CA
bundle built from the system trust store, and `DOCKER_RAMDISK`. It starts
automatically on boot.

### Building the kernel

The build is containerized so the toolchain is reproducible. The kernel source is the
vendor Emdoor/MT8167 4.4.22 tree plus the changes in `patches/`.

1. **Toolchain image.** GCC 5.4 (Ubuntu 16.04 `gcc-5-aarch64-linux-gnu`):
   ```sh
   docker build -t maic-kbuild-gcc5 kernel-project/docker-gcc5/
   ```
2. **Compile.** `build-g55.sh` seeds `.config` from the previous output, runs
   `olddefconfig`, then builds the `Image`:
   ```sh
   OUT=out_rm8 ./kernel-project/build-g55.sh
   ```
3. **Package** into a flashable boot image. This reapplies the Magisk
   `skip_initramfs` to `want_initramfs` kernel patch, packs with `mkboot.py`, and
   refuses to emit a candidate unless every gate passes (version string, device
   drivers present, ramdisk under the 4 MiB ceiling):
   ```sh
   OUTDIR=out_rm8 ./kernel-project/patches/backport/tools/pack_candidate.sh \
     <kernel-tree> maic-4.4.302-rm8 4.4.302
   ```
4. **Flash** the resulting `boot_*.img` to `boot` (`p9`). Arm the rescue, write, read
   back, and verify the checksum before rebooting. If it does not boot, recovery
   restores stock on its own.

```mermaid
flowchart TD
    A["vendor source + patches"] --> B["build-g55.sh (GCC 5.4, Docker)"]
    B --> C["pack_candidate.sh: Magisk patch + gates"]
    C --> D{"gates pass?"}
    D -->|no| B
    D -->|yes| E["arm rescue on /data"]
    E --> F["flash boot p9: write + readback verify"]
    F --> G["reboot"]
    G --> H{"boots to Android?"}
    H -->|yes| I["running custom kernel"]
    H -->|no| J["recovery auto-restores stock"]
    J --> B
```

### The auto-rescue

`p9` (boot) used to be a one-way door. A roughly 5 KB freestanding binary in the
recovery ramdisk restores a known-good boot image, pre-armed on `/data`, whenever the
device is booted into recovery. It validates the image (16 MiB, `ANDROID!` magic,
`ROOTFS` not `RECOVERY`), writes it, reads it back and verifies, and refuses on any
mismatch. It fired for real when rm5 and rm6 failed and brought the device back on its
own. The rescue target is always the stock kernel.

> **Never** write `preloader`, `lk`, or `nvram`. That is how these MediaTek boards
> hard-brick. Everything here stays on `boot` (`p9`) and `recovery` (`p10`).

## Repository layout

```
kernel-project/   custom-kernel build harness, patches, packaging (mkboot.py) and notes
  patches/        the kernel changes: overclock, crypto, USB CVEs, WireGuard, tuning
  build-*.sh      GCC 5.4 and GCC 4.9 dockerized builds
scripts/          on-device boot scripts (CA store, performance, night screen)
tools/            ntfs-3g and mtk-su helpers built for this device
certs/            ISRG Root X1 and X2 (Let's Encrypt) for the trust-store fix
```

## Known limitations

Not fixable with root alone (ROM or hardware):

- **No WPA3** (2016 supplicant, Android 7 framework), **no Google services** (only
  GMS-free clients), and **no volume slider** (removed from the SystemUI code, though
  the hardware buttons still change volume).
- The camera is low-res, front-only, with no night vision.
- The GPU firmware, Wi-Fi/BT and the camera ISP are closed blobs matched to the 4.4
  vendor ABI, so those drivers stay frozen at their stock versions.

## Disclaimer

This is personal restoration work for one specific, obscure, discontinued device,
shared in case it helps another MAIC owner. There is no warranty. Flashing a MediaTek
device can brick it. Read the [auto-rescue](#the-auto-rescue) section before you write
anything.
