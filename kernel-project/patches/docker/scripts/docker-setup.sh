#!/system/bin/sh
# MAIC: one-time install of the static Docker bundle onto /data (run as root).
# Stage first (from the Mac):  push docker-25.0.5.tgz, runc.arm64, daemon.json and the
# scripts to /data/local/tmp/docker-stage/ (e.g. with kernel-project/out/work/push.sh).
set -e
S=/data/local/tmp/docker-stage
D=/data/docker
mkdir -p $D/bin $D/etc $D/lib $D/run $D/tmp $D/scripts
cd $S
tar xzf docker-25.0.5.tgz
cp docker/* $D/bin/
# Replace the bundled runc 1.1.12 with runc 1.3.6 (still cgroup-v1 capable, has the
# 2025 container-escape fixes).  Keep the bundled one as a fallback.
mv $D/bin/runc $D/bin/runc-1.1.12
cp runc.arm64 $D/bin/runc
chmod 0755 $D/bin/*
cp daemon.json $D/etc/daemon.json
cp cgroup-mount.sh dockerd-start.sh dockerd-stop.sh docker-env.sh $D/scripts/
chmod 0755 $D/scripts/*.sh
chmod 0700 $D
$D/bin/runc --version
$D/bin/dockerd --version
echo "installed to $D"
