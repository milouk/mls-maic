#!/usr/bin/env bash
# Baseline build of the MT8167 4.4.22 kernel inside the maic-kbuild container.
#
# Out-of-tree (O=/src/out) on purpose: the source in /src/linux stays pristine, so it can
# be committed to the kernel-src branch without a single build artifact.
#
# CROSS_COMPILE: the top Makefile does `CROSS_COMPILE ?= $(CONFIG_CROSS_COMPILE:"%"=%)`,
# and the vendor defconfig sets CONFIG_CROSS_COMPILE="aarch64-linux-android-", a toolchain
# we do not have. A command-line assignment beats `?=`, so we always pass CROSS_COMPILE
# explicitly -- empty on arm64 (where aarch64 is native), the GNU prefix elsewhere.
set -euo pipefail

DEFCONFIG="${1:-tb8167p3_64_defconfig}"
VOL="${VOL:-maic-kernel}"       # kernel source volume (maic-kernel | maic-kernel-lenovo)
TARGET="${TARGET:-}"           # optional make target, e.g. Image
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}"
LOG="${LOG:-/tmp/maic-kbuild.log}"

# This tree was built with GCC 4.9 (see /proc/version on the device). Newer GCCs add
# warnings that did not exist then, and the kernel builds with -Werror, so they become
# hard errors in code that is actually fine. Demote exactly those, rather than a blanket
# -Wno-error, so genuine new errors still stop the build.
#
# The candidate list spans several GCC releases, and passing -Wno-error=<x> for a warning
# the compiler does not know is itself an error -- so probe each one against the container
# compiler and keep only what it accepts. That keeps this working if the image moves to a
# newer or older GCC.
CANDIDATE_WARNINGS="format-overflow format-truncation format-security stringop-overflow
stringop-truncation array-bounds misleading-indentation int-in-bool-context bool-operation
memset-elt-size sizeof-pointer-memaccess implicit-fallthrough maybe-uninitialized
unused-const-variable attribute-alias packed-not-aligned address-of-packed-member
zero-length-bounds stringop-overread dangling-pointer duplicate-decl-specifier
discarded-qualifiers incompatible-pointer-types unused-variable unused-but-set-variable
override-init designated-init shift-negative-value switch-unreachable pointer-compare
cast-function-type restrict nonnull parentheses sequence-point unused-function
frame-larger-than enum-conversion tautological-compare logical-not-parentheses
unknown-pragmas old-style-declaration missing-attributes bool-compare
expansion-to-defined int-conversion absolute-value multistatement-macros
sizeof-array-div memaccess strict-aliasing uninitialized char-subscripts"

# Pass the list through the environment: interpolating a multi-line string straight into
# `bash -c` would end the `for` list at the first newline.
KCFLAGS="$(docker run --rm -e WARNS="$CANDIDATE_WARNINGS" maic-kbuild bash -c '
  out=""
  for w in $WARNS; do
    if echo "int main(void){return 0;}" | gcc -Werror="$w" -x c - -o /dev/null 2>/dev/null; then
      out="$out -Wno-error=$w"
    fi
  done
  echo "$out"
')"
echo "KCFLAGS (supported by this compiler):$KCFLAGS"

if [ "$(docker run --rm maic-kbuild dpkg --print-architecture)" = "arm64" ]; then
  CROSS=""            # native: gcc already is aarch64-linux-gnu
else
  CROSS="aarch64-linux-gnu-"
fi

set +e
docker run --rm -v "$VOL":/src maic-kbuild bash -c "
  set -eo pipefail
  cd /src/linux
  mkdir -p /src/out
  echo '=== configuring: $DEFCONFIG (CROSS_COMPILE=\"$CROSS\") ==='
  make ARCH=arm64 CROSS_COMPILE='$CROSS' O=/src/out '$DEFCONFIG'
  echo '=== building -j$JOBS ==='
  make ARCH=arm64 CROSS_COMPILE='$CROSS' O=/src/out KCFLAGS='$KCFLAGS' -j$JOBS $TARGET
  echo '=== artifacts ==='
  ls -la /src/out/arch/arm64/boot/Image* 2>/dev/null || { echo 'NO Image produced'; exit 1; }
" >"$LOG" 2>&1
rc=$?
set -e

echo "exit=$rc   full log: $LOG   ($(wc -l <"$LOG") lines)"
if [ $rc -ne 0 ]; then
  echo "--- first error and surrounding context ---"
  grep -nE "Error [0-9]+|error:|not found" "$LOG" | head -20
fi
tail -15 "$LOG"
exit $rc
