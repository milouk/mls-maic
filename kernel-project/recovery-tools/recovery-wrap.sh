#!/sbin/busybox sh
# Wrapper installed AS /sbin/recovery (the recovery service always starts). Confirms it ran
# and reports cache-mount + dmesg size by SPAMMING the RAM console tail (survives the ring),
# so we learn the truth without depending on /cache persistence. Then execs real recovery.
BB=/sbin/busybox
K=/dev/kmsg

# try to mount cache and dump (best effort)
i=0; while [ $i -lt 10 ]; do [ -b /dev/block/mmcblk0p21 ] && break; $BB sleep 1; i=$((i+1)); done
$BB mkdir -p /cache 2>/dev/null
$BB mountpoint -q /cache 2>/dev/null || mount -t ext4 /dev/block/mmcblk0p21 /cache 2>/dev/null
CM=$($BB mountpoint -q /cache && echo Y || echo N)
DB=$($BB dmesg 2>/dev/null | $BB wc -c)
if [ "$CM" = "Y" ]; then
  $BB rm -rf /cache/maic_dbg; $BB mkdir -p /cache/maic_dbg
  $BB dmesg > /cache/maic_dbg/dmesg.txt 2>&1
  $BB dmesg | $BB grep -iE "pinctrl|mtkfb|disp|dpi|panel|kd070|Error applying" > /cache/maic_dbg/display.txt 2>&1
  for d in /sys/kernel/debug/pinctrl/*; do [ -d "$d" ] && $BB cat $d/pinmux-pins > /cache/maic_dbg/pinmux-$($BB basename $d).txt 2>/dev/null; done
  $BB sync; $BB sync
fi

# hand off to real recovery in the background so the device still behaves
/sbin/recovery.bin "$@" &

# SPAM status to the RAM console tail forever, so it survives the ring on power-cut
n=0
while true; do
  echo "MAIC-WRAP-STATUS ran=Y cache=$CM dmesg_bytes=$DB tick=$n" > $K
  n=$((n+1)); $BB sleep 1
done
