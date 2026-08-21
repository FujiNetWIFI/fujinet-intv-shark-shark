#!/usr/bin/env python3
"""Port reconnaissance for EXEC-based Intellivision carts.

Answers, for any 1978-80 EXEC cart, the questions PORTING.md says must be
answered before netplay work can start:

  * where the hook points are (timer table, start-of-game vector)
  * how fast the game's sim clock runs (timer interval -> tick rate)
  * every site that has to be patched (RNG calls, controller reads)
  * where the game's phase machine lives (writes to the $035D handler table)
  * whether display state is static (STIC/GRAM writes: expected zero)

This is a LINEAR scan, not a flow-following disassembler: data that happens
to look like an instruction will show up.  Treat the output as a list of
candidates to confirm in `dis1600` output, not as truth.  It is calibrated
against Baseball, whose real patch map (tools/patches.py) it reproduces.

    tools/recon.py rom/Baseball.bin
    tools/recon.py "~/PiRTO-II-Flash-Backup/MNO/NFL Football.bin"
"""
import argparse
import os
import sys

# ---------------------------------------------------------------------------
# EXEC entry points worth naming (verified against build/exec.dis; see
# spikes/NOTES.md).  Anything not listed is reported by address only.
# ---------------------------------------------------------------------------
EXEC_NAMES = {
    0x1082: "post-title mainline",
    0x108F: "MAIN LOOP",
    0x1126: "X_DEF_ISR",
    0x11FA: "boot/title hand-off",
    0x14F1: "controller scan entry",
    0x1523: "controller scan",
    0x15F8: "handler-table dispatch (jumps into game code)",
    0x167D: "X_RAND1  ** RNG **",
    0x169E: "X_RAND2  ** RNG **",
    0x17D5: "timer-table dispatch pass",
    0x1838: "X_TIMER_STOP",
    0x1844: "X_TIMER_START",
    0x181E: "set timer countdown := interval  ** relocation hazard **",
    0x1831: "set timer countdown := R0 (music)",
    0x1A71: "music note timer",
    0x1AAD: "sound update",
    0x1CCE: "sound engine RNG caller (churns $035E mid-tick)",
    0x1F2F: "X_DO_GRAM_INIT",
}

RNG_CALLS = (0x167D, 0x169E)
TIMER_CALLS = (0x181E, 0x1831, 0x1838, 0x1844)

# EXEC RAM cells a netplay port has to care about.
CELLS = {
    0x011F: "decoded input, LEFT controller   ** shadow-patch site **",
    0x0120: "decoded input, RIGHT controller  ** shadow-patch site **",
    0x0121: "keypad/action state, left",
    0x0122: "keypad/action state, right",
    0x0123: "raw port, left",
    0x0124: "raw port, right",
    0x035D: "input handler-table pointer      ** phase machine **",
    0x035E: "EXEC LFSR state  ** must never be sim state **",
    0x035F: "sound frame counter",
}

OPS = {1: "MVO", 2: "MVI", 3: "ADD", 4: "SUB", 5: "CMP", 6: "AND", 7: "XOR"}

# The EXEC main-loop pass is gated by the ISR phase counter reloaded from
# $0103.  Measured = 3 on Baseball, Auto Racing, Boxing and NFL Football,
# i.e. one pass every 3 NTSC frames.  See PORTING.md.
PASS_FRAMES = 3
FRAME_HZ = 59.92


def words(path):
    d = open(path, "rb").read()
    n = len(d) // 2 * 2
    return [(d[i] << 8) | d[i + 1] for i in range(0, n, 2)]


class Rom:
    def __init__(self, path, base):
        self.path = path
        self.base = base
        self.w = words(path)
        self.end = base + len(self.w)

    def has(self, addr):
        return self.base <= addr < self.end

    def at(self, addr):
        return self.w[addr - self.base]

    def ptr(self, addr):
        """Little-endian byte-pair pointer, as the cart header stores them."""
        return self.at(addr) | (self.at(addr + 1) << 8)

    # -- decoders ----------------------------------------------------------
    def jsrs(self):
        """(site, register, target) for every well-formed JSR/J."""
        out = []
        for i in range(len(self.w) - 2):
            if self.w[i] != 0x0004:
                continue
            w1, w2 = self.w[i + 1], self.w[i + 2]
            if w1 & 0xFC00 or w2 & 0xFC00:
                continue
            reg = 4 + ((w1 >> 8) & 3)
            tgt = (((w1 & 0xFF) >> 2) << 10) | (w2 & 0x3FF)
            out.append((self.base + i, reg, tgt))
        return out

    def refs(self):
        """(site, mnemonic, reg, operand) for direct/immediate operands.

        `site` is the address of the OPERAND word -- the word a patch map
        would rewrite -- not of the opcode.
        """
        out = []
        for i in range(len(self.w) - 1):
            v = self.w[i]
            if not 0x0240 <= v <= 0x03FF:
                continue
            op = OPS[(v >> 6) & 7]
            mode, reg = (v >> 3) & 7, v & 7
            if mode == 0:
                out.append((self.base + i + 1, op, reg, self.w[i + 1]))
            elif mode == 7:
                out.append((self.base + i + 1, op + "I", reg, self.w[i + 1]))
        return out


def report(path, base):
    rom = Rom(path, base)
    name = os.path.basename(path)
    print("=" * 72)
    print(f"{name}   {len(rom.w)} words at ${base:04X}-${rom.end - 1:04X}")
    print("=" * 72)

    # ---- header ----------------------------------------------------------
    tbl = rom.ptr(base + 2)
    start = rom.ptr(base + 4)
    gram = rom.ptr(base + 8)
    print("\n-- cart header ------------------------------------------------")
    print(f"  timer table      ${tbl:04X}   <- patch to relocate (hook point 1)")
    print(f"  start-of-game    ${start:04X}   <- patch to insert NET_START (hook point 2)")
    print(f"  GRAM init seq    ${gram:04X}")
    disp = {0x0D: "border extension", 0x0E: "display mode (0=colour stack)",
            0x0F: "colour stack 0", 0x10: "colour stack 1",
            0x11: "colour stack 2", 0x12: "colour stack 3",
            0x13: "border colour"}
    print("  display state (static; reassert these, never transport them):")
    for off, what in disp.items():
        print(f"    ${base + off:04X} = ${rom.at(base + off):02X}  {what}")

    # ---- timer table -----------------------------------------------------
    print("\n-- timer table (the sim clock) --------------------------------")
    if not rom.has(tbl):
        print(f"  !! ${tbl:04X} is outside this image -- multi-segment cart?")
    else:
        pass_hz = FRAME_HZ / PASS_FRAMES
        a = tbl
        n = 0
        while rom.has(a + 3):
            addr = rom.ptr(a)
            interval = rom.ptr(a + 2)
            if addr == 0:
                break
            stopped = " [stopped/one-shot]" if interval & 0x8000 else ""
            iv = interval & 0x7FFF
            rate = f"{pass_hz / iv:.2f} Hz" if iv else "-"
            print(f"  entry {n}: ${addr:04X}  interval ${interval:04X}"
                  f"  -> {rate}{stopped}")
            if not stopped and iv:
                print(f"           tick period {1000 * iv / pass_hz:.0f} ms"
                      f"   =>  input delay d costs d x {1000 * iv / pass_hz:.0f} ms")
            a += 4
            n += 1

    # ---- call sites ------------------------------------------------------
    jsrs = rom.jsrs()
    exec_calls = {}
    for site, reg, tgt in jsrs:
        if tgt < base:
            exec_calls.setdefault(tgt, []).append(site)

    print("\n-- RNG call sites (each needs a canonical-RNG wrapper) ---------")
    hits = [(t, s) for t, s in exec_calls.items() if t in RNG_CALLS]
    if not hits:
        print("  none found -- confirm in dis1600 before believing it")
    for tgt, sites in sorted(hits):
        for s in sites:
            print(f"  ${s:04X}  JSR ${tgt:04X}  {EXEC_NAMES.get(tgt, '')}")
            print(f"           patch words ${s + 1:04X}/${s + 2:04X} to the wrapper")

    print("\n-- timer arm/stop calls (break when the table moves) -----------")
    found = False
    for tgt in TIMER_CALLS:
        for s in exec_calls.get(tgt, []):
            found = True
            print(f"  ${s:04X}  JSR ${tgt:04X}  {EXEC_NAMES.get(tgt, '')}")
    if not found:
        print("  none")

    # ---- RAM cell references --------------------------------------------
    refs = rom.refs()
    print("\n-- controller / phase / RNG cell references -------------------")
    for cell, what in CELLS.items():
        hits = [(s, op, r) for s, op, r, v in refs if v == cell]
        if not hits:
            continue
        print(f"  ${cell:04X}  {what}")
        for s, op, r in hits:
            print(f"        ${s:04X}  {op} (R{r})   operand word = ${s:04X}")

    # ---- display writes --------------------------------------------------
    stic = [(s, op, r, v) for s, op, r, v in refs
            if op == "MVO" and v <= 0x003F]
    gramw = [(s, op, r, v) for s, op, r, v in refs
             if op == "MVO" and 0x3800 <= v <= 0x39FF]
    print("\n-- display writes (expected: none; display comes from the header)")
    print(f"  STIC register writes: {len(stic)}")
    for s, op, r, v in stic[:8]:
        print(f"        ${s:04X}  MVO R{r},${v:04X}")
    print(f"  GRAM writes:          {len(gramw)}")

    # ---- orientation -----------------------------------------------------
    print("\n-- most-called EXEC routines (orientation only) ---------------")
    top = sorted(exec_calls.items(), key=lambda kv: -len(kv[1]))[:8]
    for tgt, sites in top:
        print(f"  ${tgt:04X}  x{len(sites):<3} {EXEC_NAMES.get(tgt, '')}")
    print()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rom", nargs="+")
    ap.add_argument("--base", default="5000",
                    help="load address in hex (default 5000)")
    args = ap.parse_args()
    for path in args.rom:
        report(os.path.expanduser(path), int(args.base, 16))
    return 0


if __name__ == "__main__":
    sys.exit(main())
