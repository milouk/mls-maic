#!/system/bin/sh
# MAIC — boot service: (1) self-heal the Magisk env if the stub manager wiped it,
# (2) ensure the CA certs are mounted system-wide even if post-fs-data.d was skipped,
# (3) enable wireless ADB. Runs regardless of Magisk env completeness.
LOG=/data/local/maic_boot.log
BB=/data/local/busybox
MB=/data/adb/magisk
BK=/data/local/magisk_backup
ts() { date '+%F %T'; }
echo "$(ts) service.d/maic start" >> $LOG

# 1) self-heal the Magisk environment from backup if incomplete
if [ ! -f "$MB/busybox" ] || [ ! -f "$MB/util_functions.sh" ]; then
  echo "$(ts)   env incomplete -> restoring from $BK" >> $LOG
  mkdir -p "$MB"
  cp -af "$BK"/. "$MB"/ 2>/dev/null
  chmod 0755 "$MB"/magisk* "$MB"/busybox* "$MB"/*.sh "$MB"/chromeos/futility 2>/dev/null
  chmod 0644 "$MB"/magisk.apk 2>/dev/null
  restorecon -RF "$MB" 2>/dev/null
fi

# 2) wait for full boot, then ensure certs/hosts are mounted in init's (global) namespace
w=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $w -lt 60 ]; do sleep 2; w=$((w+2)); done
sleep 3
$BB nsenter -t 1 -m -- sh -c '
  [ -d /data/local/cacerts ] && ! grep -q "security/cacerts" /proc/mounts && mount --bind /data/local/cacerts /system/etc/security/cacerts
'
CA=$(ls /system/etc/security/cacerts 2>/dev/null | wc -l)
HN=$(wc -l < /system/etc/hosts 2>/dev/null)
echo "$(ts)   after mounts: CA=$CA hosts=$HN" >> $LOG

# 3) wireless ADB (persist.adb.tcp.port also set; this is belt-and-suspenders)
settings put global adb_enabled 1 2>/dev/null
setprop service.adb.tcp.port 5555 2>/dev/null
# boot completed successfully -> clear the watchdog counter
rm -f /data/local/boot_attempts
echo "$(ts) service.d/maic done" >> $LOG
