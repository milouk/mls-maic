#!/usr/bin/env bash
# Build the MT8167 kernel (maic-bp, linux 4.4.302) with GCC 5.4 -- the GCC >= 5.1 build.
#
# Sibling of build-m49.sh. Same layout (a kernel volume mounted at /src, the tree at
# /src/linux, output in /src/$OUT), but the compiler lives INSIDE the image
# (kernel-project/docker-gcc5/Dockerfile: Ubuntu 16.04's gcc-5-aarch64-linux-gnu, GCC 5.4.0),
# so there is no toolchain volume and CROSS_COMPILE is the distro prefix. No
# -DMAIC_ALLOW_GCC49: 5.4 is past the arm64 GCC < 5.1 #error that v4.4.270 introduced.
#
# Background: the AOSP GCC 4.9 build is the only one proven to boot this board, and the GCC 7.5
# build (docker/Dockerfile, Ubuntu 18.04 native) died before the first initcall. Whether GCC 5.4
# boots is exactly what the first flash of this output will establish.
set -euo pipefail

OUT="${OUT:-out_g55}"                 # output dir inside the kernel volume
DEFCONFIG="${DEFCONFIG:-}"            # empty => keep the existing $OUT/.config
SEED="${SEED:-out_m49w}"              # if $OUT has no .config, seed it from this dir's .config
VOL="${VOL:-maic-wt-backport}"
TARGET="${TARGET:-}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}"
LOG="${LOG:-/tmp/maic-g55.log}"
IMG=maic-kbuild-gcc5
CROSS=aarch64-linux-gnu-

# Probe which -Wno-error=<warning> options THIS compiler accepts (same list as build-m49.sh;
# GCC 5 accepts more of them than 4.9 did). Passing an unknown one is itself an error.
CANDIDATE_WARNINGS="format-security array-bounds maybe-uninitialized unused-variable
unused-but-set-variable unused-function override-init designated-init shift-negative-value
sizeof-pointer-memaccess strict-aliasing uninitialized char-subscripts parentheses
sequence-point tautological-compare logical-not-parentheses unknown-pragmas
old-style-declaration bool-compare int-conversion absolute-value frame-larger-than
discarded-qualifiers incompatible-pointer-types nonnull memaccess enum-conversion
misleading-indentation shift-overflow"

KCFLAGS="$(docker run --rm --platform linux/amd64 -e WARNS="$CANDIDATE_WARNINGS" "$IMG" bash -c '
  out=""
  for w in $WARNS; do
    if echo "int main(void){return 0;}" \
       | '"$CROSS"'gcc -Werror="$w" -x c -c - -o /dev/null 2>/dev/null; then
      out="$out -Wno-error=$w"
    fi
  done
  echo "$out"
' 2>/dev/null | tail -1)"
echo "KCFLAGS (accepted by GCC 5.4):$KCFLAGS"

# rm9: tune instruction scheduling for this exact CPU. -mtune only changes the cost/scheduling
# model, NOT -march/the ISA, so it cannot disturb the +crypto CE files or emit A35-unsupported
# instructions. GCC 5.4 knows cortex-a35 (added in GCC 5).
KCFLAGS="$KCFLAGS -mtune=cortex-a35"
echo "KCFLAGS (+A35 tune):$KCFLAGS"

set +e
docker run --rm --platform linux/amd64 -v "$VOL":/src "$IMG" bash -c "
  set -eo pipefail
  cd /src/linux
  echo \"=== tree: \$(git rev-parse --short HEAD) \$(git describe --tags --always 2>/dev/null) ===\"
  echo \"=== compiler: \$(${CROSS}gcc --version | head -1) ===\"
  mkdir -p /src/$OUT
  if [ -n '$DEFCONFIG' ]; then
    echo '=== configuring: $DEFCONFIG ==='
    make ARCH=arm64 CROSS_COMPILE=$CROSS O=/src/$OUT '$DEFCONFIG'
  else
    if [ ! -f /src/$OUT/.config ]; then
      [ -f /src/$SEED/.config ] || { echo \"no .config in /src/$OUT and no seed at /src/$SEED -- refusing to olddefconfig from nothing\"; exit 1; }
      echo '=== seeding /src/$OUT/.config from /src/$SEED/.config ==='; cp /src/$SEED/.config /src/$OUT/.config
    fi
    echo '=== olddefconfig on /src/$OUT/.config ==='
    make ARCH=arm64 CROSS_COMPILE=$CROSS O=/src/$OUT olddefconfig
  fi
  echo '=== building -j$JOBS ==='
  make ARCH=arm64 CROSS_COMPILE=$CROSS O=/src/$OUT KCFLAGS='$KCFLAGS' -j$JOBS $TARGET
  echo '=== artifacts ==='
  ls -la /src/$OUT/arch/arm64/boot/Image* || { echo 'NO Image produced'; exit 1; }
  echo \"=== Linux version string ===\"; grep -a -m1 -o 'Linux version 4[^)]*)[^)]*)' /src/$OUT/arch/arm64/boot/Image
" >"$LOG" 2>&1
rc=$?
set -e

echo "exit=$rc   log: $LOG   ($(/usr/bin/wc -l <"$LOG") lines)"
if [ $rc -ne 0 ]; then
  echo "--- first errors ---"
  grep -nE "Error [0-9]+|error:|No such file|undefined reference" "$LOG" | head -20
fi
tail -12 "$LOG"
exit $rc
