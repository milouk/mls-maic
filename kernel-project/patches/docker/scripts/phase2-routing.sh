#!/system/bin/sh
# MAIC: Phase 2 (bridge networking) policy routing -- NOT for Phase 1.
# Prereqs: Docker kernel booted (VETH + xt_qtaguid patch), daemon.phase2.json installed
# as /data/docker/etc/daemon.json, dockerd restarted.
#
# Android netd routes by per-network tables selected by ip rules; container traffic
# arriving on docker0 matches none of them and is dropped.  Send it through the
# table of the current default network.  Re-run after every Wi-Fi reconnect (netd
# rebuilds rules/NAT on network changes).
set -e
IFACE=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')
[ -n "$IFACE" ] || { echo "no default interface"; exit 1; }
TABLE=$(ip rule | sed -n "s/.*lookup \($IFACE\).*/\1/p" | head -1)
[ -n "$TABLE" ] || TABLE=main
ip rule del from 172.17.0.0/16 lookup "$TABLE" pref 5000 2>/dev/null || true
ip rule add from 172.17.0.0/16 lookup "$TABLE" pref 5000
ip rule del to 172.17.0.0/16 lookup main pref 4999 2>/dev/null || true
ip rule add to 172.17.0.0/16 lookup main pref 4999
iptables -t nat -C POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
echo 1 > /proc/sys/net/ipv4/ip_forward
echo "container egress via $IFACE (table $TABLE)"
