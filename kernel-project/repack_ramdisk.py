#!/usr/bin/env python3
"""Rewrite a newc cpio ramdisk in place, changing only what is asked for.

Extracting a ramdisk to the macOS filesystem and re-archiving it loses exactly
the things that matter: every uid/gid becomes the invoking user, modes get
mangled, and APFS silently case-folds colliding names. This reads the archive,
edits the entries in memory, and writes it back -- so every byte of every
untouched entry, including its mode, ownership, inode number and link count,
survives verbatim. The only entries that differ are the ones named on the
command line.

newc entry layout (all fields 8-char ASCII hex):
    magic 070701 | ino mode uid gid nlink mtime filesize
    devmajor devminor rdevmajor rdevminor namesize check
    name (namesize bytes, NUL-terminated), padded to 4
    data (filesize bytes), padded to 4
terminated by an entry named TRAILER!!! with filesize 0.

One caution worth keeping in mind: the kernel's initramfs parser treats a
regular file with nlink >= 2 as a hardlink and will link it to an earlier entry
with the same (dev, ino) instead of writing its contents. New entries therefore
get nlink=1 and an inode number that is not already in use.
"""
import argparse
import struct
import sys

MAGIC = b"070701"
FIELDS = ("ino", "mode", "uid", "gid", "nlink", "mtime", "filesize",
          "devmajor", "devminor", "rdevmajor", "rdevminor", "namesize", "check")


def pad4(n):
    return (n + 3) // 4 * 4


def parse(data):
    ents, off = [], 0
    while off < len(data):
        if data[off:off + 6] != MAGIC:
            if data[off:].strip(b"\x00") == b"":
                break
            sys.exit(f"bad cpio magic at offset {off}: {data[off:off+6]!r}")
        f = {k: int(data[off + 6 + i * 8: off + 6 + (i + 1) * 8], 16)
             for i, k in enumerate(FIELDS)}
        nstart = off + 110
        name = data[nstart:nstart + f["namesize"] - 1].decode("ascii", "replace")
        dstart = pad4(nstart + f["namesize"])
        blob = data[dstart:dstart + f["filesize"]]
        off = pad4(dstart + f["filesize"])
        ents.append([name, f, blob])
        if name == "TRAILER!!!":
            break
    return ents


def emit(ents):
    out = bytearray()
    for name, f, blob in ents:
        nb = name.encode("ascii") + b"\x00"
        f = dict(f)
        f["namesize"] = len(nb)
        f["filesize"] = len(blob)
        out += MAGIC
        for k in FIELDS:
            out += b"%08X" % f[k]
        out += nb
        out += b"\x00" * (pad4(len(out)) - len(out))
        out += blob
        out += b"\x00" * (pad4(len(out)) - len(out))
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True, help="uncompressed newc cpio")
    ap.add_argument("--out", required=True)
    ap.add_argument("--replace", action="append", default=[], metavar="NAME=FILE",
                    help="replace an existing entry's contents, keeping its metadata")
    ap.add_argument("--add", action="append", default=[], metavar="NAME=FILE:MODE",
                    help="add a regular file, e.g. sbin/maic_rescue=./maic_rescue:0750")
    ap.add_argument("--after", default=None,
                    help="insert added entries right after this existing entry")
    a = ap.parse_args()

    ents = parse(open(a.inp, "rb").read())
    names = [e[0] for e in ents]
    if "TRAILER!!!" not in names:
        sys.exit("input cpio has no TRAILER!!! entry; it is probably truncated")
    print(f"input : {len(ents)-1} entries")

    for spec in a.replace:
        name, _, path = spec.partition("=")
        for e in ents:
            if e[0] == name:
                old = len(e[2])
                e[2] = open(path, "rb").read()
                print(f"replace: {name}  {old} -> {len(e[2])} bytes "
                      f"(mode {e[1]['mode']:o}, uid {e[1]['uid']}, gid {e[1]['gid']} kept)")
                break
        else:
            sys.exit(f"--replace: no entry named {name!r}")

    if a.add:
        used = {e[1]["ino"] for e in ents}
        ino = max(used) + 1
        new = []
        for spec in a.add:
            name, _, rest = spec.partition("=")
            path, _, mode = rest.partition(":")
            if any(e[0] == name for e in ents):
                sys.exit(f"--add: {name!r} already exists; use --replace")
            blob = open(path, "rb").read()
            f = dict(ino=ino, mode=0o100000 | int(mode or "0750", 8), uid=0, gid=0,
                     nlink=1, mtime=0, filesize=len(blob), devmajor=0, devminor=0,
                     rdevmajor=0, rdevminor=0, namesize=0, check=0)
            ino += 1
            new.append([name, f, blob])
            print(f"add    : {name}  {len(blob)} bytes  mode {f['mode']:o} root:root nlink=1")
        idx = len(ents) - 1
        if a.after:
            for i, e in enumerate(ents):
                if e[0] == a.after:
                    idx = i + 1
                    break
            else:
                sys.exit(f"--after: no entry named {a.after!r}")
        ents[idx:idx] = new

    out = emit(ents)
    open(a.out, "wb").write(out)

    # Read the result back and prove it still parses, entry for entry.
    back = parse(out)
    if len(back) != len(ents):
        sys.exit(f"re-parse found {len(back)} entries, expected {len(ents)}")
    for (n1, f1, b1), (n2, f2, b2) in zip(ents, back):
        if n1 != n2 or b1 != b2 or any(f1[k] != f2[k] for k in
                                       ("mode", "uid", "gid", "nlink", "ino")):
            sys.exit(f"round-trip mismatch at {n1!r}")
    nonroot = [e[0] for e in back if e[1]["uid"] or e[1]["gid"]]
    if nonroot:
        sys.exit(f"entries not owned by root:root: {nonroot[:5]}")
    hard = [e[0] for e in back
            if e[1]["nlink"] > 1 and (e[1]["mode"] & 0o170000) == 0o100000]
    if hard:
        sys.exit(f"regular files with nlink>1 would be treated as hardlinks: {hard[:5]}")
    print(f"output: {a.out}  {len(out)} bytes, {len(back)-1} entries, "
          f"re-parsed and verified, all root:root")


if __name__ == "__main__":
    main()
