#!/system/bin/sh
# /data/adb/service.d/maic_ioched.sh -- set the eMMC I/O scheduler to deadline.
#
# The vendor kernel defaults to CFQ (CONFIG_DEFAULT_IOSCHED="cfq"), which is tuned for
# rotational disks and wrong for eMMC (rotational=0). `deadline` has lower overhead and
# gives predictable read latency without starving writes -- a better fit for the mixed
# interactive + Docker/background I/O on this box. noop/deadline/cfq are all compiled in,
# so this is a pure runtime switch (no rebuild). Reversible: echo cfq > .../scheduler.
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
for b in /sys/block/mmcblk0 /sys/block/mmcblk1; do
  q="$b/queue/scheduler"
  [ -f "$q" ] || continue
  [ "$(cat $b/queue/rotational 2>/dev/null)" = "0" ] || continue   # only flash
  echo deadline > "$q" 2>/dev/null
  # flash-friendly deadline tuning: keep read latency low
  echo 100 > "$b/queue/iosched/read_expire"  2>/dev/null
  echo 4   > "$b/queue/iosched/writes_starved" 2>/dev/null
done
echo "$(date) ioched=$(cat /sys/block/mmcblk0/queue/scheduler)" >> /data/adb/maic-ioched.log
