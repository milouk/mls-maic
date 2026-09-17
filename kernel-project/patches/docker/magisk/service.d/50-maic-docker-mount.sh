#!/system/bin/sh
# 50-maic-docker-mount.sh -- MAIC external-drive docker boot hook.
#
# STAGED, NOT INSTALLED. Do NOT drop this in /data/adb/service.d/ until the MANUAL flow
# (plug drive -> mount /mnt/docker -> dockerd-start.sh -> docker info) has succeeded at least
# once with the user present. dockerd on this device is resource-heavy and the external flow
# is unproven; a boot hook that auto-starts it before that is a footgun (an earlier phase-1
# run left a crash-looping dockerd/containerd).
#
# What it does, conservatively:
#   1. waits for boot, then looks for an ext4 filesystem LABEL=MAICDOCKER (up to 60 s for USB
#      enumeration). If the drive is absent -> no-op (docker simply stays off). Safe to boot
#      without the stick.
#   2. mounts it at /mnt/docker (/mnt is tmpfs, so the mountpoint is recreated each boot).
#      MOUNT-ONLY BY DEFAULT -- it does not start dockerd.
#   3. dockerd auto-start is OPT-IN: only if /data/adb/docker-autostart exists, AND behind a
#      boot guard so a dockerd that hangs/crash-loops cannot churn every boot (a stale guard
#      at boot => skip auto-start and log; clears itself after dockerd stays up 5 min).
# overlay2 REQUIRES ext4/xfs as data-root; an exFAT/NTFS stick needs an ext4 image loop-mounted
# (the userspace/external lane handles that). data-root in the external daemon.json = /mnt/docker/lib.

LABEL=MAICDOCKER
MNT=/mnt/docker
LOG=/data/adb/maic-docker.log
AUTOSTART_FLAG=/data/adb/docker-autostart
GUARD=/data/adb/maic-docker-armed

while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
sleep 8

# 1. find the labeled ext4 device (wait for USB enumeration)
dev=""
i=0
while [ $i -lt 30 ]; do
	dev=$(blkid 2>/dev/null | grep -i 'LABEL="'"$LABEL"'"' | grep -i 'TYPE="ext4"' | head -1 | cut -d: -f1)
	[ -n "$dev" ] && break
	i=$((i + 1)); sleep 2
done
[ -z "$dev" ] && { echo "$(date) no ext4 drive labeled $LABEL -> not mounting, docker stays off" >> $LOG; exit 0; }

# 2. mount (mkdir first: /mnt is tmpfs)
mkdir -p $MNT
if ! mountpoint -q $MNT; then
	mount -t ext4 -o rw,noatime,nosuid,nodev "$dev" $MNT || { echo "$(date) mount $dev at $MNT FAILED" >> $LOG; exit 0; }
fi
mkdir -p $MNT/lib
echo "$(date) mounted $dev at $MNT: $(df -h $MNT | tail -1)" >> $LOG

# 3. dockerd auto-start: opt-in + boot-guarded
[ -f "$AUTOSTART_FLAG" ] || { echo "$(date) no docker-autostart flag -> mounted only; start dockerd manually" >> $LOG; exit 0; }
if [ -f "$GUARD" ]; then
	echo "$(date) $GUARD still present (previous boot's dockerd did not stabilize) -> NOT auto-starting; 'rm $GUARD' to re-enable" >> $LOG
	exit 0
fi
echo "$(date) armed" > $GUARD; sync
sh /data/docker/scripts/dockerd-start.sh >> $LOG 2>&1
if docker version >/dev/null 2>&1; then
	( sleep 300; rm -f $GUARD; echo "$(date) dockerd stable 5 min, guard cleared" >> $LOG ) &
	echo "$(date) dockerd started (data-root on $MNT)" >> $LOG
else
	echo "$(date) dockerd failed to come up; leaving $GUARD set so next boot skips auto-start" >> $LOG
fi
