#!/system/bin/sh
# Launch the MAIC power-key watcher at boot.
#
# MUST be backgrounded: magiskd runs service.d scripts sequentially, and the watcher
# blocks forever on getevent, so running it inline would stall every later boot script.
( while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
  sleep 5
  rm -f /data/local/maic_powerkey.pid
  /data/local/maic_powerkey.sh
) &
exit 0
