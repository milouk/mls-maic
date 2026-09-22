#!/system/bin/sh
# MAIC power-key handler (evdev-direct, rm10-era rewrite).
#
# WHY THIS EXISTS: MLS gutted PhoneWindowManager.powerPress() so a SHORT press does not
# sleep -- it fires a dead broadcast no running app listens for, so the key does nothing.
# We watch the PMIC key device (mtk-pmic-keys = event3, carries KEY_POWER) and implement
# short-press ourselves. Long press is untouched stock AOSP (global-actions menu).
#
# READ MECHANISM (the important part): earlier versions piped `getevent` through busybox
# `script` to get a pty, because getevent block-buffers (4K) to a pipe and never fires
# otherwise. That pty needed a session leader (setsid), which magiskd's service.d children
# are not -- so at boot `script` could not grab its controlling tty, getevent exited at
# once, and the watcher spun in a blind reattach loop (worked when hand-started from a
# shell, dead after a real boot -- the exact bug that made it "still not working").
# This version drops getevent/script/pty/setsid entirely: it holds the evdev fd open
# (exec 3<) and reads fixed 24-byte struct input_event records with dd (one blocking read
# per event, no stdio buffering, nothing lost between reads). No session-leader needed, so
# it starts identically from a boot service or a shell.
#
# BEHAVIOUR: a short press TOGGLES the screen. The decision needs BOTH signals because the
# panel runs the deskclock daydream 24/7, so backlight alone cannot tell Awake from
# Dreaming. We sample the backlight AT key-down (before the wake ramp):
#   bl==0  -> was Asleep, the key-down already woke it -> do nothing
#   bl>0   -> Awake or Dreaming -> read mWakefulness:
#              Awake    -> drop into the deskclock daydream (owner wants the clock as idle)
#              Dreaming -> wake (KEYCODE_WAKEUP 224)
# Set MAIC_PK_OFF=sleep to blank fully (KEYCODE_SLEEP 223) instead of the daydream.

TAG=maic_powerkey
LOG=/data/local/maic_powerkey.log
DEV=/dev/input/event3
BL=/sys/class/leds/lcd-backlight/brightness
LONG_PRESS_MS=450          # AOSP shows global-actions at 500ms; stay under it
KEY_POWER=0x0074           # 116
EV_KEY=0x0001
OFF_ACTION="${MAIC_PK_OFF:-daydream}"
DREAM="am start -n com.android.systemui/.Somnambulator"

# Singleton guard: another live copy on the same device would fire every press twice.
# (Android toolbox `ps -A` does NOT list these reliably, so check /proc directly.)
PIDFILE=/data/local/maic_powerkey.pid
if [ -f "$PIDFILE" ]; then
  old=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$old" ] && [ -d "/proc/$old" ] && grep -qs maic_powerkey "/proc/$old/cmdline"; then
    exit 0        # already running
  fi
fi
echo $$ > "$PIDFILE"

ts()  { date '+%F %T'; }
log() { echo "$(ts) $*" >> $LOG; }
trim(){ [ -f $LOG ] && [ "$(wc -l < $LOG 2>/dev/null || echo 0)" -gt 400 ] && \
        { tail -200 $LOG > $LOG.tmp && mv $LOG.tmp $LOG; }; }

toggle() {
  bl0=$1
  if [ "$bl0" -eq 0 ] 2>/dev/null; then
    log "  bl@down=0 (was Asleep) -> key-down already woke it, no action"; return
  fi
  wf=$(dumpsys power 2>/dev/null | grep -m1 mWakefulness=)
  case "$wf" in
    *Awake*)
      if [ "$OFF_ACTION" = "sleep" ]; then
        log "  bl@down=$bl0 state=$wf -> sleep (223)"; input keyevent 223
      else
        log "  bl@down=$bl0 state=$wf -> daydream"; $DREAM >/dev/null 2>&1
      fi ;;
    *)  log "  bl@down=$bl0 state=$wf -> wake (224)"; input keyevent 224 ;;
  esac
}

log "powerkey watcher starting (evdev-direct, long_press=${LONG_PRESS_MS}ms)"
trim

# Hold the device open so no events are lost between per-event reads.
open_dev() { exec 3<"$DEV"; }
open_dev || { log "cannot open $DEV"; exit 1; }

DOWN_MS=""; BL_AT_DOWN=0
while :; do
  hex=$(dd bs=24 count=1 <&3 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
  if [ ${#hex} -lt 48 ]; then
    # short read / device reset -> reattach after a beat (never busy-spins)
    sleep 1; open_dev 2>/dev/null; continue
  fi
  type="0x${hex:34:2}${hex:32:2}"
  [ "$type" = "$EV_KEY" ] || continue
  code="0x${hex:38:2}${hex:36:2}"
  [ "$code" = "$KEY_POWER" ] || continue
  val=$(( 0x${hex:46:2}${hex:44:2}${hex:42:2}${hex:40:2} ))
  sec=$((  0x${hex:6:2}${hex:4:2}${hex:2:2}${hex:0:2} ))
  usec=$(( 0x${hex:22:2}${hex:20:2}${hex:18:2}${hex:16:2} ))
  ms=$(( sec * 1000 + usec / 1000 ))
  if [ "$val" -eq 1 ]; then
    BL_AT_DOWN=$(cat $BL 2>/dev/null || echo 0)
    DOWN_MS=$ms
  elif [ "$val" -eq 0 ] && [ -n "$DOWN_MS" ]; then
    DUR=$(( ms - DOWN_MS ))
    if [ "$DUR" -ge 0 ] && [ "$DUR" -lt "$LONG_PRESS_MS" ]; then
      log "SHORT press (${DUR}ms)"; toggle "$BL_AT_DOWN"
    else
      log "long press (${DUR}ms) -> left to Android (global actions)"
    fi
    DOWN_MS=""
  fi
done
