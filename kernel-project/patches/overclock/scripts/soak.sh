#!/system/bin/sh
# soak.sh [-f KHZ | -x KHZ] [-g GOV] [-m MINUTES=30] [-t MAX_TEMP_C=90] [-n THREADS=4] [-i IO_MB=128]
#
# Stability soak for undervolt/overclock stages. Runs maic_stress (self-verifying) on N threads,
# loops emmc_verify.sh, and logs with monitor.sh. Two ways to select the frequency:
#   -f KHZ  PIN:     scaling_min_freq = scaling_max_freq = KHZ. Proves the OPP itself (voltage,
#                    arithmetic, eMMC). NOTE: MTK's thermal->cpufreq notifier
#                    (mtk_power_throttle.c) only clips policy->max when clipped_freq >= policy->min,
#                    so a pin also DEFEATS thermal throttling. A pinned run that reaches MAX_TEMP_C
#                    says nothing about throttling; use -x for that.
#   -x KHZ  CEILING: scaling_max_freq = KHZ, min untouched, governor -g (default: current). This
#                    is the real-use configuration: the governor drives the OPP and thermal (ATM,
#                    trips 80.4/85.5/89 C) can pull policy->max down. Throttle evidence is logged
#                    as "max_khz" transitions and in thermal_<stamp>.txt (dmesg).
# ABORTS (and restores all cpufreq limits) on:
#   - mtktscpu temperature above MAX_TEMP_C
#   - any maic_stress MISMATCH
#   - any eMMC read-back MISMATCH
# Writes PASS/FAIL to /data/local/maic_oc/soak_result.txt. Exit 0 = PASS.
# A hang or reboot is also a FAIL: /data/local/maic_oc/soak_running is left behind.
. /data/local/maic_oc/maic_oc_common.sh
KHZ=""; CEIL=""; GOV=""; MIN=30; MAXT=90; THR=4; IOMB=128
while getopts f:x:g:m:t:n:i: o; do case $o in
	f) KHZ=$OPTARG;; x) CEIL=$OPTARG;; g) GOV=$OPTARG;; m) MIN=$OPTARG;; t) MAXT=$OPTARG;; n) THR=$OPTARG;; i) IOMB=$OPTARG;;
	*) echo "usage: $0 [-f khz | -x khz] [-g governor] [-m minutes] [-t max_temp_C] [-n threads] [-i io_mb]"; exit 1;; esac; done
[ -n "$KHZ" ] && [ -n "$CEIL" ] && { echo "-f and -x are exclusive"; exit 1; }
[ -x $OC_DIR/maic_stress ] || { echo "missing $OC_DIR/maic_stress"; exit 1; }
MODE=pin; [ -n "$CEIL" ] && MODE=ceiling; [ -z "$KHZ$CEIL" ] && MODE=governor

OLD_GOV=$(cat $CPUF/scaling_governor); OLD_MIN=$(cat $CPUF/scaling_min_freq); OLD_MAX=$(cat $CPUF/scaling_max_freq)
# rm3+ kernels enforce a hard ceiling (maic_oc_ceiling_khz) in ->verify(); a pin above it
# must raise the knob for the run and put it back afterwards. Absent on older kernels.
KNOB=$(ls /sys/module/*/parameters/maic_oc_ceiling_khz 2>/dev/null | head -1)
OLD_KNOB=""; [ -n "$KNOB" ] && OLD_KNOB=$(cat $KNOB)
TZLOG=/proc/driver/thermal/tzcpu_log; OLD_TZLOG=$(grep -o "[0-9]*$" $TZLOG 2>/dev/null)
SECS=$((MIN * 60))
STAMP=$(date +%Y%m%d-%H%M%S)
RES=$OC_DIR/soak_result.txt
MPID=""; SPID=""; IPID=""; TPID=""
TAG="khz=${KHZ:-${CEIL:+ceiling-$CEIL}}"; TAG="${TAG:-khz=governor}"; [ -z "$KHZ$CEIL" ] && TAG="khz=governor"

restore() {
	[ -n "$MPID" ] && kill $MPID 2>/dev/null
	[ -n "$SPID" ] && kill $SPID 2>/dev/null
	[ -n "$IPID" ] && kill $IPID 2>/dev/null
	[ -n "$TPID" ] && kill $TPID 2>/dev/null
	pkill -f maic_stress 2>/dev/null
	[ -n "$OLD_TZLOG" ] && echo $OLD_TZLOG > $TZLOG 2>/dev/null
	# order matters: lower min first so max can go down, then restore
	echo $OLD_MIN > $CPUF/scaling_min_freq 2>/dev/null
	echo $OLD_MAX > $CPUF/scaling_max_freq 2>/dev/null
	echo $OLD_MIN > $CPUF/scaling_min_freq 2>/dev/null
	echo $OLD_GOV > $CPUF/scaling_governor 2>/dev/null
	# put the hard ceiling back last, then re-apply max so ->verify() clamps it again
	[ -n "$KNOB" ] && { echo $OLD_KNOB > $KNOB 2>/dev/null; echo $OLD_MAX > $CPUF/scaling_max_freq 2>/dev/null; }
	rm -f $OC_DIR/soak_running
}
finish() { restore; log "SOAK $1 $TAG mode=$MODE gov=$(cat $CPUF/scaling_governor) min=$MIN reason=$2 throttle_events=$THROT peak_mC=$PEAK"; echo "$1 $STAMP $TAG mode=$MODE minutes=$MIN reason=$2 throttle_events=$THROT peak_mC=$PEAK" > $RES; [ "$1" = PASS ] && exit 0 || exit 2; }
trap 'finish FAIL interrupted' INT TERM
THROT=0; PEAK=0

echo "$STAMP $TAG" > $OC_DIR/soak_running
log "SOAK start $TAG mode=$MODE gov=${GOV:-$OLD_GOV} minutes=$MIN maxT=$MAXT threads=$THR io=${IOMB}MB ptp_offset=$(cat $PTP/ptp_offset) hps=$(cat /proc/hps/enabled 2>/dev/null)"
if [ -n "$KHZ" ]; then
	grep -qw "$KHZ" $CPUF/scaling_available_frequencies || { echo "$KHZ not in scaling_available_frequencies"; rm -f $OC_DIR/soak_running; exit 1; }
	# raise the hard ceiling for this run only (restored by restore()); no-op on kernels without it
	[ -n "$KNOB" ] && [ "$KHZ" -gt "$OLD_KNOB" ] && echo $KHZ > $KNOB
	echo $KHZ > $CPUF/scaling_max_freq; echo $KHZ > $CPUF/scaling_min_freq; echo $KHZ > $CPUF/scaling_max_freq
	[ "$(cat $CPUF/scaling_max_freq)" = "$KHZ" ] || { echo "could not pin $KHZ (ceiling $(cat $KNOB 2>/dev/null))"; restore; exit 1; }
fi
if [ -n "$CEIL" ]; then
	grep -qw "$CEIL" $CPUF/scaling_available_frequencies || { echo "$CEIL not in scaling_available_frequencies"; rm -f $OC_DIR/soak_running; exit 1; }
	if [ -n "$GOV" ]; then
		echo $GOV > $CPUF/scaling_governor
		[ "$(cat $CPUF/scaling_governor)" = "$GOV" ] || { echo "could not set governor $GOV"; restore; exit 1; }
		[ "$GOV" = interactive ] && set_interactive_tunables
	fi
	[ -n "$KNOB" ] && [ "$CEIL" -gt "$OLD_KNOB" ] && echo $CEIL > $KNOB
	echo $CEIL > $CPUF/scaling_max_freq
	[ "$(cat $CPUF/scaling_max_freq)" = "$CEIL" ] || { echo "could not set ceiling $CEIL (knob $(cat $KNOB 2>/dev/null))"; restore; exit 1; }
	log "ceiling mode: gov=$(cat $CPUF/scaling_governor) min=$(cat $CPUF/scaling_min_freq) max=$(cat $CPUF/scaling_max_freq)"
fi
# thermal evidence: mtktscpu_debug_log bit 0x1 = cpufreq notifier clip print, 0x2 = tscpu_printk
# (ATM limit changes); 0x4 would be per-250ms poll spam. Restored by restore().
[ -n "$OLD_TZLOG" ] && echo 3 > $TZLOG 2>/dev/null
( while [ -f $OC_DIR/soak_running ]; do dmesg | grep -E "thermal_protect|clipped_freq|adaptive_cpu_power_limit|static_cpu_power_limit|previous_opp|PTP is initializing|E_WF|hps.*thermal" >> $OC_DIR/thermal_$STAMP.raw 2>/dev/null; sleep 30; done ) & TPID=$!

sh $OC_DIR/monitor.sh 5 $OC_DIR/soak_$STAMP.csv & MPID=$!
$OC_DIR/maic_stress $THR $SECS > $OC_DIR/stress_$STAMP.txt 2>&1 & SPID=$!
( while [ -f $OC_DIR/soak_running ]; do sh $OC_DIR/emmc_verify.sh $IOMB 1 >> $OC_DIR/io_$STAMP.txt 2>&1 || { echo IOFAIL >> $OC_DIR/io_$STAMP.txt; break; }; sleep 20; done ) & IPID=$!

END=$(( $(cut -d. -f1 /proc/uptime) + SECS ))
LASTMAX=$(cat $CPUF/scaling_max_freq)
while [ $(cut -d. -f1 /proc/uptime) -lt $END ]; do
	t=$(tz_temp mtktscpu)
	[ "$t" -gt "$PEAK" ] && PEAK=$t
	[ "$t" -gt $((MAXT * 1000)) ] && finish FAIL "temp ${t}mC > ${MAXT}C"
	grep -q MISMATCH $OC_DIR/stress_$STAMP.txt 2>/dev/null && finish FAIL "cpu arithmetic mismatch"
	grep -q -E "MISMATCH|IOFAIL" $OC_DIR/io_$STAMP.txt 2>/dev/null && finish FAIL "emmc readback mismatch"
	if [ -n "$KHZ" ] && [ "$(cat $CPUF/scaling_cur_freq)" != "$KHZ" ]; then
		log "note: cur_freq $(cat $CPUF/scaling_cur_freq) != $KHZ (thermal/power throttle), t=${t}mC"
	fi
	# policy->max moving under us = thermal (ATM) clip / release; count and log every transition
	m=$(cat $CPUF/scaling_max_freq)
	if [ "$m" != "$LASTMAX" ]; then
		THROT=$((THROT + 1)); log "throttle: max $LASTMAX -> $m cur=$(cat $CPUF/scaling_cur_freq) online=$(cat /sys/devices/system/cpu/online) t=${t}mC"; LASTMAX=$m
	fi
	sleep 5
done
wait $SPID; src=$?
[ $src -eq 0 ] || finish FAIL "maic_stress exit $src"
grep -q "RESULT PASS" $OC_DIR/stress_$STAMP.txt || finish FAIL "maic_stress did not report PASS"
finish PASS "completed"
