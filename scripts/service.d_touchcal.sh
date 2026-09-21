#!/system/bin/sh
# /data/adb/service.d/maic_touchcal.sh -- gslX680 touch coordinate calibration.
#
# The digitizer's raw scale is slightly larger than the visible LCD on the screen-X axis
# (which is raw-Y after the panel's 90-degree rotation), so far-right taps registered a
# few px to the LEFT of the finger while the left edge was spot-on -- a scale error, not a
# uniform offset. cal_y0/cal_y1 are module params read by the driver's report path
# (maic_cal, a 2-point linear map onto the 0..600 axis); 0/0 means identity.
#
# Measured 2026-09-21 from taps on known launcher targets:
#   AdAway  screen-X 158 -> raw-Y 101
#   Clock   screen-X 863 -> raw-Y 484
# Solving the line gives cal_y0=15, cal_y1=572. Runtime-writable, no rebuild. Reversible:
# remove this script (a reboot restores identity). cal_x0/cal_x1 (vertical) left at 0.
P=/sys/module/mtk_gslX680/parameters
[ -d "$P" ] || exit 0

while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
sleep 5

echo 15  > $P/cal_y0 2>/dev/null
echo 572 > $P/cal_y1 2>/dev/null
echo "$(date) touchcal cal_y0=$(cat $P/cal_y0) cal_y1=$(cat $P/cal_y1)" >> /data/adb/maic-touchcal.log
