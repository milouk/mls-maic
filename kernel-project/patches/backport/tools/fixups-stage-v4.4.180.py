#!/usr/bin/env python3
"""Stage 6 (v4.4.180) post-merge fix-ups for code git auto-merged *inconsistently* -- none of
these files conflicted. Idempotent: a fix already applied is skipped, so this can be re-run.

1. gup_flags series (8e50b8b07 + friends): get_user_pages(tsk, mm, start, n, write, force,
   pages, vmas) became (tsk, mm, start, n, gup_flags, pages, vmas), and __get_user_pages_locked
   lost write/force. Upstream converted every in-tree caller; vendor callers were untouched.
   - mm/gup.c get_user_pages_durable(): MTK FOLL_DURABLE wrapper -- keep its write/force API,
     translate to flags inside (its vendor callers then need nothing).
   - fs/proc/task_mmu.c: Android [anon:name] printer.
   - drivers/misc/mediatek/{mtee,m4u/2.0,m4u/3.0,gud/302c,gud/311b}, goldfish_pipe.c: generic
     8-arg -> 7-arg rewrite. Only mtee is compiled on this board; the rest are converted so the
     tree is consistent whatever the config.
2. c8d66722d: struct global_attr -> struct kobj_attribute. The Android interactive governor (the
   one this device runs) is converted the same way upstream converted its own users.
"""
import re, sys

def rd(p): return open(p, encoding='utf-8', errors='surrogateescape').read()
def wr(p, s): open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)

def sub(path, old, new, count=1):
    s = rd(path)
    if old not in s and new in s:
        print(f"  {path}: already applied"); return
    n = s.count(old)
    assert n == count, f"{path}: expected {count} x {old[:60]!r}, found {n}"
    wr(path, s.replace(old, new)); print(f"  {path}: edit ok")

def split_args(s):
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch in '([{': depth += 1
        elif ch in ')]}': depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur); cur = ''
        else:
            cur += ch
    out.append(cur)
    return [a.strip() for a in out]

def flags_expr(write, force):
    w = write.strip(); f = force.strip()
    if w == '1': fw = 'FOLL_WRITE'
    elif w == '0': fw = None
    else: fw = f'({w} ? FOLL_WRITE : 0)'
    if f == '0': ff = None
    elif f == '1': ff = 'FOLL_FORCE'
    else: ff = f'({f} ? FOLL_FORCE : 0)'
    parts = [p for p in (fw, ff) if p]
    return ' | '.join(parts) if parts else '0'

def convert_gup_calls(path):
    """Rewrite every 8-argument get_user_pages(...) call in `path` to the 7-argument form."""
    s = rd(path); pos = 0; n = 0; out = ''
    pat = re.compile(r'(?<![\w.])get_user_pages\(')
    while True:
        m = pat.search(s, pos)
        if not m: break
        start = m.end(); depth = 1; i = start
        while depth:
            depth += {'(': 1, ')': -1}.get(s[i], 0); i += 1
        args = split_args(s[start:i-1])
        out += s[pos:m.start()]
        if len(args) == 8:
            new = args[:4] + [flags_expr(args[4], args[5])] + args[6:]
            # keep the original line layout of the first 4 and last 2 args; splice flags in
            head = s[start:i-1]
            # locate the write-arg span inside the original text to replace "write, force" textually
            spans = []; depth = 0; cur_start = 0
            for k, ch in enumerate(head):
                if ch in '([{': depth += 1
                elif ch in ')]}': depth -= 1
                elif ch == ',' and depth == 0:
                    spans.append((cur_start, k)); cur_start = k + 1
            spans.append((cur_start, len(head)))
            w0, w1 = spans[4]; f0, f1 = spans[5]
            lead = re.match(r'\s*', head[w0:w1]).group(0)
            head = head[:w0] + lead + flags_expr(args[4], args[5]) + head[f1:]
            out += 'get_user_pages(' + head + ')'; n += 1
        else:
            out += s[m.start():i]
        pos = i
    out += s[pos:]
    if n: wr(path, out)
    print(f"  {path}: converted {n} get_user_pages() call(s)")

# --- 1a. mm/gup.c get_user_pages_durable
sub('mm/gup.c',
    '\treturn __get_user_pages_locked(tsk, mm, start, nr_pages, write, force,\n\t\t\t\t       pages, vmas, NULL, false, FOLL_TOUCH | FOLL_DURABLE);\n',
    '\tunsigned int flags = FOLL_TOUCH | FOLL_DURABLE;\n\n\tif (write)\n\t\tflags |= FOLL_WRITE;\n\tif (force)\n\t\tflags |= FOLL_FORCE;\n\n\treturn __get_user_pages_locked(tsk, mm, start, nr_pages,\n\t\t\t\t       pages, vmas, NULL, false, flags);\n')
# --- 1b. task_mmu.c
sub('fs/proc/task_mmu.c',
    '\t\tpages_pinned = get_user_pages(current, mm, page_start_vaddr,\n\t\t\t\t1, 0, 0, &page, NULL);\n',
    '\t\tpages_pinned = get_user_pages(current, mm, page_start_vaddr,\n\t\t\t\t1, 0, &page, NULL);\n')
# --- 1c. vendor + goldfish callers
for p in ['drivers/misc/mediatek/mtee/tz_mod.c',
          'drivers/misc/mediatek/m4u/2.0/m4u.c',
          'drivers/misc/mediatek/m4u/3.0/m4u.c',
          'drivers/misc/mediatek/gud/302c/gud/MobiCoreDriver/mem.c',
          'drivers/misc/mediatek/gud/311b/gud/MobiCoreDriver/mmu.c',
          'drivers/platform/goldfish/goldfish_pipe.c']:
    convert_gup_calls(p)

# --- 2. cpufreq_interactive: global_attr -> kobj_attribute (both defs, both prototypes)
sub('drivers/cpufreq/cpufreq_interactive.c',
    '(struct kobject *kobj, struct attribute *attr, char *buf)\t\t\\\n',
    '(struct kobject *kobj, struct kobj_attribute *attr, char *buf)\t\\\n')
sub('drivers/cpufreq/cpufreq_interactive.c',
    '(struct kobject *kobj, struct attribute *attr, const char *buf,\t\t\\\n',
    '(struct kobject *kobj, struct kobj_attribute *attr, const char *buf,\t\\\n')
sub('drivers/cpufreq/cpufreq_interactive.c',
    'static struct global_attr _name##_gov_sys =',
    'static struct kobj_attribute _name##_gov_sys =')
sub('drivers/cpufreq/cpufreq_interactive.c',
    'static struct global_attr boostpulse_gov_sys =',
    'static struct kobj_attribute boostpulse_gov_sys =')

# --- 3. 2ac36cc66 made get_task_comm() a macro with BUILD_BUG_ON(sizeof(buf) != TASK_COMM_LEN).
# The MTK block-IO tracer's buffer is TASK_COMM_LEN+1; use the length-taking primitive.
sub('drivers/mmc/card/mtk_mmc_block.c',
    '\tget_task_comm(ctx->comm, thread);\n',
    '\t__get_task_comm(ctx->comm, sizeof(ctx->comm), thread);\n')

# --- 4. The 2c155709e backport removed the locked ion_handle_get_by_id() wrapper (its only
# upstream caller went _nolock); the MTK ion_drv_get_kernel_handle() API still uses it.
# Restored verbatim from v4.4.145, static (no callers outside ion.c, no header decl).
_ion = 'drivers/staging/android/ion/ion.c'
_wrapper = ('/* locked wrapper, kept for the MTK ion_drv_get_kernel_handle() API */\n'
            'static struct ion_handle *ion_handle_get_by_id(struct ion_client *client,\n\t\t\t\t\t\tint id)\n{\n'
            '\tstruct ion_handle *handle;\n\n\tmutex_lock(&client->lock);\n\thandle = ion_handle_get_by_id_nolock(client, id);\n'
            '\tmutex_unlock(&client->lock);\n\n\treturn handle;\n}\n\n')
_s = rd(_ion)
if _wrapper in _s:
    print(f"  {_ion}: already applied")
else:
    # anchor on the _nolock signature and append right after its closing brace (its body
    # differs from v4.4.145 -- b84ec04ba changed it -- so don't anchor on the body).
    _pat = re.compile(r'(static struct ion_handle \*ion_handle_get_by_id_nolock\(struct ion_client \*client,.*?\n\}\n\n)', re.S)
    _m = _pat.findall(_s)
    assert len(_m) == 1, f"{_ion}: _nolock definition matched {len(_m)}x"
    wr(_ion, _pat.sub(lambda m: m.group(1) + _wrapper, _s, count=1)); print(f"  {_ion}: edit ok (wrapper appended after _nolock)")

# --- 5. 13e84cdbd (drain the response queue on REMOTE_NDIS_RESET_MSG): MTK had already
# implemented the identical drain (plus a debug log and a counter), so git stacked upstream's
# hunk on top -> duplicate xbuf/length declarations and a duplicate loop. Keep the vendor's
# (superset) copy, drop upstream's.
sub('drivers/usb/gadget/function/rndis.c',
    '\trndis_resp_t *r;\n\tu8 *xbuf;\n\tu32 length;\n\n\t/* drain the response queue */\n'
    '\twhile ((xbuf = rndis_get_next_response(params, &length)))\n\t\trndis_free_response(params, xbuf);\n\n'
    '\tu32 length;\n\tu8 *xbuf;\n',
    '\trndis_resp_t *r;\n\tu32 length;\n\tu8 *xbuf;\n')

# --- gates
left = []
for p in ['mm/gup.c', 'fs/proc/task_mmu.c', 'drivers/misc/mediatek/mtee/tz_mod.c',
          'drivers/misc/mediatek/m4u/2.0/m4u.c', 'drivers/misc/mediatek/m4u/3.0/m4u.c',
          'drivers/misc/mediatek/gud/302c/gud/MobiCoreDriver/mem.c',
          'drivers/misc/mediatek/gud/311b/gud/MobiCoreDriver/mmu.c',
          'drivers/platform/goldfish/goldfish_pipe.c']:
    s = rd(p)
    for m in re.finditer(r'(?<![\w.])get_user_pages\(', s):
        i = m.end(); d = 1
        while d: d += {'(': 1, ')': -1}.get(s[i], 0); i += 1
        if len(split_args(s[m.end():i-1])) == 8: left.append(p)
assert not left, f"8-arg get_user_pages() calls remain in: {left}"
assert 'struct global_attr' not in rd('drivers/cpufreq/cpufreq_interactive.c')
print("fixups-stage-v4.4.180: all gates passed")
