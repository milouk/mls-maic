#!/system/bin/sh
# MAIC: start dockerd (Phase 1: host networking, no iptables, no bridge).
. /data/docker/scripts/docker-env.sh
LOG=/data/docker/dockerd.log

# runc's defaults expect /run (containerd shim runc root /run/containerd/runc).
# Android 7's rootfs is a read-only ramdisk mount; create /run in RAM only.
if [ ! -d /run ]; then
  mount -o rw,remount / && mkdir -p /run && mount -o ro,remount /
fi
mountpoint -q /run 2>/dev/null || mount -t tmpfs -o rw,nosuid,nodev,mode=755 tmpfs /run

/data/docker/scripts/cgroup-mount.sh >> $LOG 2>&1

if pgrep -x dockerd >/dev/null; then echo "dockerd already running"; exit 0; fi
echo "=== $(date) starting dockerd ===" >> $LOG
dockerd --config-file /data/docker/etc/daemon.json >> $LOG 2>&1 &
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  sleep 2
  docker version >/dev/null 2>&1 && { docker info 2>/dev/null | grep -E "Server Version|Storage Driver|Cgroup Driver|Cgroup Version|Kernel Version"; exit 0; }
done
echo "dockerd did not come up; tail of $LOG:"; tail -30 $LOG; exit 1
