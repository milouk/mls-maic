# Undervolt / overclock test plan (MAIC iQR70, MT8167)

Everything here is staged: do not start a stage until the previous one passed. Each stage has an
explicit pass criterion and rollback. Nothing in this directory has been run on the device.

## Stage 0 - prerequisites (read-only checks + copy tooling)

1. Rescue armed and pointing at stock:
   `ls -l /data/maic_rescue/DO_RESTORE; md5sum /data/maic_rescue/boot_restore.img` -> `4c65df18406167aba3bf4b1e33565cfd`.
2. Known-good kernel image on the device and on the Mac: `kernel-project/out/boot_PARITY_USB_77bf6b99.img`
   (md5 `77bf6b99ea9e03c06078bc837594e50a`).
3. Copy tooling to `/data/local/maic_oc/` (from the Mac):
   ```sh
   W=kernel-project/out/work; S=kernel-project/patches/overclock/scripts
   for f in maic_oc_common.sh monitor.sh emmc_verify.sh soak.sh uv_step.sh maic_stress; do
     $W/push.sh $S/$f $f 755; done
   $W/tr.sh 'mkdir -p /data/local/maic_oc && for f in maic_oc_common.sh monitor.sh emmc_verify.sh soak.sh uv_step.sh maic_stress; do mv /data/local/tmp/$f /data/local/maic_oc/; done; ls -l /data/local/maic_oc'
   ```
4. Run the read-only items in `device-facts/TODO-on-device.md` (1, 2, 5).

## Stage 1 - baseline soak on the current parity kernel (validates the tooling)

`sh /data/local/maic_oc/soak.sh -f 1300000 -m 30 -t 90`

- PASS criteria: `soak_result.txt` = PASS; no reboot; `soak_<stamp>.csv` max `t_cpu_mC` < 85000;
  `stress_*.txt` RESULT PASS; `io_*.txt` all OK.
- Record the baseline peak temperature. Later stages compare against it.
- Rollback: none needed (limits restored by the script).

## Stage 2 - governor (perf.sh replacement), OC_MAX_KHZ=1300000

1. Back up and replace: `cp /data/adb/service.d/perf.sh /data/local/maic_oc/perf.sh.orig`, install
   `scripts/perf.sh.replacement` as `/data/adb/service.d/perf.sh` (0755), reboot.
2. Verify: `scaling_governor` = interactive, `scaling_max_freq` = 1300000, `/proc/hps/enabled` = 1.
3. `sh soak.sh -m 30` (no `-f`: governor-driven) and a day of normal TV/streaming use.

- PASS: soak PASS; UI/streaming feel unchanged; idle temperature lower than stage 1.
- Rollback: copy `perf.sh.orig` back, reboot.

## Stage 3 - runtime undervolt (no kernel change, volatile)

`sh uv_step.sh status`, then repeat `sh uv_step.sh step -m 10` until it reports FAIL or
"runtime UV exhausted". Each step soaks 10 min at 1300 MHz + 3 min at 1040 MHz.

- Expected on this unit: at most 4 effective steps (-25 mV): PTP already runs 1300/1196 MHz at
  1175 mV and 747.5/598 MHz at the 1150 mV floor.
- PASS per step: `uv_last_good` updated. Then 24 h of normal use at `uv_step.sh apply-last-good`.
- Optional persistence: install `scripts/zz_maic_uv.sh` into `/data/adb/service.d/` (boot-guarded).
- Rollback: `uv_step.sh revert`, or simply reboot (offset resets to 0). A hang = power-cycle.

## Stage 4 - CPU overclock kernel (optional, opt-in)

1. Flash `kernel-project/out/candidates/overclock/boot_cpu-oc.img` (md5 `78707e0f601b1336987eb815a144468d`):
   push to `/data/local/tmp/`, verify md5, `dd` to `mmcblk0p9`, read back p9 and compare md5 BEFORE reboot.
2. After boot, with nothing raised yet, run TODO-on-device item 3:
   `scaling_available_frequencies` ends `1300000 1400000 1500000`; `scaling_max_freq` = 1300000;
   `ptp_status` has exactly 5 freq lines (top 1300000); `dump_power_table` has 1400000/1500000 rows.
3. Stage 4a (dormant): `soak.sh -f 1300000 -m 30` must match stage 1. **Done 2026-09-16: PASS, 80.3 C.**
4. Stage 4b: `soak.sh -f 1400000 -m 30 -t 90` (the script raises the ceiling for the test and restores it).
   **Done 2026-09-17: thermal abort at 90.2 C after 9 min; CPU/eMMC clean, vproc 1325 mV.** A pinned run
   proves the OPP, not the thermostat: MTK's cpufreq notifier refuses clips below `policy->min`, and a
   pin sets min = max. Pinned 4b/4c should be short (`-m 10`) and read only for arithmetic/eMMC/vproc.
5. Stage 4c: `soak.sh -f 1500000 -m 10 -t 90` — same reading as 4b (OPP validity only).
6. **Stage 4d — thermostat (rm4 kernel required):** `soak.sh -x 1500000 -g interactive -m 30 -t 90`.
   PASS = the run completes AND `oc_log.txt` shows `throttle: max 1500000 -> <lower>` lines with the
   temperature plateauing at ~80-84 C (`thermal_<stamp>.raw` shows `set_adaptive_cpu_power_limit` and
   `mt_cpufreq_thermal_protect limited_max_freq` going below the ceiling). A 90 C abort with `max` still
   at the ceiling = throttle broken, stop. On rm2/rm3 this stage FAILS by design (90.7 C measured):
   the vendor throttle resolves its budget to fewer cores, and HPS is off.
7. Adopt: `perf.sh.replacement` with `OC_MIN_KHZ=598000` (full range), `OC_MAX_KHZ=1500000` (or 1400000) as
   `/data/adb/service.d/perf.sh` (backup `perf.sh.orig`), remove `ceiling_guard.sh`, reboot, verify
   `maic-oc.log` (ceiling/floor/knob line, guard cleared after 10 min) and 24 h of use. No further soaks.

- PASS per pinned sub-stage: no arithmetic/eMMC mismatch; `vproc_mV` shows 1325 (4b) / 1350 (4c); no
  reboot, no `last_kmsg` panic. Temperature is NOT a verdict for a pinned run (see 4).
- Stop at the last passing frequency. Do NOT raise the 1350 mV cap.
- Rollback: `echo 1300000 > scaling_max_freq` (instant); kernel: flash `boot_PARITY_USB_77bf6b99.img`
  back with readback; if it won't boot, enter recovery -> maic_rescue restores stock, then reflash.

## Stage 5 - GPU overclock kernel (optional, last)

Prerequisite: stage 4 adopted and stable for days; `cpuidle/state0` (dpidle) usage still 0.

1. Flash `boot_cpu-gpu-oc.img` (md5 `8fd315b7771c95adc45688c49203a4a8`) with the same readback procedure.
2. Verify: `/proc/gpufreq/gpufreq_opp_dump` shows `[0] freq = 494000, volt = 125000`;
   `dmesg | grep "MAIC GPU OC"`; no "set vcore ... failed".
3. GPU load (manual: a WebGL demo page in the browser or a 3D game) for 30 min while
   `soak.sh -m 30 -n 2` runs (keeps eMMC verify + CPU verify going) and `monitor.sh` logs
   `gpu_khz` and `vcore_mV` (expect 1250 while gpu_khz = 494000, 1150 otherwise).
- PASS: no GPU hang/visual corruption, soak PASS, eMMC verify OK, t_cpu < 85 C.
- Rollback: flash `boot_cpu-oc.img` (keeps CPU OC) or the parity image.
