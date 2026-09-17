#!/system/bin/sh
# MAIC power-key handler.
#
# WHY THIS EXISTS: MLS replaced PhoneWindowManager.powerPress() so a SHORT press does not
# sleep the device -- it broadcasts android.action.ACTION_SHORT_PRESS_POWER instead. The
# only listener was MLS's own MAIC app, registered dynamically, and that app never runs
# (Lawnchair is the launcher). So the key does nothing. Long press is untouched stock AOSP
# (global actions menu) and we deliberately leave it alone.
#
# Rather than patch the framework, we watch the PMIC key device and implement short-press
# ourselves. mtk-pmic-keys (event3) carries KEY_POWER and KEY_VOLUMEDOWN.
#
# BUFFERING GOTCHA: getevent uses stdio, which block-buffers (4K) whenever stdout is not a
# tty -- a file OR a pipe. Redirecting or piping it directly loses everything until 4K
# accumulates, so a naive watcher simply never fires. busybox `script` allocates a pty,
# which makes it line-buffered. This is the same class of trap as debugfs needing `cat`
# instead of `cp`.
TAG=maic_powerkey
LOG=/data/local/maic_powerkey.log
DEV=/dev/input/event3
BL=/sys/class/leds/lcd-backlight/brightness
LONG_PRESS_MS=450          # AOSP shows the global-actions menu at 500ms; stay under it
ACTION="${MAIC_PK_ACTION:-sleep}"   # "sleep" or "daydream"

# Singleton guard. Without it, every launch (boot script + any manual start) stacks another
# watcher on the same input device, and a single press then fires the action N times.
# Note: Android's toolbox `ps -A` does NOT reliably list these, so check /proc directly.
PIDFILE=/data/local/maic_powerkey.pid
if [ -f "$PIDFILE" ]; then
  old=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$old" ] && [ -d "/proc/$old" ] && grep -qs maic_powerkey "/proc/$old/cmdline"; then
    exit 0        # already running
  fi
fi
echo $$ > "$PIDFILE"

ts() { date '+%F %T'; }
log() { echo "$(ts) $*" >> $LOG; }

# keep only the last ~200 lines so this can never grow without bound
trim() { [ -f $LOG ] && [ "$(wc -l < $LOG 2>/dev/null || echo 0)" -gt 400 ] && \
         { tail -200 $LOG > $LOG.tmp && mv $LOG.tmp $LOG; }; }

do_action() {
  case "$ACTION" in
    daydream) am start -n com.android.deskclock/com.android.deskclock.Screensaver >/dev/null 2>&1 ;;
    *)        input keyevent 223 ;;   # KEYCODE_SLEEP -- verified working on this ROM
  esac
}

log "powerkey watcher starting (action=$ACTION, long_press=${LONG_PRESS_MS}ms)"
trim

while true; do
  DOWN_MS=""; BL_AT_DOWN=0
  script -qc "getevent -lt $DEV" /dev/null 2>/dev/null | while read -r line; do
    # getevent -lt lines look like: [   82339.123456] EV_KEY  KEY_POWER  DOWN
    case "$line" in
      *KEY_POWER*DOWN*)
        DOWN_MS=$(echo "$line" | sed -n 's/^\[ *\([0-9]\{1,\}\)\.\([0-9]\{3\}\).*/\1\2/p')
        # Sample the backlight AT KEY-DOWN. If the screen was already off, this press is
        # the user WAKING the device -- Android wakes on key-down -- and sleeping it again
        # would make the power key unable to ever turn the screen on.
        BL_AT_DOWN=$(cat $BL 2>/dev/null || echo 0)
        ;;
      *KEY_POWER*UP*)
        UP_MS=$(echo "$line" | sed -n 's/^\[ *\([0-9]\{1,\}\)\.\([0-9]\{3\}\).*/\1\2/p')
        if [ -n "$DOWN_MS" ] && [ -n "$UP_MS" ]; then
          DUR=$((UP_MS - DOWN_MS))
          if [ "$BL_AT_DOWN" -le 0 ]; then
            log "ignored: screen was off at key-down (wake press), dur=${DUR}ms"
          elif [ "$DUR" -lt "$LONG_PRESS_MS" ] && [ "$DUR" -ge 0 ]; then
            log "SHORT press (${DUR}ms, bl=$BL_AT_DOWN) -> $ACTION"
            do_action
          else
            log "long press (${DUR}ms) -> left to Android (global actions)"
          fi
        fi
        DOWN_MS=""
        ;;
    esac
  done
  # getevent exited (device reset, suspend, OOM). Back off and re-attach.
  log "getevent exited; reattaching in 5s"
  sleep 5
done
