# ad82584f speaker amplifier — extracted init sequence

The `ad82584f` class-D amp (I2C `1-0031`) drives this device's speakers. **No public
driver source exists for it anywhere** — a GitHub search for `ad82584` returns zero
repositories, and it is absent from every MT8167 kernel tree and from mainline. That
made it the blocker for any kernel rebuild: no driver means no sound, which kills the
device's whole purpose.

The hard part of writing a driver for an undocumented chip is not the code, it is
knowing the register sequence. That is captured here, **taken off the working hardware**.

## How it was captured

The kernel has ftrace with I2C tracepoints. Forcing the in-kernel driver to re-probe
replays its entire initialisation, which the tracer records:

```sh
T=/sys/kernel/debug/tracing
echo 0 > $T/tracing_on; echo > $T/trace
echo 1 > $T/events/i2c/enable
echo 1 > $T/tracing_on
echo 1-0031 > /sys/bus/i2c/drivers/ad82584f/unbind
sleep 1
echo 1-0031 > /sys/bus/i2c/drivers/ad82584f/bind
sleep 2
echo 0 > $T/tracing_on
cat $T/trace > /data/local/tmp/i2c_trace.txt     # NOTE: cat, not cp - debugfs reports size 0
```

Trace lines look like `i2c_write: i2c-1 #0 a=031 f=0000 l=2 [00-04]`, meaning
register `0x00` = `0x04`.

## What is here

`ad82584f_init_sequence.txt` holds **1417 register writes covering 134 distinct
registers**, in two forms: the full ordered sequence (order matters for this kind of
part) and the final register state with last-write-wins applied.

## Why it matters

An ASoC codec driver that replays this sequence at probe is now a tractable piece of
work rather than blind reverse engineering. It does not make the kernel rebuild
risk-free, but it removes the one gap that had no path at all.

The same technique applies to the other undocumented parts: `emdoor,synaptics_dsp`
(the voice DSP, whose only symbol is `synaptics_dsp_event_work`, suggesting a thin
IRQ-to-input shim) and the `gc5024` camera sensor.

## Runtime behaviour: the amp is **probe-init only**

The init sequence above would be worthless if the driver also had to talk to the amp
during normal use — volume, mute, stream start/stop. It does not. Four independent
runtime scenarios were traced on the live device with `i2c_write`/`i2c_read` enabled,
filtering for address `a=031`:

| scenario | amp writes |
|---|---|
| Spotify playback start / pause / resume | 0 |
| volume changed via injected keyevents (`input keyevent 24/25`) | 0 |
| volume changed via the **physical** volume +/− buttons | 0 |
| screen off → suspend → screen on | 0 |

The suspend test is the useful control: it recorded 90 I2C events in the same window,
all at `a=040` (the Silead `gslx68x` touchscreen suspending and resuming), so the tracer
was demonstrably working and the amp was simply silent.

Volume is therefore handled entirely upstream in the SoC audio path (MTK AFE/DAC
digital gain); the amp is configured once at probe and then left at fixed gain for the
life of the boot. There is no runtime register protocol to reverse engineer.

**Consequence for the driver:** the ASoC codec driver needs a `probe()` that replays the
captured sequence and essentially nothing else — no `set_volume`, no mute callback, no
DAPM register pokes, no suspend/resume handlers (the amp is not powered down on suspend
either). That is a very small driver, and all of its input is already in this directory.

## Why there are no runtime writes: the enable line is a GPIO

Decompiling our own DTB (`kernel-project/dts/our_device.dts`) explains the zero-write
result above. The machine-level `sound` node is:

```dts
sound {
    compatible = "mediatek,mt8167-mt6392";
    mediatek,ext-spk-amp-warmup-time-us   = <0x13880>;  /* 80 ms */
    mediatek,ext-spk-amp-shutdown-time-us = <0x9c40>;   /* 40 ms */
    pinctrl-names = "default", "extamp_on", "extamp_off";
    ...
};
```

The external speaker amp is switched with a **pinctrl/GPIO line** (`extamp_on` /
`extamp_off`), driven by the standard MediaTek machine driver, with an 80 ms warm-up and
40 ms shutdown delay. I2C is used **only** to program the amp's registers once at probe.

So the division of labour is:

| function | mechanism | who implements it |
|---|---|---|
| register init (1417 writes) | I2C `1-0031` | the codec driver we must write |
| enable / mute at runtime | GPIO via `extamp_on`/`extamp_off` | `mediatek,mt8167-mt6392` machine driver (**exists in the BSP**) |
| volume | SoC AFE/DAC digital gain | existing MTK audio path |

That is a much better position than "write a driver for an undocumented amp": the runtime
half is stock MediaTek code, and our half is a fixed, already-captured register dump.

The DTB also gives the part's real vendor, which the chip markings did not:
`compatible = "ESMT, ad82584f"` — **ESMT** (Elite Semiconductor Microelectronics
Technology). Worth a fresh search for a datasheet under that vendor name.

## The part is publicly documented after all

Searching for `ad82584` alone found nothing, which is what produced the original
"nowhere public" verdict. The DTB's `compatible = "ESMT, ad82584f"` gives the vendor, and
under that name the part is a normal catalogue product:

- **ESMT (Elite Semiconductor Microelectronics Technology) AD82584F** — 2x20 W stereo /
  1x40 W mono digital (class-D) audio amplifier, I2S audio in, **I2C control**, with a
  20-30 band EQ, three-band DRC/clipping, 3D effect and a 2.1CH mode. Accepts 16/18/20/24-bit
  I2S at 8-192 kHz.
- Datasheets: [alldatasheet](https://www.alldatasheet.com/datasheet-pdf/pdf/1648957/ESMT/AD82584.html),
  [datasheet4u](https://datasheet4u.com/datasheets/ESMT/AD82584F/1345785).
  Vendor product page: [esmt.com.tw](https://www.esmt.com.tw/en/Products/Audio/Audio-7-13).

This also explains the **size** of the captured init: 1417 writes over 134 registers is not
a simple power-up, it is loading EQ and DRC coefficient banks. With the datasheet the
captured dump stops being an opaque blob and becomes something we can read field by field.

## CORRECTION: a complete ASoC driver DOES exist publicly

**The earlier "no driver exists anywhere" verdict in this file was wrong.** It came from
web searches, which find nothing. A GitHub *code* search finds the driver immediately, in
several vendor BSPs:

- `spsgsb/kernel-common` -> `sound/soc/codecs/amlogic/ad82584f.{c,h}` (Amlogic, Linux 4.9)
- `CrealityTech/sonic_pad_os` -> `lichee/linux-4.9/sound/soc/codecs/ad82584f.c` (Allwinner)
- `lindenis-org/lindenis-v536-lichee-linux-4.9`, `McMCCRU/linux-amlogic`,
  `voodik/android_kernel_voodik_odroidg12`

A copy is vendored at `kernel-project/vendor-refs/ad82584f/` (1044 lines). It is a full
ASoC codec driver: `reg_defaults` table, `set_eq_drc`, `set_bias_level`, DAPM widgets,
suspend/resume, GPIO reset, `snd_soc_dai_ops`.

It is unambiguously the same binding as ours -- its OF match is
`{ .compatible = "ESMT, ad82584f" }`, byte-identical to our DTB including the space after
the comma.

### Cross-validation against our capture

Comparing the driver's power-up table with the registers we captured off the live device:

| | |
|---|---|
| registers in driver table | 134 (`AD82584F_REGISTER_COUNT` = `0x86`) |
| registers in our capture | 134 |
| register *set* | **identical** -- none present in one and missing from the other |
| values identical | **117 / 134 (87%)** |
| values differing | 17 |

The 17 differences are exactly the registers that should be board- or state-specific:
`State_Control_1/2`, `MUTE` (`0x30` muted in the vendor table vs `0x00` on our device,
which was playing audio at capture time), master and channel volumes, `CFUD`, `0x85`, and
the six consecutive `0x44`-`0x49` (DRC/limiter coefficients).

Two conclusions: our ftrace capture is **complete and correct**, and the remaining work is
a *port*, not a rewrite. `port_regs.py` regenerates our values as a drop-in
`ad82584f_reg_defaults[]` (keeping the vendor's register-name comments) into
`ad82584f_reg_defaults_maic.h`.

Remaining porting work is the 4.9 -> 4.4 ASoC delta and wiring it to the MediaTek machine
driver, not chip reverse engineering.
