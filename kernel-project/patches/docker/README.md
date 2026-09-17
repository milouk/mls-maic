# Docker support — prepared, compile-verified, NOT deployed

Research: `docs/research/docker.md`. Built in the isolated volume `maic-wt-docker`
(copy of the live tree at parity build 77bf6b99). Nothing flashed, the live `maic-kernel`
volume and `maic_defconfig` are untouched.

## Contents
| File | What |
|---|---|
| `defconfig.fragment` | 30 option lines to append to `kernel-project/config/maic_defconfig` (and `/src/out_m49w/.config`) |
| `docker.patch` | 2 source fixes vs `maic-kernel` (applies cleanly, `patch -p1`) |
| `test-plan.md` | first-boot Android checks → Phase 1 → Phase 2, with pass criteria and rollback |
| `magisk/post-fs-data.d/10-maic-cpuset.sh` | fixes Android's placeholder `cpus 0` cpusets before zygote |
| `scripts/` | `docker-setup.sh`, `docker-env.sh`, `cgroup-mount.sh`, `dockerd-start.sh`, `dockerd-stop.sh`, `daemon.json` (Phase 1), `daemon.phase2.json`, `phase2-routing.sh` |
| `../../out/candidates/docker/` | `boot_docker.img` (md5 `3aec3775b3d9c5b6199f9fa416761878`), `CHECKS.txt`, `mkboot.txt`, `Image`, `System.map`, `userspace/` (bundle, runc, scripts, `VERSIONS.txt`) |

## Kernel changes
**Config** (all built in; `olddefconfig` pulled in only direct deps: `PAGE_COUNTER`, `PROC_PID_CPUSET`,
`FS_POSIX_ACL`, `SYSVIPC_SYSCTL`, `SYSVIPC_COMPAT`, `POSIX_MQUEUE_SYSCTL`, `NF_NAT_MASQUERADE_IPV6` —
the full `.config` diff shows nothing else changed):
NAMESPACES, UTS_NS, IPC_NS, PID_NS, NET_NS (USER_NS **off**), POSIX_MQUEUE, SYSVIPC, CGROUP_DEVICE,
CGROUP_FREEZER, CGROUP_PIDS, CPUSETS, MEMCG, MEMCG_SWAP (not enabled by default), MEMCG_KMEM,
CFS_BANDWIDTH, DEVPTS_MULTIPLE_INSTANCES, OVERLAY_FS, EXT4_FS_POSIX_ACL, TMPFS_POSIX_ACL, TMPFS_XATTR,
VETH, NETFILTER_XT_MATCH_ADDRTYPE/CONNTRACK/COMMENT, NF_NAT_IPV6, IP6_NF_NAT, IP6_NF_TARGET_MASQUERADE.
ANDROID_PARANOID_NETWORK stays **on**. Skipped: USER_NS, IP_VS/XT_MATCH_IPVS (swarm), NF_TABLES,
BLK_CGROUP, VXLAN/MACVLAN/IPVLAN.

**Source (docker.patch)**
1. `net/netfilter/xt_qtaguid.c` `iface_stat_fmt_proc_show()`: always report `no_dev_stats` instead of
   `dev_get_stats(iface_entry->net_dev)` — the stale/NULL `net_dev` deref that reboots Android devices once
   veth interfaces come and go. Same fix as the FreddieOliveira gist and OshekharO/Docker-On-Android (cited
   in the code). Verified in the binary: the function no longer calls `dev_get_stats`.
2. `mm/memcontrol.c`: `.attach = mem_cgroup_move_task` → `.post_attach`. **Found by compiling**: the vendor
   tree carries half of upstream stable `264a0ae164bc` ("memcg: relocate charge moving from ->attach to
   ->post_attach", 4.4.9) — the new `void` signature and the cgroup core's `post_attach` call, but not the hook
   rename. It never mattered because stock never enabled MEMCG; with MEMCG it's a `-Werror` build failure.

## Sizes
| | parity 77bf6b99 | docker | Δ |
|---|---|---|---|
| Image | 16,085,936 B | 16,318,544 B | +232,608 |
| Image.gz (build) | 7,114,306 B | 7,226,676 B | +112,370 |
| kernel fit below ATF | 42,631,965 B | 42,521,448 B | −110,517 |
| ramdisk fit below ram_console | 1,638,026 B | 1,638,026 B | 0 |

## Userspace (staged, not installed)
Docker 25.0.5 static aarch64 (containerd 1.7.13, bundled runc 1.1.12), plus **runc 1.3.6** (published
sha256 verified) installed as `runc` with 1.1.12 kept as `runc-1.1.12`. runc ≥1.4 deprecates cgroup v1 —
do not upgrade past 1.3.x. Docker publishes no checksums for static bundles; a local sha256 is recorded.

## Risks
- **CPUSETS pins every app to CPU0** unless `10-maic-cpuset.sh` runs → install it *before* flashing (it's a
  no-op on the current kernel). Check 2.2 in the test plan is the gate.
- **MEMCG activates** Android's `/dev/memcg/apps` per-app groups (inert until now) — check RAM/lmkd on first boot.
- **Paranoid networking**: non-root container users need `--group-add 3003` (or GID 3003 in the image).
- 4.4.22 has container-escape-class kernel CVEs: trusted images only, USER_NS off.
- `/run` is created in the (RAM) rootfs by `dockerd-start.sh`; untested on this device.
- Bridge networking (Phase 2) needs `phase2-routing.sh` re-run after every Wi-Fi reconnect.
- Boot-image risk is low: config/netfilter/memcg only, fit checks passed, no DTB/cmdline/ramdisk change.

## Flash-day procedure (ordered)
1. On the **current** kernel: install `10-maic-cpuset.sh` to `/data/adb/post-fs-data.d/` (0755), reboot, confirm
   the log says "no cpuset hierarchy" and nothing else changed.
2. Record baselines (`dumpsys meminfo`, UI feel); confirm rescue still points at stock (`4c65df18`).
3. Push `boot_docker.img`, verify md5 `3aec3775b3d9c5b6199f9fa416761878` on device, `dd` to `mmcblk0p9`, read back, compare md5, only then reboot.
4. Run test-plan §2 (cpusets 0-3, memcg/lmkd, full regression set). Any failure → flash back 77bf6b99.
5. Stage + run `docker-setup.sh` (§3), then Phase 1 (§4). Keep Phase 2 for a separate session.
6. When happy: append `defconfig.fragment` to `maic_defconfig` and apply `docker.patch` to `maic-kernel`.

## Running docker (device-proven, 2026-09-17 — internal storage)

Working setup after freeing ~600 MB (see `test-plan.md` for the phase-1 result). Default is
**manual start over SSH** (heavy daemon on a 2 GB device):

- **`scripts/dockerd-start-dns.sh`** — the canonical start script for this Android host. Handles the
  three host gaps: resolv.conf via an overlayfs-on-`/system/etc` in a private mount ns, a CA bundle
  built from the system trust store (`SSL_CERT_FILE`), and `DOCKER_RAMDISK=1` for runc's pivot_root.
  Prefer this over the plain `dockerd-start.sh` (which lacks the three fixes).
- **`scripts/docker-up.sh`** — post-reboot convenience: starts dockerd + recreates the
  `/system/xbin/docker` PATH wrapper (`docker-wrapper.sh`) + `docker ps -a`.
- **`scripts/daemon.internal.json`** — internal data-root (`/data/docker/lib`), overlay2, host-net.
- **`magisk/maic-docker-resolv/`** — optional Magisk module: a global `/system/etc/resolv.conf` at boot
  (belt-and-suspenders to the runtime overlay).
- `scripts/docker-env.sh` exports `SSL_CERT_FILE` + `DOCKER_RAMDISK` so an interactive root shell
  matches the daemon's environment.

No boot auto-start by default; the opt-in guarded hook is `magisk/service.d/50-maic-docker-mount.sh`
(written for the external-drive path; not needed for internal storage).
