#!/system/bin/sh
# MAIC: fix Android's placeholder cpusets once the kernel has CONFIG_CPUSETS.
#
# Stock init.rc (on init) creates the ActivityManager cpusets with "cpus 0" and expects
# the device rc to overwrite them.  This device's init.mt8167.rc/init.project.rc never
# do, because stock never had CPUSETS -- so with the Docker kernel every app would run
# on CPU0 only.  Magisk runs post-fs-data.d before zygote, so this lands in time.
#
# Install: /data/adb/post-fs-data.d/10-maic-cpuset.sh, chmod 0755, owner root.
# Safe on kernels without CPUSETS: /dev/cpuset does not exist and it exits.
LOG=/data/adb/maic-cpuset.log
ALL=0-3

[ -f /dev/cpuset/cpus ] || { echo "$(date) no cpuset hierarchy, nothing to do" >> $LOG; exit 0; }

# Parents before children: a child's cpus must be a subset of its parent's.
for g in foreground foreground/boost background system-background top-app; do
  d=/dev/cpuset/$g
  [ -d "$d" ] || continue
  echo "$ALL" > "$d/cpus" 2>>$LOG
  echo 0 > "$d/mems" 2>>$LOG
done

{
  echo "$(date) cpusets set:"
  for g in foreground foreground/boost background system-background top-app; do
    [ -d /dev/cpuset/$g ] && echo "  $g cpus=$(cat /dev/cpuset/$g/cpus) mems=$(cat /dev/cpuset/$g/mems)"
  done
} >> $LOG
