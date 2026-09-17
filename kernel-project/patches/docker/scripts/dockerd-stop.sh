#!/system/bin/sh
# MAIC: stop all containers and dockerd cleanly.
. /data/docker/scripts/docker-env.sh
# (no xargs -r: not guaranteed in Android 7 toybox)
for c in $(docker ps -q 2>/dev/null); do docker stop -t 10 "$c" >/dev/null 2>&1; done
P=$(cat /data/docker/run/docker.pid 2>/dev/null)
[ -n "$P" ] && kill "$P" 2>/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x dockerd >/dev/null || { echo stopped; exit 0; }; sleep 1; done
echo "dockerd still running, sending KILL"; pkill -9 -x dockerd; pkill -9 -x containerd
