#!/system/bin/sh
# MAIC: docker test-plan §3-§4 (Phase 1, host networking) as one scripted run. Root shell.
# Prerequisites: userspace staged in /data/local/tmp/docker-stage (bundle, runc.arm64, daemon.json,
# scripts) -- this script runs docker-setup.sh itself if /data/docker/bin/dockerd is missing.
# Writes a PASS/FAIL line per step to /data/docker/phase1_result.txt and stops dockerd at the end.
R=/data/docker/phase1_result.txt
S=/data/local/tmp/docker-stage
: > $R 2>/dev/null || { mkdir -p /data/docker; : > $R; }
ok()   { echo "PASS $1 -- $2" | tee -a $R; }
bad()  { echo "FAIL $1 -- $2" | tee -a $R; }
note() { echo "NOTE $1 -- $2" | tee -a $R; }

# §3 install
if [ ! -x /data/docker/bin/dockerd ]; then
  [ -f $S/docker-25.0.5.tgz ] || { bad 3.0 "bundle not staged in $S"; exit 1; }
  ( cd $S && sh ./docker-setup.sh ) >> /data/docker/setup.log 2>&1 && ok 3.0 "docker-setup.sh" || { bad 3.0 "docker-setup.sh (see /data/docker/setup.log)"; exit 1; }
fi
. /data/docker/scripts/docker-env.sh
RV=$(runc --version 2>/dev/null | head -1); DV=$(dockerd --version 2>/dev/null)
case "$RV" in *1.3.6*) ok 3.1 "$RV";; *) bad 3.1 "runc: $RV";; esac
case "$DV" in *25.0.5*) ok 3.2 "$DV";; *) bad 3.2 "dockerd: $DV";; esac

# §4.1 start dockerd
INFO=$(/data/docker/scripts/dockerd-start.sh 2>&1); echo "$INFO" | tail -6
echo "$INFO" | grep -q "Storage Driver: overlay2" && ok 4.1a "Storage Driver overlay2" || bad 4.1a "storage driver: $(echo "$INFO" | grep -i "Storage Driver")"
echo "$INFO" | grep -q "Cgroup Driver: cgroupfs" && ok 4.1b "Cgroup Driver cgroupfs" || bad 4.1b "cgroup driver"
echo "$INFO" | grep -q "Cgroup Version: 1" && ok 4.1c "Cgroup Version 1" || bad 4.1c "cgroup version"
docker version >/dev/null 2>&1 || { bad 4.1 "dockerd not reachable"; tail -30 /data/docker/dockerd.log; exit 1; }

# §4.2 warnings
W=$(docker info 2>&1 | grep -i warn)
echo "$W" | grep -qiE "missing.*(devices|freezer|pids|memory)" && bad 4.2 "$W" || ok 4.2 "no missing controllers ($(echo "$W" | tr '\n' ' ' | cut -c1-80))"

# §4.3 arch
A=$(docker run --rm --network host arm64v8/alpine:3.20 uname -m 2>&1); [ "$A" = aarch64 ] && ok 4.3 "alpine uname -m = aarch64" || bad 4.3 "$A"

# hello-world (exit status is the payoff the other session asked for)
docker run --rm --network host hello-world >/data/docker/hello.txt 2>&1; HRC=$?
[ $HRC -eq 0 ] && grep -q "Hello from Docker" /data/docker/hello.txt && ok 4.3b "hello-world exit 0" || bad 4.3b "hello-world exit $HRC"

# §4.4 DNS + TLS from a root container
H=$(docker run --rm --network host alpine:3.20 sh -c 'apk add --no-cache curl >/dev/null 2>&1 && curl -sI https://example.com | head -1' 2>&1); echo "$H" | grep -qE "HTTP/(2|1.1) 200" && ok 4.4 "$H" || bad 4.4 "$H"

# §4.5 paranoid network: non-root without inet group must FAIL
docker run --rm --network host --user 1000 alpine:3.20 wget -qO- http://example.com >/dev/null 2>&1 && bad 4.5 "uid 1000 could reach the network (paranoid networking NOT enforced)" || ok 4.5 "uid 1000 blocked (expected)"
# §4.6 with --group-add 3003 (inet) it must succeed
docker run --rm --network host --user 1000 --group-add 3003 alpine:3.20 wget -qO- http://example.com >/dev/null 2>&1 && ok 4.6 "uid 1000 + gid 3003 reaches the network" || bad 4.6 "gid 3003 did not help"

# §4.7 memcg enforces
docker run --rm -m 32m --network host alpine:3.20 sh -c 'head -c 100m /dev/zero | tail' >/dev/null 2>&1; M=$?
[ $M -eq 137 ] && ok 4.7 "32m limit -> killed (137)" || bad 4.7 "exit $M (expected 137)"
# §4.8 pids enforces
P=$(docker run --rm --pids-limit 10 --network host alpine:3.20 sh -c 'for i in $(seq 30); do sleep 5 & done; wait' 2>&1); echo "$P" | grep -qi "fork" && ok 4.8 "pids-limit 10 -> can't fork" || bad 4.8 "no fork errors"
# §4.9 freezer
docker run -d --name z --network host alpine:3.20 sleep 300 >/dev/null 2>&1 && docker pause z >/dev/null 2>&1 && docker unpause z >/dev/null 2>&1 && docker rm -f z >/dev/null 2>&1 && ok 4.9 "pause/unpause ok" || { docker rm -f z >/dev/null 2>&1; bad 4.9 "freezer"; }
# §4.10 cpuset
docker run --rm --cpuset-cpus 1 --network host alpine:3.20 true >/dev/null 2>&1 && ok 4.10 "cpuset-cpus 1 container starts" || bad 4.10 "cpuset"

# §4.11 stop
/data/docker/scripts/dockerd-stop.sh >/dev/null 2>&1; sleep 2
pgrep -x dockerd >/dev/null && bad 4.11 "dockerd still running" || ok 4.11 "dockerd stopped"
echo "--- summary: $(grep -c ^PASS $R) PASS, $(grep -c ^FAIL $R) FAIL"
grep -c ^FAIL $R | grep -q '^0$'
