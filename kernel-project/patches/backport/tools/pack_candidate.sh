#!/bin/sh
# pack_candidate.sh <volume> <stage-name e.g. stage-v4.4.26> <expected-version e.g. 4.4.26>
# Pulls Image from the volume, applies the Magisk skip_initramfs patch, packs with mkboot.py,
# and refuses to emit CHECKS PASS unless every gate holds.
set -eu
VOL=$1; STAGE=$2; VER=$3
OUTDIR=${OUTDIR:-out_m49w}   # build output dir inside the volume (e.g. trial2_out)
ROOT=${MAIC_ROOT:-$PWD}
OUT=$ROOT/kernel-project/out/candidates/backport/$STAGE
mkdir -p "$OUT"
docker run --rm -v "$VOL":/src -v "$OUT":/o -e OUTDIR="$OUTDIR" maic-kbuild:latest sh -c 'cp /src/$OUTDIR/arch/arm64/boot/Image /o/Image && cp /src/$OUTDIR/.config /o/config && chmod 666 /o/Image /o/config'
python3 - "$OUT" "$VER" <<'PY'
import sys, hashlib, re
out, ver = sys.argv[1], sys.argv[2]
img = bytearray(open(out + '/Image', 'rb').read())
lines = []; ok = True
def gate(name, cond, detail=''):
    global ok
    lines.append(f"[{'PASS' if cond else 'FAIL'}] {name} {detail}"); ok &= bool(cond)
n = img.count(b'skip_initramfs'); gate('skip_initramfs present exactly once before patch', n == 1, f'(found {n})')
if n == 1:
    o = img.find(b'skip_initramfs'); before = bytes(img[o:o+14]); img[o:o+14] = b'want_initramfs'
    gate('patch changed exactly 4 bytes', sum(a != b for a, b in zip(before, img[o:o+14])) == 4)
i = bytes(img)
gate('want_initramfs == 1', i.count(b'want_initramfs') == 1)
gate('skip_initramfs == 0', i.count(b'skip_initramfs') == 0)
gate('maic_synaptics_dsp driver', b'maic_synaptics_dsp' in i)
gate('External I2S out widget', b'External I2S out' in i)
gate('stock touch cfg id 0x93832a', i.count((0x93832a).to_bytes(4, 'little')) == 1)
gate('swmode sysfs absent', b'swmode' not in i)
m = re.search(rb'Linux version (\d+\.\d+\.\d+)', i)
gate('version string', m and m.group(1).decode() == ver, f"(found {m.group(1).decode() if m else None}, want {ver})")
open(out + '/Image.patched', 'wb').write(i)
open(out + '/gates.txt', 'w').write('\n'.join(lines) + '\n')
print('\n'.join(lines)); sys.exit(0 if ok else 1)
PY
gzip -9 -n -c "$OUT/Image.patched" > "$OUT/Image.gz"
cd "$ROOT"
python3 kernel-project/mkboot.py --base kernel-project/out/boot_PARITY_USB_77bf6b99.img --kernel "$OUT/Image.gz" \
  --dtb kernel-project/captures/our_device.dtb --ramdisk-name ROOTFS --out "$OUT/boot_$STAGE.img" > "$OUT/mkboot.log" 2>&1
grep -E "fit|preserved|md5" "$OUT/mkboot.log"
{ echo "stage: $STAGE  expected version: $VER"; echo "built: $(date -u +%FT%TZ)"; cat "$OUT/gates.txt";
  echo; grep -E "fit|preserved|md5|output" "$OUT/mkboot.log";
  echo; echo "boot image md5: $(md5 -q "$OUT/boot_$STAGE.img")  size: $(stat -f%z "$OUT/boot_$STAGE.img")";
  echo "RESULT: CHECKS PASS — candidate only, NOT flashed"; } > "$OUT/CHECKS.txt"
rm -f "$OUT/Image" "$OUT/Image.patched"
echo "candidate: $OUT/boot_$STAGE.img"
