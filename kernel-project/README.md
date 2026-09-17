# Kernel project — rebuild 4.4.22 with namespaces (Docker), keeping all hardware

## Goal
Same kernel version (4.4.22), rebuilt from source with `CONFIG_PID_NS`, `NET_NS`,
`IPC_NS`, `UTS_NS`, `OVERLAY_FS` and the missing cgroup controllers enabled, so Docker
works and **nothing else changes**. Keeping the version and BSP identical keeps the
driver ABI identical, so the Android 7 HALs (PowerVR DDK `1.8@4490469`, WiFi, camera,
audio) keep working.

Optional later rung: merge 4.4 LTS stable up to **4.4.302** (Feb 2022) for ~5.5 years of
CVE fixes, still inside a series that does not break driver APIs.

## Source
`XiKoTaSu/android_kernel_eebbk_mt8167` — **kernel 4.4.22, the exact version this device
runs**. Carries `drivers/misc/mediatek/connectivity/{bt,common,fmradio,gps,wlan}` (our
CONSYS WiFi), `drivers/misc/mediatek/gpu/gpu_rgx` (our PowerVR), `gslX680` (our touch),
`lcm/kd070d5450nha6_rgb_dpi` (our exact panel), and `tb8167p3_64_defconfig`.

## Gaps and their status

| part | in source? | plan |
|---|---|---|
| panel `kd070d5450nha6` | yes, exact | use as-is |
| touch `gslX680` (Silead) | yes | need our panel-specific GSL firmware blob |
| WiFi CONSYS, `gpu_rgx` | yes | use as-is |
| GPU DDK | source has `m1.8ED4302432/4333936`, we run `1.8@4490469` | reconcile build ID; same 1.8 ABI |
| **amp `ad82584f`** | **nowhere public** | write ASoC driver replaying `../tools/ad82584f/` sequence — **probe-only, no runtime writes (proven)** |
| **voice DSP** | nowhere public | thin IRQ-to-input shim, reimplement |
| **camera `gc5024`** | not in MT8167 trees | port from `bolt1502/MT6735-37_GC5024_Driver` |

## Build environment (working)

Upstream: `XiKoTaSu/android_kernel_eebbk_mt8167`, branch **`4.4.22`** -- the *exact*
version the device runs (`Linux version 4.4.22 ... gcc 4.9 ... #33 SMP PREEMPT Fri May 15
2020`). Reference defconfig: **`tb8167p3_64_defconfig`**; `mt8167.dtsi` is present.

```sh
docker build -t maic-kbuild kernel-project/docker
JOBS=8 ./kernel-project/build.sh tb8167p3_64_defconfig   # log: /tmp/maic-kbuild.log
```

The source lives in the Docker volume `maic-kernel` at `/src/linux`, built out-of-tree
into `/src/out` so the tree stays pristine.

**Why a container and not the Mac:** macOS is case-insensitive by default and Linux has
files differing only by case (`xt_CONNMARK.h` vs `xt_connmark.h`, `ipt_ECN.h` vs
`ipt_ecn.h`). The tree cannot be checked out on the Mac at all. Since the target is arm64
and Apple Silicon is arm64, the container compiles **natively** -- no cross-toolchain, no
qemu, full speed.

Three things had to be solved to get it compiling:

1. `CROSS_COMPILE ?= $(CONFIG_CROSS_COMPILE:"%"=%)`, and the vendor defconfig sets that to
   `aarch64-linux-android-` (an AOSP prebuilt we do not have, and which is x86_64-only so
   it would not run here anyway). A command-line assignment beats `?=`, so `build.sh`
   always passes `CROSS_COMPILE` explicitly -- empty on arm64.
2. The kernel was built with GCC 4.9; GCC 7 adds warnings that did not exist then and the
   tree uses `-Werror`. `build.sh` **probes** each candidate `-Wno-error=` against the
   container compiler and passes only the supported ones (passing an unknown one is itself
   an error). Targeted, so genuine new errors still stop the build.
3. One of those is a real MediaTek bug rather than a style nit:
   `drivers/misc/mediatek/uart/mt8167/platform_uart.c` does
   `if (atomic_inc_and_test(&vfifo->entry) > 1)`, and `atomic_inc_and_test` returns a
   bool, so the test is always false. Demoted, not fixed -- it is vendor code and not on
   our path.

## Input devices / hardware keys (live inventory)

The three physical keys are split across **two different drivers**, which a kernel
rebuild must both provide:

| input | device | keys reported |
|---|---|---|
| `event2` | `mtk-kpd` (keypad controller) | `KEY_VOLUMEUP` |
| `event3` | `mtk-pmic-keys` (PMIC) | `KEY_VOLUMEDOWN`, `KEY_POWER` |
| `event1` | `DSP_IRQ` (the `emdoor,synaptics_dsp` voice DSP) | `KEY_POWER`, `KEY_VOICECOMMAND` |
| `event0` | `ACCDET` (headset jack detect) | volume keys, `KEY_HANGEUL`, `KEY_NEXTSONG` |
| `event5` | `mtk-tpd` (Silead `gslx68x` touch) | — |
| `event4` | `hwmdata` | — |

Good news for the rebuild: `mtk-pmic-keys` is **in mainline** (`drivers/input/keyboard/mtk-pmic-keys.c`),
so power + volume-down are covered by upstream code.

**This also identifies what the voice DSP is for.** `DSP_IRQ` reports `KEY_VOICECOMMAND`
and `KEY_POWER`, i.e. it is a wake-word / voice-trigger block that pokes the input
subsystem — exactly the "thin IRQ-to-input shim" the gap table predicted. Reimplementing
it means generating those two key events from its IRQ, not reproducing an audio path.
Only `/system/usr/keylayout/mtk-kpd.kl` exists; the other devices fall back to `Generic.kl`.

### Power key: short press is a vendor broadcast, not sleep

MLS modified `PhoneWindowManager.powerPress()`. Instead of sleeping, it does
`sendBroadcast("android.action.ACTION_SHORT_PRESS_POWER")` (visible in `services.odex`,
and logged by AMS each press as `Sending non-protected broadcast ... from system`).
The only code referencing that action is `/system/priv-app/MAIC/oat/arm64/MAIC.odex`,
which registers for it **dynamically** — so with the MAIC app not running (Lawnchair is
the launcher), nothing receives it and the key appears dead. Long press is untouched:
`mLongPressOnPowerBehavior=1` = stock global-actions dialog. `mShortPressOnPowerBehavior=2`
is therefore vestigial — the vendor code path returns before honouring it.

Because the broadcast is **unprotected**, any app can claim the key with a plain
receiver. No framework patch and no kernel change needed.

## Driver gap: our board vs the upstream reference board

Decompiled our DTB and the reference `tb8167p3_64.dtb` the build produces, then diffed the
`compatible` strings. The delta is small -- **15 strings** -- which is the good news.

**In the reference but not ours** (just disable): `mediatek,camera_flashlight`,
`mediatek,camera_main_af`, `mediatek,mc3433` (a different accelerometer),
`mediatek,mt8167-irrx`.

**Ours, checked against what the tree actually ships:**

| compatible | status | source |
|---|---|---|
| `kd,kd070d5450nha6` (panel) | **in tree** | `lcm/kd070d5450nha6_rgb_dpi` |
| `mediatek,cap_touch` (Silead touch) | **in tree** | `touchscreen/mediatek/gslX680` |
| `ti,lp8557-led` (backlight) | **in tree** | `lp855x_bl.c` |
| `mediatek,flashlights_lm3642` | **in tree** | `leds-lm3642.c` |
| `mediatek,camera_sub_af` | **probably in tree** | node is at i2c `0x18`, the standard **DW9714** address, and `lens/sub/common/dw9714af` already exists |
| `ESMT, ad82584f` (amp) | **VENDORED** | Amlogic/Allwinner BSP driver, OF match byte-identical to ours |
| `silergy,sym827-regulator` (**vproc**) | **VENDORED** | `drivers/regulator/sym827-regulator.c` from MTK trees, OF match identical |
| `mediatek,STK8BAXX` (accelerometer) | **VENDORED** | `accelerometer/stk8baxx-new/` from an MTK tree, same path layout we have |
| `nuvoton,nau8540` (4-ch mic ADC) | **VENDORED** | mainline `sound/soc/codecs/nau8540.{c,h}` |
| `gc5024` (camera) | **VENDORED** | `imgsensor/src/*/gc5024_mipi_raw/` from an MTK tree |
| `emdoor,synaptics_dsp` (voice DSP) | **written** | nothing public; reimplemented in `drivers/synaptics_dsp.c`. Measured inert on stock -- see below |
| `emdoor,ts809_led_en` | **no loss** | `soc:led_en` has **no driver bound on the stock kernel** either, exactly like `zigbee`. Dropping it changes nothing |
| `mediatek,cc2530` (ZigBee) | **no loss** | see below |

All vendored copies live in `kernel-project/vendor-refs/`.

### How these were found, and a correction

The earlier "nowhere public" verdicts in this repo came from **web search engines**, which
return nothing useful for `ad82584`, `sym827` or `stk8baxx`. A GitHub **code** search finds
all of them in seconds. That was a methodology error on my part, and it cost real effort:
the amp in particular was written up as a from-scratch driver project when a complete
1044-line ASoC driver for the exact same binding already existed. Search code, not the web,
for vendor driver names.

### ZigBee (cc2530): nothing is lost by omitting it

Our DTB declares `zigbee { compatible = "mediatek,cc2530"; }` -- and that is *all* it
declares: no `reg`, no interrupts, no UART phandle. On the **live stock device** there is a
platform device named `zigbee` but **no driver bound to it**, and `dmesg` never mentions
cc2530. So the radio is doing nothing today, and a new kernel that omits it is not a
regression.

Whether the chip is even populated is unproven. A CC2530 runs TI's ZNP firmware and speaks a
serial protocol, so it needs no kernel driver at all -- it would appear as a UART. The device
has `ttyS1/2/3` and `ttyMT0/1` free (`ttyS0` is the console). A future zero-cost experiment
is to probe those for a ZNP `SYS_VERSION` response; if one answers, ZigBee becomes usable
from **userspace** (zigbee2mqtt) on the *current* kernel, with no kernel work at all.

`silergy,sym827-regulator` was the one that worried me -- it is **vproc**, the CPU core
supply, not a peripheral we could shrug off. It turned out to be a clean drop-in: the MTK
driver's OF match is `silergy,sym827-regulator`, exactly our string.

Two discoveries worth calling out. `mediatek,STK8BAXX` finally **identifies the
accelerometer**, which had only ever shown up as the generic `mediatek,gsensor1`. And
`mediatek,cc2530` means the board carries a **TI CC2530 ZigBee radio** -- a genuine smart-home
radio sitting unused in a kitchen hub.

## The voice DSP is inert on the stock kernel (measured)

The one driver with no public source is `emdoor,synaptics_dsp`, and the obvious worry was
that a reimplementation would be a guess. It was measured on the **stock, working** device
instead of reasoned about.

Method: watch `/dev/input/event1` (the stock driver's `DSP_IRQ` input device) through a pty
while sampling `/proc/interrupts` every 4 s, for 120 s, with someone speaking, trying
wake-word phrases and clapping next to the microphones.

Result:

```
t+0s   ... mtk-eint  72 Edge  DSP_IRQ   count = 1
t+116s ... mtk-eint  72 Edge  DSP_IRQ   count = 1
input events captured: 0
```

**The interrupt count never moved off 1** -- that single count is from boot -- and the stock
driver emitted **no input events at all**. The block is powered and bound, and does nothing.

That is almost certainly because the feature is dead rather than broken: MAIC was MLS's
voice-assistant product, MLS is bankrupt, and the assistant app that would have armed the
DSP (and possibly pushed its firmware) never runs on this device any more.

**Consequence:** the fidelity of our reimplementation barely matters. A faithful
replacement is "apply the pinctrl power/reset sequence, register an input device named
`DSP_IRQ` advertising `KEY_POWER` and `KEY_VOICECOMMAND`, and wire up the edge IRQ" --
which is what `drivers/synaptics_dsp.c` does. Whatever the original did *with* an
interrupt is untestable and unused, because no interrupt ever arrives.

Note the microphones are **not** affected by this: they are the `nau8540` 4-channel ADC on
I2C, a separate and fully supported mainline driver. Anything that wants to listen (a
sound-triggered alert, for instance) goes through the nau8540, not this block.

## Testing a kernel WITHOUT risking the device

`boot` is `mmcblk0p9`; **`recovery` is `mmcblk0p10`** -- a separate, standard `ANDROID!`
image, also 16 MB (our `Image.gz-dtb` is ~7 MB, so it fits with room to spare). `para`
(`mmcblk0p11`) is MTK's BCB/misc and currently reads **all zeros** (no pending command).

That gives a test path that never touches `boot`:

1. `dd` the **stock recovery off to the Mac first** (it is the thing we are overwriting).
2. Pack the new kernel with the **stock recovery ramdisk** (which already runs `adbd`), and
   write that to `recovery` only. `boot` is untouched throughout.
3. Boot it with the **hardware key combo**, *not* `adb reboot recovery`.
4. If it works: adb in and read `dmesg` to see exactly which drivers probed.
5. If it hangs: hold power to force off, boot normally. `boot` is intact, so the device
   comes straight back.

**Step 3 is the whole point.** `adb reboot recovery` writes a `boot-recovery` command into
the `para` BCB; if the recovery kernel then hangs before clearing it, the bootloader keeps
re-entering the broken recovery -- a boot loop that needs mtkclient to escape. Entering
recovery by key combo leaves **no persistent state anywhere**, so a failure costs one
power cycle and nothing else.

### The LK boot menu -- CONFIRMED WORKING, and this is the cable-free escape hatch

**LK = "Little Kernel"**, the second-stage bootloader: `preloader -> LK -> Linux kernel`.
It draws the logo, implements fastboot, and picks normal/recovery/fastboot from the BCB
flag and from keys held at power-on.

**THE COMBO THAT WORKS (verified on the device):**

> **Unplug the power cable. Hold VOLUME UP. Plug the power cable back in.**

The device is mains-powered and boots when AC is applied, so LK's key-sampling window
happens at **cold power-on via the cable** -- not when pressing Power on an already-running
device. That is why "hold Vol Up + press Power" repeatedly failed: by then the window had
long passed. Holding Vol Up through AC application lands in the boot menu, from which
Recovery was successfully entered and exited.

Menu contents and controls, from strings in `firmware/lk.img` and confirmed in use:

```
[Normal      Boot]         <<==
[Recovery    Mode]
[Fastboot    Mode]
[FACTORY]
[VOLUME_UP to select.  VOLUME_DOWN is OK.]
```

**VOLUME_UP moves the selection, VOLUME_DOWN confirms.**

Other key results, for the record:

| at cold power-on | result |
|---|---|
| **Volume Up held** | **boot menu** (this is `MT65XX_RECOVERY_KEY`) |
| Volume Down held | **FACTORY mode** -- sits at the logo, shows nothing. Harmless, exit by removing power, but avoid |
| nothing held | normal boot |

### Does a set BCB skip the boot menu? STILL UNKNOWN -- the first test was invalid

An attempt was made to answer this: `boot-recovery` was written into the BCB command
field, then the device was booted holding Volume Up, and it went to recovery without
showing the menu. **That result does not mean what it looks like.** The AC cable was not
fully unplugged for that attempt, so there was no cold power-on and LK's ~50 ms key window
never opened. Volume Up was never sampled. The device simply honoured the flag, which is
exactly what it should do.

So the question is open. To answer it properly the cable must be fully removed first, then
Volume Up held while power is reapplied -- the same sequence that reliably reaches the menu
with a clear BCB.

**It does not actually matter for the test plan**, because the rule below holds either way.

### The rule: enter recovery ONLY from the boot menu, never via the BCB

> **Never use Magisk's "reboot to recovery", `adb reboot recovery`, or anything else that
> writes the BCB, during kernel testing.**

| entry method | BCB | if the test kernel hangs |
|---|---|---|
| Magisk / `adb reboot recovery` | set | LK keeps re-entering recovery -> **needs mtkclient + cable** |
| **boot menu -> `[Recovery Mode]`** | **untouched** | power-cycle -> **boots normally from p9** |

If the BCB is never written, nothing persists to send LK back into a broken recovery, so a
hung test kernel costs exactly one power cycle. That is what keeps the USB-A-to-A cable a
nice-to-have rather than a blocker -- and it holds regardless of how the open question
above resolves.

Both menu paths are confirmed working: `[Recovery Mode]` entered and exited stock recovery,
and `[Normal Boot]` booted Android normally.

**Note on stock recovery's "No command" screen:** that is the normal idle screen. To get its
menu, hold **Power** and tap **Volume Up** once, then release -- not both volume keys.

### Round-trip already validated with the stock recovery

Entered recovery from the menu and exited with "reboot system now". Afterwards, verified
byte-for-byte that nothing moved:

| partition | md5 | |
|---|---|---|
| `boot` p9 | `4c65df18406167aba3bf4b1e33565cfd` | our Magisk-patched boot, unchanged |
| `recovery` p10 | `79290d0f47a3e25977e17f6b87a2c722` | stock, matches `backups/` |
| BCB p11 | all zeros | recovery cleared the flag on exit |

### Zero-write test options: both ruled out

- `fastboot boot` -- the bootloader is **locked** (`ro.boot.flash.locked=1`,
  `verifiedbootstate=green`). `ro.oem_unlock_supported=1`, but unlocking forces a wipe.
- **kexec** -- not compiled in. `/proc/kallsyms` shows `sys_kexec_load` and friends only as
  **weak stubs at address 0**, and `/sys/kernel/kexec_loaded` does not exist.

So the recovery partition remains the test vehicle, with the boot menu as the escape hatch.

Still required before any of this: the **USB-A-to-A cable** and mtkclient ready as the
backstop, because the honest worst case (a bad write, a wrong partition) still needs the
preloader. And confirm which combo this LK uses before relying on it.

## MUST DO BEFORE ANY KERNEL FLASH

Harvest everything from the **working** device first, because a failed flash may end
access. Captures live in `captures/`.

- [x] `our_device.dtb` — our device tree (md5 `3d9e5e5cf8473106af49eea9e3d1bdac`)
- [x] `../tools/ad82584f/ad82584f_init_sequence.txt` — amp probe-time init, 1417 writes
- [x] `gc5024_init_sequence.txt` — camera sensor init, 319 writes
- [x] **amp RUNTIME behaviour — DONE, and the answer is "there is none".** Traced during
      real Spotify playback (start/pause/resume), injected volume keys, **physical** volume
      +/- buttons, and a screen-off suspend/resume cycle: **zero** writes to `a=031` in all
      four. The suspend run is the control — it caught 90 events, all at `a=040` (the Silead
      touchscreen), so the tracer was working and the amp was genuinely silent. Volume lives
      in the SoC mixer (MTK AFE/DAC digital gain). The driver needs a `probe()` that replays
      the captured sequence and nothing else: no volume/mute callbacks, no DAPM register
      pokes, no suspend/resume. See `../tools/ad82584f/README.md`.
- [ ] voice DSP behaviour (`synaptics_dsp_event_work`)
- [ ] GSL touch firmware blob (symbols exist: `gsl_DataInit`, `gsl_version_id`; note
      `/proc/gsl_config` reads empty)

## Capture technique

```sh
T=/sys/kernel/debug/tracing
echo 0 > $T/tracing_on; echo > $T/trace
echo 1 > $T/events/i2c/enable
echo 1 > $T/tracing_on
# ... trigger the activity, or force a driver re-probe:
#   echo 1-0031 > /sys/bus/i2c/drivers/ad82584f/unbind ; echo 1-0031 > .../bind
echo 0 > $T/tracing_on
cat $T/trace > /data/local/tmp/trace.txt    # cat, NOT cp: debugfs reports size 0
```

Line format: `i2c_write: i2c-1 #0 a=031 f=0000 l=2 [00-04]` = reg `0x00` <- `0x04`.

## Backups
The working boot image is `../firmware/magisk_patched_boot_25.2.img`, verified identical
to the live partition (md5 `4c65df18406167aba3bf4b1e33565cfd`). Stock and 21.4 boots are
alongside it.

## Prerequisite
**A USB-A-to-A cable.** A kernel that does not boot leaves no adb, so `mtk-su` cannot
rescue it. Do not flash to `boot` without it.

## RESULT: the eebbk tree does not boot this board

Four recovery-partition tests, all entered from the boot menu so the BCB stayed clean and
every failure cost exactly one power cycle:

| # | image | result |
|---|---|---|
| 1 | our kernel + our patched ramdisk | nothing, fell back to Android |
| 2 | **stock kernel + stock ramdisk, repacked (signature dropped)** | **BOOTED** -- stock recovery appeared |
| 3 | our kernel + stock ramdisk | nothing |
| 4 | **pristine `tb8167p3_64_defconfig` kernel + stock ramdisk** | **black screen, no boot** |

**Test 2 is the control that matters:** LK does **not** verify recovery image signatures, so
the missing 4,576-byte PKCS#7 block was a red herring. (Stock `boot` is signed too, yet the
Magisk-patched unsigned one runs fine.)

**Test 4 is the verdict:** a completely unmodified build of the reference defconfig from this
tree does not boot either. So the fault is **the source tree**, not our drivers, the panel
swap, the touch firmware or the ramdisk patch.

### Why we cannot debug it further from here

The kernels die before producing a single character:

- `pstore` is enabled in our config (`PSTORE_RAM` at `0x44410000`), and after every attempt
  the ramoops buffer still held the *previous Android session's* log -- our kernel never
  reached even the RAM console.
- The arm64 image headers are structurally identical to stock (`text_offset 0x80000`, same
  flags, same `ARM\x64` magic), so LK loaded it and jumped; it died immediately.
- The image is valid gzip with the DTB appended exactly as stock, magiskboot preserves both
  MTK headers (`KERNEL` and `RECOVERY`) and the `bootopt=64S3,32N2,64N2` cmdline, and the
  recomputed header checksum is fine -- test 2 proves that whole path works.
- The stock kernel carries **no IKCONFIG blob**, so its exact configuration cannot be
  recovered for comparison.
- The device has **no accessible UART** (it is enclosed).

No console channel means further bisection of this tree is blind and expensive.

### Better candidate: the Lenovo smart-display tree

`deadman96385/android_kernel_lenovo_mt8167s` -- kernel **4.4.95** (newer than 4.4.22, so more
stable patches), branches **`ivy-smart-display`** and **`smart-clock`**: the same *device
class* as this hardware, rather than an education tablet.

It is also where the **correct 1024x600 DPI panel driver** came from -- the one that matched
this device exactly, while the eebbk copy was an 800x1280 DSI driver for different hardware.
That is real evidence its target is close to ours.

Hardware coverage there: `gslX680` and `sym827` present; `ad82584f`, `nau8540` and
`stk8baxx` absent -- but those are already vendored here and would port across, as would the
extracted GSL firmware and the device's own DTB.

Everything harvested from the device stays valid regardless of tree: the DTB, the amp
register dump, the camera init sequence, the touch firmware blob.


## Diagnosis: the kernel dies in early boot (watchdog reset), cause narrowed

Built a marker mechanism (init writes a file to /cache at "on fs", before any UI) plus a
post-fs-data hook that snapshots dmesg early. Read MTK's own crash record at
`/proc/aed/reboot-reason`. Findings, consistent across our full build, a diagnostic build,
and a `maxcpus=1 cpuidle.off=1` build:

- **`WDT status: 5`, `bootreason: watchdog`** — the hardware watchdog fired; the kernel
  never started kicking it. Not a clean panic.
- **`last init function: 0x0`** — MTK records the current initcall pointer during boot; it
  is still 0, so **the kernel died before the initcall phase even began** (before
  `do_initcalls`, before the RAM console driver, which is why pstore only ever holds the
  previous Android session).
- **`LAST PC CORE_0 = 0x43009870`, identical every attempt.** 0x43000000 is where ATF
  (the EL3 secure monitor, partition `tee1`, MTK header name "atf") loads. So when the
  watchdog fired the CPU was in **secure world**, at the same address every time — not
  scattered, which points at a deterministic early hang, not a race.
- The boot marker file is **never written**, confirming init never runs.

**Ruled out by controlled tests** (all entered from the boot menu, BCB clean, one power
cycle each): image signature (stock repacked-unsigned boots), the ramdisk (our kernel
fails with the stock ramdisk too), our source modifications (a pristine
`tb8167p3_64_defconfig` fails identically), the kernel Image header (byte-identical
`text_offset`/flags/magic to stock), SMP/idle (maxcpus=1 cpuidle.off=1 unchanged), and
missing code (init-section symbol diff vs the running stock kernel shows only our own
drivers added and nothing boot-critical removed).

**What remains:** the kernel *binary* is the differentiator — the stock kernel, repacked
through the exact same path, boots; ours does not, and so does a pristine build of the
reference defconfig. Both our failing trees were built with **GCC 7.5**; the stock kernel
was built with **GCC 4.9** (per its `/proc/version`). An early-boot hang with zero console
output, deterministic PC, before initcalls, is a classic **compiler-codegen** signature for
an old (4.4) kernel built with a much newer toolchain. That is the top untried hypothesis.

**Blocker on testing it:** the device is enclosed (no UART), so there is no console channel;
each hypothesis costs a full build + a physical flash/boot with a binary pass/fail. And a
period-correct aarch64 GCC 4.9/4.8 is hard to obtain natively on an Apple-Silicon host —
the Linaro/AOSP prebuilts are x86_64 and hit Rosetta errors under Docker.

## BREAKTHROUGH: it's the display driver, and the compiler DID matter

Testing the GCC 4.9 hypothesis (the exact stock toolchain, `4.9.x 20150123 (prerelease)`,
run as an x86_64 prebuilt under Docker's amd64 emulation on Apple Silicon) changed the
failure mode completely:

| build | `/proc/aed/reboot-reason` | meaning |
|---|---|---|
| GCC 7.5, any config | WDT status 5, **last init 0x0**, PC in ATF (0x43009870) | died before the initcall phase even started |
| **GCC 4.9, pristine tb8167p3_64_defconfig** | WDT status 5, **exp_type 2 (KE)**, fiq step 69, **last init = mtkfb_init** | booted into driver initcalls, **panicked in the display driver** |

So GCC 7 genuinely miscompiled the early boot path — GCC 4.9 sails past it and the kernel
runs all the way to `mtkfb_init` (the MediaTek framebuffer initcall), where it takes a
kernel exception. **That is why the screen was black every single time: the display init
was the crash.**

And the pristine build that panicked there still carries the eebbk tree's *wrong* panel
driver — the 800x1280 MIPI-DSI `kd070d5450nha6_rgb_dpi` we already identified and replaced.
Our `maic` tree has the correct 1024x600 parallel-DPI driver plus matching `LCM_WIDTH/HEIGHT`,
so the next build (maic_defconfig + GCC 4.9) tests whether the correct display driver gets
past `mtkfb_init`.

**Toolchain of record for this kernel: aarch64-linux-android-4.9, not GNU GCC 7.** Build
container `kernel-project/docker-amd64` (emulated x86_64), toolchain volume `maic-tc49`
(`LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9`,
branch lineage-17.1).

## THE KERNEL BOOTS. (maic tree + correct panel + GCC 4.9)

Building our full `maic` tree (correct 1024x600 DPI panel, all vendored drivers, USB switch)
with GCC 4.9 and reading `/proc/last_kmsg` afterwards proved the kernel boots and runs:

```
[0.734] musb probe ... [0.761] android_usb gadget: android_usb ready
[0.750] kd070d5450nha6_rgb_dpi panel@0: Error applying setting, reverse things back
[0.763] mtk-tpd: MediaTek touch panel driver init
[1.083] mtk-tpd: Cap touch panel driver          <- our GSL touch driver up
[1.483] init: /init.recovery.mt8167.rc            <- USERSPACE INIT RUNNING
...
[275.4] [BATTERY] CC mode charge, timer=280 ...   <- alive 4+ minutes, until power-cycled
```

No panic, no watchdog. The GSL touch driver initialised, userspace init parsed its rc, and
the kernel ran indefinitely. The full log is saved at
`kernel-project/out/first_successful_boot_log.txt`.

The "stuck green screen" is now explained and is a small remaining issue, not a crash:
`kd070d5450nha6_rgb_dpi panel@0: Error applying setting, reverse things back` comes from
`drivers/pinctrl/core.c` — the **pinctrl** subsystem failed to apply the panel's `pinctrl-0`
(its LCD power/reset pin group, DTB phandle 0x59). The backlight is on (screen is lit
green, not black) but a panel control pin group did not apply, so no proper image. This is
a pinctrl/DTS reconciliation, not a driver rewrite.

### Remaining work (all on a booting kernel now)

1. **Panel pinctrl**: reconcile the panel@0 `pinctrl-0` group so the DPI panel initialises
   fully. Investigate with live dmesg once adb is up.
2. **adb enumeration**: the gadget reaches "android_usb ready" and configures (`cfg 1
   speeds: super high full`) but did not enumerate on the host. Likely a cmode/swmode
   ordering issue — the swmode flip to device mode needs to settle before the gadget
   pullup, or the cable re-presented. Once fixed we get a live recovery shell + dmesg.
3. Fix the marker rc bug: `umount` is not an init keyword (cosmetic; use a different
   cleanup or drop it).

The kernel itself — five vendored drivers, extracted touch firmware, correct panel, our
own DTB, built with the period-correct aarch64-linux-android-4.9 — is sound.

## Debugging refinements: adb-in-recovery is electrically hard; display is a pinctrl lead

Two sub-problems remain on the (now booting) kernel:

**adb for debugging — harder than expected, and not essential.** The tablet's USB port is a
full-size **Type-A receptacle wired as a host** (it sources VBUS). Making it enumerate as a
*device* to a PC is not a pure software switch: our kernel's `swmode device` reconfigures the
gadget (`android_usb ready`, `cfg 1 speeds` seen in the log) but nothing enumerates on the
Mac, consistent with a host-port VBUS/topology conflict rather than a driver bug. A
diagnostic ramdisk (embedded busybox + `kernel-project/recovery-tools/usbup.sh`, logging via
/dev/kmsg, applying the `swmode idle`->`device` fix that clears the on-init host_mode) was
built and booted, but the 64KB MTK RAM console wraps under battery-thread spam before the
markers can be read back, so this channel is unreliable too. Conclusion: getting a debug
shell needs a real UART, which the enclosed device does not expose. Not worth more cycles.

**The display (green screen) — a pinctrl lead, and the user's eyes are the feedback loop.**
The boot log shows `pinctrl core: Error applying setting, reverse things back` for
`panel@0`'s `pinctrl-0` = the `dpi_pins_default` group (DTB phandle 0x59). That group has 22
DPI pinmux entries; one is anomalous (`0x2`, versus the well-formed `0xNN0M` of the rest).
The panel backlight is on (screen lit green) but the UI never appears, consistent with the
DPI data/control pin group not fully applying. Because "green vs. recovery text" is visible
to the user, the panel can be iterated without adb.

### Status summary

- **Kernel: boots and runs** on the real device (eebbk 4.4.22 + our drivers + correct panel,
  built with aarch64-linux-android-4.9). GSL touch inits, userspace init runs.
- **Display: green** — DPI pinctrl group apply fails; top lead for the next iteration.
- **adb debug shell: blocked** by the host-port USB electrical constraint + no UART.
- Everything else (root, Magisk 25.2, power key, NTFS, debloat, all vendored drivers) is
  done and working on the stock kernel.

---

## Session: the green screen is NOT the panel (and three retracted claims)

Method note: every claim below was settled by comparing against the **stock kernel** —
either its running behaviour over SSH, its saved early dmesg, or its binary. Several
hypotheses that sounded convincing died the moment they were checked that way. Where the
old text above contradicts this section, this section wins.

### Retractions

1. **"The DPI pinctrl failure causes the green screen."** WRONG. The stock kernel prints
   the identical three lines and displays perfectly:
   ```
   mediatek-mt8167-pinctrl 1000b000.pinctrl: Fail configure pin 35, param 9, arg 2
   mediatek-mt8167-pinctrl 1000b000.pinctrl: pin_config_group_set op failed for group 35
   kd070d5450nha6_rgb_dpi panel@0: Error applying setting, reverse things back
   ```
   (`/data/local/early_dmesg.txt`, saved by `post-fs-data.d/early_dmesg.sh`.) It is noise.
   The DTB patch built to remove panel@0's pinctrl was pointless and was never flashed.

2. **"adb/USB is electrically blocked — the port is wired as host."** Overstated. The live
   DT says `mode = <2>` (MUSB_PERIPHERAL) and the node has real `iddig_gpio` (pio 41) and
   `drvvbus_gpio` (pio 68) with pinctrl states `drvvbus_low`/`drvvbus_high`. The port has
   ID detection and software control over VBUS sourcing. `iddig_state=0` in dmesg means it
   is *currently* host, not permanently strapped that way. Untested, but not "blocked".

3. **"The gc5024 camera driver may be grabbing a DPI pin."** WRONG. Stock emits the exact
   same four `gpio_to_desc` warnings — `cam0_rst:-2`, `invalid GPIO -2`, `Unable to request
   GPIO_CAM0_RST`. Identical. Not our bug.

### The panel driver is provably correct

`lcm_get_params` was extracted from the **stock kernel binary** (find the
`kd070d5450nha6_rgb_dpi` string, find the 8-byte pointer to it = the `LCM_DRIVER` struct,
follow +16 = `get_params`, disassemble) and field offsets were resolved by compiling
`offsetof()` against this tree's `lcm_drv.h`. `sizeof(LCM_PARAMS)` is 1032 in both, matching
stock's `memset` size — same layout.

| field | stock | ours |
|---|---|---|
| type / width / height | 1 / 1024 / 600 | LCM_TYPE_DPI / 1024 / 600 |
| PLL_CLOCK / ssc_disable | 51 / 1 | 51 / 1 |
| hsync pw,bp,fp | 48,112,160 | 48,112,160 |
| vsync pw,bp,fp | 10,13,12 | 10,13,12 |
| dpi.format | 1 | RGB666 = 1 |
| dpi.rgb_order | 0 | RGB = 0 |
| 4x polarity | 0 | RISING = 0 |
| io_driving_current | 1 | 8MA = 1 |

Every field matches. **The panel replacement is correct and is not the bug.**

### The display path works — proved with the Tux logo

The vendor config has `# CONFIG_VT is not set`, so `console=tty0` (already on the stock
cmdline) went nowhere and `CONFIG_LOGO=y` never drew, because `fb_show_logo()` is driven by
fbcon. Turning on VT+fbcon (`config/diag-fbcon.config`) made the kernel draw Tux with **no
userspace involved**.

Result on hardware: **Tux rendered correctly, then the screen went green a split second
later, and no console text was ever visible.**

That means panel power, DPI timings, RGB666 format, clocking and the DISP pipeline are all
working at framebuffer-registration time. The display is configured *correctly* and then
something breaks it. Since the framebuffer content path demonstrably works, what breaks is
most likely the **scanout/overlay configuration**, not the buffer. Green is therefore not
"the display never came up" — it is a regression from a known-good state, very early, in
kernel context.

Ruled out as the trigger by timing ("split second", long before userspace) and by
comparison: regulator late-cleanup (`regulator_init_complete`, late_initcall_sync) — stock
disables the same two regulators `vmc` and `vmch` and nothing else.

### Booting Android from the recovery slot cannot work

LK sets the boot mode, and the kernel reports it:

```
stock, normal boot (p9)  : g_platform_boot_mode = 0   (NORMAL_BOOT)
ours, recovery slot (p10): g_platform_boot_mode = 2   (RECOVERY_BOOT)
```

So Android's init and Magisk behave as recovery, and the Android ramdisk has no recovery to
run — it stalls after `magiskinit`. This is structural; no image-side fix. **Test kernels
in p10 must be paired with the stock recovery ramdisk.**

### MTK blob names: ROOTFS vs RECOVERY

The boot partition's ramdisk blob is named `ROOTFS`; the recovery partition's is `RECOVERY`
(the 32-byte name in the MTK 512-byte header). Flashing a `ROOTFS`-named ramdisk into p10
means **LK loads the kernel but not the ramdisk** — the kernel then falls through to
`root=/dev/ram` and panics:

```
VFS: Cannot open root device "ram" or unknown-block(1,0): error -6
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(1,0)
```

`mkboot.py --ramdisk-name` handles this. This cost several boot cycles before it was found.

### Debug channel: last_kmsg actually works

`/proc/last_kmsg` survives a full AC-removal power cycle (the RAM console at 0x44400000
retains across the brief power loss), so after any failed boot: power off, boot normally,
read it. Confirmed repeatedly — it is how the VFS panic and the 120-second live-kernel run
were both diagnosed. `integrate.sh` now demotes the `batt_temperature_table` dump from
CRTI to FULL because those ~500 lines wrapped the 64K buffer before 0.5s and destroyed the
entire early boot every time.

### Reproducibility hole, closed

The AOSP `aarch64-linux-android-4.9` toolchain — the only compiler that produces a bootable
kernel, since GCC 7.5 miscompiles this tree's early boot — had been installed in a `--rm`
container and was **gone**. It is also gone from the prebuilt repo's default branch
("Remove aarch64-linux-android gcc-4.9 libs and includes"); `android10-release` still has
it. It now lives in the persistent `maic-toolchain` Docker volume, with `build-m49.sh`
scripting the whole build (and probing `-Wno-error=` flags against the *4.9* cross compiler,
not the container's native gcc).

### Tools added

- **`mkboot.py`** — swaps only the kernel of an existing boot image, preserving header,
  cmdline, load addresses and ramdisk byte-for-byte. Validated by round-tripping p9 to an
  **identical md5** (`4c65df18406167aba3bf4b1e33565cfd`). Verifies gzip, arm64 magic, FDT
  magic and DTB totalsize before writing, and re-reads the result to prove the ramdisk
  survived.
- **`build-m49.sh`** — GCC 4.9 build via the emulated amd64 image + `maic-toolchain` volume.
- **`config/diag-fbcon.config`** — the on-screen kernel console described above.
- `backups/boot_magisk_p9.img` — verified byte-identical to the device (gitignored).

### Safety notes

- Test images go to **p10 (recovery)**; p9 is never touched, so a failed boot costs nothing.
- Do **not** read DISP registers via `/sys/kernel/debug/dispsys` `regr:` — reading a block
  whose clock is gated reboots the device (verified the hard way).
- `recovery-tools/recovery-wrap.sh` causes a bootloop. Do not use it. (Left uncommitted.)

### Offline session: four more display hypotheses retired, zero boot cycles

With the device unavailable, these were killed by reading code and the stock binary rather
than by flashing. Recorded so they are never re-tried:

| hypothesis | verdict | evidence |
|---|---|---|
| Idle manager switches the DPI panel to cmd mode after 500ms | DEAD | the whole block in `primary_display.c` is inside `#if 0`; the live `primary_display_idlemgr_enter_idle()` is an empty stub. It also guarded on `!primary_display_is_video_mode()`, so it never applied to a DPI panel. |
| `_disp_primary_path_idle_detect_thread` (0.5s timer) | DEAD | only created under `#ifdef MTK_DISP_IDLE_LP`, and `disp_drv_platform.h:75` has `/* #define MTK_DISP_IDLE_LP */` commented out. Also gated on `is_hwc_update_frame`, which is `static int` (=0) and only set by Android's HWC — never in recovery. |
| OVL background colour painting the screen green | DEAD | `gOVLBackground` is an uninitialised global (BSS = 0 = black), identical in our tree and the Lenovo tree. |
| DPI background configured 0x0 because the LCM never sets `bg_width`/`bg_height` | DEAD | offsets 264/268; **stock does not write them either** (its only stores are at 0, 24, 28, 240, 248, 256, 260, 288-312, 444). Both are 0. |

Also verified identical and therefore not the cause: `ddp_dpi.c` is byte-for-byte the same in
our tree and the Lenovo tree; the `ddp_gamma.c`/`ddp_dither.c` differences are entirely
`#if defined(CONFIG_MACH_MT67xx)` blocks for other SoCs.

**Emulation is not an option.** QEMU has no MT8167 machine model. A real attempt
(`qemu-system-aarch64 -M virt -cpu cortex-a53 -kernel Image`) produced zero output in 45s,
as expected: our `earlycon` is `uart8250` at `0x11005000`, an address that does not exist on
`virt`, and the config has no PL011 driver. Writing an MT8167 model would be a months-long
project, and the bug lives *inside* the peripherals a stub model would not implement.

### Reference values for the instrumented boot

Captured from the RUNNING STOCK kernel (`/sys/class/graphics/fb0/`):

```
bits_per_pixel = 32     stride = 4096      virtual_size = 1024,1824
modes = U:1024x600p-0   pan = 0,1200       rotate = 0
```

`virtual_size` 1824 = ALIGN(600,32) x 3 = 608 x 3 and stride 4096 = ALIGN(1024,32) x 4,
which confirms `MTK_FB_ALIGNMENT == 32`.

So the instrumented kernel (`patches/diag-display-instrumentation.patch`) should print:

```
MAIC set_par: bpp=32 xres=1024 yres=600 xvirt=1024 pitch=1024 line_len=4096 ...
```

Anything else is the bug. And `MAIC dpi_stop` appearing AFTER the logo renders would catch
the green screen in the act — that is the single most diagnostic line to look for.

## Leading hypothesis: the LK-inherited display path is never clock-referenced

Found by comparing our built kernel against the stock binary (agent analysis), then verified
by hand in the source. This is the best explanation yet for "renders correctly, then goes
uniformly green a split second later".

`MTK_NO_DISP_IN_LK` is not defined (`videox/disp_drv_platform.h:102`), so at
`videox/primary_display.c:5423`:

```c
#ifndef MTK_NO_DISP_IN_LK
	if (_is_decouple_mode(pgc->session_mode))
#endif
		dpmgr_path_start(pgc->dpmgr_handle, CMDQ_DISABLE);
```

We run in DIRECT_LINK mode, so the condition is false and **`dpmgr_path_start()` is
skipped**. `dpmgr_path_init()` is commented out at `:5335` and `:5337`. `path_top_clock_on()`
(→ `mtk_smi_larb_get()`, `ddp_path.c:1022`) is reachable only from `dpmgr_path_init`,
`dpmgr_path_power_on` (resume only) and `dpmgr_path_idle_on` (dead).

**Net: at boot the kernel holds zero clock references on OVL/RDMA/COLOR/DPI0/SMI.** The path
runs purely on LK's programming with Linux `enable_count == 0` — and
`late_initcall_sync(clk_disable_unused)` (`drivers/clk/clk.c:274`) disables every unreferenced
clock. There is no `CLK_IGNORE_UNUSED` or `CLK_IS_CRITICAL` anywhere in
`drivers/clk/mediatek/*8167*`, and `CONFIG_COMMON_CLK_MT8167=y`.

Timing corroborates it: panel/DPI pinctrl at **1.358892**, and the `late_initcall_sync`
sibling `regulator_init_complete` at **1.716548** — a **0.36 s** gap, matching the observed
"split second".

One-word test: append **`clk_ignore_unused`** to the cmdline (`clk.c:242` `__setup`).
If the green disappears, confirmed; the real fix is then to make the display path claim its
clocks instead of inheriting them.

Unproven part, labelled as such: *why stock survives*. Stock builds proprietary
`CONFIG_MTK_M4U` (stock-only strings `m4u_get_larbdev`, `MTK_M4U_ioctl`) whose larb handling
plausibly holds the SMI/MM clocks, whereas we build `CONFIG_MTK_PSEUDO_M4U` + generic
`CONFIG_MTK_IOMMU`, so `m4u_config_port()` at `primary_display.c:5522-5540` is not compiled
at all. Inference, not evidence.

### Why every log so far had zero display lines

`DISPMSG`/`DISPCHECK`/`DDPMSG` are **not** `pr_debug` — that reading came from a dead `#if 0`
branch. The live definitions (`videox/disp_drv_log.h:82-93`, `dispsys/ddp_log.h` `#else`) are
`pr_err` **gated on `g_mobilelog`**, which is declared at `videox/debug.c:132` with no
initialiser (= 0). `dbg_log_level` was the wrong knob. Setting `g_mobilelog = 1` lights up
~749 call sites. Only `DISPERR` is unconditional (grep anchor `HGC:` in our build,
`ERROR:` in stock — a vendor edit at `disp_drv_log.h:152`).

### MTK LK truncates the boot-image cmdline at 99 bytes

LK copies the header cmdline through `snprintf(buf, CMDLINE_TMP_CONCAT_SIZE=100, ...)` and
then appends its OWN arguments after ours. Linux 4.4 `parse_args` is last-wins, so **LK beats
us on any key it also sets** (`printk.disable_uart`, `boot_reason`, `androidboot.*`), and
editing the DTB's `/chosen/bootargs` is useless because LK overwrites it. `mkboot.py
--cmdline-append` now refuses to build past 99 bytes rather than let it truncate silently.
For anything longer, use `CONFIG_CMDLINE_EXTEND=y` + `CONFIG_CMDLINE` (verified backported in
this tree at `drivers/of/fdt.c:963-1019`).

### Tooling bugs found by review (both could have cost a wasted evening)

- **`build-m49.sh` defaulted to `OUT=out_m49`** — the stale pass with `CONFIG_MTK_COMBO`
  unset (no WiFi/BT, 67 config lines adrift). It would have silently built the wrong kernel
  and reported success. Now defaults to `out_m49w`, and refuses to run `olddefconfig` when no
  `.config` exists (which otherwise writes a generic arm64 config, builds an Image, and
  reports success for a kernel containing none of our drivers).
- **`mkboot.py` accepted a truncated `Image.gz`** — `decompressobj.decompress()` returns
  partial output without raising, `unused_data` stays empty, and the arm64 magic at 0x38 is
  near the start so it still matches. An unbootable kernel passed every check. Now guarded
  with `o.eof`, verified to fire on a deliberately truncated file. Also added a `second_size`
  guard. The p9 round-trip is still byte-identical after both changes.

## Completeness audit vs the stock kernel

Stock has no `.config` on the device, so its feature set was reconstructed three ways and
cross-checked: (1) decoding stock's **kallsyms table** out of the binary (42,709 text symbols;
token table at file 0xC66CC0, count at 0xBDF000), (2) the `__FILE__` paths embedded in both
images, giving a file-level compiled-in diff (612 vs 613 files), and (3) DT `compatible`
strings present in each image's .rodata. Ground-truthed against BOOTPROF probe lines in
`stock_dmesg.txt`. Both kernels are `CONFIG_MODULES=n`.

Our DTB is byte-identical to stock's, so the device tree is not a variable — only driver
coverage is.

### DT coverage: 186 nodes

| bucket | count |
|---|---|
| driver in both stock and ours | 140 |
| driver in **neither** (dead vendor boilerplate — do not chase) | 41 |
| **stock has it, we do not** | **2** |
| we have it, stock does not | 3 |

The only two real DT gaps:

- **`mediatek,mt8167-usb11`** — the source is in our tree
  (`drivers/misc/mediatek/usb11/mt8167/musbfsh_core.c`) but `CONFIG_MTK_USBFSH` is unset.
  Stock probes `musbfsh-hdrc` and registers USB bus 2 ("hub 2-0:1.0: 1 port detected").
  ~110 symbols missing. Anything on the USB1.1 port is dead for us.
- **`emdoor,synaptics_dsp`** — board-custom char device with its own IRQ and
  `dsp_rst`/`dsp_pwr`/`led_pwr` pinctrl. **No source exists anywhere.** Function unknown.

### Things we build that stock does not — and the hardware is not there

- **`nau8540`** — stock has no nau8540 at all; ours NAKs (`Failed to read device id ... -6`).
- **`sym827`** — stock has none. Ours NAKs. The DT declares it `regulator-always-on` for
  `vproc`, so a **failing** always-on supply driver is worse than no driver. Combined with
  the latent `regulator_unregister(ERR_PTR)` panic and the GPIO-34 (a live DPI pin) leak,
  `CONFIG_REGULATOR_SYM827=n` is the right answer.
- **The entire accelerometer subsystem** — stock has NO `acc_driver_add`, no `MC3XXX*`, no
  `STK8BAXX*`. The hardware appears not to be populated. The stk8baxx porting work was spent
  on a chip this board does not have.

### Real functional gaps, ranked

| gap | evidence | severity |
|---|---|---|
| **ad82584f never bound to the sound card** — stock's `2ND EXT Codec` link has `.codec_name = "ad82584f.1-0031"`; ours is still `snd-soc-dummy`, so `ad82584f_init()` never runs (stock spends 471 ms there at boot) | stock rodata `ad82584f.1-0031`; stock log `ad82584f <-> 2ND I2S mapping ok` vs ours `snd-soc-dummy-dai <-> 2ND I2S` | HIGH — no speaker audio |
| **Missing mixer controls** `Ext Spk Amp Switch` / `Ext HP Amp Switch` + `External I2S out/in` DAPM widgets, which the Android HAL sets **by name** | stock-only syms `mt8167_evb_ext_spk_amp_get/put`, `ext_spk_amp_turn_on/off` | HIGH — audio routing |
| **Touchscreen**: stock binds `gslx68x` (3 clean `gsl_load_fw` passes); our tree only has `gslX680`, which NAKs at 0x40 before firmware is ever touched | ours `Dma I2C Write Error: 0x00E0 ... -6`, `reset_chip fail!` | HIGH |
| **GPU DDK revision**: stock `1.8@4490469`, ours `1.8@4333936` (`gpu_rgx/Makefile:18-20` hardcodes `m1.8ED4333936/`). The FW-vs-KM *build options* check returns `PVRSRV_ERROR_BUILD_OPTIONS_MISMATCH` unconditionally on mismatch | `[drm] Initialized pvr 1.8.4333936` | HIGH (inferred) — likely cause of a non-composited Android UI |
| `CONFIG_MTK_DUAL_INPUT_CHARGER_SUPPORT` off — stock builds the full DISO path, we ship stubs | stock-only `diso_*` symbols | HIGH **if** the tablet has a DC barrel jack |
| `CONFIG_I2C_CHARDEV` off — no `/dev/i2c-N`; MTK HALs and factory tools use it | stock compiles `drivers/i2c/i2c-dev.c` | MEDIUM |
| Camera sensor list narrower: missing `GC0310`, `GC2356`, `GC2365`, `SP0A09` (and note GC0312 != GC0310) | `*SensorInit` symbol diff | MEDIUM |

Verified as NOT gaps (parity confirmed): the whole MTK connectivity stack, GPU services core,
M4U/SMI/IOMMU, video codec, thermal, battery/PMIC/auxadc, MMC/NAND, display/MTKFB/DSI/DPI/
AAL/CMDQ, accdet, PMIC keys, AEE/ram_console/pstore, watchdog, every USB class driver,
HDMI EXTD path, cpufreq, PTPOD/EEM.

**WiFi/BT is complete**, symbol-for-symbol: wmt 391 vs stock 380, stp 260 vs 263,
mtk_wcn 207 vs 207, consys 66 vs 66, btif 146 vs 144, wlan gen2 313 vs 308. The only
differences are inlining artefacts, and we have *extra* WAPI. Nothing missing.

### CONFIG_VT is ours, not stock's

Stock has **zero** console layer — no `fbcon_init`, no `do_take_over_console`, no
`logo_linux_clut224`, no `drivers/tty/vt/vt.c`. `CONFIG_VT=y` appears only in `out_m49w`
because this investigation added it; `maic_defconfig:288` and every other build dir have it
off. fbcon drawing into the same buffer MTKFB/OVL owns is a known source of colour garbage,
so it must not stay in any non-diagnostic build.

It is deliberately kept in **image A only**, because the Tux logo is the one visual
success/failure indicator available in recovery, and the green screen predates fbcon (it was
already present on `out_m49`), so it cannot be the root cause. **Image B has VT off** to keep
the diagnostic run free of that confound.

## Drivers removed (each verified absent from stock AND failing to probe here)

Removal criterion: the driver must be (a) absent from the stock kernel binary, and (b)
observably failing on this hardware. Both were required before deleting anything.

| removed | stock binary | our boot log |
|---|---|---|
| `CONFIG_REGULATOR_SYM827` | `sym827` / `SYM827`: **0 hits** | `Failed to read SYM827_REG_ID_1 reg` / `Failed to initialize regulator: -6` |
| `CONFIG_SND_SOC_NAU8540` | `nau8540` / `NAU85L40`: **0 hits** | `nau8540 1-001c: Failed to read device id from the NAU85L40: -6` |
| `CONFIG_MTK_STK8BAXX_NEW` | `STK8BAXX`: **0**, `acc_driver_add`: **0**, `ACCELEROMETER`: **0** | `acc real driver init fail` |
| `CONFIG_MTK_MC3433` | `MC3XXX`: **0** | would otherwise claim the gsensor node |

One near-miss worth recording: a naive `grep gsensor` on the stock binary returns 5 hits,
which looks like accelerometer support. They are `debug_imgsensor` and `get_imgsensor_id` --
substring matches on **imgsensor** (the camera). The decisive checks are `ACCELEROMETER`,
`acc_probe` and `STK8BAXX`, all zero. **Stock has no accelerometer driver at all**; the chip
is not populated on this board.

`sym827` was the most valuable removal: beyond being dead weight, the DT declares it
`regulator-always-on` for `vproc`, so a *failing* driver is worse than none; it carries a
latent `regulator_unregister(ERR_PTR)` panic in PID 1 (unreachable only while the chip NAKs);
and it leaks **GPIO 34, a live DPI data pin**, via `gpio_request()` in
`of_get_sym827_platform_data()` with no `gpio_free` on any path. MediaTek's pinctrl
`.gpio_request_enable` physically re-muxes the pin to GPIO mode, so that request is not
harmless. Vproc is actually supplied by the MT6392 PMIC (`proc-supply = <&mt6392 buck_vproc>`
on all four CPU nodes).

Result: all four gone from `System.map` (0 symbols each), Image 16,170,664 -> 15,970,312
bytes (-200 KB).

## adb over USB in recovery: why it never worked

Not a cable or VBUS problem, which is what was chased before. From the stock recovery
ramdisk (`backups/recovery_stock.img`):

```
init.rc:101  service adbd /sbin/adbd --root_seclabel=u:r:su:s0 --device_banner=recovery
init.rc:102      disabled
init.rc:107  on property:ro.debuggable=1
init.rc:108-113      write /sys/class/android_usb/android0/{enable 0,idVendor 0E8D,
                     idProduct 201C,f_ffs/aliases adb,functions adb,enable 1}
init.rc:114      start adbd
```

and `default.prop` has `ro.debuggable=0` (plus `ro.adb.secure=1`). `sbin/adbd` **is
present** (1,099,352 bytes) but the service is declared `disabled` and the only trigger that
starts it never fires. No cable would ever have helped.

What we already have on the kernel side, which stock does NOT:

```
CONFIG_USB_G_ANDROID=y            android_usb gadget
CONFIG_USB_F_FS=y                 functionfs (what adb binds)
CONFIG_MTK_MUSB_SW_WITCH_MODE=y   -> /sys/devices/platform/mt_usb/swmode
                                     accepts "device" -> mt_usb20_sw_connect()
```

Stock's `mt_usb` exposes only `cmode` and `saving`; ours would also expose `swmode`, the
software OTG role switch. Note `cmode` is **cable_mode** (CHRG_ONLY=0 / NORMAL=1 /
HOST_ONLY=2), not a host/device switch -- an earlier misreading.

Remaining unknowns before attempting this: the ramdisk must be repacked with correct
root ownership/modes (it was extracted as a non-root macOS user), and a previous ramdisk
modification (`recovery-tools/recovery-wrap.sh`) **bootlooped the device**, so the risk is
real and being assessed separately before anything is tried.

## Why `recovery-wrap.sh` bootlooped (and what it means for ramdisk edits)

Worth stating precisely, because the wrong lesson was drawn from it for a long time.

The wrapper installed itself **as `/sbin/recovery`** — the binary named by `init.rc:98`
(`service recovery /sbin/recovery`). That process is the **only** thing on the device that
reads and clears the bootloader control block in `para`/p11. Confirmed on both sides: LK
contains `mboot_recovery_load_misc` and the literal `boot-recovery`; `sbin/recovery` contains
`boot-recovery`, `%s/by-name/para` and `/cache/recovery/command`, and `etc/recovery.fstab`
maps `by-name/para -> /misc`.

Because the wrapper never let the real recovery run, the BCB was never cleared, so LK
re-entered recovery on every boot. Three independent silent failures guaranteed it:
`#!/sbin/busybox sh` (there is **no** `/sbin/busybox` — `sbin/` holds exactly `adbd`,
`healthd`, `multi_init`, `recovery`, `ueventd`, `watchdogd`); a dependency on a
`/sbin/recovery.bin` that only exists if the packaging renamed the original; and a final
`while true; do ... sleep 1; done` that never execs and never exits, permanently occupying
the service slot.

Note the `recovery` service is **not** `critical` (only `ueventd` and `healthd` are), so this
was never an init crash-loop — it was purely the un-cleared BCB.

**The lesson is narrow:** the bootloop was NOT caused by "editing the ramdisk". It was caused
by **replacing the recovery binary**. Data-only edits to `default.prop` or an added `service`
block are a different risk class. The rule: **never put anything on the `/sbin/recovery`
path; add services, never wrap the recovery binary.** `recovery-tools/recovery-wrap.sh`
should be deleted rather than fixed.

Related discipline that makes every test cost exactly one power cycle: **enter recovery only
via the LK boot menu** (unplug AC, hold VOLUME UP, replug). Never `adb reboot recovery` or
Magisk's reboot-to-recovery — those set the BCB, and a set BCB is what turns a bad recovery
image into a loop that needs mtkclient.

## Corrections to the USB model (our kernel != stock)

Two things previously recorded here were read off the STOCK kernel and are false for ours:

- **`cmode` does not exist in our build.** There is no `DEVICE_ATTR(cmode, ...)` anywhere in
  our `drivers/misc/mediatek/usb20/`; `cable_mode` is just a static defaulting to
  `CABLE_MODE_NORMAL` (`usb20.c:82`). So `init.recovery.mt8167.rc`'s `write .../cmode 2`
  silently no-ops on our kernel. (And `cmode` was only ever *cable* mode — CHRG_ONLY /
  NORMAL / HOST_ONLY — never a host/device role switch.)
- **Our kernel does not source VBUS.** `mt_usb_init_drvvbus()` selects the `drvvbus_init`
  pinctrl state, which is `output-low`. The only code that raises it is
  `musb_id_pin_work`/`musb_id_pin_sw_work(true)`, and with `CONFIG_MTK_MUSB_SW_WITCH_MODE=y`
  the iddig IRQ body (`usb20_host.c:523-536`) is compiled out, so that work is never
  scheduled and `musb->is_host` stays `false` (`usb20.c:1220`). The ~4688 mV measured
  earlier was the **stock** kernel, where that path IS compiled in.

Consequence: the "Type-A port sources VBUS so device mode is blocked" story does not apply to
our kernel. A plain **USB-A-male -> USB-C-male** cable should work, since the Mac's C port
sees Rd, supplies VBUS and acts as host, and D+/D- pass straight through.

The one genuine unknown left is whether the Mac's VBUS physically reaches the SoC/PMIC sense
node through the host port's load switch. If that switch is unidirectional,
`musb_hal_is_vbus_exist()` -> `upmu_is_chr_det()` stays false and the gadget never comes up.
`musb_force_on=1` (`musb_core.c:2714`, module `musb_hdrc`) bypasses exactly that check, so it
is testable **with the stock ramdisk untouched**.

Also note `mt_usb_connect()` is a no-op for us — its whole body is inside
`#ifndef CONFIG_MTK_MUSB_SW_WITCH_MODE` (`usb20.c:449-461`) — so the only surviving way to
queue `connection_work` is `mt_usb20_sw_connect()`, reachable from
`echo device > /sys/devices/platform/mt_usb/swmode`.

## pstore console enlarged 64K -> 256K

`/proc/last_kmsg` is served by **pstore**, not MTK's own ram console: `mtk_ram_console.c`
wraps `register_console()` in `#ifndef CONFIG_PSTORE`, and `CONFIG_PSTORE=y`. Every capture
we took was exactly 65598 bytes = the 64K zone minus its 12-byte header plus 74 bytes of MTK
header lines — i.e. it wrapped every time, destroying early boot.

`CONFIG_PSTORE_CONSOLE_SIZE` is now `0x40000`. That is the **largest safe value**, because
`fs/pstore/ram.c:669` charges the console twice:

```c
dump_mem_sz = cxt->size - cxt->console_size * 2 - cxt->ftrace_size - cxt->pmsg_size;
```

(this tree allocates both `cprz` and `bprz`). Against the 896K already reserved at
0x44410000, 0x40000 still leaves 79 crash-dump records; 0x80000 would underflow `dump_mem_sz`
and the ramoops probe would fail, leaving **no pstore at all**. No DTB change is needed — the
space is already reserved, and the region ends exactly at minirdump's base (0x44410000 +
0xe0000 = 0x444f0000).

## CONSENSUS on the green screen (read this before re-investigating)

Written after an adversarial review that disproved two claims made earlier in this file.
Where earlier sections conflict with this one, **this one wins**.

### Agreed root cause (two independent analyses converge)

**The display path never claims its resources.** In DIRECT_LINK mode the kernel inherits a
running display from LK and takes **zero** references on it:

- `dpmgr_path_start()` runs only `if (_is_decouple_mode(...))` (`primary_display.c:5423`) — skipped
- `dpmgr_path_init()` is commented out (`primary_display.c:5335`, `:5337`)
- `disp_probe` (`ddp_drv.c:542`) does `devm_clk_get` in a loop at `:620` and **never**
  `clk_prepare_enable`
- therefore `path_top_clock_on()` / `mtk_smi_larb_get()` are never reached at boot

Two `late_initcall`s then tear the path down. They are adjacent links in one chain and the
timing cannot separate them (291 us apart in `quiet_lastkmsg.txt`):

| order | what | effect |
|---|---|---|
| `late_initcall` #49 | `mtk_smi_init_late()` (`drivers/memory/mtk-smi.c:487-511`) does `pm_runtime_put_sync` on smi-common | drops the **last** ref on the DISP power domain -> `scpsys_power_off()`: bus protection, SRAM power-down, `clk_disable_unprepare(smi_mm)`, ISO assert, **RST_B hardware reset**, PWR_ON cleared |
| `late_initcall_sync` | `clk_disable_unused()` (`clk.c:274`) | disables the display gates, whose `enable_count` is 0 |

`mtk_smi_common_probe` (`:338-350`) even comments that its `get_sync` exists so *"the disp
power domain would [not] be turn off ... meanwhile disp hw are still access register, this
would cause system abnormal."*

**Both are fixed by the same change**: make the display path take a real reference once
(`path_top_clock_on()` / `mtk_smi_larb_get()`), which pins the genpd **and** the clocks.

### DISPROVEN — do not repeat these

- **"Stock survives because it builds proprietary `CONFIG_MTK_M4U`."** FALSE. Stock's own
  dmesg prints `PSEUDO M4Upseudo_probe, 2298, iommu_pgt_base 0xbbcd8000` — identical to ours
  down to the pgt base — and `pseudo_m4u_do_config_port` is in stock's kallsyms. Both kernels
  build `CONFIG_MTK_PSEUDO_M4U`. `m4u_get_larbdev`/`MTK_M4U_ioctl`/`m4u_config_port` are
  defined by `pseudo_m4u.c` and are in OUR System.map too; they were never stock-only.
- **"`clk_disable_unused` explains why stock is fine and we are not."** FALSE. Stock has the
  same DTB (the only diff is the 3-line `panel@0` pinctrl removal, which was never flashed),
  the same display source, and the same symbols. Stock holds zero references too and runs the
  same `clk_disable_unused` over the same gates.
- **`CLK_IGNORE_UNUSED` is not available as a driver-side fix**: `clk-gate-v1.c` / `clk-mtk-v1.c`
  / `clk-pll-v1.c` set it, but the Makefile gates them on `COMMON_CLK_MEDIATEK_V1`/`MT6799`
  and the built objects are `clk-gate.o`, `clk-mtk.o`, `clk-mt8167.o` — no `-v1`.
- **`MTKFB_UT`'s `0xFF00FF00` green fill** (`mtkfb.c:1840`) is dead code —
  `/* #define MTKFB_UT */` is commented out at `disp_drv_platform.h:120`.
- **DPI's own background is black**, not green: `ddp_dpi.c:416` writes `BG_COLOR = 0`.

### The reframe that matters

Stock does the *same* teardown. The difference is almost certainly **userspace**: on a normal
Android boot, SurfaceFlinger/HWC opens `fb0` within a frame or two and drives
`primary_display_resume` -> `dpmgr_path_power_on` -> `path_top_clock_on`, restoring power and
clocks before anyone sees it. Our kernel boots the **recovery** slot, where nothing ever
performs that repair, so the dead path stays on screen.

If that holds, the green screen is **not a regression we introduced**, and our kernel may
display correctly on a normal Android boot. Labelled inference, not proof — but it is the
only story consistent with every observation.

### Consequence for testing

`clk_ignore_unused` is **not a sound test on its own**: it parses in time (`__setup` at
`clk.c:242`, handled during `parse_args`) and prints `clk: Not disabling unused clocks` when
it takes, but it does **not** stop `mtk_smi_init_late()`, which fires earlier. There is no
cmdline escape for that path — `pd_ignore_unused` only guards `genpd_poweroff_unused()`, not
an explicit `put_sync`.

So: if green persists with `clk_ignore_unused`, that does **NOT** disprove the resource-
ownership theory. Check for the `clk: Not disabling unused clocks` line to confirm the flag
took, then read it as evidence for the genpd path rather than against the theory.

## Verified bug list (each confirmed on BOTH sides: our build AND stock's binary)

Method: symbol sizes from address deltas in `System.map`, plus strings present in one binary
and absent from the other. Every row below was re-checked by hand after an agent reported it,
because this project has produced several false leads from stale files and substring matches.

| issue | ours | stock | status |
|---|---|---|---|
| **Camera reset/power never asserted** | `mtkcam_gpio_init` was **8 bytes** (empty stub) | 408 bytes + `cam0_pnd1`, `cam0_rst1`, `Cannot find camera pinctrl` | **FIXED** -- now 408 bytes and those strings are present |
| `battery_shutdown()` does not stop the battery kthreads | **4 bytes** | has `failed to terminate battery related thread` | confirmed, unfixed |
| `musb_do_idle()` does register I/O in the timer callback instead of a workqueue | **716 bytes** | has `schedule work to do musb_do_idle` | confirmed, unfixed |
| `rtc-mt6397.c` is an older revision | 1 generic `regmap write/read error!!!` | **5** distinct `__func__`-prefixed variants | confirmed, unfixed |
| `CONFIG_MTK_MUSB_SW_WITCH_MODE` is ours-only | `mt_usb_connect`/`mt_usb_disconnect` are **4-byte stubs** | `swmode`: **0 hits** in stock | confirmed |
| eMMC CMD18 timeout | 1 event (3 lines) in **every** boot reaching 14 s | **0** | confirmed as observed; cause NOT established |

Two caveats recorded deliberately:

- **The eMMC timeout is not proven to be our bug.** All our logs are RECOVERY boots; stock's
  log is a NORMAL Android boot. The I/O workloads are not comparable and we have no stock
  recovery log. Do not "fix" this without a like-for-like capture.
- **`do_connection_work: 37 callbacks suppressed` appears 7x in stock and 0x in ours**, which
  corroborates that USB connection work never runs for us -- a direct consequence of
  `CONFIG_MTK_MUSB_SW_WITCH_MODE` stubbing `mt_usb_connect()`.

### The camera fix

`imgsensor/src/mt8167/camera_hw/Makefile` matched `CONFIG_ARCH_MTK_PROJECT="tb8167p3_64"`
against `findstring tb8167p` and forced `-DDEMO_BOARD_SUPPORT=1`, selecting
`kd_camera_hw.c`'s legacy-GPIO branch. That branch's `mtkcam_gpio_init()` is empty and its
`mtkcam_gpio_set()` drives `cam0_rst`/`cam0_pdn` through GPIO numbers the DT does not
provide -- both resolve to `-2`, so `gpio_direction_output()` returns `-EINVAL` and **reset is
never asserted**. No sensor can leave reset, which is more fundamental than the four missing
sensor drivers. Stock builds the `DEMO_BOARD_SUPPORT == 0` branch, which uses the eleven
pinctrl states the (identical) DT actually defines.

`ccflags-y` is per-Makefile and NOT inherited, so `kd_sensorlist.c` keeps
`DEMO_BOARD_SUPPORT=1` from `src/mt8167/Makefile` -- matching stock. Do not change that one.

### `smi_keep_disp`: a cmdline escape for the DISP power-domain teardown

`clk_ignore_unused` only blocks ONE of the two teardown paths. The other,
`mtk_smi_init_late()`'s `pm_runtime_put_sync()` on the DISP power domain
(`drivers/memory/mtk-smi.c`), runs at `late_initcall` -- strictly EARLIER -- and there is no
generic cmdline escape for it (`pd_ignore_unused` only guards `genpd_poweroff_unused()`, not
an explicit put).

Added `__setup("smi_keep_disp")`, **default off so behaviour is identical to stock**, which
skips that put and logs which branch it took. With both flags on the cmdline, both teardown
paths are blocked in a single boot, making the test decisive in either direction.

Noted while reading that function: it dereferences `larb->smi_common_dev` **before** the
`if (!larb)` NULL check. Latent, not triggered today.

## Diagnostic instrumentation (7 points) and what a good boot looks like

All logging uses `pr_err` deliberately: MTK's own display macros are either `pr_debug`
(compiled out) or gated on `g_mobilelog`, and `pr_err` survives to `/proc/last_kmsg` without
depending on `console_loglevel`.

| log line | fires when | meaning |
|---|---|---|
| `MAIC scpsys: power ON  domain '<n>'` | `scpsys_power_on` | a power domain comes up |
| `MAIC scpsys: power OFF domain '<n>'` | `scpsys_power_off` | **if `'disp'` appears, that is the green screen** |
| `MAIC smi: keeping DISP power domain` | `mtk_smi_init_late` | `smi_keep_disp` took effect |
| `MAIC smi: dropping DISP power domain ref now` | same | default/stock behaviour |
| `MAIC dpi_config: ...` | `ddp_dpi_config` | the timing/format actually programmed |
| `MAIC dpi_trigger: enabling DPI` | `ddp_dpi_trigger` | DPI output switched on |
| `MAIC dpi_stop: ... DPI OUTPUT DISABLED` | `ddp_dpi_stop` | DPI switched off |
| `MAIC set_par: bpp= xres= ... pitch= line_len=` | `mtkfb_set_par` | overlay reprogrammed |
| `MAIC pan: yoffset=` | `mtkfb_pan_display_impl` | framebuffer panned/scrolled |

**Expected-good values** (from the running stock kernel's `/sys/class/graphics/fb0/`):
`bpp=32 xres=1024 yres=600 xvirt=1024 pitch=1024 line_len=4096`.

### Wrong-file trap, recorded so it is not repeated

The DISP power domain on this SoC is driven by **`drivers/soc/mediatek/mtk-scpsys-mt8167.c`**
(`CONFIG_MTK_SCPSYS_MT8167=y`). The generic `drivers/soc/mediatek/mtk-scpsys.c` is the MT8173
variant and is **NOT compiled** (`CONFIG_MTK_SCPSYS_MT8173` is unset). Patching the generic
file builds cleanly and silently does nothing -- the only way this was caught was grepping
the built Image for the instrumentation's own strings. **Always verify a patch landed by
looking for its strings/symbols in the output, not by a successful build.**

### What a successful recovery boot should look like on screen

With `CONFIG_VT` + `CONFIG_FRAMEBUFFER_CONSOLE` on:

1. **Tux logo, top-left** at `register_framebuffer()` -- proves panel power, DPI timing,
   format and the DISP pipeline, with zero userspace involvement.
2. **Scrolling white kernel text** -- the live boot log, photographable. This is the only
   cable-free debug channel this device has.
3. **Stock recovery UI** drawing over it -- `/sbin/recovery` started and is rendering.

Partial outcomes are diagnostic in themselves: Tux + text but no recovery UI means the
display is fine and the failure is in userspace; Tux flashing then green means both teardown
paths were blocked and the theory is wrong; green with no Tux means the framebuffer never
rendered at all, which would be a different failure from every run so far.

## adb in recovery: the image, and what it does and does not give you

`mkboot.py --ramdisk` now supports swapping the ramdisk (it wraps a raw gzip in the 512-byte
MTK header and, critically, updates `ramdisk_size` at header offset 16 -- leaving that stale
would hand the kernel a wrong-length ramdisk and fail the same silent way the
ROOTFS/RECOVERY name bug did).

### The three edits, and why each

| file | change | why |
|---|---|---|
| `default.prop` | `ro.debuggable=0` -> `1` | the ONLY trigger for `start adbd` (`init.rc:107-114`); the service is declared `disabled` at `:102` |
| `init.rc:101` | drop `--root_seclabel=u:r:su:s0` | names SELinux type `su`, which is not in this sepolicy; if adbd were built with `ALLOW_ADBD_ROOT` it would `setcon()` an invalid context and `LOG(FATAL)` |
| `/adb_keys` (new, 0644 root:root) | the Mac's public key | this `adbd` contains `adb_auth_client.cpp` and `/adb_keys` but **not** `ro.adb.secure`, i.e. built WITHOUT `ALLOW_ADBD_NO_AUTH` -- auth is mandatory and `ro.adb.secure=0` would do nothing |

`/sbin/recovery` is byte-identical to stock (md5 `48e1ffd8e2c0e0ff8d7a320d381a13f2`,
1,529,144 bytes) -- verified as a hard gate, because replacing that binary is exactly what
bootlooped the device last time.

Repack detail worth keeping: Linux cannot represent symlink permission bits (`lstat()` always
reports 0777), so GNU cpio emits `0120777` for symlinks where stock's `mkbootfs` recorded
`0120644`/`0120750`. The headers were normalised afterwards so 153 unchanged entries are
byte-identical to stock including metadata. The new gzip is 11,676 bytes SMALLER than stock's,
so there is no size risk.

### What this will and will not do

**Will:** start `adbd`, configure the legacy android gadget (idVendor 0E8D, idProduct 201C,
`f_ffs/aliases adb`, `functions adb`), and accept the Mac's key without an authorisation
prompt (there is no UI in recovery to accept one).

**Will NOT give you `adb shell`.** There is no shell binary anywhere in that ramdisk -- `sbin/`
holds only `adbd`, `healthd`, `multi_init`, `recovery`, `ueventd`, `watchdogd` -- and adbd
execs `/system/bin/sh`, which is an empty mount point. `adb devices`, `adb pull` and
`adb push` should work; `adb shell` needs a static busybox added later.

**Unresolved, and only testable on hardware:** whether the Mac's VBUS reaches the SoC's sense
node through the host port's load switch. If it does not, `usb_cable_connected()` never
returns true and the gadget never comes up. `musb_force_on=1` bypasses exactly that check --
it is a `module_param_cb` on module `musb_hdrc`, so `musb_hdrc.musb_force_on=1` can be added
to the cmdline (budget permitting: 54/99 bytes used today).

Note also `mt_usb_connect()` and `mt_usb_disconnect()` are **4-byte stubs** in our build --
their bodies are inside `#ifndef CONFIG_MTK_MUSB_SW_WITCH_MODE` -- so the automatic
VBUS-driven connect path does not exist for us. The surviving trigger is
`echo device > /sys/devices/platform/mt_usb/swmode`, which needs userspace, or a kernel-side
call to the same work queue.

## GPU: DDK revision now matches the device userspace

Our tree shipped DDK revisions up to `m1.8ED4333936`, but the device's GPU userspace and
firmware are **newer**:

```
stock kernel              rogueddk 1.8@4490469
/vendor/lib/libsrv_um.so          1.8@4490469
our kernel (before)       rogueddk 1.8@4333936    <- OLDER than the userspace calling into it
```

That is the risky direction: the PowerVR bridge is unversioned across DDK revisions, so an
older kernel driver serving newer userspace can be missing entry points or disagree on struct
layouts, with no graceful degradation.

**It was fixable.** `m1.8ED4490469` is public in other MT8167 BSP trees whose GPU config is
identical to ours (`CONFIG_MTK_PLATFORM="mt8167"`, `CONFIG_MTK_GPU_VERSION="rgx clark 1.7ED"`).
Fetched 365 files / 6.6MB from `bigrammy/android_kernel_acer_b3-a40fhd` (Acer Iconia B3-A40,
also MT8167, Android 7.0 / Linux 4.4 — its `gpu_rgx` directory listing is exactly ours plus
that one extra revision). Structurally identical: same `generated/ hwdefs/ include/ kernel/
services/ Makefile` layout, 365 vs 364 files. Builds clean, and the Image now reports
`rogueddk 1.8@4490469`.

Watch out: `gpu_rgx/Makefile`'s version selector is a **no-op `ifeq`** -- both branches
hardcode the same path -- so the literal directory name in that file is the only thing that
picks a revision.

### What this does and does not guarantee

The **revision** mismatch was never fatal on its own: `PVRSRV_STRICT_COMPAT_CHECK` is not
defined, so `rgxinit.c`'s DDK-build check only logs `(WARN) Incompatible driver DDK build
version`. What IS fatal is a mismatch in the **build-options bitmask** from `rgx_options.h`
(`PVRSRV_ERROR_BUILD_OPTIONS_MISMATCH`, returned unconditionally) -- and that is independent
of the revision number. Matching revisions makes agreement far more likely, not certain.

Untestable in recovery, since nothing there uses the GPU. It only gets exercised on a full
Android boot.

### Methodology note (this is the second time)

I twice concluded a driver was unobtainable and was twice wrong. The vendored drivers
(ad82584f, sym827, stk8baxx, nau8540, gc5024) were found by GitHub **code** search in
seconds after being declared "nowhere public", and the GPU DDK was declared "not fixable
without vendor sources we cannot get" and turned out to be a sparse-checkout away:

    gh api -X GET search/code -f q='m1.8ED4490469'   -> 57 hits

**Search the code index before concluding something does not exist.**

## Touch fixed: an EXPECTED NAK was being treated as fatal

`reset_chip()` writes `0x88` to GSL register `0xE0` to halt the chip's internal DSP. The
chip NAKs that write **by design** as it stops its own I2C block. Our revision accumulated
the `-ENXIO` into `ret`:

```c
ret  = gsl_i2c_write_bytes(client, 0xe0, ...);   /* -ENXIO -- EXPECTED */
ret += gsl_i2c_write_bytes(client, 0xe4, ...);
ret += gsl_i2c_write_bytes(client, 0xbc, ...);
if (ret < 0) GSL_LOGE("reset_chip fail!\n");
return ret;                                       /* caller aborts */
```

so `init_chip()` aborted and `tpd_registration()` bailed with `Failed to init chip!` --
meaning `request_irq()` and the touch event thread **never ran at all**. Stock's `gslx68x` is
an older rev of the same Silead file whose `reset_chip()` is `void` and never checks: its
binary contains **zero** occurrences of `reset_chip fail`, `Failed to init chip` or
`Dma I2C Write Error`.

Tellingly the firmware upload already worked -- `gsl_load_fw` completes all 15,213 writes in
~9.7s, comparable to stock's 8.37s probe. Everything functioned except the one return check.

Fix: do not assign that one write's return to `ret`. `0xE4` and `0xBC` are still checked.

**Retraction:** an earlier note here suggested stock enables a touch power rail we were
missing, based on `g_vproc_en_gpio_number 488` / `g_vproc_vsel_gpio_number 487` in stock's
log. Those are **misnamed copy-paste variables inside stock's touch driver holding the touch
RST/INT GPIOs** -- 488-387 = GPIO101 (`rst-gpio`), 487-387 = GPIO100 (`int-gpio`). Nothing to
do with vproc, which is `sym827@60` with `vsel-gpio` = GPIO34. Our rail was never the problem:
`regulator_get(..., "vtouch")` -> `ldo_vgp1` @2.8V is enabled 190ms before the first I2C byte.

**Known unknown:** `mtk_gslX680.c:1507` requests `IRQF_TRIGGER_RISING` while the DT declares
the interrupt falling (`interrupts = <0x64 0x2>`). That path had never executed, so if the
chip now initialises but produces no events, this is the next one-line fix.

## Audio: the amp is now bound to the card

`mt8167_evb.c`'s `2ND EXT Codec` dai_link had `.codec_name = "snd-soc-dummy"`, so
`ad82584f_init()` -- which does the reset, the 134-register init and the **final unmute**
(reg 0x02) -- never ran, leaving the speakers silent. Stock binds `ad82584f.1-0031` /
`ad82584f`; its log shows `ad82584f <-> 2ND I2S mapping ok` where ours showed
`snd-soc-dummy-dai`. Now matched.

## The full-boot error audit, and the method that made it valid

With `loglevel=5` on the cmdline the capture finally spans **0.170s -> shutdown** in the 64K
ram console. (`console_loglevel` gates what reaches pstore -- `printk.c`'s
`if (level >= console_loglevel && !ignore_loglevel) return;` sits BEFORE the per-console loop,
and pstore is a registered console. So one cmdline flag controls capture volume; no rebuild,
no layout change.)

68 error/warning shapes. **Exactly two were ours**, and both are now fixed: the touch NAK,
and accelerometer-core noise (stock contains ZERO accelerometer strings, so
`CONFIG_CUSTOM_KERNEL_ACCELEROMETER` is now off -- the two chip drivers had already been
removed as unpopulated hardware).

**Seven looked new and were not**, and this is the important part:

```
cannot get reg-vgpu                     0.489s
failed to initialize dvfs info for cpu0 0.488s
cannot get module clock: smi-larb0      0.170s
cannot get module clock: mtcmos-dis     0.170s
[AUXADC_AP] find node failed            0.494s
blockio: fail to allocate               0.542s
ion_mtk_heap_create: error creating heap 0.252s
Unable to detect cache hierarchy        0.480s
```

All fire **before 0.590s, which is where stock's log begins** -- so they were invisible to
every log-vs-log comparison we had ever run, and looked unique to us. Checking the stock
BINARY settled it: every one of those strings is present in both kernels with identical
counts. `failed to initialize dvfs info for cpu0` was one step from being reported as a CPU
DVFS regression caused by removing sym827. It was never broken.

**Rule: log-vs-log comparison is only valid inside the overlapping time window. Outside it,
compare binaries.** That one discipline retired seven false leads in a single pass.

Everything else in the list is a recovery-boot artifact that stock recovery would produce
identically: all `PVR_K`/`rgx.fw.signed` failures (`/vendor` unmounted -- the firmware DOES
exist at `/vendor/firmware/rgx.fw.signed`), `init: cannot find /sbin/fuelgauged_static`,
`healthd: BatteryCurrentNowPath not found`, `[MT6620][nvram_read] failed`.

### Touch: CONFIRMED FIXED on hardware

The one-token change works. Boot `seq=8` (`test_ALL`, verified by 0 accelerometer strings):

```
reset_chip fail!     : 0     (was 1)
Failed to init chip  : 0     (was 1)
test_i2c error       : 0
mtk-tpd: tpd_fb_notifier_callback   (repeatedly -- driver alive)
1.596/1.643/1.700  Dma I2C Write Error: 0x00E0   <- still there, now correctly ignored
   ... 9.4 s of silence ...                      <- firmware downloading, zero errors
11.131             Dma I2C Write Error: 0x00E0
```

An independent decompile of stock's `tpd_i2c_probe` (VA 0xffffff80087d8e64) settles why stock
never cared:

```
bl init_chip(client)        ; return value DISCARDED
bl check_mem_data(client)   ; return value DISCARDED
```

The chip was healthy all along: `gsl_load_fw` completes every write, and `check_mem_data`
reads `0xb0 == 5a5a5a5a` (firmware loaded and running). Stock actually FAILS that check on
its first pass and retries. We were discarding a working touchscreen over one status code.

Second fix applied in the same area: `request_irq` used `IRQF_TRIGGER_RISING` while stock
passes `IRQF_TRIGGER_FALLING` and the DTB declares falling (`cap_touch@40: interrupts =
<0x64 0x2>`). **A trigger flag in `request_irq()` overrides the DT type**, so ours won and was
wrong. That path had never executed before, so the bug was unreachable until now.

**Do not port a different driver.** Our `mtk_gslX680.c` is byte-identical to the one in
`bigrammy/android_kernel_acer_b3-a40fhd` (a shipping MT8167 vendor kernel). `gslx68x` vs
`gslX680` is a naming difference within the same Silead family -- stock prints the identical
`Sileadinc gslX680 touch panel driver init` banner. Importing a `GSLX68X` variant would be a
regression.

**Why every log looked like total failure:** `GSL_DEBUG` was `0`, so `GSL_LOGD`/`GSL_LOGF`
compiled to nothing and only `GSL_LOGE` (pr_err) survived. We saw exclusively the errors and
none of the successful sequence. Set to 1 with the macros promoted from `pr_debug` to
`pr_info` for verification builds (44 debug strings now in the image, previously 0).

**Retraction:** an earlier entry blamed a missing touch power rail, citing
`g_vproc_en_gpio_number 488` / `g_vproc_vsel_gpio_number 487` in stock's log. Those are
misnamed variables inside stock's touch driver holding the touch **reset** and **interrupt**
GPIOs -- DTB `rst-gpio = <&pio 101>` -> 387+101 = 488, `int-gpio = <&pio 100>` -> 387+100 =
487. Our `vtouch` rail (`ldo_vgp1` @2.8V) was enabled 190 ms before the first I2C byte and was
never the problem.

### Touch: WORKING, with multi-touch (boot seq=9)

With the falling-edge IRQ fix and the driver's own logging enabled, real coordinates arrive:

```
report_data_handle: tp-gsl finger_num = 1
before: x[0] = 338, y[0] = 340, id[0] = 0
gsl_report_point 1
tpd_down id: 0, x:279, y:684
touch_event_handler, task running
report_data_handle: tp-gsl finger_num = 2        <- two fingers tracked simultaneously
before: x[0] = 332, y[0] = 341, id[0] = 0
before: x[1] = 1035, y[1] = 110, id[1] = 0
```

223 debug lines in one boot. The chip reports raw coordinates, the driver maps them into the
rotated 600x1024 space (`x:279, y:684`, both in range -- consistent with
`CONFIG_MTK_LCM_PHYSICAL_ROTATION=270` and `TPD_RES_X=600 / TPD_RES_Y=1024`), the event
thread runs, and `tpd_down` fires. Full path silicon -> input subsystem.

Two one-line changes got here from "Failed to init chip!":
1. do not accumulate the expected `0xE0` NAK into `reset_chip()`'s return
2. `IRQF_TRIGGER_FALLING` instead of `RISING`, matching stock and the DTB

**For a production build, revert the diagnostics:** `GSL_DEBUG` back to `0` and the
`GSL_LOGD`/`GSL_LOGF` macros back to `pr_debug`. 223 lines per touch session would flood the
64K ram console instantly.

## Complete change set

`patches/all-kernel-changes.patch` is regenerated from the live tree and covers all 12
modified files, with a header separating the fixes (keep) from the diagnostics (remove for
production). The kernel source itself lives in the `maic-kernel` Docker volume, not this
repo, so that patch plus `integrate.sh` and `config/maic_defconfig` are the authoritative
record.

Diagnostics currently in the build, to strip for production:
`smi_keep_disp` + power-domain logging, the `MAIC set_par/pan/dpi_*` markers, `g_mobilelog`,
`dbg_log_level`, and `GSL_DEBUG`. The two cmdline flags `clk_ignore_unused smi_keep_disp` are
NOT diagnostics -- they are the display fix, until the path is made to claim its own clocks.
