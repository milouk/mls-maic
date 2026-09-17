#!/system/bin/sh
# MAIC: zram swap with LZ4.
#
# Evidence (boot ramdisk, fstab.mt8167): this ROM defines NO zram device, so on
# stock zram0 exists (CONFIG_ZRAM=y creates it) but has disksize 0 and is unused.
# /system/etc/init could not be inspected offline, so both cases are handled:
#   - zram0 unconfigured (disksize 0): create an LZ4 zram swap of $SIZE
#   - zram0 already in use with another algorithm: switch it to LZ4, keeping size
#
# Safe by construction:
#   - exits unless the kernel lists "lz4" in /sys/block/zram0/comp_algorithm
#   - only swapoff()s an active zram when its data fits in free RAM (+150 MB),
#     retrying for up to an hour, never forcing an OOM
#   - if re-creation fails, restores the previous algorithm so swap is not lost
#   - disable entirely with ENABLE=0 in /data/adb/maic-zram.conf, or remove the module
#
# Switch logic originally drafted by a parallel preparation agent; setup path and
# config file added after the fstab check.
Z=/sys/block/zram0
DEV=/dev/block/zram0
CONF=/data/adb/maic-zram.conf
LOG=/data/local/tmp/maic-zram-lz4.log
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

ENABLE=1
SIZE=536870912          # 512 MiB: conservative for a 2 GB device
SWAPPINESS=             # leave the kernel default unless set in the conf file
[ -f "$CONF" ] && . "$CONF"
[ "$ENABLE" = "1" ] || { log "disabled in $CONF"; exit 0; }

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
sleep 30

[ -e "$Z/comp_algorithm" ] || { log "no zram0 in this kernel; nothing to do"; exit 0; }
ALGS=$(cat "$Z/comp_algorithm")
case " $ALGS " in
  *" lz4 "*|*"[lz4]"*) : ;;
  *) log "kernel does not offer lz4 ($ALGS); leaving zram unchanged"; exit 0 ;;
esac
OLDALG=$(echo "$ALGS" | sed -n 's/.*\[\([a-z0-9]*\)\].*/\1/p')
CUR=$(cat "$Z/disksize")
STREAMS=$(cat "$Z/max_comp_streams" 2>/dev/null)
NCPU=$(grep -c ^processor /proc/cpuinfo)

create() {   # $1 = algorithm, $2 = size
  echo 1 > "$Z/reset" 2>/dev/null
  echo "$1" > "$Z/comp_algorithm" || return 1
  echo "${STREAMS:-$NCPU}" > "$Z/max_comp_streams" 2>/dev/null
  echo "$2" > "$Z/disksize" || return 1
  mkswap "$DEV" >/dev/null 2>&1 || return 1
  swapon "$DEV" || return 1
  [ -n "$SWAPPINESS" ] && echo "$SWAPPINESS" > /proc/sys/vm/swappiness
  return 0
}

if [ "${CUR:-0}" -eq 0 ] 2>/dev/null; then
  log "zram0 unconfigured; creating lz4 swap of $SIZE bytes (streams ${STREAMS:-$NCPU})"
  if create lz4 "$SIZE"; then log "done: $(cat $Z/comp_algorithm), $(grep zram0 /proc/swaps)"
  else echo 1 > "$Z/reset" 2>/dev/null; log "setup failed; zram left unconfigured (as stock)"; fi
  exit 0
fi

case "$ALGS" in *"[lz4]"*) log "already lz4 ($ALGS)"; exit 0 ;; esac

kb() { grep "^$1:" /proc/meminfo | tr -s ' ' | cut -d' ' -f2; }
used_kb() { grep "^$DEV " /proc/swaps | tr -s ' \t' ' ' | cut -d' ' -f4; }
tries=0
while :; do
  USED=$(used_kb); USED=${USED:-0}
  AVAIL=$(kb MemAvailable); AVAIL=${AVAIL:-$(kb MemFree)}
  [ $((USED + 153600)) -lt "${AVAIL:-0}" ] && break
  tries=$((tries + 1))
  [ $tries -ge 12 ] && { log "gave up: swap used ${USED} kB vs available ${AVAIL} kB"; exit 0; }
  sleep 300
done

log "switching zram0 $OLDALG -> lz4 (size $CUR, swap used ${USED} kB)"
swapoff "$DEV" 2>>"$LOG" || { log "swapoff failed; leaving zram unchanged"; exit 0; }
if create lz4 "$CUR"; then log "done: $(cat $Z/comp_algorithm)"
else
  log "lz4 setup failed; restoring $OLDALG"
  create "$OLDALG" "$CUR" && log "restored: $(cat $Z/comp_algorithm)" || log "RESTORE FAILED - zram swap off until reboot"
fi
