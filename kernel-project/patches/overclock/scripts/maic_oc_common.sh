#!/system/bin/sh
# Shared helpers for the MAIC undervolt/overclock tooling. Source, don't run.
OC_DIR=/data/local/maic_oc
CPUF=/sys/devices/system/cpu/cpu0/cpufreq
PTP=/proc/ptp/PTP_DET_MCUSYS
PWRAP=/sys/kernel/debug/regmap/1000f000.pwrap/registers
mkdir -p $OC_DIR 2>/dev/null

ts() { date '+%F %T'; }
log() { echo "$(ts) $*" | tee -a $OC_DIR/oc_log.txt; }

# thermal zone path by type name (mtktscpu, mtktspmic, mtktsAP, mtktsbattery, mtktswmt)
tz_path() { for z in /sys/class/thermal/thermal_zone*; do [ "$(cat $z/type 2>/dev/null)" = "$1" ] && { echo $z; return; }; done; }
tz_temp() { p=$(tz_path "$1"); [ -n "$p" ] && cat $p/temp 2>/dev/null || echo -1; }   # milli-degC

# MT6392 VOSEL -> mV (700 + v*6.25). Reads are side-effect free (regmap debugfs, 11 bytes/line).
vosel_mv() {  # $1 = register (hex, e.g. 0220)
	# printf handles 0x... portably (toybox/mksh); avoids relying on $((0x..)) support
	skip=$(( $(printf '%d' 0x$1) / 2 ))
	v=$(dd if=$PWRAP bs=11 skip=$skip count=1 2>/dev/null | sed 's/.*: //')
	[ -z "$v" ] && { echo -1; return; }
	echo $(( (70000 + $(printf '%d' 0x$v) * 625) / 100 ))
}
vproc_mv() { vosel_mv 0220; }
vcore_mv() { vosel_mv 0314; }

gpu_khz() { grep -o 'g_cur_gpu_freq = [0-9]*' /proc/gpufreq/gpufreq_var_dump 2>/dev/null | grep -o '[0-9]*$'; }

# interactive governor tunables -- keep identical to /data/adb/service.d/perf.sh (OC variant)
set_interactive_tunables() {
	C=/sys/devices/system/cpu
	for T in $C/cpufreq/interactive $C/cpu0/cpufreq/interactive; do
		[ -d "$T" ] || continue
		echo 20000   > $T/timer_rate 2>/dev/null
		echo 1300000 > $T/hispeed_freq 2>/dev/null
		echo 85      > $T/go_hispeed_load 2>/dev/null
		echo 40000   > $T/above_hispeed_delay 2>/dev/null
		echo "80 1300000:90" > $T/target_loads 2>/dev/null
		echo 60000   > $T/min_sample_time 2>/dev/null
		echo 0       > $T/io_is_busy 2>/dev/null
	done
}
