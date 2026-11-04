#!/usr/bin/env python3
"""Build a plugin zip deterministically (fixed timestamps, sorted entries), so the same
inputs give the same bytes on every run: a deleted version can then be restored with
identical bytes (gate G6), and fixtures can hold entries `zip` will not write.

  mkzip.py OUT.zip DIR [--prefix TOP/] [--add NAME=TEXT ...] [--symlink NAME=TARGET]
  mkzip.py OUT.zip --manifest PATH=JSON [--add NAME=TEXT ...]   (no DIR)

DIR's files are added relative to DIR, under --prefix if given. --add writes an extra
entry verbatim (its NAME is not checked, which is how a traversal entry such as
"../evil.md" gets into a fixture). --manifest is --add for JSON text.
"""
import argparse, os, stat, sys, zipfile

DATE = (2026, 1, 1, 0, 0, 0)

def entry(zf, name, data, mode=0o644, link=False):
    info = zipfile.ZipInfo(name, DATE)
    info.compress_type = zipfile.ZIP_DEFLATED
    kind = stat.S_IFLNK if link else stat.S_IFREG
    info.external_attr = ((kind | mode) & 0xFFFF) << 16
    info.create_system = 3
    zf.writestr(info, data)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("out")
    p.add_argument("dir", nargs="?")
    p.add_argument("--prefix", default="")
    p.add_argument("--add", action="append", default=[])
    p.add_argument("--manifest", action="append", default=[])
    p.add_argument("--symlink", action="append", default=[])
    a = p.parse_args()
    files = []
    if a.dir:
        for root, dirs, names in os.walk(a.dir):
            dirs.sort()
            for n in sorted(names):
                full = os.path.join(root, n)
                rel = os.path.relpath(full, a.dir).replace(os.sep, "/")
                with open(full, "rb") as f:
                    files.append((a.prefix + rel, f.read()))
    for spec in a.add + a.manifest:
        name, _, text = spec.partition("=")
        files.append((name, text.encode()))
    with zipfile.ZipFile(a.out, "w") as zf:
        for name, data in sorted(files, key=lambda x: x[0]):
            entry(zf, name, data)
        for spec in a.symlink:
            name, _, target = spec.partition("=")
            entry(zf, name, target.encode(), 0o777, link=True)
    return 0

if __name__ == "__main__":
    sys.exit(main())
