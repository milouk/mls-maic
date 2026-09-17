#!/system/bin/sh
# uv_step.sh status | step [-m MINUTES=10] | revert | apply-last-good
#
# Runtime CPU undervolt via PTP/EEM's offset knob (no kernel change, volatile: every reboot
# resets the offset to 0, so a hang or crash undoes itself on the next boot).
#   /proc/ptp/PTP_DET_MCUSYS/ptp_offset : signed int, unit = 1 PMIC step = 6.25 mV
#   applied as clamp(ptp_volt + offset, 1150 mV, OPP DT voltage) per OPP
# On this unit (2026-09-15) PTP runs 1300/1196 MHz at 1175 mV and 1040 MHz at 1168.75 mV, and
# 747.5/598 MHz are already on the 1150 mV floor, so runtime undervolting can gain at most
# -4 steps (-25 mV) before every OPP sits on the floor. Deeper UV needs a kernel change
# (lower PTP VMIN in mtk_ptp.c) -- see README.
#
# step: offset -= 1, verify it took, soak at 1300000 kHz then 1040000 kHz; PASS -> record as
# last good; FAIL -> write the previous offset back.
. /data/local/maic_oc/maic_oc_common.sh
LG=$OC_DIR/uv_last_good
MINSTEP=-8      # hard script floor (-50 mV); PTP's 1150 mV clamp normally stops earlier
cmd=${1:-status}; shift 2>/dev/null
M=10; while getopts m: o; do case $o in m) M=$OPTARG;; esac; done

status() {
	echo "ptp_offset=$(cat $PTP/ptp_offset)  last_good=$(cat $LG 2>/dev/null || echo none)"
	grep -E "PTPOD|freq\[" $PTP/ptp_status
	echo "vproc=$(vproc_mv)mV vcore=$(vcore_mv)mV cur=$(cat $CPUF/scaling_cur_freq) gov=$(cat $CPUF/scaling_governor) t_cpu=$(tz_temp mtktscpu)mC"
}
# PTP-managed voltage of the top PTP OPP (1300 MHz) = first entry of the second tuple on the
# PTP_LOG line: "... (82800) - (1193750, 1187500, ...) - (100, 92, ...)". NOT the freq[0] line:
# on CONFIG_MAIC_CPU_OC kernels freq[0] is the fixed-voltage 1500 MHz OC OPP, which ptp_offset
# never touches. (PTP temperature-compensates: 1175000 uV at 54 C, 1193750 uV at 83 C.)
top_mv() { grep -m1 '^PTP_LOG' $PTP/ptp_status | sed 's/.*) - (\([0-9]*\),.*) - (.*/\1/'; }

case $cmd in
status) status ;;
revert) echo 0 > $PTP/ptp_offset; log "UV revert -> 0"; status ;;
apply-last-good)
	v=$(cat $LG 2>/dev/null) || { echo "no last good offset"; exit 1; }
	echo $v > $PTP/ptp_offset; log "UV apply last good $v"; status ;;
step)
	cur=$(cat $PTP/ptp_offset); next=$((cur - 1))
	[ $next -lt $MINSTEP ] && { echo "refusing: $next below script floor $MINSTEP"; exit 1; }
	before=$(top_mv)
	[ "$before" -le 1150000 ] && { echo "top OPP already at PTP floor (${before} uV): runtime UV exhausted"; exit 1; }
	echo $next > $PTP/ptp_offset; sleep 3
	after=$(top_mv)
	log "UV step $cur -> $next: top OPP ${before} -> ${after} uV"
	sh $OC_DIR/soak.sh -f 1300000 -m $M && sh $OC_DIR/soak.sh -f 1040000 -m 3
	if [ $? -eq 0 ]; then echo $next > $LG; log "UV step $next PASS (recorded as last good)"; else echo $cur > $PTP/ptp_offset; log "UV step $next FAIL -> reverted to $cur"; exit 2; fi
	status ;;
*) echo "usage: $0 status|step [-m minutes]|revert|apply-last-good"; exit 1 ;;
esac
