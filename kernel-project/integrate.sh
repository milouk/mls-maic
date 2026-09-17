#!/usr/bin/env bash
# Integrate the MAIC board's drivers into the kernel tree.
#
# Runs INSIDE the maic-kbuild container against /src/linux (branch "maic"), with the
# vendored sources from kernel-project/vendor-refs/ mounted at /refs.
# Idempotent: each step checks whether it has already been applied, so re-running after
# adding a driver is safe.
set -euo pipefail
K=/src/linux; R=/refs
cd $K
say() { echo "  -> $*"; }

# insert TEXT (a file) immediately before the first line matching PATTERN
insert_before() {   # $1=file $2=pattern $3=textfile
  grep -q -F -f /dev/null "$1" 2>/dev/null || true
  awk -v pat="$2" -v tf="$3" '
    !done && index($0,pat)==1 { while ((getline l < tf) > 0) print l; done=1 }
    { print }
  ' "$1" > "$1.new" && mv "$1.new" "$1"
}

# ---------------------------------------------------------------- sym827 (vproc) -----
# DTB: sym827@60 { compatible = "silergy,sym827-regulator"; regulator-name = "vproc"; }
# The vendored driver's OF match is exactly that string: a straight drop-in.
# This one is not optional -- vproc is the CPU core supply.
[ -f drivers/regulator/sym827-regulator.c ] || { cp $R/sym827/sym827-regulator.c drivers/regulator/; say "sym827-regulator.c"; }
[ -f include/linux/regulator/sym827-regulator.h ] || { cp $R/sym827/sym827-regulator.h include/linux/regulator/; say "sym827-regulator.h"; }
if ! grep -q REGULATOR_SYM827 drivers/regulator/Kconfig; then
  cat > /tmp/k.txt <<'KTXT'
config REGULATOR_SYM827
	tristate "Silergy SYM827 regulator"
	depends on I2C
	help
	  Silergy SYM827 external buck regulator. On the MAIC board this
	  supplies vproc, the CPU core rail.

KTXT
  insert_before drivers/regulator/Kconfig "config REGULATOR_MT6392" /tmp/k.txt
  say "Kconfig REGULATOR_SYM827"
fi
grep -q "sym827-regulator.o" drivers/regulator/Makefile || \
  { printf 'obj-$(CONFIG_REGULATOR_SYM827)\t+= sym827-regulator.o\n' >> drivers/regulator/Makefile; say "Makefile sym827"; }

# ------------------------------------------------------------------ stk8baxx ---------
# DTB: cust_accel@0 { compatible = "mediatek,STK8BAXX"; i2c_num=<1>; i2c_addr=<0x18>; }
# Registers via MTK's acc_driver_add(), same as the mc3433 already in this tree.
A=drivers/misc/mediatek/accelerometer
if [ ! -d $A/stk8baxx-new ]; then
  mkdir -p $A/stk8baxx-new
  cp $R/stk8baxx/stk8baxx.c $R/stk8baxx/stk8baxx.h $R/stk8baxx/Kconfig $R/stk8baxx/Makefile $A/stk8baxx-new/
  say "stk8baxx-new/"
fi
grep -q "stk8baxx-new/Kconfig" $A/Kconfig || \
  { echo 'source "drivers/misc/mediatek/accelerometer/stk8baxx-new/Kconfig"' >> $A/Kconfig; say "Kconfig stk8baxx"; }
if ! grep -q "stk8baxx-new/" $A/Makefile; then
  # must sit INSIDE the else branch, with the other i2c accelerometers
  sed -i 's|^obj-$(CONFIG_MTK_LIS3DH)   +=  lis3dh/|&\nobj-$(CONFIG_MTK_STK8BAXX_NEW)   +=  stk8baxx-new/|' $A/Makefile
  say "Makefile stk8baxx"
fi

# ------------------------------------------------------------------- nau8540 ---------
# DTB: nuvoton@1c { compatible = "nuvoton,nau8540"; reg = <0x1c>; }  (4-ch mic array ADC)
# From mainline, where it has existed since 4.11.
if [ ! -f sound/soc/codecs/nau8540.c ]; then
  cp $R/nau8540/nau8540.c $R/nau8540/nau8540.h sound/soc/codecs/
  say "nau8540"
fi
if ! grep -q SND_SOC_NAU8540 sound/soc/codecs/Kconfig; then
  cat > /tmp/n.txt <<'NTXT'
config SND_SOC_NAU8540
	tristate "Nuvoton Technology Corporation NAU85L40 CODEC"
	depends on I2C

NTXT
  insert_before sound/soc/codecs/Kconfig "config SND_SOC_NAU8825" /tmp/n.txt
  say "Kconfig nau8540"
fi
if ! grep -q "snd-soc-nau8540" sound/soc/codecs/Makefile; then
  printf 'snd-soc-nau8540-objs := nau8540.o\n' >> sound/soc/codecs/Makefile
  printf 'obj-$(CONFIG_SND_SOC_NAU8540)\t+= snd-soc-nau8540.o\n' >> sound/soc/codecs/Makefile
  say "Makefile nau8540"
fi


# ------------------------------------------------------------------ ad82584f ---------
# DTB: ad82584f@31 { compatible = "ESMT, ad82584f"; reg = <0x31>; }
# The vendored driver (Amlogic BSP) matches that exact string. Its power-up register
# table is tuned for Amlogic boards, so it is replaced with the 134 values captured off
# this device -- same 134 registers, 117 of which already agreed.
if [ ! -f sound/soc/codecs/ad82584f.c ]; then
  cp $R/ad82584f/ad82584f.c $R/ad82584f/ad82584f.h sound/soc/codecs/
  say "ad82584f"
fi
if ! grep -q SND_SOC_AD82584F sound/soc/codecs/Kconfig; then
  cat > /tmp/a.txt <<'ATXT'
config SND_SOC_AD82584F
	tristate "ESMT AD82584F class-D amplifier"
	depends on I2C

ATXT
  insert_before sound/soc/codecs/Kconfig "config SND_SOC_NAU8825" /tmp/a.txt
  say "Kconfig ad82584f"
fi
if ! grep -q "snd-soc-ad82584f" sound/soc/codecs/Makefile; then
  printf 'snd-soc-ad82584f-objs := ad82584f.o\n' >> sound/soc/codecs/Makefile
  printf 'obj-$(CONFIG_SND_SOC_AD82584F)\t+= snd-soc-ad82584f.o\n' >> sound/soc/codecs/Makefile
  say "Makefile ad82584f"
fi


# -------------------------------------------------------------------- gc5024 ---------
# DTB: kd_camera_hw1@36 { compatible = "mediatek,camera_main"; reg = <0x36>; }
# The vendored MTK driver uses i2c_write_id 0x6e (= 0x37 << 1) and reads its chip id from
# registers 0xf0/0xf1 -- which is exactly what our ftrace capture recorded at a=037 on
# bus 2, so this is the right sensor at the right address.
IMG=drivers/misc/mediatek/imgsensor
if [ ! -d $IMG/src/mt8167/gc5024_mipi_raw ]; then
  mkdir -p $IMG/src/mt8167/gc5024_mipi_raw
  cp $R/gc5024/gc5024mipi_Sensor.c $R/gc5024/gc5024mipi_Sensor.h $R/gc5024/Makefile \
     $IMG/src/mt8167/gc5024_mipi_raw/
  say "gc5024_mipi_raw/"
fi
if ! grep -q "GC5024MIPI_SENSOR_ID" $IMG/inc/kd_imgsensor.h; then
  sed -i 's|^#define GC2355_SENSOR_ID .*|&\n#define GC5024MIPI_SENSOR_ID                    0x5024|' $IMG/inc/kd_imgsensor.h
  sed -i 's|^#define SENSOR_DRVNAME_GC2355_MIPI_RAW .*|&\n#define SENSOR_DRVNAME_GC5024_MIPI_RAW          "gc5024mipiraw"|' $IMG/inc/kd_imgsensor.h
  say "kd_imgsensor.h: GC5024 id + drvname"
fi
if ! grep -q "GC5024MIPI_RAW_SensorInit" $IMG/src/mt8167/kd_sensorlist.h; then
  # prototype, next to the other "Others" entries
  sed -i 's|^UINT32 T8EV5_YUV_SensorInit(PSENSOR_FUNCTION_STRUCT \*pfFunc);|&\nUINT32 GC5024MIPI_RAW_SensorInit(PSENSOR_FUNCTION_STRUCT *pfFunc);|' \
     $IMG/src/mt8167/kd_sensorlist.h
  # table entry -- inserted before the IMX220 entry so it is probed early (the file asks
  # for large sensors first, and 5MP outranks the 2MP gc2355)
  python3 - <<'PYX'
p='/src/linux/drivers/misc/mediatek/imgsensor/src/mt8167/kd_sensorlist.h'
s=open(p).read()
anchor='\t /*SY*/\n#if defined(IMX220_MIPI_RAW)'
entry=('\t /*GC*/\n'
       '#if defined(GC5024_MIPI_RAW)\n'
       '\t{GC5024MIPI_SENSOR_ID, SENSOR_DRVNAME_GC5024_MIPI_RAW, GC5024MIPI_RAW_SensorInit}\n'
       '\t,\n'
       '#endif\n')
assert anchor in s, 'kdSensorList anchor not found'
s=s.replace(anchor, entry+anchor, 1)
open(p,'w').write(s)
PYX
  say "kd_sensorlist.h: GC5024 prototype + table entry"
fi

# Swap the amp's power-up table for the values captured off this device.
python3 /work/swap_regs.py

# Swap the touchscreen firmware for the blob extracted from this device's stock kernel.
python3 /work/swap_gslfw.py



# ------------------------------------------------------------------- panel -----------
# CRITICAL. The eebbk tree's copy of kd070d5450nha6_rgb_dpi is, despite the directory
# name, a MIPI DSI driver for an 800x1280 panel (it fills params->dsi.*). This board has
# a 1024x600 panel on the PARALLEL RGB (DPI) interface, proven on the live device:
#   - /sys/class/graphics/fb0/modes  = U:1024x600p-0
#   - clk_summary shows mm_dpi0_pxl ENABLED at 102 MHz while every dpi1/dsi clock is 0
#   - (1024+48+112+160) x (600+10+13+12) x 60Hz = 51.2 MHz == the driver's PLL_CLOCK 51,
#     and the clock tree runs 2x that
# Every other public tree (Lenovo mt8167s, NotKit alps, LCM-MTK, OrangePi) carries this
# panel as 1024x600 DPI; the eebbk copy is the outlier. Using it would have produced a
# black screen.
LCMDIR=drivers/misc/mediatek/lcm/kd070d5450nha6_rgb_dpi
if ! grep -q "FRAME_WIDTH  (1024)" $LCMDIR/kd070d5450nha6_rgb_dpi.c 2>/dev/null; then
  cp $R/lcm/kd070d5450nha6_rgb_dpi.c $LCMDIR/kd070d5450nha6_rgb_dpi.c
  say "panel: replaced eebbk 800x1280 DSI driver with canonical 1024x600 DPI"
fi


# ------------------------------------------------------ GPU DDK revision -------------
# The device's GPU userspace and firmware are built at DDK 1.8@4490469:
#     /vendor/lib/libsrv_um.so   -> 1.8@4490469
#     /vendor/firmware/rgx.fw.signed
# and the stock kernel reports "rogueddk 1.8@4490469". Our tree only shipped up to
# m1.8ED4333936, i.e. an OLDER driver than the userspace that will call into it. The PVR
# bridge is unversioned across DDK revisions, so an older KM driver against newer UM is a
# real risk of missing entry points / changed struct layouts.
#
# m1.8ED4490469 is public in other MT8167 BSP trees with an IDENTICAL
# CONFIG_MTK_PLATFORM="mt8167" / CONFIG_MTK_GPU_VERSION="rgx clark 1.7ED". Fetch it with:
#
#   git init acer && cd acer
#   git remote add origin https://github.com/bigrammy/android_kernel_acer_b3-a40fhd.git
#   git sparse-checkout init --cone
#   git sparse-checkout set drivers/misc/mediatek/gpu/gpu_rgx/m1.8ED4490469
#   git fetch --depth 1 origin master && git checkout FETCH_HEAD
#
# then copy that directory into drivers/misc/mediatek/gpu/gpu_rgx/. 365 files, 6.6MB.
#
# NOTE the selector is a no-op ifeq -- BOTH branches hardcode the same path -- so the only
# thing that picks the version is the literal directory name here.
GPUDIR=drivers/misc/mediatek/gpu/gpu_rgx
if [ -d $GPUDIR/m1.8ED4490469 ] && grep -q "m1.8ED4333936/" $GPUDIR/Makefile 2>/dev/null; then
  sed -i 's|obj-y += m1.8ED4333936/|obj-y += m1.8ED4490469/|g' $GPUDIR/Makefile
  say "gpu_rgx: selecting m1.8ED4490469 (matches the device userspace 1.8@4490469)"
fi

# ------------------------------------------------- quiet the battery table dump ------
# battery_meter.c prints the whole battery profile and temperature table during probe --
# roughly 500 lines before 0.5s. The MTK RAM console (/proc/last_kmsg) is only 64K, so
# that spam wraps away the ENTIRE early boot: kernel banner, cmdline, and all display
# init. On a device with no serial console, last_kmsg after a failed boot is the only
# debug channel we have, so losing its first half is expensive.
#
# battery_log() prints only when Enable_BATDRV_LOG >= level, and that defaults to
# BAT_LOG_CRTI (1); BAT_LOG_FULL is 2, so demoting these two loops silences them while
# leaving every other battery message at its original level.
BM=drivers/power/mediatek/battery_meter.c
if grep -q 'battery_log(BAT_LOG_CRTI, "batt_temperature_table' $BM 2>/dev/null; then
  sed -i 's/battery_log(BAT_LOG_CRTI, "batt_temperature_table/battery_log(BAT_LOG_FULL, "batt_temperature_table/g' $BM
  say "battery_meter: demoted batt_temperature_table dump CRTI->FULL (keeps early boot in last_kmsg)"
fi

# ------------------------------------------------------------ version string ---------
# scripts/setlocalversion appends "+" when the git tree has modifications, which ours
# always does (integrate.sh edits it). The device runs plain "4.4.22", so suppress the
# marker with an empty .scmversion to match the stock version string exactly.
if [ ! -f .scmversion ]; then
  : > .scmversion
  say ".scmversion (suppress the '+' localversion marker)"
fi

# ------------------------------------------------------------ maic_defconfig -------
# Install our defconfig into the tree so `make maic_defconfig` works on a fresh checkout.
# Without this the build is not reproducible from a pristine kernel-src tree.
if ! cmp -s /work/config/maic_defconfig arch/arm64/configs/maic_defconfig 2>/dev/null; then
  cp /work/config/maic_defconfig arch/arm64/configs/maic_defconfig
  say "arch/arm64/configs/maic_defconfig"
fi

echo "integration pass complete"
