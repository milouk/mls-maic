#!/system/bin/sh
# MAIC: persist the "tuned" speaker level (ad82584f channel volume 231 -> 246, ~+7 dB,
# balanced to Master 246). Judged by ear as noticeably louder and still clear.
# The codec PGA / Int-Spk controls are HAL-managed and reset on stream start, so only
# the amp channel volume is set here (it persists). Re-applied a few times to survive
# the audio HAL coming up after boot.
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
for d in 8 20 40; do
  sleep $d
  tinymix "AMP Ch1 Volume" 246 >/dev/null 2>&1
  tinymix "AMP Ch2 Volume" 246 >/dev/null 2>&1
done
