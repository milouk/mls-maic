# Thermal throttle that actually lowers the frequency

`thermal-throttle.patch` fixes two bugs in the vendor MT8167 CPU thermal path
(`drivers/misc/mediatek/base/power/mt8167/mtk_power_throttle.c`). Both hit the stock
1300 MHz operating point.

- **The power budget picked "fewer cores", which does nothing here.** The vendor search
  over the power table had its core-count match commented out. In a table sorted by
  power, that turns the search into "first entry under budget", which is few cores at
  a high frequency. The core limit is applied through MTK hotplug (HPS), and this build
  keeps HPS off (`scripts/service.d_perf.sh`), so the frequency never dropped and the SoC
  ran past 80 C. The fix restores the core-count match and skips the unused zero OPP
  slots, so the budget keeps the cores and lowers the frequency.
- **The clip could not go below `policy->min`.** The vendor notifier refused any thermal
  clip below the current floor, and MTK PerfService raises that floor during touch
  boosts, so thermal lost its frequency lever at exactly the wrong time. The clip now
  wins over the floor. The floor comes back on its own when the limit is released,
  because `cpufreq_update_policy()` rebuilds the policy from `user_policy`. A zero clip
  ("no limit computed yet") is ignored.
