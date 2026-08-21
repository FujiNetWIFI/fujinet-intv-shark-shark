#!/usr/bin/env python3
"""Destination-phase assertion (PORTING.md §5.5, §7.25).

A CRC gate PASS can be two consoles identically stuck in the same wrong
place -- the checksum compare cannot see that. This cart's boot state is
the "SELECT 1 OR 2 PLAYERS" prompt, which masked ($3F, disc-only) fuzz can
NEVER answer on its own; the only way past it is SS_INJECT (a keypad
digit + ENTER, driven from sim state -- src/hook.asm). A run that somehow
never got the injector wired up correctly would park on the prompt
forever, with $0172 stuck at 0 and every checksum agreeing trivially.

** CONFIRMED LIVE (spikes/NOTES.md M3): ** a run with NO script content
driving the prompt still landed $0172 (SS_PCOUNT) at NET_COUNT (2), moved
off SS_HTBL_PROMPT ($5185) onto SS_HTBL_LIVE ($5193), and both MOB0
($031D-base) and MOB1 ($0325-base) showed real, non-zero, actively
populated game state -- the strongest "real gameplay ran, for BOTH
seats" signal available.

** REVISED (spikes/NOTES.md M7): ** a real 2-console rig run under fuzz
legitimately reached GAME OVER (GAME_TBL == SS_HTBL_PLAYAGAIN, $629C)
within its run window -- fuzz input is far more reckless than a skilled
player and both divers getting caught well inside 100s of play is
expected, not a bug (confirmed by 0 CRC mismatches across 20 rounds that
same run). GAME_TBL landing on SS_HTBL_NULL or SS_HTBL_PLAYAGAIN is
therefore ALSO accepted as real-gameplay evidence -- reaching game over
requires substantially MORE real gameplay than parking on the boot
prompt ever could. SS_PCOUNT is only required to be 1-2 while still in
SS_HTBL_LIVE; once the round ends the cart's own code may hold or reset
it to anything, which is not evidence of anything wrong.

Usage: check_dest_phase.py build/det_a.out [...]
"""
import re
import sys

DUMP_RE = re.compile(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#", re.M)

SS_HTBL_PROMPT = 0x5185
SS_HTBL_LIVE = 0x5193
SS_HTBL_NULL = 0x1906
SS_HTBL_PLAYAGAIN = 0x629C


def check(path):
    text = open(path).read()
    mem = {}
    for m in DUMP_RE.finditer(text):
        addr = int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            mem[addr + i] = int(w.rstrip("*"), 16)

    fail = []
    if not mem:
        return [f"{path}: no memory dumps found"]

    pcount = mem.get(0x172)
    tbl_lo = mem.get(0x80C0)
    tbl_hi = mem.get(0x80C1)
    table = None
    if tbl_lo is not None and tbl_hi is not None:
        table = tbl_lo | (tbl_hi << 8)

    if table is None:
        fail.append("no $80C0/$80C1 (GAME_TBL) dump found")
    elif table == SS_HTBL_PROMPT:
        fail.append("GAME_TBL still points at SS_HTBL_PROMPT ($5185) -- "
                    "parked on the player-count prompt; every checksum "
                    "agrees trivially")
    elif table not in (SS_HTBL_LIVE, SS_HTBL_NULL, SS_HTBL_PLAYAGAIN):
        fail.append(f"GAME_TBL = ${table:04X}, expected SS_HTBL_LIVE "
                    f"($5193), SS_HTBL_NULL ($1906) or SS_HTBL_PLAYAGAIN "
                    f"($629C)")

    if table == SS_HTBL_LIVE:
        if pcount is None:
            fail.append("no $0172 dump found (the run script must dump $0170-$0173)")
        elif not (1 <= pcount <= 2):
            fail.append(f"SS_PCOUNT ($0172) = {pcount}, expected 1-2 -- the "
                        f"player-count prompt was never answered (SS_INJECT "
                        f"never fired, or fired with a wrong event code)")

    mob0 = any(mem.get(a, 0) for a in range(0x31D, 0x325))
    mob1 = any(mem.get(a, 0) for a in range(0x325, 0x32D))
    if not mob0:
        fail.append("MOB0 ($031D-$0324, seat 0/left) all zero -- P1's "
                    "diver was never populated")
    if not mob1:
        fail.append("MOB1 ($0325-$032C, seat 1/right) all zero -- P2's "
                    "diver was never populated (a cross-seat routing bug "
                    "would show up exactly this way, M1c)")

    if fail:
        return [f"{path}: {f}" for f in fail]

    tbl_note = f" (GAME_TBL=${table:04X})" if table is not None else ""
    pcount_note = f"player count = {pcount}, " if table == SS_HTBL_LIVE else ""
    print(f"DEST-PHASE OK ({path}): {pcount_note}"
          f"MOB0 and MOB1 both populated{tbl_note}")
    return []


problems = []
for arg in sys.argv[1:] or ["build/det_a.out"]:
    problems += check(arg)

if problems:
    print("DEST-PHASE FAIL:")
    for p in problems:
        print("  -", p)
    sys.exit(1)
