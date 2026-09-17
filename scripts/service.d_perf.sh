#!/system/bin/sh
# MAIC performance tuning (device is always on AC). Magisk late_start service.
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
sleep 6
# CPU: lock all cores to max frequency
for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do echo performance > "$c" 2>/dev/null; done
# keep all cores online (disable MTK hotplug/ppm core limits if present)
echo 0 > /proc/hps/enabled 2>/dev/null
for o in /sys/devices/system/cpu/cpu[1-9]*/online; do echo 1 > "$o" 2>/dev/null; done
# GPU: fix to max frequency
echo 390000 > /proc/gpufreq/gpufreq_opp_freq 2>/dev/null
# IO scheduler: eMMC is non-rotational (rotational=0), so cfq's seek-avoidance
# heuristics just add latency. Prefer deadline, fall back to noop, never cfq.
if ! echo deadline > /sys/block/mmcblk0/queue/scheduler 2>/dev/null; then
  echo noop > /sys/block/mmcblk0/queue/scheduler 2>/dev/null
fi
# GPS/AGPS daemons: no GPS use on a kitchen tablet (location is network-only); frees RSS + wakeups
stop slpd 2>/dev/null
stop wifi2agps 2>/dev/null

# VM tuning for eMMC. Android defaults write back dirty pages every 2-3s, which
# turns into a stream of tiny writes on flash (write amplification + I/O stalls).
# This device is always on mains, so batching writes is nearly risk-free.
echo 1000 > /proc/sys/vm/dirty_expire_centisecs 2>/dev/null      # 2s  -> 10s
echo 1500 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null   # 3s  -> 15s
# larger readahead helps sequential media reads (Stremio / TV streams / Spotify cache)
echo 512 > /sys/block/mmcblk0/queue/read_ahead_kb 2>/dev/null
# keep dentry/inode cache longer: file lookups are cheaper than re-reading eMMC
echo 50 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null            # 100 -> 50
