# rm13: kernel security hardening + WiFi power-save off

Low-risk, config-first hardening for the shipping kernel, chosen from a KSPP-style
review of what actually backports to 4.4 without breaking this vendor tree. Measured:
**zero CPU cost** (a fixed compute loop was identical before/after, 865 cs), and **no
`usercopy`/`BUG`/list-corruption events** even under docker network+disk load.

## What's enabled (`defconfig.fragment`)

- **`CONFIG_HARDENED_USERCOPY=y`** -- bounds-checks every copy between kernel heap/stack
  and userspace, blocking a whole class of over-read/over-write bugs. This is the
  4.8-era bounds-checking flavour (no per-cache whitelist), the version Android shipped
  widely on 4.4, so false-positive risk is low. The vendor tree only backported the
  allocator hook for **SLAB**; this kernel uses **SLUB**, so `hardened-usercopy-slub.patch`
  backports `__check_heap_object()` into `mm/slub.c` (upstream 4.8 `ed18adc1cdd0`, minus
  the `red_left_pad` redzone field which doesn't exist on this 4.4 SLUB) -- without it the
  build fails to link once `HARDENED_USERCOPY` is on.
- **`CONFIG_SCHED_STACK_END_CHECK=y`** -- catches kernel stack overruns at schedule time.
- **`CONFIG_DEBUG_LIST=y`** -- catches linked-list corruption, a common exploit primitive.

Deliberately **not** done: `CC_STACKPROTECTOR_STRONG` (breaks this build via
camera_isp frame-larger-than), `DEBUG_RODATA`/`ARM64_SW_TTBR0_PAN` (rm5/rm6 did not
boot), `SLAB_FREELIST_RANDOM` (option absent from this tree's Kconfig -- needs a code
backport for marginal gain), `FORTIFY_SOURCE`/`RANDSTRUCT`/`VMAP_STACK` (too invasive /
GCC 5.4 plugin infra absent). See `../../../BENCHMARKS.md`.

## WiFi power-save off (`wifi-ps-off.patch`)

`CFG_SUPPORT_PWR_MGT 1 -> 0` in the connsys gen2 driver. The device is always on mains,
so 802.11 power-save only adds latency. Measured after the change: gateway ping
**2.03 / 2.77 / 3.66 ms, 0% loss, 0.48 ms jitter** -- tight and stall-free. WiFi + BT
confirmed fully functional. There is no clean runtime knob for this on connsys gen2, so
it is a compile-time flag.
