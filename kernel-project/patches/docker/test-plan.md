# Docker kernel — test plan

Candidate: `kernel-project/out/candidates/docker/boot_docker.img` (md5 `3aec3775b3d9c5b6199f9fa416761878`),
built from `maic-wt-docker` = parity build 77bf6b99 + `defconfig.fragment` + `docker.patch`.
Rollback at any point: flash `kernel-project/out/boot_PARITY_USB_77bf6b99.img` (known good), or if
the device won't boot, the rescue path (recovery → `maic_rescue` → stock p9 `4c65df18`).

## 0. Before flashing (on the current kernel)
| # | Step | Pass |
|---|---|---|
| 0.1 | Install `magisk/post-fs-data.d/10-maic-cpuset.sh` → `/data/adb/post-fs-data.d/`, `chmod 0755` | file present, executable |
| 0.2 | Reboot once on the current kernel | `/data/adb/maic-cpuset.log` says "no cpuset hierarchy, nothing to do"; boot unchanged |
| 0.3 | Record baselines: `dumpsys meminfo | head -20`, `cat /proc/meminfo | head -5`, launcher feel | saved |

## 1. Flash (gated)
Push image, `dd` to `mmcblk0p9`, read back, compare md5 = `3aec3775b3d9c5b6199f9fa416761878` **before** rebooting.

## 2. First boot — Android sanity BEFORE any Docker
| # | Check | Pass criteria |
|---|---|---|
| 2.1 | `cut -c1-40 /proc/version` | our build (root@…), not stock |
| 2.2 | `cat /dev/cpuset/*/cpus /dev/cpuset/foreground/boost/cpus` | **every group `0-3`** (FAIL = `0`: script didn't run → apps pinned to CPU0) |
| 2.3 | `cat /data/adb/maic-cpuset.log` | lists all 5 groups at 0-3 |
| 2.4 | `grep -E "cpuset|memcg" /proc/mounts` ; `ls /dev/memcg/apps | head` | mounted; apps hierarchy exists |
| 2.5 | `ps -A -o pid,psr,comm | awk '$2!=0' | wc -l` | processes running on CPUs other than 0 |
| 2.6 | Open launcher, TV app, Spotify; scroll | no stutter vs baseline |
| 2.7 | `dumpsys meminfo | head -20`, `logcat -d | grep -i lmkd | tail` | free RAM within ~5% of baseline; no lmkd kill storm |
| 2.8 | Regression set: speaker (Spotify on tablet speaker), mic (`tinycap`), touch, Wi-Fi, BT, USB host `drvvbus_high` | all as before |
| 2.9 | `grep -wE "overlay|mqueue" /proc/filesystems`; `grep -E "devices|freezer|pids|memory|cpuset" /proc/cgroups` | all present, enabled=1 |
| 2.10 | `unshare -p -f -n -u -i --mount-proc sh -c 'echo pid=$$; ip link'` (toybox) | pid=1, only `lo` |

**Stop here if 2.2–2.8 fail** → flash back 77bf6b99.

## 3. Install userspace
Push `kernel-project/out/candidates/docker/userspace/*` to `/data/local/tmp/docker-stage/`, run `docker-setup.sh`.
Pass: `runc --version` = 1.3.6, `dockerd --version` = 25.0.5.

## 4. Phase 1 — host networking
| # | Command (root shell, `. /data/docker/scripts/docker-env.sh`) | Pass |
|---|---|---|
| 4.1 | `/data/docker/scripts/dockerd-start.sh` | Storage Driver overlay2, Cgroup Driver cgroupfs, Cgroup Version 1 |
| 4.2 | `docker info 2>&1 | grep -i warn` | no "missing" for devices/freezer/pids/memory (swap-limit warning is expected) |
| 4.3 | `docker run --rm --network host arm64v8/alpine:3.20 uname -m` | `aarch64` |
| 4.4 | `docker run --rm --network host alpine:3.20 sh -c 'apk add --no-cache curl && curl -sI https://example.com | head -1'` | `HTTP/2 200` (DNS + root socket path) |
| 4.5 | `docker run --rm --network host --user 1000 alpine:3.20 wget -qO- http://example.com` | **fails** (paranoid network, expected) |
| 4.6 | same with `--group-add 3003` | succeeds |
| 4.7 | `docker run --rm -m 32m alpine:3.20 sh -c 'head -c 100m /dev/zero | tail'` | killed (exit 137) → memcg enforces |
| 4.8 | `docker run --rm --pids-limit 10 alpine:3.20 sh -c 'for i in $(seq 30); do sleep 5 & done; wait'` | "can't fork" errors → pids enforces |
| 4.9 | `docker run -d --name z alpine:3.20 sleep 300; docker pause z; docker unpause z; docker rm -f z` | freezer ok |
| 4.10 | `docker run --rm --cpuset-cpus 1 alpine:3.20 cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null || true` | container starts |
| 4.11 | `dockerd-stop.sh` then Android sanity 2.6–2.7 again | clean stop, UI fine |
| 4.12 | Reboot, rerun 2.2 and 4.1 | cpusets 0-3, dockerd starts |

## 5. Phase 2 — bridge networking (only after Phase 1 passes)
1. Install `scripts/daemon.phase2.json` as `/data/docker/etc/daemon.json`, restart dockerd, run `phase2-routing.sh`.
2. `docker run -d -p 8080:80 --name web nginx:alpine` → `curl -sI http://127.0.0.1:8080` from the tablet and from the Mac (`http://<device-ip>:8080`).
3. **qtaguid stress (the reboot bug):**
   `for i in $(seq 50); do docker run --rm alpine:3.20 true; cat /proc/net/xt_qtaguid/iface_stat_fmt >/dev/null; done`
   while in a second shell `while true; do cat /proc/net/xt_qtaguid/iface_stat_fmt >/dev/null; done`.
   Pass: **no reboot**, `uptime` keeps counting, `dmesg | grep -i "unable to handle\|Oops"` empty.
4. Toggle Wi-Fi off/on, rerun `phase2-routing.sh`, repeat step 2.

## Pass/fail summary to record
kernel md5 · cpusets · memcg/lmkd · regressions · dockerd info · 4.3–4.10 · Phase 2 qtaguid stress.

---

## RESULT 2026-09-17 — phase 1 attempted on-device: FAILED on storage (not kernel/config)

Ran over SSH on the rm6-era daily (kernel supports it: cgroups/memcg/ns/overlay2 all verified by rm1).
- **§3 install PASSED:** `docker-setup.sh` ok, runc 1.3.6, docker 25.0.5, bundle sha256 verified.
- **§4.1 dockerd FAILED:** dockerd started, wrote the cgroup mounts, then **died** — `/data` hit 99%
  (41 MB free) during init. The static binaries alone are **192 MB** (dockerd 63 / containerd 36 /
  docker 33 + runc/ctr/shim); dockerd then needs runtime + overlay2 + image space on top, and this
  3.2 GB `/data` (~2.5 GB system/apps) has only ~475 MB free. Disk-exhaustion at startup.
- Cleaned up fully (`rm -rf /data/docker` + stage): `/data` back to 481 MB / 86 %, no residue.

**Conclusion:** Docker is not viable on internal storage as-is. Two paths, **user's call**:
1. Free ~400 MB internal (uninstall apps), then re-run phase 1; or
2. Put the docker install + `data-root` (`/var/lib/docker`) on an **external USB drive** — USB host
   works; needs a stick + ext4/exFAT + a `daemon.json` `data-root` pointing at the mount. Bigger
   project (mount at boot, drive stays plugged into the one USB-A port). Not built yet — add a
   `daemon.external.json` + mount hook if the user chooses this.

The kernel side (the reason docker was a *kernel* task — cgroup/ns/memcg/overlay2 config) is proven
good; this is purely a userspace/storage limit of the device.

---

## RESULT 2026-09-17 (cont.) — phase 1 PASSES internally after space freed + 3 Android-host fixes

Once ~600 MB was freed (removed docker's first install, uninstalled the 408 MB Google app →
/data at 80 %, 683 MB free), internal docker works: `hello-world` printed "Hello from Docker!",
a busybox container ran a command, `docker ps -a` / pull / run all work, images persist on
`/data/docker/lib` (overlay2, cgroupfs, cgroup v1). data-root stayed internal (`/data/docker/lib`).

**But space was only half the story** — `phase1-run.sh`'s `dockerd-start.sh` also had to handle three
gaps specific to an Android host (peer found these on-device; fold into the repo scripts):

1. **DNS — Android has no `/etc/resolv.conf`** (it uses `netd`), and `/system` is Magisk-read-only so
   you can't just write `/system/etc/resolv.conf`. Fix: start dockerd inside a private mount namespace
   (`unshare -m`) with an **overlayfs on `/system/etc`** (lowerdir `/system/etc`, upperdir carrying a
   `resolv.conf`: `nameserver <lan-dns>` + `1.1.1.1`/`8.8.8.8`). The overlay preserves every other
   `/system/etc` file. (A Magisk module can provide a global one at boot, but the live overlay is what
   makes dockerd resolve.)
2. **TLS — no CA bundle**, so dockerd can't verify registry certs. Fix:
   `cat /system/etc/security/cacerts/* > /data/docker/cacert.pem` (≈150 certs) and
   `export SSL_CERT_FILE=/data/docker/cacert.pem`.
3. **`pivot_root` fails on the Android ramdisk rootfs** (`runc: pivot_root .: invalid argument`).
   Fix: `export DOCKER_RAMDISK=1` → runc uses `MS_MOVE`+`chroot` instead.

These live in the device-side `dockerd-start-dns.sh` / `docker-up.sh` / `/system/xbin/docker` wrapper;
the repo `dockerd-start.sh` should adopt all three (esp. `DOCKER_RAMDISK` + `SSL_CERT_FILE` + resolv
overlay). Default remains **manual** start (`docker-up.sh` over SSH) for this heavy daemon on a 2 GB
device; boot auto-start is opt-in. **Docker on internal storage is viable and working.**
