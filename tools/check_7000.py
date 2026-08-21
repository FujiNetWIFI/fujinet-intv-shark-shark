#!/usr/bin/env python3
"""Fail if any build .cfg maps -- or its segment SPANS INTO -- $7000.

The EXEC boot EXECUTES the word at $7000 (the ECS expansion hook); a
segment that only overflows into it is exactly as fatal as one that starts
there, and just as silent until something crashes at a fixed cycle count
(PORTING.md §7.22). A plain `grep '= $7000'` only catches the first shape.
This cart sits closer to the boundary than any prior port (hook.asm's
netcode segment starts at $6800, 2048 words below $7000), so the span
check is real insurance here, not just tidiness.

Usage: check_7000.py CFG [CFG ...]
"""
import re
import sys

MAP_RE = re.compile(
    r"^\s*\$([0-9A-Fa-f]+)\s*-\s*\$([0-9A-Fa-f]+)\s*=\s*\$([0-9A-Fa-f]+)\s*$"
)


def check(path):
    problems = []
    in_mapping = False
    with open(path) as f:
        for line in f:
            line = line.split(";", 1)[0]  # strip cfg comments
            stripped = line.strip()
            if stripped.startswith("["):
                in_mapping = stripped.lower() == "[mapping]"
                continue
            if not in_mapping or not stripped:
                continue
            m = MAP_RE.match(line)
            if not m:
                continue
            src_lo, src_hi, dest_lo = (int(g, 16) for g in m.groups())
            length = src_hi - src_lo + 1
            dest_hi = dest_lo + length - 1
            if dest_lo <= 0x7000 <= dest_hi:
                problems.append(
                    f"{path}: segment ${dest_lo:04X}-${dest_hi:04X} "
                    f"(from src ${src_lo:04X}-${src_hi:04X}) covers $7000"
                )
    return problems


def main():
    bad = []
    for path in sys.argv[1:]:
        bad.extend(check(path))
    for p in bad:
        print(f"FATAL: {p}")
    if bad:
        sys.exit(1)


if __name__ == "__main__":
    main()
