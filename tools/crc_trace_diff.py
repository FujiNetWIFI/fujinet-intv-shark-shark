#!/usr/bin/env python3
"""Compare the per-sim-tick state checksum rings of two determinism runs.

Each input is a jzIntv debugger session log containing `m` dumps of the
netcode vars ($8100-$810F) and the trace ring ($9000-$91FF).  Both runs park
at the same sim tick (TRACE_STOP), so ring slots correspond 1:1.
"""
import re
import sys

DUMP_RE = re.compile(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#", re.M)


def parse(path):
    mem = {}
    for m in DUMP_RE.finditer(open(path).read()):
        addr = int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            mem[addr + i] = int(w.rstrip("*"), 16)
    return mem


def main():
    a, b = parse(sys.argv[1]), parse(sys.argv[2])

    for name, mem in (("A", a), ("B", b)):
        if 0x8108 not in mem:
            sys.exit(f"run {name}: no $8108 dump found")
    tick_a = a[0x8108] | (a[0x8109] << 8)
    tick_b = b[0x8108] | (b[0x8109] << 8)
    print(f"run A parked at tick {tick_a}, run B at tick {tick_b}")
    if tick_a != tick_b:
        sys.exit("PARK TICK MISMATCH - runs are not comparable")

    mismatches = []
    missing = 0
    for slot in range(256):
        addr = 0x9000 + slot * 2
        if addr not in a or addr not in b:
            missing += 1
            continue
        ca = a[addr] | (a[addr + 1] << 8)
        cb = b[addr] | (b[addr + 1] << 8)
        if ca != cb:
            tick = (tick_a & ~0xFF) - 0x100 + slot if slot >= (tick_a & 0xFF) \
                else (tick_a & ~0xFF) + slot
            mismatches.append((tick, slot, ca, cb))

    if missing:
        print(f"warning: {missing} ring slots missing from dumps")

    # Settled-state check at the park point: object table + game scratch.
    # (The ring excludes ISR-written object cells; this covers them.)
    # Field +5 of each 8-word object record ($031D + 8n + 5) is a real-frame
    # animation counter (see src/debug.asm TRACE_RANGES): stalls shift its
    # phase, so it differs at matched sim ticks by design.  Utopia parks
    # mid-game with weather animating, so unlike the earlier ports the
    # exclusion has to be explicit here (confirmed twice: virt==hook and
    # det A/B each flagged ONLY field-+5 cells).
    def anim_field(x):
        return 0x031D <= x < 0x035D and (x - 0x031D) % 8 == 5
    settled = [x for x in sorted(set(a) & set(b))
               if a[x] != b[x] and not anim_field(x)
               and (0x015D <= x < 0x01F0 or 0x0315 <= x < 0x35E)]
    if settled:
        print(f"SETTLED-STATE FAIL: {len(settled)} cells differ at park:")
        for x in settled[:10]:
            print(f"  ${x:04X}: A=${a[x]:04X} B=${b[x]:04X}")
        sys.exit(1)
    print("settled-state check: object table + scratch identical at park")
    if mismatches:
        print(f"DETERMINISM FAIL: {len(mismatches)}/256 slots differ")
        for tick, slot, ca, cb in mismatches[:10]:
            print(f"  tick {tick} (slot {slot:3d}): A=${ca:04X} B=${cb:04X}")
        first = min(mismatches)[0]
        print(f"first divergence at sim tick {first}")
        sys.exit(1)
    print("DETERMINISM PASS: all 256 compared ticks have identical checksums")


if __name__ == "__main__":
    main()
