#!/system/bin/sh
# MAIC performance tuning (device is always on AC). Magisk late_start service.
# Stock CPU range 598-1300 MHz: this MT8167B enforces its fused 1.3 GHz bin in
# hardware, so there is no overclock (see BENCHMARKS.md).

while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
sleep 6

C=/sys/devices/system/cpu
# CPU: interactive governor over the full stock range. Global tunables (4.4 android
# interactive) or per-policy.
for g in $C/cpu[0-9]*/cpufreq/scaling_governor; do echo interactive > "$g" 2>/dev/null; done
for T in $C/cpufreq/interactive $C/cpu0/cpufreq/interactive; do
	[ -d "$T" ] || continue
	echo 20000   > $T/timer_rate 2>/dev/null
	echo 1300000 > $T/hispeed_freq 2>/dev/null
	echo 85      > $T/go_hispeed_load 2>/dev/null
	echo 40000   > $T/above_hispeed_delay 2>/dev/null
	echo 80      > $T/target_loads 2>/dev/null
	echo 60000   > $T/min_sample_time 2>/dev/null
	echo 0       > $T/io_is_busy 2>/dev/null
done
echo 598000 > $C/cpu0/cpufreq/scaling_min_freq 2>/dev/null

# MTK hotplug off, all cores online; the thermal throttle lowers the frequency instead.
echo 0 > /proc/hps/enabled 2>/dev/null
for o in $C/cpu[1-9]*/online; do echo 1 > "$o" 2>/dev/null; done

# IO scheduler: eMMC is non-rotational, prefer deadline, fall back to noop, never cfq.
if ! echo deadline > /sys/block/mmcblk0/queue/scheduler 2>/dev/null; then
	echo noop > /sys/block/mmcblk0/queue/scheduler 2>/dev/null
fi
# No GPS use on a kitchen tablet (location is network-only).
stop slpd 2>/dev/null
stop wifi2agps 2>/dev/null

# VM tuning for eMMC: batch dirty writeback (always on mains).
echo 1000 > /proc/sys/vm/dirty_expire_centisecs 2>/dev/null
echo 1500 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null
echo 512 > /sys/block/mmcblk0/queue/read_ahead_kb 2>/dev/null
echo 50 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null
