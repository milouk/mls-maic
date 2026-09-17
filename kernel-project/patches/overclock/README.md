# MT8167 undervolt / overclock - prepared, not deployed

Prepared 2026-09-15 in the isolated tree `maic-wt-oc`. Source plan: `docs/research/overclocking.md`.
Nothing was flashed or written on the tablet. Device facts below were read-only captures on our
kernel (`root@bbf13c661ee2`) before this fork lost device access; raw outputs are in `device-facts/`.

## Device facts (read-only, `device-facts/`)

- **CPU policy:** governor `performance`, set at boot by `/data/adb/service.d/perf.sh`. The same
  script also disables MTK hotplug (`echo 0 > /proc/hps/enabled`) and writes a non-existent GPU OPP
  (390000 kHz) that does nothing. `time_in_state`: 92126 of 92690 ticks at 1300000 kHz.
  Available governors: ondemand userspace powersave interactive performance.
- **OPPs:** 598000 747500 1040000 1196000 1300000 kHz (1.3G bin).
- **PTP/EEM live table:** 1300000/1196000 @ 1175000 uV, 1040000 @ 1168750 uV, 747500/598000 @ 1150000 uV (floor);
  `ptp_offset` = 0. So **runtime undervolt headroom is only ~25 mV** (4 PMIC steps) before every OPP hits the
  1150 mV clamp.
- **PMIC registers** (`pmic_vosel_and_idle.txt`): VPROC 1175-1181.25 mV, VCORE 1150 mV, stable over ~27k SODI
  cycles. SODI restores a live backup of VPROC (safe for OC voltages) and does not use its fixed 1125 mV VCORE
  entries. Deep idle (`dpidle`) usage is 0.
- **Thermal:** zones mtktswmt, mtktsbattery, mtktscpu, mtktspmic, mtktsAP. The userspace thermal daemons
  (`/vendor/bin/thermal`, `thermald`, `com.mediatek.thermalmanager`) configure `mtktscpu`:
  117 C sysrst, 107 C shutdown, 100 C cpu00, 89 / 85.5 / 80.4 C adaptive coolers. These differ from
  the driver defaults and stay in force.
- **GPU:** 400M table 403000/299000/253500 kHz, all at 115000 (1.15 V); voltage switching compiled out.
- **Clock parents** (`clock_parents_summary.txt`): eMMC `msdc0` and SD `msdc1` on `mainpll_d8`,
  `msdc2` on `univpll_d6`. MMPLL feeds only the GPU (`mfg_bg3d`); `mtk-sd.c` never reparents. **GPU OC is not
  blocked by the storage clock.**
- Also noted in source: the vendor driver itself has a **1.5G efuse bin at 1500 MHz @ 1.30 V**
  (`mt8167-cpufreq.c`, `lv == 1`), so our 1500 MHz @ 1.35 V is conservative relative to the vendor's own bin.

## What is implemented (`overclock.patch`, 4 files, additive, applies cleanly to `maic-kernel`)

| Option | Effect |
|---|---|
| `CONFIG_MAIC_CPU_OC` (default n) | Adds 1400 MHz @ 1.325 V and 1500 MHz @ 1.35 V (= buck_vproc DT max) on efuse bins 0/2. **Dormant at boot**: `policy->max` starts at 1300 MHz, so the kernel behaves like stock until `scaling_max_freq` is raised. PTP scans OPPs from `freq_base` (1300 MHz) down, so it never undervolts the OC OPPs. MTK's power table (`opp_tbl_default`, 8 slots) picks up the new OPPs automatically, so thermal power throttling covers them. |
| `CONFIG_MAIC_GPU_OC` (default n) | Selects the vendor 500M GE8300 table (494 MHz @ 1.25 V, then stock OPPs @ 1.15 V) on non-E1 chips that would use the 400M table. Re-enables the GPU supply voltage call on `buck_vcore`, clamped to 1150-1250 mV with a 2 ms settle on the way up. Fixed-frequency debug pinning above 403 MHz raises vcore first. |

Compile-verified: OFF (functionally identical to parity: two objects byte-identical, `mtk_ptp.o` differs
only in `__LINE__` constants), CPU=y/GPU=y, CPU=y/GPU=n. `maic-wt-oc`'s `.config` is left with both OFF.

## Candidates (`kernel-project/out/candidates/overclock/`, see `CHECKS.txt`)

| image | config | md5 |
|---|---|---|
| `boot_cpu-oc.img` | CPU OC on, GPU off | `78707e0f601b1336987eb815a144468d` |
| `boot_cpu-gpu-oc.img` | CPU + GPU OC on | `8fd315b7771c95adc45688c49203a4a8` |

Both are packed on `boot_PARITY_USB_77bf6b99.img` (ramdisk and cmdline preserved) and gated on:
Magisk `want_initramfs` x1 (4 bytes changed), `skip_initramfs` x0, `maic_synaptics_dsp`, `External I2S out`,
stock touch id `0x93832a`, no `swmode`, plus the OC marker strings. All passed.

## Tooling (`scripts/`)

- `maic_stress` (static aarch64, source `maic_stress.c`): N-thread load that verifies every round
  against a golden result, so silent miscomputation is caught, not just crashes.
- `monitor.sh`: CSV of freq/limits/governor/online cores/temps/**real** vproc+vcore (PMIC register)/GPU freq/PTP.
- `emmc_verify.sh`: write, drop caches, read back, compare md5.
- `soak.sh`: runs stress + eMMC verify + monitor. `-f KHZ` PINS min=max (proves the OPP: voltage,
  arithmetic, eMMC — but a pin also defeats thermal throttling, see below); `-x KHZ [-g GOV]` sets a
  CEILING only (min untouched, real-use configuration; logs every `policy->max` change as a `throttle:`
  line and the ATM/notifier dmesg lines into `thermal_<stamp>.raw`). Aborts and restores limits on
  temperature > threshold, arithmetic mismatch or I/O mismatch. Writes PASS/FAIL.
- `uv_step.sh`: runtime undervolt via `ptp_offset` (volatile): status / step with soak and auto-revert / revert.
- `zz_maic_uv.sh`: optional boot-guarded re-apply of the last good offset.
- `perf.sh.replacement`: interactive governor over the full range (`OC_MIN_KHZ=598000`, hispeed 1300000,
  1400/1500 at ~90 % load) with an explicit `OC_MAX_KHZ` ceiling (1300000 until validated, then 1500000),
  rm3 ceiling knob written first, boot guard, HPS left off as before, the bogus GPU write removed, all
  I/O/VM tuning kept.
- `ceiling_guard.sh` (device only, `/data/local/maic_oc/`): TEMPORARY lower-only 3 s watchdog holding
  `scaling_max_freq` at 1300000 on rm2 until rm4 is flashed. Remove once the knob kernel is in.

## Findings on the device, 2026-09-16/17 (rm2 = CPU OC dormant, on the 4.4.302 backport)

- **"Dormant" leaks.** The `->init()` clamp only sets the default. `[922:PerfServiceMana]` (MTK
  PerfService in system_server) writes `scaling_max_freq=1500000` (= `cpuinfo_max_freq`) and rotates
  `scaling_min_freq` through 1300000/1196000/1040000/598000 on every boost. Under `performance` the CPU
  then sits at 1500 MHz @ 1.35 V unrequested (69 s, then ~10 min, then ~2 min observed). Fix: rm3
  `maic_oc_ceiling_khz` enforced in `->verify()` (`ceiling-knob.patch.txt`).
- **The thermostat pulled a lever connected to nothing.** ATM engages at 80.4 C and cuts the CPU budget
  to its 300 mW floor in seconds, but vendor `mt_cpufreq_thermal_protect()` has the core-count match
  commented out, so in a power-sorted table 300 mW resolves to **1 core @ 1400 MHz**. The core limit is
  applied through HPS, which perf.sh disables; the frequency never dropped and the SoC reached 90.7 C
  (ceiling-mode soak, 1400 MHz, 3 min). Same gap on the stock-1300 daily config (4a peaked 80.3 C).
  Also: the vendor cpufreq notifier refuses any clip below `policy->min`, so a pinned soak (`-f`) can
  never show throttling, and a 1300 floor would cap throttling at 1300. Fix: rm4
  (`thermal-throttle.patch.txt`): core-count match restored (prefer keeping cores, lower the frequency;
  zero OPP slots skipped) and the clip overrides the floor (guarded on `clipped_freq != 0`).
- Stage results: 4a (1300 pinned) PASS, peak 80.3 C. 4b (1400 pinned) thermal abort at 90.2 C after 9 min,
  CPU/eMMC clean, vproc 1325 mV — an OPP-valid, throttle-blind run. Ceiling 1400 on rm2: 90.7 C, see above.
- Candidates (`kernel-project/out/candidates/backport/`): `maic-4.4.302-rm2-cpuoc-gcc54` (5b084d2b, ON
  DEVICE), `maic-4.4.302-rm3-cpuoc-ceiling-gcc54` (5516513584…, superseded, not flashed),
  `maic-4.4.302-rm4-cpuoc-thermal-gcc54` (rm3 + throttle fix; md5 in its `CHECKS.txt`).

## Recommended order

1. **Governor first** (stage 2): dropping `performance` is the biggest real-world win (idle heat), zero risk.
2. **Runtime undervolt** (stage 3): small here (≤25 mV) because PTP already runs this chip near its floor.
   Deeper UV means lowering PTP `VMIN` in `mtk_ptp.c`; not implemented, as it lowers the floor for every OPP
   and belongs to a separate, slower validation.
3. **CPU OC** (stage 4): flash `boot_cpu-oc.img`; it boots at stock limits; stage 1400 then 1500 MHz via soak.
4. **GPU OC** last (stage 5), optional; little benefit for video playback (fixed-function decode).

## Expected gains

CPU burst +7.7 % (1400) / +15.4 % (1500). Sustained gains are thermally capped: 1500 MHz @ 1.35 V draws
about 1.5x the dynamic power of today's 1300 MHz @ 1.175 V operating point. GPU +22 % peak. Undervolt: lower
idle/light-load power, no performance change.

## Risks

- **Brick:** effectively none. Kernel-only; preloader/lk/nvram untouched; p9 is reversible via readback
  flashing and `maic_rescue` (stock).
- **Instability** at 1500 MHz is plausible; the soak's verified arithmetic catches marginal operation early.
- **GPU OC raises the whole SoC's digital rail** to 1.25 V while at 494 MHz, which means more heat and
  leakage. If deep idle (`dpidle`) ever becomes active, its PMIC table writes fixed VCORE values and would
  undercut the raised vcore; check `cpuidle/state0/usage` = 0 first. Input boost jumps to the top GPU OPP
  on touch, so vcore will step often.
- **Wear:** ≤1.35 V vproc / ≤1.25 V vcore with thermal protections intact. Avoid pinning OC OPPs 24/7:
  use interactive, not performance.

## Open items (need the device owner, read-only): `device-facts/TODO-on-device.md`
