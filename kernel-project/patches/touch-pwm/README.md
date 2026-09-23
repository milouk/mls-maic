# Backlight PWM frequency vs. capacitive-touch coupling

Reported symptom: spurious/ghost touches, worse at high screen brightness.

## Root cause

The panel's backlight is a TI LP8557 LED driver in PWM-input mode (fed directly from
MediaTek's own DISP_PWM block, not driven over I2C -- the LP8557's i2c node exists in
sysfs but has no driver bound, confirming this board uses PWM-only dimming). TI's LP8557
datasheet, section 7.8 "PWM Interface Characteristics", specifies:

| Parameter | Min | Max | Unit |
|---|---|---|---|
| `f_PWM` (PWM frequency) | 75 | **25000** | Hz |

The board's stock configuration is `clocksource=0` (26 MHz reference), `clockdiv=0`
(the hardware's fastest available divider), period = 1024 steps
(`DISP_PWM_CON_1_OFF`, hardcoded in `drivers/misc/mediatek/video/common/pwm10/ddp_pwm.c`).
That computes to:

```
26,000,000 / (0 + 1) / 1024 ≈ 25,391 Hz
```

**Already fractionally *above* the chip's documented maximum.** This is not a
regression introduced by any change on this device -- the stock, factory DTB is
byte-identical to `our_device.dtb` for this node (verified: both decompile to the same
`pwm_config = <0x00 0x00 0x00 0x00 0x00>`), so the board has run marginally
out-of-spec since it left the factory. The datasheet's own `PWM_RES` (input
resolution) table also shows dimming resolution getting *worse* as frequency rises
(down to 8 bits above 19.5 kHz) -- so the stock setting isn't just borderline on the
frequency spec, it's in the chip's least-characterized, worst-resolution zone too.

An out-of-spec, high-current switching regulator (the boost converter driving the LED
string) is a textbook capacitive-touch noise source; whether that's the *entire*
explanation for the reported symptom or one contributing factor, correcting it is
strictly an improvement with no downside.

**A first attempt at this fix went the wrong direction** -- raising the frequency
further to move it "away from the noisy band" -- before the datasheet check above was
done. That would have pushed the chip *further* out of spec, not into it. Lesson: check
the actual chip spec before picking a target frequency, however intuitive "faster must
be cleaner" seems.

## Fix

Double the clock divider: `clockdiv 0 -> 1`. New frequency:

```
26,000,000 / (1 + 1) / 1024 ≈ 12,695 Hz
```

Solidly inside the 75-25000 Hz range with real margin, still far above any
visible-flicker threshold, and lands in the datasheet's `PWM_RES < 19.5 kHz` (9-bit)
tier -- a better-resolved, better-characterized operating point than stock, not just a
lower-risk one.

The divider is architecturally the only knob available without giving up dimming
resolution: the period (1024 steps) is hardcoded in `ddp_pwm.c`, and the divider is
already at its hardware minimum in the stock config, so it can only go up (= slower)
from here, never down.

*(One caveat worth stating plainly: the exact resulting frequency depends on
`DISP_PWM_CON_0_OFF`'s clockdiv field being a simple linear N+1 divider on this specific
IP block, inferred rather than confirmed from an explicit source comment -- support: the
stock clockdiv=0 landing suspiciously close to, and just over, the datasheet's exact
25000 Hz ceiling is hard to explain as coincidence under any other common divider
shape. Whatever the true formula, a monotonically increasing divider register value
can only lower the frequency, never raise it -- so the fix is directionally guaranteed
correct even if the exact resulting Hz isn't pinned to three figures.)*

## Applying it

This patches the **compiled device tree blob** directly (`our_device.dtb`), not the
DTS source, and not the kernel driver:

```sh
python3 patch_backlight_pwm_div.py our_device.dtb our_device_pwmfix.dtb
```

Changes exactly one byte (verified). Repack with the existing, already-built kernel
`Image.gz` -- no kernel rebuild needed, this is a pure device-tree change:

```sh
python3 kernel-project/pack.sh  # or your usual mkboot.py / pack_candidate.sh invocation,
                                 # pointing DTB at our_device_pwmfix.dtb
```

### Why binary-patch the DTB instead of editing the DTS and recompiling

This device has a standing, hard-learned rule: never flash a *recompiled* DTB in place
of the device's actual captured one. A `dtc`-recompiled DTB from source can silently
diverge from the captured one in phandle numbering and clock-node ordering even when
the visible DTS text looks identical -- exactly the bug that caused an unrelated,
much worse boot hang earlier in this device's history (see `../backport/`). Binary-
patching the one field that actually needs to change, and diffing the result against
the original to confirm nothing else moved, sidesteps that whole class of bug.
Standard `fdtget`/`fdtput` were tried and rejected this DTB outright (even for
trivially-present paths) -- this board's legacy MTK devicetree isn't strict-libfdt
compliant, even though `dtc`'s own (more permissive) decompiler reads it fine. Hence
the small hand-rolled FDT struct-block walker in the patch script instead.
