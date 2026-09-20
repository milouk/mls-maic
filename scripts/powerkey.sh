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
# BEHAVIOUR: a short press TOGGLES the screen. The decision needs BOTH signals because
# this panel runs the deskclock daydream 24/7, so backlight alone cannot tell Awake from
# Dreaming (both are 255 by day, 10 at night), and mWakefulness alone loses a race:
#   Asleep  + key-down -> Android auto-wakes to Awake before our shell can read the state
#   Dreaming+ key-down -> stays Dreaming (Android does NOT auto-wake)
#   Awake   + key-down -> stays Awake
# So we sample the backlight INSTANTLY at key-down (a fast cat, before the wake ramp):
#   bl==0  means it was Asleep -> the key-down already woke it, do nothing
#   bl>0   means Awake or Dreaming -> read mWakefulness (now reliable, no auto-wake):
#            Awake    -> sleep (KEYCODE_SLEEP 223)
#            Dreaming -> wake  (KEYCODE_WAKEUP 224)
# Both keyevents are verified working on this ROM. KEYCODE_POWER (26) is useless here, it
# lands back in MLS's dead broadcast path.
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

# Decide the toggle from the backlight sampled at key-down ($1) plus, when the screen was
# not fully off, the PowerManager state.
toggle() {
  bl0=$1
  if [ "$bl0" -eq 0 ] 2>/dev/null; then
    log "  bl@down=0 (was Asleep) -> key-down already woke it, no action"
    return
  fi
  wf=$(dumpsys power 2>/dev/null | grep -m1 mWakefulness=)
  case "$wf" in
    *Awake*) log "  bl@down=$bl0 state=$wf -> sleep (223)"; input keyevent 223 ;;
    *)       log "  bl@down=$bl0 state=$wf -> wake (224)";  input keyevent 224 ;;
  esac
}

log "powerkey watcher starting (long_press=${LONG_PRESS_MS}ms)"
trim

while true; do
  DOWN_MS=""; BL_AT_DOWN=0
  script -qc "getevent -lt $DEV" /dev/null 2>/dev/null | while read -r line; do
    # getevent -lt lines look like: [   82339.123456] EV_KEY  KEY_POWER  DOWN
    case "$line" in
      *KEY_POWER*DOWN*)
        # Sample the backlight FIRST, before the wake ramp: this is our only reliable
        # read of the pre-press state for the Asleep case (bl==0).
        BL_AT_DOWN=$(cat $BL 2>/dev/null || echo 0)
        DOWN_MS=$(echo "$line" | sed -n 's/^\[ *\([0-9]\{1,\}\)\.\([0-9]\{3\}\).*/\1\2/p')
        ;;
      *KEY_POWER*UP*)
        UP_MS=$(echo "$line" | sed -n 's/^\[ *\([0-9]\{1,\}\)\.\([0-9]\{3\}\).*/\1\2/p')
        if [ -n "$DOWN_MS" ] && [ -n "$UP_MS" ]; then
          DUR=$((UP_MS - DOWN_MS))
          if [ "$DUR" -lt "$LONG_PRESS_MS" ] && [ "$DUR" -ge 0 ]; then
            log "SHORT press (${DUR}ms)"
            toggle "$BL_AT_DOWN"
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
