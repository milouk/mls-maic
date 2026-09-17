# USB attack-surface CVE backports (post-4.4-EOL, MT8167 / 4.4.302)

4.4.302 is the last 4.4 release, so CVEs fixed *after* Feb 2022 were never backported to it.
The confirmed-live USB host class drivers (`USB_VIDEO_CLASS=y`, `SND_USB_AUDIO=y`, `USB_HID=y`)
are the biggest exposure — a hostile/emulated USB device can reach kernel memory. These three
fixes are faithful backports of the mainline commits, applied to the `maic-bp` tree and folded
into the rm6 kernel candidate. Each was verified (build + string check); none touches a blob.

| CVE | mainline | file | change | our commit |
|---|---|---|---|---|
| CVE-2024-53104 | `ecf2b43018da` | `uvc_driver.c` | guard the frame-descriptor loop with `ftype` (skip `UVC_VS_UNDEFINED` → OOB write) | `61a3b82` |
| CVE-2024-50302 | `177f25d1292c` | `hid-core.c` | `hid_alloc_report_buf`: `kmalloc`→`kzalloc` (uninit kernel-mem leak) | `692294b` |
| CVE-2024-53197 | `b909df18ce2a` | `sound/usb/quirks.c` | Extigy+Mbox2 boot quirks read the new descriptor into a local and bound `bNumConfigurations` before overwriting `dev->descriptor` (OOB) | `97ab66d` |

**Applied hunks:** the CVE-2024-53197 patch here keeps only the Extigy + Mbox2 hunks; the mainline
commit's Mbox3 hunks are dropped because `snd_usb_mbox3_boot_quirk` does not exist in 4.4.

## Deferred (needs hand-adaptation, NOT in rm6)

- **CVE-2024-53150** (ALSA usb-audio, `sound/usb/clock.c`, OOB read finding clock sources). The
  mainline fix (`096bb5b43edf`) adds length checks to `validate_clock_source/selector/multiplier`
  over the **refactored `union uac23_clock_*_desc` (v2/v3)** structure, which does **not exist** in
  this 4.4 tree (it uses `uac_clock_source_is_valid` / `snd_usb_find_clock_source`). A correct
  backport must add equivalent `bLength` bounds checks to the 4.4 code paths by hand — deferred
  rather than ship an uncertain security patch. Realistic exposure (malicious USB *audio* device)
  is low on this kitchen tablet, but it remains open.
