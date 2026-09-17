#!/system/bin/sh
# monitor.sh [interval_s=5] [outfile=/data/local/maic_oc/monitor_<date>.csv]
# Read-only logger: CPU freq/limits, online CPUs, temps, vproc/vcore (PMIC register), GPU freq,
# PTP top-OPP voltage and offset. Runs until killed.
. /data/local/maic_oc/maic_oc_common.sh
I=${1:-5}
OUT=${2:-$OC_DIR/monitor_$(date +%Y%m%d-%H%M%S).csv}
echo "time,cur_khz,min_khz,max_khz,governor,online,t_cpu_mC,t_pmic_mC,t_ap_mC,t_batt_mC,vproc_mV,vcore_mV,gpu_khz,ptp_offset,ptp_top" > $OUT
while :; do
	top=$(grep -o 'freq\[0\] = [0-9]*, voltage = [0-9]*' $PTP/ptp_status 2>/dev/null | sed 's/freq\[0\] = //; s/, voltage = /@/')
	echo "$(date +%T),$(cat $CPUF/scaling_cur_freq),$(cat $CPUF/scaling_min_freq),$(cat $CPUF/scaling_max_freq),$(cat $CPUF/scaling_governor),$(cat /sys/devices/system/cpu/online),$(tz_temp mtktscpu),$(tz_temp mtktspmic),$(tz_temp mtktsAP),$(tz_temp mtktsbattery),$(vproc_mv),$(vcore_mv),$(gpu_khz),$(cat $PTP/ptp_offset 2>/dev/null),$top" >> $OUT
	sleep $I
done
