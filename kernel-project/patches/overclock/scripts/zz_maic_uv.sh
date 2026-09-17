#!/system/bin/sh
# /data/adb/service.d/zz_maic_uv.sh -- OPTIONAL, NOT installed. Re-applies the last undervolt
# offset that PASSED uv_step.sh, with a boot guard:
#   - waits for boot_completed + 120 s (so a bad offset can't block reaching a shell/rescue),
#   - drops a flag before applying and clears it after 15 min of uptime;
#   - if the flag is still there at the next boot, the previous boot died with the offset
#     applied: the offset is NOT applied again and last_good is quarantined.
OC=/data/local/maic_oc; PTP=/proc/ptp/PTP_DET_MCUSYS/ptp_offset
(
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 5; done
sleep 120
if [ -f $OC/uv_applying ]; then
	mv -f $OC/uv_last_good $OC/uv_last_good.quarantined 2>/dev/null
	rm -f $OC/uv_applying
	echo "$(date '+%F %T') UV boot guard: previous boot died with offset applied -> quarantined" >> $OC/oc_log.txt
	exit 0
fi
v=$(cat $OC/uv_last_good 2>/dev/null) || exit 0
touch $OC/uv_applying
echo $v > $PTP
echo "$(date '+%F %T') UV applied ptp_offset=$v at boot" >> $OC/oc_log.txt
sleep 900
rm -f $OC/uv_applying
) &
exit 0
