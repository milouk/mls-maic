#!/usr/bin/env python3
"""Resolve git conflict blocks in a file by per-block choice.
usage: resolve.py FILE CHOICE[,CHOICE...]   CHOICE in ours|theirs|both|theirs+ours
One choice per conflict block in order; a single choice applies to all blocks.
Handles diff3-less markers (<<<<<<< / ======= / >>>>>>>)."""
import sys, re
path, choices = sys.argv[1], sys.argv[2].split(',')
src = open(path, encoding='utf-8', errors='surrogateescape').read().split('\n')
out, i, n = [], 0, 0
while i < len(src):
    l = src[i]
    if l.startswith('<<<<<<< '):
        ours, theirs, j = [], [], i + 1
        while not src[j].startswith('======='):
            ours.append(src[j]); j += 1
        j += 1
        while not src[j].startswith('>>>>>>> '):
            theirs.append(src[j]); j += 1
        c = choices[n] if n < len(choices) else choices[-1]
        out += {'ours': ours, 'theirs': theirs, 'both': ours + theirs, 'theirs+ours': theirs + ours}[c]
        n += 1; i = j + 1; continue
    out.append(l); i += 1
open(path, 'w', encoding='utf-8', errors='surrogateescape').write('\n'.join(out))
print(f"{path}: resolved {n} block(s) with {choices}")
