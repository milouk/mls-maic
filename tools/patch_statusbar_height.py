#!/usr/bin/env python3
"""
Restore the status bar on the MLS MAIC.

MLS shipped framework-res.apk with android:dimen/status_bar_height = 0dp, which is
why the ROM has no clock, no notification shade and no status icons: SystemUI still
creates the StatusBar window, it just gets zero height.

This rebuilds framework-res.apk with that single dimension set to <dp> (default 24)
and re-signs it with the AOSP platform test key -- which is the very key that signed
this ROM (verified SHA1 27:19:6E:38:6B:87:5E:76:AD:F7:00:E7:EA:84:E4:C6:EE:E3:3D:FA),
so the signature still validates and PackageManager accepts the "android" package.

Exactly one byte of resources.arsc changes.

Usage:
  python3 patch_statusbar_height.py framework-res.apk out.apk [dp]
then sign:
  jarsigner -keystore platform.p12 -storetype PKCS12 -storepass android \
    -sigalg SHA256withRSA -digestalg SHA-256 out.apk platform

Get the key (public, from AOSP):
  B=https://android.googlesource.com/platform/build/+/refs/tags/android-7.1.2_r39/target/product/security
  curl -s "$B/platform.pk8?format=TEXT"      | base64 -d > platform.pk8
  curl -s "$B/platform.x509.pem?format=TEXT" | base64 -d > platform.x509.pem
  openssl pkcs8 -inform DER -nocrypt -in platform.pk8 -out platform.key.pem
  openssl pkcs12 -export -in platform.x509.pem -inkey platform.key.pem \
    -out platform.p12 -name platform -passout pass:android
"""
import struct, sys, zipfile

# Res_value for @android:dimen/status_bar_height inside resources.arsc.
# Layout: uint16 size, uint8 res0, uint8 dataType(0x05=dimension), uint32 data
# data = (mantissa << 8) | (radix << 4) | unit ; unit 1 = dip
VALUE_OFF = 0x0087B2B8
EXPECT = bytes([0x08, 0x00, 0x00, 0x05, 0x01, 0x00, 0x00, 0x00])  # size 8, dimension, 0dp


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    dp = int(sys.argv[3]) if len(sys.argv) > 3 else 24
    if not 0 < dp < 256:
        sys.exit("dp must be 1..255 (mantissa is a single byte here)")

    zin = zipfile.ZipFile(src)
    arsc = bytearray(zin.read("resources.arsc"))

    got = bytes(arsc[VALUE_OFF:VALUE_OFF + 8])
    if got != EXPECT:
        sys.exit(f"refusing to patch: expected {EXPECT.hex()} at 0x{VALUE_OFF:08x}, got {got.hex()}.\n"
                 "This is not the framework-res.apk this patch was derived from.")

    arsc[VALUE_OFF + 5] = dp          # mantissa byte; unit stays 1 (dip)
    size, res0, dtype, data = struct.unpack_from("<HBBI", arsc, VALUE_OFF)
    assert data == (dp << 8) | 1, "encoding error"

    with zipfile.ZipFile(dst, "w") as zout:
        for it in zin.infolist():
            if it.filename.startswith("META-INF/"):
                continue          # drop the old signature; jarsigner writes a fresh one
            data_bytes = bytes(arsc) if it.filename == "resources.arsc" else zin.read(it.filename)
            zi = zipfile.ZipInfo(it.filename, date_time=it.date_time)
            zi.compress_type = it.compress_type          # resources.arsc must stay STORED
            zi.external_attr, zi.internal_attr = it.external_attr, it.internal_attr
            zi.create_system = it.create_system
            zout.writestr(zi, data_bytes)

    print(f"patched status_bar_height -> {dp}dp (data=0x{data:08x}); wrote {dst}")
    print("now sign it with the platform key, then ship as a Magisk module replacing")
    print("/system/framework/framework-res.apk")


if __name__ == "__main__":
    main()
