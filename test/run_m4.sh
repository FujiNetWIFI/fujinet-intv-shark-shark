#!/bin/sh
# M8 recovery test: the 2-player rig with a fault injection -- console 2's
# $0168 cell (P1's most-recently-dispatched disc heading, written only by
# L_63AD's fresh-disc-press path, $63B4 -- confirmed in dis1600, the same
# cell tools/run_lagcheck.sh tracks) is corrupted mid-run via the debugger.
#
# FIRST CHOICE WAS $0172 (SS_PCOUNT) -- REJECTED after a live run (spikes/
# NOTES.md M8): it is ALSO the loop bound SS_TICK4 consults EVERY TICK, so
# corrupting it doesn't produce a one-shot CRC mismatch the way Golf's
# stroke-count fault did -- it silently stops MOB1's flicker/spawn upkeep
# for as long as the fault persists, which (indirectly, through whatever
# conditional RNG consumption that upkeep gates) kept re-diverging the
# canonical RNG mirror faster than the quiescent-gated push could catch
# up, and the host's gate loop eventually timed out and set NET_DROPPED.
# $0168 is written only on a genuine fresh disc dispatch and not
# consulted by any ongoing per-tick logic (unlike $0166/$0167, which
# L_6415's settle/AI path shares) -- corrupting it is a one-shot,
# contained state corruption, not an ongoing control-flow divergence.
#
# Expected: CRC mismatch detected, the host pushes the state image
# (broadcast), ALL consoles re-baseline together, CRC rounds go back to
# matching, nobody drops.  PLAYERS fixed at 2 (this cart hard-caps there).
set -e
. "$(dirname "$0")/serverlib.sh"
BUILD=build
RIG="$BUILD/rig"
JZINTV="${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}"
RUN_SECS="${RUN_SECS:-100}"
PLAYERS="${PLAYERS:-2}"

i=1
while [ "$i" -le "$PLAYERS" ]; do
    [ -d "$RIG/fn$i" ] || { echo "run 'make rig PLAYERS=$PLAYERS' once first"; exit 1; }
    i=$((i+1))
done

# Same guard as run_rig.sh: never point fuzz clients at production.
if ! grep -q '127\.0\.0\.1' "$BUILD/srv_endpoint.asm" 2>/dev/null; then
    echo "run_m4.sh: build/srv_endpoint.asm is not 127.0.0.1 -- rebuild first"
    exit 1
fi

# Stale rig fujinet instances hold the BOIP ports and make every later
# launch a silent no-op (the fresh copy fails to bind and dies).
pkill -f 'fujinet -u 127.0.0.1:1808' 2>/dev/null || true
sleep 0.5
FNS=""
i=1
while [ "$i" -le "$PLAYERS" ]; do
    ( cd "$RIG/fn$i" && exec ./fujinet -u 127.0.0.1:1808$i ) > "$RIG/fn$i.log" 2>&1 &
    FNS="$FNS $!"
    i=$((i+1))
done
( relay_server --port 9113 --auto-go "$PLAYERS" ) \
    > "$RIG/m4_server.log" 2>&1 &
SRV=$!
trap 'kill $FNS $SRV 2>/dev/null || true' EXIT
sleep 1.5

# The debugger's `r N` counts INSTRUCTIONS (~4.6 cycles each on average),
# so ~200000 instructions per emulated second.  Console 2 gets the fault
# poke at ~40s (well past matchmaking at any player count); every console
# gets the stagger-compensated run length so all quit together.
CONS=""
i=1
while [ "$i" -le "$PLAYERS" ]; do
    SECS=$(( RUN_SECS - 2 * (i - 1) ))
    {
        printf 'b 14D5\nr 10000000\n'
        j=1
        while [ "$j" -lt "$i" ]; do
            printf 'n 14D5\nr %d\nb 14D5\nr 10000000\n' $((0x49BF0 + i * 4369))
            j=$((j+1))
        done
        printf 'g 7 14D7\nn 14D5\n'
        if [ "$i" = 1 ] && [ -n "$QUIESCE" ]; then
            # QUIESCE=1: starting when the fault lands (matching console
            # 2's timing below), keep FORCING the HOST's MOB "alive" bits
            # dead -- $031D and $0325 bit $0800 clear (0), $0323/$032B
            # zero -- repeatedly across a wide window.
            #
            # FIRST ATTEMPT forced SS_QUIESCENT ($81AF, the DERIVED flag)
            # directly instead -- root-caused live (spikes/NOTES.md M8)
            # to be structurally unable to work: SS_GAME_TICK (src/
            # hook.asm) recomputes SS_QUIESCENT FRESH every single tick,
            # from the real MOB bits, BEFORE RS_PENDING ever reads it in
            # that same tick's LS_PASS flow -- an external debugger poke
            # landing between ticks is therefore always overwritten by
            # the very next tick's real computation before RS_PENDING can
            # observe it, no matter how the forcing loop's timing is
            # tuned. Forcing the UNDERLYING condition instead means
            # SS_GAME_TICK's own real computation naturally reproduces
            # SS_QUIESCENT=1 every tick for as long as the forcing holds,
            # which is what actually lets RS_PENDING observe it.  This
            # also serves as the M1b/M1c MOB-bit hypothesis's first live
            # confirmation, not just a workaround.
            #
            # Same reason for repeated forcing as the family precedent
            # (Sea Battle's forced pair): a one-shot poke does not
            # reliably land, because CRC comparison (and therefore
            # RS_PENDING actually polling) only happens on 64-tick
            # boundaries and RS_PEND_MAX is only 60 ticks, so a narrow
            # window can miss it entirely.  RS_PENDING checks
            # SC_PHASE/SC_PHASE_DEAD FIRST and pushes IMMEDIATELY if
            # quiescent -- forcing the underlying bits continuously
            # guarantees any push that becomes pending during the window
            # takes the quiescent branch.
            #
            # WIDENED to ~50s (from an initial 15s that missed, spikes/
            # NOTES.md M8): the fault below (SS_PCOUNT, immediate and
            # reliable -- see its own comment) still needs a CRC
            # comparison cycle to actually detect it, and the wider
            # window gives ample margin.  Left deliberately short of the
            # full remaining run (leaves ~10s of clean tail) so the
            # session still demonstrates a genuinely settled end state,
            # not an artificially-held one forever (the Sea Battle
            # precedent's own hard-won lesson).
            printf 'r 8000000\n'
            k=0
            while [ "$k" -lt 200 ]; do
                printf 'e 31D 0\ne 325 0\ne 323 0\ne 32B 0\nr 50000\n'
                k=$((k+1))
            done
            # Capture RS_GATE right here, before any LATER (organic)
            # push has a chance to overwrite it -- it is a single cell
            # holding only the reason for the MOST RECENT push.
            printf 'm 818A 1\n'
            printf 'r %d\n' $(( (SECS - 40 - 50) * 200000 ))
        elif [ "$i" = 2 ] && [ -n "$QUIESCE" ]; then
            # QUIESCE mode uses SS_PCOUNT ($0172), not $0168: LS_CKSUM
            # checksums every cell in $015D-$01EF UNCONDITIONALLY each
            # comparison, so in principle either fault shows up on the
            # very next CRC check regardless of whether game logic ever
            # reads it -- but $0168 gets legitimately REWRITTEN by ordinary
            # fuzz-driven disc dispatch often enough (P1's next fresh
            # press) that it can get silently overwritten back to a normal
            # value before that next check ever happens, especially within
            # a run this short (confirmed live, spikes/NOTES.md M8: a
            # QUIESCE run saw 0 mismatches all run with the $0168 fault).
            # SS_PCOUNT has no such window -- nothing rewrites it during
            # play -- so it reliably shows up immediately, which is what
            # this test actually needs (a mismatch inside the wide forcing
            # window below, not eventually via random fuzz luck).  The
            # ongoing-divergence risk that made it the WRONG choice for
            # the plain (unforced) test is exactly what QUIESCE's wide,
            # early forcing window is now sized to outrun.
            printf 'r 8000000\ne 172 1\nr %d\n' $(( (SECS - 40) * 200000 ))
        elif [ "$i" = 2 ]; then
            # Fault: rewrite console 2's $0168 (P1's disc-heading echo) to
            # $77 -- outside the 0-15 range any real disc dispatch or
            # masked ($3F) fuzz can ever produce, so "does it still read
            # $77" is an unambiguous repair check (Golf's own convention).
            # Inside the CRC range $015D-$01EF; see this file's header
            # comment for why $0172 was tried first and rejected for the
            # PLAIN (unforced) test -- QUIESCE mode uses it instead, above,
            # for the opposite reason (its immediacy is a feature there).
            printf 'r 8000000\ne 168 77\nr %d\n' $(( (SECS - 40) * 200000 ))
        else
            printf 'r %d\n' $(( SECS * 200000 ))
        fi
        printf 'm 8100 20\nm 8150 60\nm 80C0 2\nm 8180 10\nm 8090 10\nm 0160 20\nm 031D 10\n'
        printf 'q\n'
    } > "$RIG/m4c$i.scr"
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
        timeout $((RUN_SECS + 200)) "$JZINTV" -d --script="$RIG/m4c$i.scr" \
        --fujinet=localhost:1985$i -e rom/exec.bin -g rom/grom.bin \
        "$BUILD/sharkshark_net$i.bin" > "$RIG/m4c$i.out" 2>&1 &
    CONS="$CONS $!"
    sleep 2
    i=$((i+1))
done
wait $CONS || true

PLAYERS=$PLAYERS python3 - "$RIG" <<'EOF'
import os, re, sys
rig = sys.argv[1]
players = int(os.environ["PLAYERS"])
SS_HTBL_PROMPT = 0x5185
SS_HTBL_LIVE = 0x5193
SS_HTBL_NULL = 0x1906
SS_HTBL_PLAYAGAIN = 0x629C

def cells(path):
    mem = {}
    for m in re.finditer(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#",
                         open(path).read(), re.M):
        a = int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            mem[a + i] = int(w.rstrip("*"), 16)
    return mem

def first_reading(path, addr):
    """The FIRST time `addr` was dumped in `path`, not the last -- for
    cells like RS_GATE ($818A) that get overwritten by a later, unrelated
    push before the run ends."""
    for m in re.finditer(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#",
                         open(path).read(), re.M):
        a = int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            if a + i == addr:
                return int(w.rstrip("*"), 16)
    return None

ok = True
for n in range(1, players + 1):
    m = cells(f"{rig}/m4c{n}.out")
    tick = m.get(0x8108, 0) | (m.get(0x8109, 0) << 8)
    active, dropped, hold = m.get(0x8162, 0), m.get(0x8163, 0), m.get(0x8090, 9)
    diag = [m.get(0x8180 + i, 0) for i in range(4)]
    pend, waited = m.get(0x8187, 0), m.get(0x8189, 0)
    seat = m.get(0x8160, 9)
    why = m.get(0x818A, 0)
    gtbl = m.get(0x80C0, 0) | (m.get(0x80C1, 0) << 8)
    gate = "n/a (guest)" if seat else {
        0: "never pushed",
        1: f"QUIESCENT (SS_QUIESCENT forced) after {waited} ticks",
        2: f"cap expired at {waited} ticks (pushed mid-play)"}.get(why, "?")
    print(f"console {n}: seat={seat} active={active} dropped={dropped} "
          f"hold={hold} tick={tick} diag(slip,rej,tmo,err)={diag}")
    print(f"           resync gate: pending={pend} GAME_TBL=${gtbl:04X} -> {gate}")
    ok &= (active == 1 and dropped == 0 and hold == 0 and tick > 400
           and diag == [0, 0, 0, 0])
    # Destination-phase assertion (§7.25): same signals as
    # check_dest_phase.py and the rig verdict -- the player-count prompt
    # was answered and GAME_TBL moved off it.
    pcount = m.get(0x172, 0)
    mob0 = any(m.get(a, 0) for a in range(0x31D, 0x325))
    mob1 = any(m.get(a, 0) for a in range(0x325, 0x32D))
    print(f"           pcount={pcount} mob0={mob0} mob1={mob1}")
    if gtbl == SS_HTBL_PROMPT:
        print(f"console {n}: PARKED ON THE PLAYER-COUNT PROMPT -- every "
              f"dump agrees trivially")
        ok = False
    elif gtbl not in (SS_HTBL_LIVE, SS_HTBL_NULL, SS_HTBL_PLAYAGAIN):
        print(f"console {n}: GAME_TBL=${gtbl:04X} is none of LIVE/NULL/"
              f"PLAYAGAIN -- unexpected destination")
        ok = False
    if not (mob0 and mob1):
        print(f"console {n}: MOB0={mob0} MOB1={mob1} -- one seat's diver "
              f"was never populated")
        ok = False
    # The fault itself. QUIESCE mode pokes $0172 (SS_PCOUNT) 2 -> 1;
    # the plain test pokes $0168 to $77 (outside the 0-15 range any real
    # disc dispatch or masked fuzz can ever produce -- see this file's
    # header/fault-site comments for why each mode uses a different one).
    # By the end of a successful recovery neither fault value should
    # still be present on EITHER console -- a resync that only fixed the
    # CRC bookkeeping but left the actual corrupted byte in place would
    # be a false pass.
    if os.environ.get("QUIESCE"):
        if gtbl == SS_HTBL_LIVE and pcount != 2:
            print(f"console {n}: SS_PCOUNT is still the fault value "
                  f"{pcount} (expected 2) -- not actually repaired")
            ok = False
    heading0 = m.get(0x168)
    if heading0 == 0x77:
        print(f"console {n}: $0168 is still the fault value $77 -- "
              f"not actually repaired")
        ok = False

# QUIESCE=1 exists to prove the quiescent branch works at all; require it.
if os.environ.get("QUIESCE"):
    host_why = first_reading(f"{rig}/m4c1.out", 0x818A)
    if host_why != 1:
        print(f"QUIESCE run: host RS_GATE={host_why}, expected 1 (quiescent) "
              f"-- the dead-ball branch of RS_PENDING did not fire")
        ok = False
    else:
        print("QUIESCE run: the dead-ball branch of RS_PENDING fired as intended")

lines = open(f"{rig}/m4_server.log").read().splitlines()
mm = [i for i, l in enumerate(lines) if "CRC MISMATCH" in l]
oks = [i for i, l in enumerate(lines) if "crc ok" in l]
recovered = bool(mm) and bool(oks) and max(oks) > max(mm)
print(f"server: mismatches={len(mm)} crc-ok-lines={len(oks)} "
      f"recovered-after-fault={recovered}")
ok &= recovered
print(f"M4 PASS ({players} players)" if ok else "M4 FAIL")
sys.exit(0 if ok else 1)
EOF
