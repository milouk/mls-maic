# MAIC status-bar height fix (RRO)

MLS zeroed `android:dimen/status_bar_height` (0dp) on the iQR70 ROM, so the status bar has
no height. This restores it to **24dp** using a **Runtime Resource Overlay (RRO)** — the
[AOSP-documented](https://source.android.com/docs/core/runtime/rros) way to override a
framework resource without touching `framework-res.apk`.

## Why not patch framework-res.apk (the old module)

The previous fix shipped a whole re-signed `framework-res.apk` via a Magisk module. That
works under Magisk 25.2 (bind-mount magic mount) but **hangs boot under Magisk 27+**, whose
magic mount was rewritten to use overlayfs — and `framework-res.apk` is memory-mapped by
zygote at the earliest boot stage, so overlaying it wedges system bring-up. The RRO is a
~3.4 KB non-boot-critical APK in `/vendor/overlay`, so it mounts fine under any Magisk.

## Install

Ship `module/` as the Magisk module `maic_statusbar_rro`. It drops the overlay into
`/system/vendor/overlay/`; the ROM's `idmap` (it has `/system/bin/idmap` + `/data/resource-cache`)
pairs it at boot. Verified: StatusBar window height `0 -> 23px` (24dp @ density 150).

## Rebuild

See `build.sh`. The overlay is signed with the **public AOSP platform test-key**, which is
what signs this ROM (`framework-res.apk` cert SHA256 `C8:A2:E9:BC…2A:B8`).
