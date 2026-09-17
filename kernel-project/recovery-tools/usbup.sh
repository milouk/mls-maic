#!/sbin/busybox sh
# MAIC recovery USB-adb bringup + diagnostics. Logs via /dev/kmsg so everything lands in
# the MTK RAM console and survives to /proc/last_kmsg after a power-cycle (the proven
# channel; /cache may not be mounted this early).
BB=/sbin/busybox
K=/dev/kmsg
US=/sys/class/android_usb/android0
UDC=/sys/class/udc/musb-hdrc.0.auto
MU=/sys/devices/platform/mt_usb
say(){ echo "MAIC-USBUP: $*" > $K; }

say "START pid=$$ kernel=$($BB uname -r)"
say "swmode_node=$([ -e $MU/swmode ] && echo yes || echo NO) cmode=$($BB cat $MU/cmode 2>/dev/null) udc=$($BB cat $UDC/state 2>/dev/null)"

# Force controller to DEVICE role. on-init left it host-only (cmode 2 -> host_mode=true),
# so a bare 'swmode device' is a no-op; must 'idle' first to clear host_mode.
echo 1 > $MU/cmode 2>/dev/null; say "cmode:=1 rc=$?"
echo idle > $MU/swmode 2>/dev/null; say "swmode:=idle rc=$?"; $BB usleep 400000
echo device > $MU/swmode 2>/dev/null; say "swmode:=device rc=$?"; $BB usleep 400000
say "after-swmode cmode=$($BB cat $MU/cmode) udc=$($BB cat $UDC/state)"

# (re)configure the adb gadget
echo 0 > $US/enable 2>/dev/null
echo 18d1 > $US/idVendor 2>/dev/null
echo d001 > $US/idProduct 2>/dev/null
echo adb > $US/functions 2>/dev/null
echo 1 > $US/enable 2>/dev/null
say "gadget state=$($BB cat $US/state 2>/dev/null) fn=$($BB cat $US/functions 2>/dev/null) en=$($BB cat $US/enable 2>/dev/null)"

setprop service.adb.root 1 2>/dev/null
/sbin/adbd & say "adbd pid=$!"

i=0
while [ $i -lt 30 ]; do
  say "t${i} udc=$($BB cat $UDC/state 2>/dev/null) spd=$($BB cat $UDC/current_speed 2>/dev/null) gadget=$($BB cat $US/state 2>/dev/null)"
  $BB sleep 4; i=$((i+1))
done
say "DONE"
