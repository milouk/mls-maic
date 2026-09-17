#!/sbin/busybox sh
# MAIC recovery diagnostic dump. Kernel boots; recovery has no shell UI we can read and USB
# device-mode is electrically blocked, so dump everything to the CACHE partition (raw node
# mmcblk0p21, mounted with retries) for reading back from Android.
BB=/sbin/busybox
O=/cache/maic_dbg
CACHE_DEV=/dev/block/mmcblk0p21
say(){ echo "MAIC-DBG: $*" > /dev/kmsg; }

say "dbg start pid=$$"
# mount cache by the raw node, with retries (by-name symlink timing is unreliable this early)
i=0
while [ $i -lt 20 ]; do
  [ -b $CACHE_DEV ] && break
  $BB sleep 1; i=$((i+1))
done
$BB mkdir -p /cache 2>/dev/null
$BB mountpoint -q /cache 2>/dev/null || mount -t ext4 $CACHE_DEV /cache 2>/dev/null || $BB mount -t ext4 $CACHE_DEV /cache 2>/dev/null
say "cache mounted=$($BB mountpoint -q /cache && echo yes || echo NO) dev_present=$([ -b $CACHE_DEV ] && echo yes || echo NO)"

$BB rm -rf $O; $BB mkdir -p $O
echo "kernel: $($BB cat /proc/version)" > $O/info.txt
echo "cmdline: $($BB cat /proc/cmdline)" >> $O/info.txt
$BB dmesg > $O/dmesg.txt 2>&1
$BB cat /proc/mounts > $O/mounts.txt 2>&1

# pinctrl: which pins are claimed, by whom, and the DPI group state
PD=/sys/kernel/debug/pinctrl
for d in $PD/*; do
  [ -d "$d" ] || continue
  n=$($BB basename $d)
  $BB cat $d/pinmux-pins  > $O/pinmux-$n.txt 2>/dev/null
  $BB cat $d/pinconf-pins > $O/pinconf-$n.txt 2>/dev/null
  $BB cat $d/pinmux-functions > $O/pinfuncs-$n.txt 2>/dev/null
done
# display state
$BB cat /sys/class/graphics/fb0/modes > $O/fb0_modes.txt 2>/dev/null
$BB cat /sys/class/graphics/fb0/virtual_size >> $O/fb0_modes.txt 2>/dev/null
$BB dmesg | $BB grep -iE "pinctrl|mtkfb|disp|dpi|panel|kd070|lcm|primary_display" > $O/display.txt 2>&1

$BB sync; $BB sync
say "dump complete: $($BB ls $O | $BB tr '\n' ' ')"

# bonus: try USB adb anyway (harmless if the port can't do device mode)
echo 1 > /sys/devices/platform/mt_usb/cmode 2>/dev/null
echo idle > /sys/devices/platform/mt_usb/swmode 2>/dev/null; $BB usleep 300000
echo device > /sys/devices/platform/mt_usb/swmode 2>/dev/null
echo 0 > /sys/class/android_usb/android0/enable 2>/dev/null
echo 18d1 > /sys/class/android_usb/android0/idVendor 2>/dev/null
echo d001 > /sys/class/android_usb/android0/idProduct 2>/dev/null
echo adb > /sys/class/android_usb/android0/functions 2>/dev/null
echo 1 > /sys/class/android_usb/android0/enable 2>/dev/null
/sbin/adbd &
say "adbd launched (bonus)"
# keep dumping dmesg periodically so late messages are captured too
i=0
while [ $i -lt 20 ]; do
  $BB sleep 3
  $BB dmesg > $O/dmesg.txt 2>&1
  $BB sync
  i=$((i+1))
done
say "done"
