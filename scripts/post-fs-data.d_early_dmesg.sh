#!/system/bin/sh
# Save the kernel log a few seconds into every boot.
#
# MTK's ram console prints how the PREVIOUS boot died (e.g. "ram_console: last init
# function: 0x...") during the first second of kernel boot. On this device the battery
# thread floods dmesg so hard that the 128K ring buffer rolls over long before adb is
# reachable, so those lines are gone by the time anyone looks. post-fs-data runs early
# enough to catch them. Keeps the current and previous boot.
D=/data/local/early_dmesg
[ -f $D.txt ] && mv -f $D.txt $D.1.txt
{
  echo "bootreason=$(getprop ro.boot.bootreason) captured=$(date '+%F %T')"
  dmesg
} > $D.txt 2>/dev/null
exit 0
