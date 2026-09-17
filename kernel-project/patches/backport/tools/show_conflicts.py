#!/usr/bin/env python3
import sys
for path in sys.argv[1:]:
    L = open(path, errors='replace').read().split('\n'); i = 0; n = 0
    print(f"################ {path}")
    while i < len(L):
        if L[i].startswith('<<<<<<< '):
            n += 1; j = i + 1; ours = []; theirs = []
            while not L[j].startswith('======='): ours.append(L[j]); j += 1
            j += 1
            while not L[j].startswith('>>>>>>> '): theirs.append(L[j]); j += 1
            ctx = L[max(0, i-3):i]
            print(f"--- block {n} @line {i+1} ctx: " + ' | '.join(c.strip() for c in ctx if c.strip())[-120:])
            for tag, blk in (('OURS', ours), ('THEIRS', theirs)):
                print(f"  [{tag} {len(blk)} lines]"); [print('    ' + x) for x in blk[:25]]
                if len(blk) > 25: print('    ...')
            i = j
        i += 1
