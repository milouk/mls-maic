#!/usr/bin/env bash
# Build the MT8167 4.4.22 kernel with the AOSP aarch64-linux-android-4.9 toolchain.
#
# Why a separate script from build.sh: the stock kernel was built with GCC 4.9, and GCC 7.5
# miscompiles this tree's early boot path -- the kernel dies before the first initcall
# (/proc/aed/reboot-reason shows `last init function 0x0`). Only a 4.9-built image boots.
# That toolchain ships as x86_64 binaries, so it runs in the emulated linux/amd64 image.
#
# The toolchain lives in the `maic-toolchain` Docker volume so it survives container removal
# (an earlier 4.9 build was lost exactly that way). Repopulate it with:
#
#   git clone --depth 1 https://android.googlesource.com/platform/prebuilts/gcc/\
#linux-x86/aarch64/aarch64-linux-android-4.9 tc49
#   cd tc49 && git fetch --depth 1 origin android10-release && git checkout FETCH_HEAD
#   docker volume create maic-toolchain
#   docker run --rm -v maic-toolchain:/tc -v "$PWD":/host:ro alpine \
#          sh -c 'cp -a /host/. /tc/ && rm -rf /tc/.git'
#
# NOTE: the toolchain is gone from the repo's default branch ("Remove aarch64-linux-android
# gcc-4.9 libs and includes"); android10-release still carries it.
set -euo pipefail

# out_m49w, NOT out_m49: the volume holds both, and out_m49 is a stale pass with
# CONFIG_MTK_COMBO unset (no WiFi/BT, 67 config lines adrift). Defaulting to it silently
# builds the wrong kernel and the script still reports success because an Image appears.
OUT="${OUT:-out_m49w}"                # output dir inside the kernel volume
DEFCONFIG="${DEFCONFIG:-}"            # empty => keep the existing $OUT/.config
VOL="${VOL:-maic-kernel}"
TARGET="${TARGET:-}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}"
LOG="${LOG:-/tmp/maic-m49.log}"
IMG=maic-kbuild-amd64
CROSS=aarch64-linux-android-

# Same idea as build.sh, but probed against the 4.9 CROSS compiler rather than the
# container's native gcc: 4.9 rejects most of these, and passing -Wno-error=<unknown>
# is itself an error, so probing against the wrong compiler would break the build.
CANDIDATE_WARNINGS="format-security array-bounds maybe-uninitialized unused-variable
unused-but-set-variable unused-function override-init designated-init shift-negative-value
sizeof-pointer-memaccess strict-aliasing uninitialized char-subscripts parentheses
sequence-point tautological-compare logical-not-parentheses unknown-pragmas
old-style-declaration bool-compare int-conversion absolute-value frame-larger-than
discarded-qualifiers incompatible-pointer-types nonnull memaccess enum-conversion"

KCFLAGS="$(docker run --rm --platform linux/amd64 -v maic-toolchain:/tc \
             -e WARNS="$CANDIDATE_WARNINGS" "$IMG" bash -c '
  export PATH=/tc/bin:$PATH
  out=""
  for w in $WARNS; do
    if echo "int main(void){return 0;}" \
       | '"$CROSS"'gcc -Werror="$w" -x c -c - -o /dev/null 2>/dev/null; then
      out="$out -Wno-error=$w"
    fi
  done
  echo "$out"
' 2>/dev/null | tail -1)"
# From linux-stable v4.4.270 on (backport stage 9), include/linux/compiler-gcc.h refuses
# GCC < 5.1 on arm64 (upstream 6eedcd638: GCC 4.9 can emit stack references beyond an
# already-adjusted SP -- GCC bug 63293 -- subtle data corruption under interrupts). This 4.9
# toolchain is the only one known to boot this board, and stock was built with it too. The
# tree keeps the #error; -DMAIC_ALLOW_GCC49 is the explicit, per-build acknowledgement that
# bypasses it (see kernel-project/patches/backport/tools/patch-gcc49-override.py). Drop the
# define and the check bites again.
KCFLAGS="$KCFLAGS -DMAIC_ALLOW_GCC49"
echo "KCFLAGS (accepted by GCC 4.9):$KCFLAGS"

set +e
docker run --rm --platform linux/amd64 -v "$VOL":/src -v maic-toolchain:/tc "$IMG" bash -c "
  set -eo pipefail
  export PATH=/tc/bin:\$PATH
  cd /src/linux
  mkdir -p /src/$OUT
  if [ -n '$DEFCONFIG' ]; then
    echo '=== configuring: $DEFCONFIG ==='
    make ARCH=arm64 CROSS_COMPILE=$CROSS O=/src/$OUT '$DEFCONFIG'
  else
    # Guard: with no .config present, 'make olddefconfig' silently succeeds and writes a
    # generic arm64 defconfig -- no MTK platform, none of our drivers -- and the build then
    # produces an Image, so the script would report success for a completely wrong kernel.
    [ -f /src/$OUT/.config ] || { echo \"no .config in /src/$OUT -- refusing to olddefconfig from nothing\"; exit 1; }
    echo '=== reusing existing /src/$OUT/.config ==='
    make ARCH=arm64 CROSS_COMPILE=$CROSS O=/src/$OUT olddefconfig
  fi
  echo '=== building -j$JOBS ==='
  make ARCH=arm64 CROSS_COMPILE=$CROSS O=/src/$OUT KCFLAGS='$KCFLAGS' -j$JOBS $TARGET
  echo '=== artifacts ==='
  ls -la /src/$OUT/arch/arm64/boot/Image* || { echo 'NO Image produced'; exit 1; }
" >"$LOG" 2>&1
rc=$?
set -e

echo "exit=$rc   log: $LOG   ($(/usr/bin/wc -l <"$LOG") lines)"
if [ $rc -ne 0 ]; then
  echo "--- first errors ---"
  grep -nE "Error [0-9]+|error:|No such file" "$LOG" | head -20
fi
tail -12 "$LOG"
exit $rc
