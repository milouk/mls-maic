#!/usr/bin/env python3
"""Stage 9 (v4.4.270) post-merge fix-ups for code git auto-merged inconsistently. Idempotent.

1. 5cc4e064d "zsmalloc: account the number of compacted pages correctly" made
   struct zs_pool_stats.pages_compacted an atomic_long_t and converted upstream's only reader
   (mm_stat_show). The vendor /proc/zraminfo reader (zraminfo_proc_show) still passed the raw
   field: "aggregate value used where an integer was expected".
"""
def rd(p): return open(p, encoding='utf-8', errors='surrogateescape').read()
def wr(p, s): open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
def sub(path, old, new, count=1):
    s = rd(path)
    if old not in s and new in s:
        print(f"  {path}: already applied"); return
    n = s.count(old)
    assert n == count, f"{path}: expected {count} x {old[:60]!r}, found {n}"
    wr(path, s.replace(old, new)); print(f"  {path}: edit ok")

sub('drivers/block/zram/zram_drv.c',
    'P2K(pool_stats.pages_compacted));',
    'P2K(atomic_long_read(&pool_stats.pages_compacted)));')

assert 'P2K(pool_stats.pages_compacted)' not in rd('drivers/block/zram/zram_drv.c')
print("fixups-stage-v4.4.270: all gates passed")
