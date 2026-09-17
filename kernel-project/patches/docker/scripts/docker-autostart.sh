#!/system/bin/sh
# /data/adb/service.d/docker-autostart.sh -- start Docker after boot (Magisk late_start, root).
# Reversible: delete this file to disable. Docker needs no network to start.
( while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
  sleep 10
  /system/bin/sh /data/docker/scripts/docker-up.sh
) >> /data/docker/autostart.log 2>&1 &
