#!/usr/bin/env python3
"""List differing RAM cells between two determinism-run dumps (parked state).
Usage: cell_diff.py det_a.out det_b.out
"""
import sys

from crc_trace_diff import parse


def main():
    a, b = parse(sys.argv[1]), parse(sys.argv[2])
    common = sorted(set(a) & set(b))
    diffs = [(x, a[x], b[x]) for x in common
             if a[x] != b[x] and (0x015D <= x <= 0x01EF or 0x02F0 <= x <= 0x035F)]
    for addr, va, vb in diffs:
        print(f"${addr:04X}: A=${va:04X} B=${vb:04X}")
    print(f"{len(diffs)} differing cells in checksummed ranges")


if __name__ == "__main__":
    main()
