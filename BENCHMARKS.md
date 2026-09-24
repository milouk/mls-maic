# Measured, not assumed

This device has accumulated a lot of "should help" kernel changes. This document is
the result of actually measuring them on the real hardware, live, rather than trusting
the reasoning that motivated each one. Several real, previously-unnoticed bugs turned
up in the process of trying to get honest numbers -- described below, mostly fixed in
the tree (`kernel-project/patches/`). Everything here was run on the real tablet with
Magisk 30.7, not in emulation: the network, I/O and memory results on `rm11`
(`4.4.302-cip114`), and the overclock investigation on debug builds that followed it,
ending in `rm12` (the same kernel with the overclock removed).

Where a test showed no meaningful difference, or showed the "wrong" direction, that is
reported too. The goal is an accurate picture, not a highlight reel.

## rm12 vs. the stock kernel, head to head

The A/B sections below each isolate one setting on one kernel. This section asks a
different question: does the whole custom kernel (`4.4.302-cip114`, rm12) actually beat
the factory kernel (`4.4.22 #33`)? Both were measured on the same tablet, same day, same
userspace (Magisk + the same `service.d` scripts), same 1.3 GHz silicon -- only the boot
image differed. The stock kernel was flashed (Magisk-patched so root survived for the
tools), benchmarked, then rm12 was restored from a byte-exact snapshot. Tooling was
identical: musl `fio` 3.41 and `iperf3` 3.20 copied to `/data` so they run without Docker
(the stock kernel can't run Docker at all -- see below).

| Metric | stock 4.4.22 | rm12 4.4.302-cip114 | Result |
|---|---|---|---|
| CPU 1 thread (centisec, lower=faster) | 873 / 878 | **864 / 867** | rm12 ~1.3% faster |
| CPU 4 threads, wall time | 903 | **881** | rm12 ~2.4% faster |
| App cold start, Settings (best of 3) | 534 ms | **455 ms** | rm12 ~15% faster |
| Ping under upload saturation (avg) | 57.8 ms | **27.1 ms** | rm12 ~2.1x lower latency |
| Ping under upload (max) | 150.8 ms | **77.7 ms** | rm12 ~2x lower spike |
| iperf3 retransmits (up / down) | 2 / 8 | **0 / 0** | rm12 cleaner |
| Congestion control available | cubic, reno | **+ bbr**, bic, westwood, htcp | stock lacks BBR |
| SysV IPC (Docker prerequisite) | **absent** | present | stock can't run Docker |
| zram compressor active | lzo | **lz4** | see zram A/B |
| KSM (RAM dedup) | off | **on** | stock lacks it |

The CPU and app-launch gains are the `-mtune=cortex-a35` scheduling plus the memory/IO
tuning, on identical silicon at the identical 1.3 GHz ceiling. The latency-under-load
halving is BBR + `fq` controlling bufferbloat, the most useful real-world network
difference on this device.

Two honest caveats:

- **Single-shot WiFi throughput is not reliable here and is not the story.** One 10 s
  `iperf3` upload sampled stock/cubic *higher* than rm12/bbr (33.7 vs 19.0 Mbit/s), and
  download roughly equal (14.2 vs 14.8). The MT6625L 2.4 GHz radio varies far more than
  that between back-to-back runs, so a single sample proves nothing about throughput. The
  rigorous, interleaved BBR-vs-cubic comparison is in "TCP: BBR vs. cubic" above; that is
  the authoritative throughput result. What the head-to-head *does* show robustly is
  latency and retransmits, where BBR wins consistently.
- **Storage was not compared cross-kernel.** `fio` needs a SysV shared-memory segment,
  which the stock kernel doesn't provide (`CONFIG_SYSVIPC` is off -- the same gap that
  blocks Docker), so it only ran on rm12 (random 4k 70/30: 2153 IOPS / 8.6 MB/s read,
  3.7 MB/s write; sequential 1M: ~20 MB/s each way). `dd` at the shell's 10 ms timer
  resolution is too coarse to trust for the rest. Raw eMMC bandwidth is a property of the
  media and the `mtk-sd` driver, which are unchanged between the two kernels; the storage
  decision that actually mattered -- the I/O scheduler -- is A/B-proven in its own section
  below.

**Every deliberate config choice checks out against stock:** `deadline` over stock's
`cfq` default (I/O section), `lz4` over stock's `lzo` (zram section), BBR + `fq` which
stock can't even offer (TCP section), KSM which stock lacks, and `-mtune=cortex-a35` worth
a measurable couple of percent. Nothing rm12 changed regressed against the factory kernel.


## TCP: BBR vs. cubic

Method: `iperf3` (device as sender, a LAN host as receiver over WiFi), interleaved
trials alternating congestion control to cancel drift, plus a separate external `ping`
run concurrently with a saturating transfer (classic bufferbloat methodology). Two
independent rounds, increasing rigor (more trials, longer duration) between them.

| | cubic | BBR |
|---|---|---|
| Throughput, round 1 (3x10s) | 32.08 Mbps (±6.59) | 21.00 Mbps (±2.80) |
| Throughput, round 2 (5x15s) | 22.91 Mbps (±4.06) | 15.58 Mbps (±3.98) |
| Retransmits, round 1 | 8 | 0 |
| Retransmits, round 2 | 22 | 1 |
| Max congestion window | 357-361 KB | 73-99 KB |
| In-flow RTT (iperf3-reported) | 60-94 ms | 22-44 ms |
| External ping under load, run 1 (avg/max) | 51 / 117 ms | 25 / 65 ms |
| External ping under load, run 2 (avg/max) | 95 / 273 ms | 37 / 106 ms |

**Honest headline: BBR is not faster.** cubic pushed 40-50% more raw throughput in
every trial, consistently, with more trials making the gap *larger* not smaller. It
gets there by growing its congestion window 4-5x larger than BBR's -- filling buffers
until it induces loss (8-30x more retransmits than BBR) and inflating latency for
everything else sharing the link, up to 273 ms in the worst case. BBR deliberately
keeps a much smaller queue footprint: consistently near-zero retransmits, and
latency-under-load roughly half of cubic's, confirmed independently by both iperf3's
own RTT tracking and a completely separate `ping` measurement.

The WiFi link tested is thin (20-40 Mbps -- this tablet's radio, not the AP) and 10-15s
trials may be short for BBR's bandwidth-probe phase to fully converge; a longer
sustained transfer would likely close some of the throughput gap. That caveat doesn't
change the latency result, which was consistent across every test run.

**Verdict for this device:** correct choice. It runs Docker, WireGuard and SSH
concurrently on one link; one bulk transfer running slower is a non-issue, every other
connection stalling behind it for up to a quarter-second is the actual problem BBR
solves. Set as the persistent default (`kernel-project/patches/tuning/maic_sysctl.sh`).

### Bug found: the qdisc sysctl was a no-op on the interface that matters

`net.core.default_qdisc=fq` only governs qdiscs created *fresh* for an interface. It
does not retroactively change one a driver already configured, and Android's WiFi stack
brings `wlan0` up with `mq`/`pfifo_fast` regardless of the sysctl, before any post-boot
script runs. Verified live: with the sysctl set to `fq`, `tc qdisc show dev wlan0`
still showed `mq`/`pfifo_fast`. **BBR had been running unpaced this entire time.**

Fix: `kernel-project/patches/bbr/maic_qdisc_wlan0.sh`, a boot script that explicitly
forces `tc qdisc replace dev wlan0 root fq` after the interface comes up. Measured
effect on top of BBR, otherwise identical conditions (3x15s trials):

| | BBR, sysctl only (driver default `mq`/`pfifo_fast`) | BBR, `fq` forced onto wlan0 |
|---|---|---|
| Throughput | 15.58 Mbps | **19.45 Mbps** (+25%) |
| Retransmits | 1 | **0** |
| In-flow RTT | 44.20 ms | **22.03 ms** (again roughly halved) |

No trade-off this time -- strictly better on all three axes. Verified persisting across
a clean reboot with zero manual intervention.

## I/O scheduler: deadline vs. cfq vs. noop

Method: read latency (`ioping`, 4 KiB direct reads) sampled *while* an 80 MB write is
saturating the eMMC in the background (`dd ... conv=fdatasync`), for each scheduler.
This is the textbook test for exactly what `deadline` is designed to guarantee: bounded
read latency regardless of write pressure. Two independent rounds.

| Scheduler | Round 1 avg / max | Round 2 avg / max |
|---|---|---|
| **deadline** | **486 / 519 µs** | **480 / 502 µs** |
| cfq | 512 / 588 µs | 529 / 589 µs |
| noop | 663 / **3810 µs** | 563 / **2040 µs** |

`deadline` wins clearly and consistently across both rounds: lowest average *and* by
far the tightest worst case. `noop` -- pure FIFO, no read/write prioritization at all --
shows occasional multi-millisecond spikes (up to 8x deadline's worst case) exactly as
expected when a bulk write can starve a read indefinitely. `cfq` sits in between,
consistent with it optimizing for fairness rather than a hard latency bound.
**Confirms the kernel default (`deadline`) was the right call, and specifically that
`noop` would have been the wrong one** despite being the "simplest" option.

## zram: lz4 vs. lzo

Only these two compressors are compiled in (no zstd). Tested on an isolated `zram1`
device (hot-added via `/sys/class/zram-control/hot_add`), never touching the live swap
device, with a ~17 MB payload built from real `/system` files (APK/JAR/odex/so content,
not synthetic zeros or random data).

| | Compression ratio | Decompress throughput (3 runs) |
|---|---|---|
| lzo | **1.546x** (10.9 MB compressed) | 132-134 MB/s |
| lz4 | 1.455x (11.6 MB compressed) | **145-148 MB/s** (~10% faster) |

lzo compresses ~6% smaller; lz4 decompresses ~10% faster, consistently across 3 repeated
trials each. Since swap-*in* (decompression) sits on the interactive page-fault path and
swap-out (compression) is a background operation, decompression speed is the more
latency-relevant metric on a low-RAM device where responsiveness matters more than swap
footprint. **This empirically confirms lz4 was the right choice** (it had been selected
on this reasoning previously, but not measured until now).

## Overclocking: not possible on this chip (CPU or GPU)

Short version: this tablet's SoC is the **MT8167B**, the 1.3 GHz / 400 MHz-GPU bin of
the MT8167 (the MT8167A is the 1.5 GHz bin). The speed bin is fused, and the chip
enforces it in its clock hardware, below anything a kernel can change. An earlier
overclock (1400/1500 MHz CPU, 494 MHz GPU) was built, shipped and "validated", but it
never ran faster than stock. It has been removed from the kernel and from this repo
(`rm12`). The CPU runs the stock 598-1300 MHz range and the GPU the stock 253.5-403 MHz
range.

### Why it looked like it worked

`scaling_cur_freq`, `cpuinfo_cur_freq`, `/sys/kernel/debug/clk/clk_summary` and the
cpufreq stats all showed 1500 MHz. They all come from the kernel's own bookkeeping, so
they report what was requested, not what the silicon is doing. Three CPU benchmarks
(`gzip`, a shell arithmetic loop, `sysbench cpu`) showed no difference between "1300"
and "1500", which is what started the investigation.

Two real software bugs sat on top of the hardware limit and hid it. Neither mattered in
the end:

- A stale boot-guard marker had silently kept the ceiling at 1300 MHz for over a day.
- MTK's PTP driver (`ptp_cpufreq_notifier()` in `mtk_ptp.c`) re-clamps every cpufreq
  policy change to a ceiling it captures once at early boot, before userspace raises
  it. A resync hook fixed that, but the clock still didn't move.

### What actually stops it

Measured on the device with the SoC's own frequency meter (`/proc/clkdbg`, `fmeter`):
`mcusys_debug_mon0` x ~257 kHz is the real CPU clock (2326 at 598 MHz, 5058 at 1300 MHz),
and `csw_mux_mfg_ck` is the real GPU clock in kHz (403,050 at 403 MHz). A kernel built
with extra logging read the PLL register back before and after every write.

| Attempt | Result |
|---|---|
| CPU: normal `ARMPLL_CON1` write, 1400 / 1500 MHz at /1 | The register drops the write. It reads back unchanged immediately after `writel()`. |
| CPU: the same write again with the `PCW_CHG` latch bit toggled | Still dropped |
| CPU: VCO 2800 / 3000 MHz with a /2 post-divider | Dropped. Even VCO 2600 /2 (a 1300 MHz output) is dropped. |
| CPU: FHCTL frequency-hopping controller drives the PLL (`FHCTL0` DVFS mode, DDS/MON reach the 1500 or 2800 MHz target) | Real clock stays at ~1.3 GHz |
| CPU: other clock sources | The CPU mux (`ifr_mux1_sel`) only offers `clk26m`, `armpll`, `univpll` (1248 MHz) and `mainpll_d2`. None is above 1.3 GHz. |
| GPU: 494 MHz OPP (vendor "500M" table, vcore raised to 1.25 V) | `MMPLL_CON1` drops the write-back. The GPU stays at 403 MHz. |
| GPU: FHCTL3 kept in control at the 494 MHz DDS | The meter still reads 403,050 kHz |

A raw read-only dump of the clock/efuse register space (apmixedsys `0x10018000`, efusec `0x10009000`, mcucfg `0x10200000`, via the in-kernel `clkdbg reg_read`) confirmed there is no writable frequency-limit register to raise: `ARMPLL_CON1` holds the live pcw/postdiv, and nothing in the efuse or mcucfg space is a software-liftable ceiling. The limit is enforced inside the PLL, downstream of every register software can write.

Accepted settings are exactly the stock operating points (598, 747.5, 1040, 1196, 1300
MHz). 747.5 MHz (VCO 1495 /2) really runs at 747.5 (benchmark-checked), so the PLL can
run a VCO above 1.3 GHz. It is the output above the bin that is refused, and the clamp
holds even when FHCTL feeds the PLL directly. That points to a fuse-driven limiter in
the PLL itself, not to anything in the register decode or in software.

Benchmark with each strategy (single-threaded `awk` loop, centiseconds, lower is
faster):

| Setting | Time | vs. 1300 |
|---|---|---|
| 598 MHz | 3525-3569 | scales with the clock, so the benchmark is valid |
| 747.5 MHz | 2830-2836 | real (2820 expected) |
| 1300 MHz | 1613-1625 | baseline |
| "1400/1500 MHz", any strategy | 1599-1623 | 0-1% (a real 1500 would be ~15%) |

An earlier note here said that requesting 1500 MHz under 4-core load dropped the CPU to
747.5 MHz. That was a test artifact: the register had dropped the 1500 MHz write, so the
PLL stayed at whatever the previous operating point had been.

### Outside research

- No public MT8167/MT8516 preloader, LK or ATF source exists. The leaked MediaTek
  preloaders for sibling chips (MT6580/6735/6755/6765) only use the speed-bin fuse to
  pick boot-time values. None of them programs a "max frequency" register that a
  kernel could raise.
- The vendor kernel has no unlock step. On a 1.5 GHz-binned chip (`lv == 1`), the same
  `ARMPLL_CON1` write simply works.
- The MT8167B bin also limits video decode (1080p30 vs 1080p60) and display resolution,
  which fits chip-wide fuse gating.
- The well-known "MediaTek overclocks" of that era are GPU (`MMPLL`) values or
  unverified `scaling_cur_freq` claims. No verified above-bin CPU overclock was found for
  MT8163/8167/8516/6735/6580, including on the heavily hacked MT8163 Fire HD 8.

### What was kept

The thermal-throttle fix that was developed alongside the overclock
(`kernel-project/patches/thermal/`) is a real vendor bug that also hits the stock
1300 MHz operating point. The vendor code only reduced the core count, which does
nothing with MTK hotplug off, so the SoC ran past 80 C. It now lowers the frequency, and
it is built unconditionally.

## KSM (kernel samepage merging) -- live, not benchmarked

Not an A/B test -- KSM is always-on, so this is just a direct measurement:

```
pages_shared=633  pages_sharing=8478  pages_unshared=23037  pages_volatile=32493
```

`pages_sharing` (8478) x 4 KiB pages = **~33.1 MB of RAM currently deduplicated** across
the running container/app set, at the moment this was captured. This number moves with
what's actually running; it's a live floor, not a synthetic benchmark result.

## Crypto: ARMv8 Crypto Extensions

`/proc/crypto` confirms the kernel selects the hardware-accelerated driver over the
generic one by priority (`cbc-aes-ce`, priority 300, beats the generic `cbc(aes-generic)`
at a lower priority) -- i.e. `CONFIG_CRYPTO_AES_ARM64_CE` is genuinely active for kernel
crypto users (dm-crypt, IPsec, WireGuard-adjacent kernel paths), not just compiled in
and unused. No on-device throughput benchmark: neither `openssl` nor `cryptsetup` is
available, and installing them via a container would test userspace's own ARMv8 ASM
crypto routines, a separate code path from the kernel driver this config actually
gates. Presence confirmed; throughput not independently measured this session.

## Driver-tuning sweep (2026-09-24): what's already optimal, what isn't tunable

After fingerprinting every vendor driver (GPU PowerVR GE8300 DDK 1.8, WiFi MT6625L
connsys gen2 `11_70_00_20161025_1`, camera GC5024, touch gslX680, amp ad82584f) and
searching for updates/optimizations/hacks, the honest headline is: **the device is
already near-optimally tuned**, and most remaining levers are either vendor-enabled,
hardware-fused, or behind a closed ABI. Details:

### Audio amp (ad82584f) -- measured, left at vendor default

The one lever with real day-to-day upside is the class-D amp. To decide *safely* whether
there was clean headroom to raise output, the amp was measured with a deterministic
acoustic A/B: inject a fixed tone at the speaker DAC via the AFE sine generator
(`Audio_SideGen_Switch = AFE_SGEN_O3O4`), capture it with the built-in mic (`tinycap`
on `MultiMedia1_Capture`), and analyze RMS / FFT / THD on a host.

| Amp channel volume | mic RMS | THD (acoustic) |
|---|---|---|
| 231 (vendor default) | -54.4 dBFS | ~13% |
| 246 (raised) | -53.9 dBFS | ~3.9% |

The method is deterministic and repeatable, **but the built-in mic captures the speaker
at only ~-54 dBFS**, so the A/B deltas (+0.5 dB RMS; the THD numbers) are within
measurement noise -- not precise enough to reliably detect clipping onset. Since the amp
is already at near-maximum (Master 246/255, Speaker PGA +14 dB) and raising gain without
trustworthy distortion measurement risks shipping audible clipping, **the amp was left at
the vendor default.** A calibrated result would need an external mic/line capture, which
isn't available remotely. Conclusion: measurable in method, not safely improvable with
on-device instrumentation, and already well set by the vendor.

### Already optimal (verified live) -- no change needed

- **HW video decode is engaged**: `MtkCodecService` + `mediacodec` services running; the
  H.264/HEVC 1080p30 decode path is active, not falling back to software.
- **GPU input-boost is already enabled** (`/proc/gpufreq/gpufreq_input_boost`), and the
  GPU is capped at its fused 403 MHz OPP -- pinning it would only defeat DVFS/thermal for
  no gain. GPU 494 MHz is fused off in hardware (same as the CPU overclock).
- **WiFi doesn't sleep**: Android `wifi_sleep_policy = 2` (never) is already set.
- **WiFi aggregation/SGI/QoS** (`CFG_SUPPORT_AMPDU_TX/RX`, `RX_SGI`, `QOS`) are already
  `=1` in the driver config.

### Not tunable without a kernel rebuild or new hardware

- **802.11 power-save** has no clean runtime knob on connsys gen2; disabling it (a small
  latency win on an always-on device) needs the `CFG_SUPPORT_PWR_MGT` compile flag -- a
  candidate for a future kernel, not a runtime change.
- **Touch** report-rate/sensitivity is firmware-burned in the gslX680 config array; only
  the coordinate calibration (`cal_*`) is tunable, and that's already done.
- **GPU driver / WiFi firmware** can't be updated: the PowerVR blob is BVNC-locked to
  22.40.54.30, and `WIFI_RAM_CODE_8167` is a frozen 2016 device blob. Community WiFi
  forks are the same driver repackaged.

### Vendor-driver CVEs -- fingerprinted, nothing worth backporting

Every vendor-driver CVE that maps to this device (PowerVR `pvrsrvkm` 2021 series, connsys
gen2 June-2018 cluster, MTK camera/cmdq) is **local privilege-escalation requiring a
malicious app already installed** -- and the WLAN `gl_proc.c` bounds fix is already
present in-tree. No *remotely* reachable vendor-driver bug exists for this hardware (the
scary MediaTek WiFi RCEs are all AP/router mt76 chipsets, not our MT6625L client). For a
curated, GMS-free appliance behind home NAT, that attack surface is near-zero, and the
one confirmed local hole (CVE-2020-0069) is best left unpatched because fixing it breaks
`mtk-su`, the cable-free root-recovery tool. CIP already covers the network/filesystem
surface.

## Bugs found and fixed while trying to get honest numbers

Three real, previously-unnoticed problems turned up purely from insisting on verifying
"is this setting actually active" rather than trusting that it was, once set:

1. **A stray backup script silently undid a config change on every boot.**
   `maic_sysctl.sh.bak.pre-bbr` (a backup created mid-session) was left inside
   `/data/adb/service.d/`, which Magisk executes every file in, not just the intended
   one. It ran alphabetically after the real script and its old, uncommented
   `fq_codel` fallback line reverted the qdisc setting every single boot. Caught by
   insisting on a *zero-manual-intervention* verification after a clean reboot rather
   than trusting a live-set value that could have been left over from testing.
2. **The wlan0 qdisc sysctl was a no-op for the interface it was meant to control**
   (see above) -- found only by checking `tc qdisc show dev wlan0` directly instead of
   trusting `/proc/sys/net/core/default_qdisc`.
3. **The CPU overclock never overclocked.** Every software-side reading (`scaling_cur_freq`,
   `cpuinfo_cur_freq`, `clk_summary`, cpufreq stats) reported 1500 MHz, because they all
   read the kernel's own bookkeeping. The SoC's hardware frequency meter and a benchmark
   showed the chip enforcing its fused 1.3 GHz bin in the PLL. Two real software bugs
   (a stale boot guard, PTP re-clamping the policy) sat on top and hid it. The overclock
   was removed; see "Overclocking: not possible on this chip" above.

None of these were visible from configuration, from `scaling_max_freq`, or even from
`scaling_cur_freq` alone -- each required checking a more authoritative layer (a clean
reboot with zero manual intervention, `tc qdisc show` instead of the sysctl, and
finally the SoC's hardware frequency meter instead of the kernel's own frequency
bookkeeping) and
refusing to accept "the setting is present" or "the driver says it worked" as proof
that it did.
