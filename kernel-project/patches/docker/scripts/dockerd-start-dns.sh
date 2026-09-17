#!/system/bin/sh
# MAIC: start dockerd on an Android host. Device-proven 2026-09-17 (internal data-root).
# Handles the Android-host gaps a stock dockerd-start hits:
#   1. DNS  - Android has no /etc/resolv.conf (netd), and /system is Magisk-ro. dockerd runs in a
#             private mount ns with an overlayfs on /system/etc that adds resolv.conf (all other
#             /system/etc files preserved via lowerdir).
#   2. TLS  - no CA bundle for registry certs -> build one from the system trust store, SSL_CERT_FILE.
#   3. ramdisk - runc pivot_root fails on the Android ramdisk rootfs -> DOCKER_RAMDISK=1 (MS_MOVE+chroot).
#   4. /run  - rootfs / is ro and NOT remountable by toolbox, and /run does not exist; dockerd 25.x
#             hardcodes /run/docker/plugins (ignores exec-root). Create a writable /run tmpfs INSIDE
#             the private mount ns via a ns-local busybox rw-remount (real system untouched).
. /data/docker/scripts/docker-env.sh
LOG=/data/docker/dockerd.log
# host-ns setup: cgroups + resolv upperdir (/run is created inside the private ns below)
/data/docker/scripts/cgroup-mount.sh >> $LOG 2>&1
mkdir -p /data/docker/etcu /data/docker/etcw
[ -s /data/docker/etcu/resolv.conf ] || printf "nameserver 1.1.1.1\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /data/docker/etcu/resolv.conf
# CA bundle (once): concat the Android system trust store so dockerd can verify registry TLS
[ -s /data/docker/cacert.pem ] || cat /system/etc/security/cacerts/* > /data/docker/cacert.pem 2>/dev/null
# already running?
for p in /proc/[0-9]*; do c=$(cat $p/comm 2>/dev/null); [ "$c" = dockerd ] && { docker version >/dev/null 2>&1 && { echo "dockerd already running"; exit 0; }; }; done
echo "=== $(date) starting dockerd (dns overlay ns + private /run) ===" >> $LOG
# dockerd in a private mount ns: writable /run (ns-local busybox rw-remount) + /system/etc overlay for resolv.conf
unshare -m sh -c '
  mount --make-rprivate / 2>/dev/null
  /system/xbin/busybox mount -o remount,rw /
  mkdir -p /run
  /system/xbin/busybox mount -o remount,ro /
  mount -t tmpfs -o rw,nosuid,nodev,mode=755 tmpfs /run
  mount -t overlay overlay -o lowerdir=/system/etc,upperdir=/data/docker/etcu,workdir=/data/docker/etcw /system/etc
  export SSL_CERT_FILE=/data/docker/cacert.pem DOCKER_RAMDISK=1; exec /data/docker/bin/dockerd --config-file /data/docker/etc/daemon.json
' >> $LOG 2>&1 &
for i in $(seq 1 30); do sleep 2; docker version >/dev/null 2>&1 && { echo "dockerd up after ~$((i*2))s"; exit 0; }; done
echo "dockerd did not come up"; tail -20 $LOG; exit 1
