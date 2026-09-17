#!/system/bin/sh
# MAIC: cgroup v1 hierarchies for runc under /sys/fs/cgroup.
#
# Android already mounts: cpuacct at /acct, cpu at /dev/cpuctl, cpuset at /dev/cpuset,
# memory at /dev/memcg.  Mount EACH subsystem ALONE: re-mounting a subsystem with the
# same option set just attaches the existing hierarchy (harmless), but a combined
# "cpu,cpuacct" mount fails because Android mounted them separately.
# Never mount cgroup2: 4.4 v2 has no usable controllers.
OPTS=rw,nosuid,nodev,noexec,relatime
# blkio/perf_event/hugetlb/net_cls/schedtune are not enabled in this kernel; skipped.
SUBSYS="cpu cpuacct cpuset devices freezer memory pids"

mountpoint -q /sys/fs/cgroup 2>/dev/null || \
  mount -t tmpfs -o rw,nosuid,nodev,noexec,mode=755 cgroup_root /sys/fs/cgroup || exit 1

for cg in $SUBSYS; do
  grep -qw "$cg" /proc/cgroups || { echo "skip $cg (not in /proc/cgroups)"; continue; }
  mkdir -p /sys/fs/cgroup/$cg
  if ! mountpoint -q /sys/fs/cgroup/$cg 2>/dev/null; then
    mount -t cgroup -o $OPTS,$cg $cg /sys/fs/cgroup/$cg || { echo "FAILED $cg"; rmdir /sys/fs/cgroup/$cg; }
  fi
done
grep " cgroup " /proc/mounts
