#!/system/bin/sh
# MAIC auto-restore on boot (Magisk late_start service). Permanent-root replacement for postboot.sh.
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
sleep 4
settings put global adb_enabled 1
setprop service.adb.tcp.port 5555
stop adbd; start adbd
chcon u:object_r:system_file:s0 /data/local/cacerts /data/local/cacerts/* /data/local/hosts 2>/dev/null
grep -q "security/cacerts" /proc/mounts || mount --bind /data/local/cacerts /system/etc/security/cacerts
grep -q "etc/hosts" /proc/mounts || mount --bind /data/local/hosts /system/etc/hosts
