#!/bin/sh
# Stage 8 (v4.4.240) conflict resolutions. Run inside the tree after `git merge v4.4.240`.
# 5 files. See logs/stage-v4.4.240.md for per-block rationale.
set -e
R=/t/resolve.py

# keep the vendor dts Makefile include; take the wider targets list (ac4ba8055) -- PY below
python3 $R arch/arm64/boot/Makefile ours
python3 $R arch/x86/kernel/vmlinux.lds.S theirs
# cb9bbb958 alarm-register read/modify/write with field masks (masks auto-merged). The vendor
# power-on-alarm switch is re-inserted BEFORE the bulk read so anything its helper writes into
# the alarm registers' spare bits is captured, not clobbered (PY below).
python3 $R drivers/rtc/rtc-mt6397.c theirs
python3 $R include/linux/mtd/nand.h both
# 09d96c8d1/77ef57530 VRF rework of RA route handling: upstream (net, ..., dev) signatures, with
# the Android per-interface table (addrconf_rt_table) as the default in every tb_id/fc_table
# site, and the vendor all-tables purge (fib6_clean_all) kept -- a strict superset of upstream's
# flag-driven scan (PY below).
python3 $R net/ipv6/route.c theirs,theirs,theirs,theirs,theirs,theirs,theirs,theirs,theirs,ours

python3 - <<'PY'
import re
def rd(p): return open(p, encoding='utf-8', errors='surrogateescape').read()
def wr(p, s): open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
def sub(path, old, new, count=1):
    s = rd(path); n = s.count(old)
    assert n == count, f"{path}: expected {count} x {old[:60]!r}, found {n}"
    wr(path, s.replace(old, new)); print(f"  {path}: edit ok")
def resub(path, pat, new, flags=re.M):
    s = rd(path); m = re.findall(pat, s, flags=flags)
    assert len(m) == 1, f"{path}: regex {pat[:50]!r} matched {len(m)}x"
    wr(path, re.sub(pat, new, s, count=1, flags=flags)); print(f"  {path}: regex edit ok")

sub('arch/arm64/boot/Makefile',
    'targets := Image Image.gz\n',
    'targets := Image Image.bz2 Image.gz Image.lz4 Image.lzma Image.lzo\n')

_log = ('\tdev_err(rtc->dev, "set al time = %04d/%02d/%02d %02d:%02d:%02d (%d)\\n",\n'
        '\t\t  tm->tm_year + RTC_MIN_YEAR, tm->tm_mon, tm->tm_mday,\n'
        '\t\t  tm->tm_hour, tm->tm_min, tm->tm_sec, alm->enabled);\n\n')
_switch = ('\tswitch (alm->enabled) {\n\tcase 2:\n\t\t/* enable power-on alarm */\n\t\tmtk_rtc_save_pwron_time(true, tm, false);\n\t\tbreak;\n'
           '\tcase 3:\n\t\t/* enable power-on alarm with logo */\n\t\tmtk_rtc_save_pwron_time(true, tm, true);\n\t\tbreak;\n'
           '\tcase 4:\n\t\t/* disable power-on alarm */\n\t\tmtk_rtc_save_pwron_time(false, tm, false);\n\t\tbreak;\n'
           '\tdefault:\n\t\tbreak;\n\t}\n\n')
resub('drivers/rtc/rtc-mt6397.c',
      r'(static int mtk_rtc_set_alarm\(.*?tm->tm_mon\+\+;\n\n)\tmutex_lock\(&rtc->lock\);\n(\tret = regmap_bulk_read\(rtc->regmap, rtc->addr_base \+ RTC_AL_SEC,)',
      lambda m: m.group(1) + _log + '\tmutex_lock(&rtc->lock);\n' + _switch + m.group(2), flags=re.S)

sub('net/ipv6/route.c',
    '\tu32 tb_id = l3mdev_fib_table(dev) ? : RT6_TABLE_INFO;\n',
    '\tu32 tb_id = l3mdev_fib_table(dev) ? : addrconf_rt_table(dev, RT6_TABLE_INFO);\n')
sub('net/ipv6/route.c',
    '\tcfg.fc_table = l3mdev_fib_table(dev) ? : RT6_TABLE_INFO,\n',
    '\tcfg.fc_table = l3mdev_fib_table(dev) ? : addrconf_rt_table(dev, RT6_TABLE_INFO),\n')
sub('net/ipv6/route.c',
    '\tu32 tb_id = l3mdev_fib_table(dev) ? : RT6_TABLE_DFLT;\n',
    '\tu32 tb_id = l3mdev_fib_table(dev) ? : addrconf_rt_table(dev, RT6_TABLE_DFLT);\n')
# git's blocks covered only the TAILS of the rt6_{add,get}_route_info signatures; the vendor
# first line `(struct net_device *dev,` was shared prefix, so 'theirs' yielded `dev` twice and no
# `net`. Upstream's first parameter is `struct net *net` (its trailing `dev` param supplies dev).
sub('net/ipv6/route.c', 'rt6_add_route_info(struct net_device *dev,\n', 'rt6_add_route_info(struct net *net,\n', count=2)
sub('net/ipv6/route.c', 'rt6_get_route_info(struct net_device *dev,\n', 'rt6_get_route_info(struct net *net,\n')
# rt6_route_rcv(): upstream's `net` local (the callers above now pass it) did not auto-merge.
sub('net/ipv6/route.c',
    '\t\t  const struct in6_addr *gwaddr)\n{\n\tstruct route_info *rinfo = (struct route_info *) opt;\n',
    '\t\t  const struct in6_addr *gwaddr)\n{\n\tstruct net *net = dev_net(dev);\n\tstruct route_info *rinfo = (struct route_info *) opt;\n')
PY
# 4 sites: add decl + get decl (the latter already carried `net` from upstream's block) + both defs
[ "$(grep -c 'rt6_\(add\|get\)_route_info(struct net \*net,' net/ipv6/route.c)" -eq 4 ] || { echo "route.c: expected 4 (struct net *net, signature sites"; exit 1; }
[ "$(grep -c 'rt6_\(add\|get\)_route_info(struct net_device \*dev,' net/ipv6/route.c)" -eq 0 ] || exit 1

# Gates (tree-wide, no extension filter) + structural checks.
n=$(grep -rl '^<<<<<<< HEAD' . | wc -l); echo "conflict markers remaining (tree-wide): $n"
[ "$n" -eq 0 ] || { grep -rl '^<<<<<<< HEAD' .; exit 1; }
[ "$(grep -c 'addrconf_rt_table(dev, RT6_TABLE_' net/ipv6/route.c)" -ge 4 ] || { echo "route.c: addrconf_rt_table sites < 4"; exit 1; }
grep -q 'fib6_clean_all(net, rt6_addrconf_purge, NULL)' net/ipv6/route.c || exit 1
# rtc: the switch must precede the bulk read inside set_alarm
python3 - <<'PY'
import re
s = open('drivers/rtc/rtc-mt6397.c').read()
f = re.search(r'static int mtk_rtc_set_alarm\(.*?\n}\n', s, re.S).group(0)
assert f.index('mtk_rtc_save_pwron_time(true, tm, false)') < f.index('regmap_bulk_read(rtc->regmap, rtc->addr_base + RTC_AL_SEC') < f.index('RTC_AL_SEC_MASK'), "rtc set_alarm ordering wrong"
print("  rtc-mt6397.c: switch -> bulk_read -> masked update order verified")
PY
echo "stage-240 resolve: all gates passed"
