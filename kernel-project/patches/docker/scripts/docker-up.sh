#!/system/bin/sh
# Start docker on demand (after a reboot). Root shell.
sh /data/docker/scripts/dockerd-start-dns.sh
# (re)create the /system/xbin/docker PATH wrapper -- auto-elevates via su so a non-root SSH shell
# can run it (docker is root-only: /data/docker mode 700, root socket).
cat > /system/xbin/docker 2>/dev/null <<'W'
#!/system/bin/sh
if [ "$(id -u)" != 0 ]; then
  exec su -c "DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker $*"
fi
export DOCKER_HOST=unix:///data/docker/run/docker.sock
exec /data/docker/bin/docker "$@"
W
chmod 0755 /system/xbin/docker 2>/dev/null
export DOCKER_HOST=unix:///data/docker/run/docker.sock
/data/docker/bin/docker ps -a
