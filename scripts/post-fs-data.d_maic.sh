#!/system/bin/sh
# MAIC — inject Let's Encrypt CA certs + ad-block hosts BEFORE apps start.
# post-fs-data.d runs in the global mount namespace, but ONLY when the Magisk
# environment (/data/adb/magisk) is complete. If it was wiped, service.d/maic.sh
# below re-applies these via nsenter and restores the environment for next boot.
LOG=/data/local/maic_boot.log
ts() { date '+%F %T'; }
echo "$(ts) post-fs-data.d/maic start" >> $LOG

# --- boot watchdog -------------------------------------------------------
# Runs before modules are magic-mounted. service.d/maic.sh clears the counter
# only after sys.boot_completed, so a device that never finishes booting will
# increment it on each attempt and auto-disable the risky module. This is what
# makes a bad /system replacement recoverable with no cable and no adb.
CNT=/data/local/boot_attempts
RISKY=/data/adb/modules/statusbar
n=$(cat $CNT 2>/dev/null || echo 0)
n=$((n+1)); echo $n > $CNT
if [ "$n" -ge 2 ] && [ -d "$RISKY" ]; then
  touch "$RISKY/disable" 2>/dev/null
  echo "$(ts)   WATCHDOG: boot attempt $n without a completed boot -> disabled $RISKY" >> $LOG
fi
# -------------------------------------------------------------------------
# Our overlay dir REPLACES the whole system cert store, so any stock CA missing
# from it would silently stop being trusted. Sync first (runs before the bind, so
# /system/etc/security/cacerts is still the pristine store here), then mount.
if [ -d /data/local/cacerts ] && ! grep -q "security/cacerts" /proc/mounts; then
  n=0
  for f in /system/etc/security/cacerts/*; do
    b=${f##*/}
    if [ -e "$f" ] && [ ! -e "/data/local/cacerts/$b" ]; then
      cp -a "$f" "/data/local/cacerts/$b" 2>/dev/null && n=$((n+1))
    fi
  done
  [ $n -gt 0 ] && echo "$(ts)   synced $n new stock CA(s) into overlay" >> $LOG
  # ALWAYS enforce correct attributes: Android's DirectoryCertificateSource walks
  # this whole directory and NPEs (killing TLS app-wide) if any file is unreadable.
  chown 0:0 /data/local/cacerts/* 2>/dev/null
  chmod 0644 /data/local/cacerts/* 2>/dev/null
  chcon u:object_r:system_file:s0 /data/local/cacerts/* 2>/dev/null
  mount --bind /data/local/cacerts /system/etc/security/cacerts && \
    echo "$(ts)   certs bound (pfd, $(ls /data/local/cacerts | wc -l) certs)" >> $LOG
fi
# NTFS support. vold already implements NTFS automounting and shells out to a FUSE
# helper ("ntfs::Mount() execute command"), it just looks for /vendor/bin/ntfs-3g,
# which this ROM never shipped. /vendor is a symlink to /system/vendor, so overlay
# /system/vendor/bin with a copy that keeps all stock binaries (each with its ORIGINAL
# SELinux context -- thermald_exec, wmt_loader_exec etc; flattening them breaks those
# daemons) and adds ntfs-3g + ntfsfix, built from upstream 2022.10.3.
# Guarded by a file-count sanity check so a truncated overlay can never hide the stock
# vendor binaries.
if [ -d /data/local/vendorbin ] && ! grep -q " /system/vendor/bin " /proc/mounts; then
  have=$(ls /data/local/vendorbin 2>/dev/null | wc -l)
  want=$(ls /system/vendor/bin 2>/dev/null | wc -l)
  if [ "$have" -ge "$want" ]; then
    mount --bind /data/local/vendorbin /system/vendor/bin && \
      echo "$(ts)   vendor/bin bound ($have files, ntfs-3g added)" >> $LOG
  else
    echo "$(ts)   REFUSED vendor/bin overlay: only $have files vs $want stock" >> $LOG
  fi
fi

# Dalvik heap. The ROM ships a 128m growth limit, which is what a heavy app (browser,
# Stremio) hits before OOM -- a plausible cause of the old "browser crashes when
# downloading" complaint. There is ~1.4 GB available on this 2 GB device, so give apps
# more headroom. Must be set here: zygote reads these at start, before apps launch.
resetprop dalvik.vm.heapgrowthlimit 192m 2>/dev/null
resetprop dalvik.vm.heapsize 384m 2>/dev/null

# Systemwide unix tools. Stock /system/xbin holds only dexlist + tcpdump, so the
# shell lacks awk, vi, less, wget, diff, nc, unzip, xz, hexdump... Overlay a dir that
# keeps both stock binaries and adds busybox plus a symlink per applet. Same bind-mount
# pattern as the certs, deliberately NOT a Magisk module: a module adding files that do
# not exist in the stock mirror gets its attributes corrupted on every boot.
# /system/xbin is last in PATH, so stock /system/bin tools still win.
if [ -d /data/local/xbin ] && ! grep -q " /system/xbin " /proc/mounts; then
  chown -R 0:0 /data/local/xbin 2>/dev/null
  chmod 0755 /data/local/xbin 2>/dev/null
  find /data/local/xbin -type f -exec chmod 0755 {} \; 2>/dev/null
  chcon -R u:object_r:system_file:s0 /data/local/xbin 2>/dev/null
  mount --bind /data/local/xbin /system/xbin && \
    echo "$(ts)   xbin bound ($(ls /data/local/xbin | wc -l) tools)" >> $LOG
fi

# NOTE: /system/etc/hosts is deliberately NOT touched here any more. AdAway owns it
# via Magisk's systemless-hosts module (auto-updating blocklists, UI toggle). A static
# copy of the old 79,964-entry list is kept at /data/local/hosts.bak as a fallback.
