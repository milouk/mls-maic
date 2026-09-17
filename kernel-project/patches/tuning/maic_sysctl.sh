#!/system/bin/sh
# /data/adb/service.d/maic_sysctl.sh -- MAIC runtime VM/security sysctl tuning.
# Magisk late_start service. Every write is reversible (reboot clears; originals below) and
# NONE of these can hang or brick the device -- they are pure /proc/sys knobs, applied after
# boot_completed so a bad value can never block reaching a shell. Applied+recorded 2026-09-17.
#
# Only knobs that are (a) applicable to THIS kernel (4.4.302) and (b) not already optimal are set.
# Verified baseline on-device 2026-09-17 -- rollback values in [brackets]:
#   vm.swappiness            = 100  already max (zram active)          -> unchanged
#   vm.dirty_background_ratio= 5    already optimal                    -> unchanged
#   vm.watermark_scale_factor= N/A  (added in 4.6, absent in 4.4)      -> skip
#   kernel.kptr_restrict     = 2    already hardened by Android        -> unchanged
#   kernel.yama.ptrace_scope = N/A  (Yama not compiled)                -> skip
#   net.core.default_qdisc: fq_codel module not built -> needs a kernel rebuild, not set here.
set_sysctl() { [ -w "$1" ] && echo "$2" > "$1" 2>/dev/null; }

while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
sleep 8
LOG=/data/adb/maic-sysctl.log

# --- memory (2 GB device, zram swap active) ---
# dirty_ratio 20 -> 10: cap dirty pages at ~10% RAM so eMMC writeback flushes in smaller bursts
# instead of one multi-hundred-MB stall that starves video/UI reads.  [was 20]
set_sysctl /proc/sys/vm/dirty_ratio 10
# page-cluster 3 -> 0: with zram, read ONE page per swap-in instead of 8; kills decompress waste
# and swap-in latency for the random access a low-RAM Android sees.  [was 3]
set_sysctl /proc/sys/vm/page-cluster 0
# extra_free_kbytes 7200 -> 16384: let kswapd reclaim proactively into zram (~16 MB headroom)
# instead of foreground allocations hitting slow direct reclaim on a 30-MB-free device.  [was 7200]
set_sysctl /proc/sys/vm/extra_free_kbytes 16384

# --- hardening (root/Magisk unaffected; su still reads dmesg) ---
# dmesg_restrict 0 -> 1: only root reads the kernel log (kASLR/leak hygiene).  [was 0]
set_sysctl /proc/sys/kernel/dmesg_restrict 1

# --- network (bufferbloat) ---
# fq_codel needs CONFIG_NET_SCH_FQ_CODEL, which the current kernel lacks (only sch_htb built).
# It is in the rm5 hardening kernel; once rm5 is flashed, uncomment to make it the default qdisc:
grep -qw fq_codel /proc/sys/net/core/default_qdisc 2>/dev/null || set_sysctl /proc/sys/net/core/default_qdisc fq_codel  # [was pfifo_fast]

echo "$(date) applied: dirty_ratio=$(cat /proc/sys/vm/dirty_ratio) page-cluster=$(cat /proc/sys/vm/page-cluster) extra_free_kbytes=$(cat /proc/sys/vm/extra_free_kbytes) dmesg_restrict=$(cat /proc/sys/kernel/dmesg_restrict)" >> $LOG
