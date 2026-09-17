#!/usr/bin/env bash
# Produce a kernel blob for this specific device.
#
# An MTK/Android arm64 kernel blob is literally `Image.gz` with the board's DTB appended
# -- verified on the reference build, where Image.gz-dtb was exactly Image.gz plus the
# 53,484-byte tb8167p3_64.dtb and nothing else.
#
# So we do NOT author a DTS. The device's own DTB was extracted from its live boot image
# (captures/our_device.dtb, md5 3d9e5e5cf8473106af49eea9e3d1bdac) and is appended verbatim.
# That reuses the exact hardware description this board already boots with, instead of
# re-deriving one from the reference board's DTS -- which describes different hardware
# (different accelerometer, no amp, no voice DSP, an IR receiver we do not have).
#
# Every driver we integrated was checked against the strings in THAT DTB:
#   nuvoton,nau8540            -> nau8540.c            exact match
#   ESMT, ad82584f             -> ad82584f.c           exact match (including the space)
#   silergy,sym827-regulator   -> sym827-regulator.c   exact match
#   mediatek,STK8BAXX          -> stk8baxx registers via acc_driver_add(); MTK's accel core
#                                 tries each registered driver until one probes, so it wins
#                                 when it finds its chip at i2c 1-0x18.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT_DIR=kernel-project/out
DTB=kernel-project/captures/our_device.dtb
mkdir -p "$OUT_DIR"

# pull the freshly built compressed kernel out of the build volume
docker run --rm -v maic-kernel:/src -v "$PWD/$OUT_DIR:/out" maic-kbuild \
  bash -c 'cp /src/out/arch/arm64/boot/Image.gz /out/Image.gz && chmod 0644 /out/Image.gz'

[ -f "$DTB" ] || { echo "missing $DTB"; exit 1; }
# sanity: the DTB must start with the FDT magic, or we would append garbage to a kernel
magic=$(od -An -tx1 -N4 "$DTB" | tr -d ' \n')
[ "$magic" = "d00dfeed" ] || { echo "not an FDT: magic=$magic"; exit 1; }

cat "$OUT_DIR/Image.gz" "$DTB" > "$OUT_DIR/Image.gz-dtb-maic"

printf 'Image.gz          %s bytes\n' "$(wc -c < "$OUT_DIR/Image.gz")"
printf 'our_device.dtb    %s bytes\n' "$(wc -c < "$DTB")"
printf 'Image.gz-dtb-maic %s bytes\n' "$(wc -c < "$OUT_DIR/Image.gz-dtb-maic")"
echo "md5: $(md5 -q "$OUT_DIR/Image.gz-dtb-maic" 2>/dev/null || md5sum "$OUT_DIR/Image.gz-dtb-maic" | cut -d' ' -f1)"
