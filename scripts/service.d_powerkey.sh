#!/system/bin/sh
# Launch the MAIC power-key watcher at boot (magiskd service.d).
# MUST background: the watcher blocks forever on the input device, so running it inline
# would stall every later boot script. No setsid/pty needed any more -- the watcher reads
# the evdev fd directly (see maic_powerkey.sh). We do NOT clear the pidfile here: the
# watcher's own singleton guard validates staleness (dead PID or non-watcher cmdline), so
# clearing it would only open a double-launch race.
( while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
  sleep 5
  /data/local/maic_powerkey.sh
) &
exit 0
