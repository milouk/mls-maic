#!/usr/bin/env bash
# Build + sign the MAIC status-bar RRO overlay, and package it as a Magisk module.
#
# WHY an RRO and not a framework-res.apk patch:
#   MLS zeroed android:dimen/status_bar_height (0dp). The old fix replaced the whole
#   /system/framework/framework-res.apk via a Magisk module. That works on Magisk 25.2
#   (bind-mount magic mount) but HANGS BOOT on Magisk 27+ (overlayfs magic mount), because
#   framework-res.apk is memory-mapped by zygote at the earliest boot stage.
#   The AOSP best practice (source.android.com/docs/core/runtime/rros) is a Runtime
#   Resource Overlay: a tiny APK that overrides only status_bar_height, dropped into
#   /vendor/overlay. It is not boot-critical, so it mounts fine under any Magisk.
#
# Requirements: aapt2 (Google Maven, osx/linux), a stock framework-res.apk to link against,
# and the platform signing key. NOTE: this ROM (MLS iQR70) is signed with the PUBLIC AOSP
# platform test-key (framework-res cert SHA256 C8:A2:E9:BC...2A:B8), so overlays are signed
# with aosp-mirror/platform_build target/product/security/platform.{pk8,x509.pem}.
set -euo pipefail
AAPT2=${AAPT2:-aapt2}
FRAMEWORK=${FRAMEWORK:-framework-res.apk}     # pull from device /system/framework/
PK8=${PK8:-platform.pk8}; PEM=${PEM:-platform.x509.pem}
"$AAPT2" compile --dir overlay/res -o compiled.zip
"$AAPT2" link -o overlay-unsigned.apk -I "$FRAMEWORK" \
  --manifest overlay/AndroidManifest.xml --min-sdk-version 24 --target-sdk-version 24 \
  --auto-add-overlay compiled.zip
openssl pkcs8 -inform DER -nocrypt -in "$PK8" -out platform.key.pem
openssl pkcs12 -export -in "$PEM" -inkey platform.key.pem -out platform.p12 -name platform -passout pass:android
cp overlay-unsigned.apk module/system/vendor/overlay/MaicStatusBarOverlay.apk
jarsigner -keystore platform.p12 -storetype PKCS12 -storepass android \
  -digestalg SHA-256 -sigalg SHA256withRSA module/system/vendor/overlay/MaicStatusBarOverlay.apk platform
echo "built + signed module/system/vendor/overlay/MaicStatusBarOverlay.apk"
