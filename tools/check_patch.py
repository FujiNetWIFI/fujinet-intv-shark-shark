#!/usr/bin/env python3
"""Verify a hooked build differs from the original ROM only at declared
patch sites within the original $5000-$5FFF image.

Usage: check_patch.py ORIGINAL.bin HOOKED.bin PATCHES.py [COMPARE_WORDS]

COMPARE_WORDS, when given, limits the comparison to the first N words of
the original image instead of its full length. Needed when the patched
dump was itself truncated with dump_rom.py --stop (the words beyond the
truncation point belong to a hook segment's own ORG, not the original
image, and must not be diffed against it).
"""
import ast
import sys

BASE = 0x5000


def words(path, count=None):
    data = open(path, "rb").read()
    n = len(data) // 2 if count is None else count
    return [(data[i * 2] << 8) | data[i * 2 + 1] for i in range(n)]


def main():
    orig_path, hook_path, patch_path = sys.argv[1], sys.argv[2], sys.argv[3]
    compare_words = int(sys.argv[4]) if len(sys.argv) > 4 else None
    with open(patch_path) as f:
        patches = ast.literal_eval(f.read())

    orig = words(orig_path, compare_words)
    hooked = words(hook_path, len(orig))  # hooked file starts with the $5000 seg

    bad = []
    unpatched = []
    for i, (a, b) in enumerate(zip(orig, hooked)):
        addr = BASE + i
        if addr in patches:
            if a == b:
                unpatched.append(addr)
        elif a != b:
            bad.append((addr, a, b))

    for addr, a, b in bad:
        print(f"UNDECLARED DIFF at ${addr:04X}: ${a:04X} -> ${b:04X}")
    for addr in unpatched:
        print(f"NOTE: declared patch at ${addr:04X} left value unchanged")
    if bad:
        sys.exit(1)
    print(f"verify-patch: OK ({len(patches)} declared sites, "
          f"{len(patches) - len(unpatched)} changed)")


if __name__ == "__main__":
    main()
