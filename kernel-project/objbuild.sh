#!/usr/bin/env bash
# Compile one or more individual kernel objects against /src/out, with the same demoted
# warnings the full build uses. Fast way to validate a newly integrated driver.
set -uo pipefail
KC=$(docker run --rm maic-kbuild bash -c '
  out=""
  for w in format-overflow format-truncation format-security stringop-overflow array-bounds \
           misleading-indentation int-in-bool-context bool-operation memset-elt-size \
           sizeof-pointer-memaccess implicit-fallthrough maybe-uninitialized unused-const-variable \
           duplicate-decl-specifier discarded-qualifiers incompatible-pointer-types unused-variable \
           unused-but-set-variable override-init designated-init shift-negative-value \
           switch-unreachable pointer-compare restrict nonnull parentheses sequence-point \
           unused-function tautological-compare logical-not-parentheses unknown-pragmas \
           old-style-declaration bool-compare expansion-to-defined int-conversion strict-aliasing \
           uninitialized char-subscripts; do
    echo "int main(void){return 0;}" | gcc -Werror="$w" -x c - -o /dev/null 2>/dev/null && out="$out -Wno-error=$w"
  done; echo "$out"')
docker run --rm -v maic-kernel:/src maic-kbuild bash -c "
cd /src/linux
make ARCH=arm64 CROSS_COMPILE= O=/src/out KCFLAGS='$KC' $* 2>&1 | grep -vE '^  (CHK|CALL|GEN|Using|HOSTCC|MKELF|HOSTLD|CC      scripts)' | tail -30"
