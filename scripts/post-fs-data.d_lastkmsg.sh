#!/system/bin/sh
# Archive the PREVIOUS boot's kernel log, every boot, before anything can overwrite it.
#
# Why this exists: /proc/last_kmsg (served by pstore on this device -- mtk_ram_console.c
# registers its own console only #ifndef CONFIG_PSTORE) holds exactly ONE previous boot.
# The test cycle is "boot recovery -> power off -> boot normally -> read the log", and a
# single accidental extra reboot silently destroys the thing we powered the device off to
# collect. Each of those cycles needs a human standing at the device, so losing one is
# expensive.
#
# post-fs-data runs before the current boot has produced much log of its own, and well
# before anyone could reboot again. Archives are timestamped and kept, so a stale or
# mistaken reboot no longer costs the capture.
#
# Both sources are recorded because they are NOT always the same window:
#   /proc/last_kmsg              -> pstore_console_show(), the saved-old console buffer
#   /sys/fs/pstore/console-ramoops -> the same zone via the pstore filesystem
#   /sys/fs/pstore/dmesg-ramoops-* -> panic/oops records, which bypass console_loglevel
D=/data/local/maic_logs
mkdir -p $D 2>/dev/null

# Boot counter gives a stable ordering even when the RTC is wrong (this device commonly
# boots believing it is 2017, so timestamps alone sort badly).
N=$(cat $D/.seq 2>/dev/null || echo 0)
N=$((N + 1))
echo $N > $D/.seq
STAMP="$(printf %03d $N)_$(date '+%Y%m%d-%H%M%S' 2>/dev/null)"

# Do NOT use [ -s /proc/last_kmsg ] here: procfs reports st_size 0 even when the file has
# content (confirmed on this device -- ls shows "0 /proc/last_kmsg" while cat returns ~65KB),
# so -s is always false and nothing would ever be archived. Write first, judge afterwards by
# the size of what we actually read.
TMP=$D/.partial
{
    echo "=== archived $(date '+%F %T' 2>/dev/null) seq=$N"
    echo "=== this boot: bootreason=$(getprop ro.boot.bootreason) mode=$(getprop ro.bootmode)"
    echo "=== kernel now running: $(cat /proc/version)"
    echo
    echo "########## /proc/last_kmsg ##########"
    cat /proc/last_kmsg 2>/dev/null
    echo
    echo "########## /sys/fs/pstore ##########"
    for f in /sys/fs/pstore/*; do
      [ -f "$f" ] || continue
      echo "----- $f -----"
      cat "$f" 2>/dev/null
    done
    echo
    echo "########## /proc/aed/reboot-reason ##########"
    cat /proc/aed/reboot-reason 2>/dev/null
} > $TMP 2>/dev/null

# The header alone is a few hundred bytes; anything under ~1K means both log sources were
# empty and this is not worth keeping (it would push real captures out of the rotation).
SZ=$(wc -c < $TMP 2>/dev/null || echo 0)
if [ "$SZ" -gt 1024 ]; then
  mv -f $TMP $D/boot_$STAMP.txt
  chmod 0644 $D/boot_$STAMP.txt 2>/dev/null
else
  rm -f $TMP
  # Roll the counter back so an empty boot does not burn a sequence number.
  echo $((N - 1)) > $D/.seq
fi

# Keep the 20 most recent; these are ~100-600K each now that the console ring is 512K.
ls -1t $D/boot_*.txt 2>/dev/null | sed -n '21,$p' | while read -r old; do
  rm -f "$old" 2>/dev/null
done
exit 0
