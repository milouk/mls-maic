#!/system/bin/sh
# /system/xbin/docker -- PATH wrapper. docker (root-only: /data/docker is mode 700, the socket is
# root) must run as root, but an interactive SSH shell lands non-root (uid 2000), which can't even
# traverse /data/docker -> "not found". Auto-elevate via su when not already root.
# Note: the su -c path flattens args ($*); fine for normal docker commands, an arg with embedded
# spaces would need care (edge case).
if [ "$(id -u)" != 0 ]; then
  exec su -c "DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker $*"
fi
export DOCKER_HOST=unix:///data/docker/run/docker.sock
exec /data/docker/bin/docker "$@"
