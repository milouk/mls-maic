# Stage 11: linux-4.4.y-cip @ cip114

Upstream 4.4.302 is the last release in the 4.4 line -- kernel.org EOL'd it. CIP
(Civil Infrastructure Platform) maintains `linux-4.4.y-cip`, a stable *continuation*:
professionally-maintained backports of everything the mainline stable process would
have shipped for 4.4, had it not been discontinued. At the point this was merged, CIP
was 6929 commits past our exact 4.4.302 base -- effectively "4.4.303 and up" for a
kernel that officially stopped at .302.

## Why

The kernel's security/stability posture had been "4.4.302 plus five hand-picked CVE
backports" (`patches/security/`). CIP replaces that with a maintained baseline covering
everything we actually run: `fs/ext4`, `net/ipv4`/`ipv6`/`netfilter`/`core`/`sched`,
`mm`, `crypto`, `drivers/net/usb`, `lib`. Two of the five hand-picked CVEs
(CVE-2025-38556, CVE-2024-53197) turn out to be *exactly* CIP's own fixes -- no
divergence, just redundant work retired by the merge.

## Scope of the merge

~2700 files changed. Excluded from the merge entirely (other architectures, hardware
this board doesn't have, or drivers already frozen for other reasons):
`arch/{x86,powerpc,mips,arm,...}`, `Documentation`, `tools`, `samples`,
`net/bluetooth` (MT6625L is a fixed 2013-era combo chip, see the WiFi/BT notes in the
main README), `drivers/net/wireless`, `drivers/net/ethernet`, `drivers/gpu`,
`drivers/media`, `drivers/scsi` (SCSI is USB-mass-storage glue here, no SCSI-attached
disks), `drivers/infiniband`.

Of everything left, the overwhelming majority (~2670 files) either fast-forwarded
cleanly (our copy was byte-identical to the pristine 4.4.302 CIP branched from) or
3-way-merged with zero conflicts (CIP's change and ours touched different regions of
the same file). `resolve-stage-cip114.sh` documents the ~22 files that needed an actual
decision -- everything else is a plain merge, same as every prior stage.

## What needed a decision, and why

**Vendor feature CIP doesn't have (keep vendor):**
- `net/ipv4/tcp.c`, `tcp_timer.c` -- the board's configurable `sysctl_tcp_rto_max`
  replaces upstream's hardcoded `TCP_RTO_MAX`; real, intentional, worth keeping. `tcp.c`
  still absorbs CIP's *other* unrelated fixes in the same file (an `out_of_order_queue`
  -> `RB_ROOT` conversion, a splice-read fix) via the ordinary merge, since those don't
  touch the same lines.
- `drivers/usb/gadget/function/{u_ether.c,rndis.c}` -- vendor's RNDIS pair has two
  MTK-only additions (a different, still-header-exposed `struct eth_dev` shape in
  `u_ether.h`; a throughput-tuning `rndis_set_max_pkt_xfer()` that `f_rndis.c` calls
  directly) with no CIP equivalent. `android.c`, `f_rndis.c`, `u_ether.h` were never
  touched by the merge, so keeping both files vendor keeps that whole cluster
  internally consistent rather than mixing versions.
- `arch/arm64/mm/proc.S`, `drivers/watchdog/mtk_wdt.c` -- MTK-specific, nothing to merge.
- `drivers/mtd/ubi/wl.c` -- CIP's version needs a fastmap "fast_attach" feature that
  spans several more files in `drivers/mtd/ubi/` we never touched. This board has no
  raw NAND (eMMC only); `CONFIG_MTD_UBI=y` is unused generic-defconfig cruft, not worth
  the blast radius to chase.

**CIP fix that needed a vendor feature spliced back in:**
- `fs/ext4/mballoc.c` -- the board threads a `blkdev_flags` (secure-discard) argument
  four functions deep: `ext4_trim_fs` -> `ext4_trim_all_free` -> `ext4_trim_extent` ->
  `ext4_issue_discard` -> the final `sb_issue_discard()` call. CIP's version drops it.
  Took CIP for the whole file (every other fix, including a genuine `count` ->
  `count_clusters` overflow-fix rename at an unrelated call site), then hand-restored
  just those 4 signatures to the vendor 5-argument-deep threading. `fs/ext4/ext4.h`'s
  declaration and `fs/ext4/ioctl.c`'s caller were never touched by the merge (no
  conflict marker -- they don't overlap CIP's lines at all), so taking CIP outright
  here would have silently desynced them from the function body. That's the general
  risk with any "just take theirs" resolution on a vendor-extended function: check who
  else calls it before assuming a clean merge means a consistent one.

**Build-environment (GCC 5.4), not a real conflict:**
- `include/linux/overflow.h` -- `check_{add,sub,mul}_overflow()`'s type-mismatch guard
  (`(void) (&__a == &__b)`) is a deliberate compile-time-only diagnostic upstream relies
  on GCC accepting as a soft warning. GCC 5.4 has no selectable flag for it by name
  (confirmed: `-Werror=compare-distinct-pointer-types` is rejected as unrecognized, not
  just inactive), and legitimate callers this backport pulls in mix `size_t`/`unsigned`
  on purpose (e.g. `lib/ts_kmp.c`). Stripped the 6 diagnostic-only lines from the active
  branch; the real `__builtin_*_overflow()` call is untouched, zero runtime effect.
  Left the unused `#else` fallback branch alone.

**Excluded directory, header not excluded (the same class of bug as the ext4 one):**
- `drivers/scsi/hosts.c` -- `drivers/scsi/*` was excluded from the merge, but
  `include/scsi/scsi_host.h` was not, and CIP widened `scsi_host_lookup()`'s `hostnum`
  from `u16` to `u32`. `hosts.c` (still vendor, untouched) kept the old signature *and*
  a local `const unsigned short *` pointer cast in `__scsi_host_match()` that would
  have silently truncated the wider value on every call -- a real latent bug, not just
  a compile error. Widened both.

## Result

Full `Image.gz` build succeeded first try after these 22 files were resolved (plus a
7-iteration build-fix loop finding them one at a time the first time this was done --
`resolve-stage-cip114.sh` is the distilled, already-correct version; a fresh `git merge`
+ this script should reach a clean build directly). Verified post-merge: no leftover
conflict markers or `.rej`/`.orig` files anywhere in the tree; all vendor-kept files
byte-identical to their pre-merge content; the five originally-hand-backported CVEs
(now a mix of CIP-native and CIP-superseding-vendor) still present; the three
explicitly-forbidden config options (`DEBUG_RODATA`, `ARM64_SW_TTBR0_PAN`,
`CC_STACKPROTECTOR_STRONG`) still unset; a full `.config` diff against the pre-merge
baseline shows no unexpected changes.
