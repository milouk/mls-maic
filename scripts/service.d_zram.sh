#!/system/bin/sh
# /data/adb/service.d/maic_zram.sh -- switch the zram compressor from lzo to lz4.
#
# WHY: init/fstab brings up zram0 with lzo. On this Cortex-A35, lz4 decompresses much
# faster than lzo for ~the same ratio, which is what matters for swap-IN latency on a
# 2 GB device juggling Docker + streaming. comp_algorithm can only be written while zram
# is empty, so we swapoff/reset/reconfigure. Run after boot_completed while swap is still
# ~0, so nothing is lost. Fully reversible: remove this script and a reboot restores lzo.
ZRAM=/sys/block/zram0
DEV=/dev/block/zram0
LOG=/data/adb/maic-zram.log
[ -e "$ZRAM/comp_algorithm" ] || exit 0

while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
sleep 8

# already lz4? nothing to do (idempotent)
if grep -q '\[lz4\]' "$ZRAM/comp_algorithm"; then
  echo "$(date) already lz4" >> $LOG; exit 0
fi

MKSWAP=$(command -v mkswap 2>/dev/null)
[ -z "$MKSWAP" ] && [ -x /data/local/busybox ] && MKSWAP="/data/local/busybox mkswap"
SIZE=$(cat "$ZRAM/disksize"); [ "$SIZE" -gt 0 ] 2>/dev/null || SIZE=1033023488

swapoff "$DEV" 2>/dev/null
echo 1     > "$ZRAM/reset"          2>/dev/null
echo lz4   > "$ZRAM/comp_algorithm" 2>/dev/null
echo "$SIZE" > "$ZRAM/disksize"     2>/dev/null
$MKSWAP "$DEV" >/dev/null 2>&1
swapon "$DEV" 2>/dev/null

echo "$(date) zram algo=$(cat $ZRAM/comp_algorithm) size=$(cat $ZRAM/disksize)" >> $LOG
