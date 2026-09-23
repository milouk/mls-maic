# TCP BBR backport

Upstream added BBR in 4.9; this device is 4.4.302 (+ CIP's stable continuation, see
`../backport/`). BBR never existed on 4.4 upstream, so this is a real backport, not a
config flip: the canonical 4.9 series (7 commits, oldest to newest below) hand-adapted
onto a kernel two years older than the code it introduces.

## The series

`a4f1f9ac8153` lib/win_minmax: windowed min or max estimator
`6403389211e1` tcp: use windowed min filter library for TCP min_rtt estimation
`b9f64820fb22` tcp: track data delivery rate for a TCP connection
`d7722e8570fc` tcp: track application-limited rate samples
`eb8329e0a04d` tcp: export data delivery rate
`c0402760f565` tcp: new CC hook to set sending rate with rate_sample in any CA state
`0f8782ea1497` tcp_bbr: add BBR congestion control

`lib/win_minmax.c`, `net/ipv4/tcp_rate.c`, `net/ipv4/tcp_bbr.c` are wholesale new files;
they apply verbatim. Everything else in `bbr.patch` is the 4.4-vs-4.8 adaptation this
series needed on top of the files it touches (`include/{linux,net}/tcp.h`,
`include/net/inet_connection_sock.h`, `include/uapi/linux/{tcp,inet_diag}.h`,
`net/ipv4/{tcp,tcp_input,tcp_output,tcp_minisocks,tcp_cong}.c`, `lib/Makefile`,
`net/ipv4/{Kconfig,Makefile}`).

## What actually had to change for 4.4

- **No `cong_control` hook.** 4.4's `tcp_ack()` calls the classic `cong_avoid()`/pacing
  path unconditionally. Added `tcp_cong_control()` (runs `ca_ops->cong_control` when the
  congestion-control module provides one, else falls through to the old path) and wired
  it into `tcp_ack()`'s tail, after `tcp_rate_gen()`.
- **`struct tcp_sock` was missing the delivery-rate fields.** `delivered`, `lost`,
  `app_limited`, `first_tx_mstamp`, `delivered_mstamp`, `rate_delivered`,
  `rate_interval_us` didn't exist; added them. (`data_segs_in`/`data_segs_out` did
  already exist in this tree and needed no change.)
- **`ICSK_CA_PRIV_SIZE` was 64 bytes; `sizeof(struct bbr)` is 88.** Widened
  `icsk_ca_priv` in `inet_connection_sock.h` to 88 bytes (11x `u64`) -- the same +24
  bytes/socket mainline paid when BBR landed.
- **`tcp_skb_cb.tx` substruct packing.** Adding the two `skb_mstamp` fields BBR/tcp_rate
  need pushes `sizeof(struct tcp_skb_cb)` to 48 bytes against the 44-byte budget
  `skb->cb[]` actually has on this tree (structure layout differs enough from 4.8 that
  the padding upstream got for free isn't there). Marked the `tx` substruct `__packed`
  to fit back inside 44.
- **BBR's own CC-ops needs (`tso_segs_goal`, `sndbuf_expand`) didn't exist as hookable
  ops**, and its 3-arg `tcp_tso_autosize()` call didn't match this tree's existing
  (differently-shaped) TSO-sizing code. Added both ops to `tcp_congestion_ops`, wired
  them at the existing `tcp_tso_segs()`/`tcp_sndbuf_expand()` call sites, and made
  `tcp_tso_autosize()` 3-arg + exported to match. `tcp_bbr.c` itself needed no changes.
- **Prerequisite delivered/lost accounting** that the 7-commit series assumes already
  exists from later kernels but this tree doesn't have: `tp->delivered +=` on both the
  SACK path (`tcp_sacktag_one`) and the cumulative-ACK path (`tcp_clean_rtx_queue`);
  `tp->lost +=` at the three loss-marking sites. Without this BBR estimates zero
  bandwidth (the algorithm has no data to sample).
- One upstream hunk (a `delivered_mstamp` reset inside `tcp_shifted_skb`) was left out
  on purpose: 4.4 has no `tcp_skb_collapse_tstamp` to hook it from, and the field is
  already correctly reset elsewhere on this tree; no compile or steady-state impact.

## Enabling it

Built-in (`CONFIG_TCP_CONG_BBR=y`, `CONFIG_TCP_CONG_ADVANCED=y`,
`CONFIG_NET_SCH_FQ=y`) but **not** the default congestion control -- BBR wants `fq` as
its pacer, not the `fq_codel` default, so switching both is a deliberate runtime step,
not a silent kernel-side default flip:

```sh
sysctl -w net.core.default_qdisc=fq
sysctl -w net.ipv4.tcp_congestion_control=bbr
```

See `../tuning/maic_sysctl.sh` for the persisted version of this (a Magisk
`service.d` script, applied after `boot_completed`).

## Verifying it actually links, not just compiles

`grep`-ing for symbol name strings in a raw/gzip-decompressed `Image` is not reliable
proof the code is linked in -- kernel symbol tables are frequently kallsyms-compressed,
not literal ASCII, in the boot payload. Check the real `vmlinux` ELF instead:

```sh
aarch64-linux-gnu-nm vmlinux | grep -E "bbr_init|bbr_main|tcp_bbr_cong_ops|tcp_rate_gen"
```

and confirm `module_init(bbr_register)` -> `tcp_register_congestion_control(&tcp_bbr_cong_ops)`
is present in `tcp_bbr.c` -- that's what makes `bbr` actually appear in
`/proc/sys/net/ipv4/tcp_available_congestion_control` at boot, not just sit as
dead-linked code.
