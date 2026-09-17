# Read-only checks still wanted (for the device owner; this prep fork may no longer touch the tablet)

All commands are read-only. Run as root (`su -c`).

1. Interactive governor tunables actually exposed on this kernel (the policy0 dir was listed but not read):
   ls /sys/devices/system/cpu/cpufreq/policy0/ /sys/devices/system/cpu/cpufreq/interactive 2>&1
   for f in /sys/devices/system/cpu/cpufreq/interactive/* /sys/devices/system/cpu/cpufreq/policy0/interactive/*; do [ -f "$f" ] && echo "$f=$(cat $f)"; done
2. Efuse CPU bin actually read by the driver (the OC OPPs are only added on bins 0/2):
   dmesg | grep -iE "invalid efuse|MAIC CPU OC|dump_power_table" | head
3. After booting a CONFIG_MAIC_CPU_OC=y candidate (do NOT raise scaling_max_freq yet):
   cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies   # expect ... 1300000 1400000 1500000
   cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq                # expect 1300000 (dormant)
   cat /proc/ptp/PTP_DET_MCUSYS/ptp_status                                  # expect exactly 5 freq[] lines, top 1300000
   dmesg | grep dump_power_table | tail -30                                 # expect 1400000/1500000 rows
4. After booting a CONFIG_MAIC_GPU_OC=y candidate:
   cat /proc/gpufreq/gpufreq_opp_dump      # expect [0] 494000 125000
   cat /sys/kernel/debug/regulator/regulator_summary | grep -A2 vcore
   dmesg | grep -i "MAIC GPU OC"
5. Before and after any GPU OC test, confirm deep idle is still unused (its PMIC table would reset vcore):
   cat /sys/devices/system/cpu/cpu0/cpuidle/state0/usage   # expect 0
