#!/system/bin/sh
# /data/adb/service.d/maic_ksm.sh -- enable Kernel Samepage Merging (rm9+).
#
# KSM dedups identical anonymous pages across processes -- most useful here for the
# Docker container instances + the app set on this 2 GB device, clawing back real RAM.
# The scan runs in the background (ksmd); on an always-AC box the CPU cost is free.
# Gentle cadence (100 pages every 500 ms) so it never competes with the UI/streaming.
# Reversible: echo 0 > /sys/kernel/mm/ksm/run, or remove this script.
[ -d /sys/kernel/mm/ksm ] || exit 0

while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
sleep 10

echo 100 > /sys/kernel/mm/ksm/pages_to_scan   2>/dev/null
echo 500 > /sys/kernel/mm/ksm/sleep_millisecs  2>/dev/null
echo 1   > /sys/kernel/mm/ksm/run              2>/dev/null

echo "$(date) KSM run=$(cat /sys/kernel/mm/ksm/run) scan=$(cat /sys/kernel/mm/ksm/pages_to_scan) sleep=$(cat /sys/kernel/mm/ksm/sleep_millisecs)ms" >> /data/adb/maic-ksm.log
