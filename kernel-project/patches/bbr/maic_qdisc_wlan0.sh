#!/system/bin/sh
# /data/adb/service.d/maic_qdisc_wlan0.sh -- force `fq` as wlan0's REAL root qdisc.
#
# WHY THIS EXISTS: `net.core.default_qdisc` (set in ../tuning/maic_sysctl.sh) only governs
# qdiscs created fresh for an interface; it does NOT retroactively change one a driver
# already set up. Android's WiFi (mac80211) stack brings wlan0 up with `mq` (multi-queue)
# at the root and `pfifo_fast` on each hardware TX queue, REGARDLESS of the sysctl
# default, and it does this before our post-boot scripts ever run. Verified live: with the
# sysctl set to fq, `tc qdisc show dev wlan0` still showed `mq`/`pfifo_fast` -- the sysctl
# was a no-op for the interface that actually matters.
#
# Measured impact of actually fixing this (BBR, otherwise identical conditions, 3 x 15s
# iperf3 runs each): +25% throughput (19.45 vs 15.58 Mbps), retransmits 1->0, RTT-under-
# saturation roughly halved again (22 vs 44 ms) on top of BBR's own already-large
# improvement over cubic. This is not a redundant belt-and-suspenders fix; it is the
# difference between BBR getting real pacing and BBR running unpaced. See ../../BENCHMARKS.md.
#
# Android's `tc` prints "Android does not support qdisc 'fq'" -- a stale/inaccurate
# advisory from an AOSP tc build restriction list, NOT the kernel: fq is definitely
# compiled in (CONFIG_NET_SCH_FQ=y, see ../bbr/) and the replace succeeds (exit 0,
# `tc qdisc show` confirms `fq` afterwards). The message is cosmetic; do not treat it as
# failure -- this script logs the *actual* post-replace qdisc, not the exit code alone.

while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
# wait for wlan0 to actually exist and be up, not just boot_completed
i=0
while [ ! -e /sys/class/net/wlan0 ] && [ "$i" -lt 30 ]; do sleep 1; i=$((i+1)); done
sleep 3   # let the driver finish its own qdisc setup before we override it

LOG=/data/adb/maic-qdisc.log
if [ -e /sys/class/net/wlan0 ]; then
  /system/bin/tc qdisc replace dev wlan0 root fq >> "$LOG" 2>&1
  echo "$(date) wlan0 qdisc now: $(/system/bin/tc qdisc show dev wlan0 | head -1)" >> "$LOG"
else
  echo "$(date) wlan0 never appeared, skipping" >> "$LOG"
fi
