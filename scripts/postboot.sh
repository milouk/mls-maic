#!/system/bin/sh
# MAIC post-reboot: after re-rooting with mtk-easy-su, in Termux run:
#   su -c "sh /data/local/postboot.sh"
settings put global adb_enabled 1
setprop service.adb.tcp.port 5555
stop adbd; start adbd
chcon u:object_r:system_file:s0 /data/local/cacerts /data/local/cacerts/* /data/local/hosts 2>/dev/null
umount /system/etc/security/cacerts 2>/dev/null
umount /system/etc/hosts 2>/dev/null
mount --bind /data/local/cacerts /system/etc/security/cacerts
mount --bind /data/local/hosts /system/etc/hosts
echo "postboot done: adb=$(getprop service.adb.tcp.port) CA=$(ls /system/etc/security/cacerts | wc -l) hosts=$(grep -c ^0.0.0.0 /system/etc/hosts)"
