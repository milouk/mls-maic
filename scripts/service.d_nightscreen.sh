#!/system/bin/sh
# MAIC night mode.
#
# This panel is always on AC with the deskclock daydream enabled, so it never
# blanks -- it shows a clock 24/7. That clock is wanted (it is the kitchen clock),
# but at full brightness it lights up the room all night and wears the panel.
#
# So: keep the clock, just dim it hard overnight and restore in the morning.
# Brightness is genuinely controllable here -- writing screen_brightness
# propagates to /sys/class/leds/lcd-backlight/brightness.
NIGHT_START=0        # 00:00
NIGHT_END=7          # 07:00
NIGHT_BRIGHTNESS=10  # out of 255: readable in a dark room, not glaring
DAY_BRIGHTNESS=255
STATE=/data/local/.night_state
LOG=/data/local/maic_boot.log

# magiskd runs service.d scripts SEQUENTIALLY and waits for each, so this loop
# must be backgrounded or it blocks every script sorting after it (perf.sh).
(
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 5; done
sleep 20

# the clock screensaver must stay on for the clock to be visible at night
settings put secure screensaver_enabled 1 2>/dev/null
settings put system screen_brightness_mode 0 2>/dev/null

while true; do
  H=$(date +%H); H=${H#0}; [ -z "$H" ] && H=0
  if [ "$H" -ge "$NIGHT_START" ] && [ "$H" -lt "$NIGHT_END" ]; then want=night; else want=day; fi
  if [ "$(cat $STATE 2>/dev/null)" != "$want" ]; then
    if [ "$want" = "night" ]; then
      settings put system screen_brightness $NIGHT_BRIGHTNESS
      # Nightly TRIM. Android's own idle-maintenance fstrim only runs when the
      # screen is OFF, and the daydream clock keeps this panel on permanently, so
      # it otherwise never runs. First manual run reclaimed 1.14 GB on /data.
      /data/local/busybox fstrim /data >/dev/null 2>&1
      /data/local/busybox fstrim /cache >/dev/null 2>&1
      echo "$(date '+%F %T') nightly fstrim done" >> $LOG
    else
      settings put system screen_brightness $DAY_BRIGHTNESS
    fi
    echo "$want" > $STATE
    echo "$(date '+%F %T') nightscreen -> $want" >> $LOG
  fi
  sleep 600
done
) &
exit 0
