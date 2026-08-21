#!/bin/sh
# Full local 2-player rig (PLAYERS fixed at 2 -- this cart hard-caps there), headless:
#   Nx fujinet-pc-rs232 (isolated copies, BOIP :19851..:1985N)
#   1x intv_relay_server (:9113, --auto-go N)
#   Nx jzintv --fujinet (net1 waits; net2..netN auto-join), fuzz inputs
# Pass criteria: every console NET_ACTIVE with matching seat/count, ticks
# advance, DIAG counters zero, N-way CRC rounds verified, no mismatches.
set -e
. "$(dirname "$0")/serverlib.sh"
BUILD=build
RIG="$BUILD/rig"
PLAYERS="${PLAYERS:-2}"

# Refuse to run rig binaries built against anything but the local server:
# fuzz inputs must never reach production.
if ! grep -q '127\.0\.0\.1' "$BUILD/srv_endpoint.asm" 2>/dev/null; then
    echo "run_rig.sh: build/srv_endpoint.asm is not 127.0.0.1 -- rebuild with"
    echo "  make SRV_HOST=127.0.0.1 build/sharkshark_net1.bin ..."
    exit 1
fi
JZINTV="${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}"
FNPC_DIST="${FNPC_DIST:-$HOME/Workspace/fujinet-pc-rs232/build/dist}"
RUN_SECS="${RUN_SECS:-90}"

# ---- fujinet-pc instances -------------------------------------------------
i=1
while [ "$i" -le "$PLAYERS" ]; do
    if [ ! -d "$RIG/fn$i" ]; then
        mkdir -p "$RIG/fn$i"
        cp -r "$FNPC_DIST"/. "$RIG/fn$i/"
        rm -rf "$RIG/fn$i/SD"
        mkdir -p "$RIG/fn$i/SD"
        python3 - "$RIG/fn$i/fnconfig.ini" "1985$i" <<'EOF'
import re, sys
path, port = sys.argv[1], sys.argv[2]
s = open(path).read()
s2, n = re.subn(r"(\[BOIP\][^\[]*?port=)[0-9]*", r"\g<1>" + port, s, count=1, flags=re.S)
assert n == 1, "BOIP port not patched"
open(path, "w").write(s2)
EOF
    fi
    i=$((i+1))
done

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
    > "$RIG/server.log" 2>&1 &
SRV=$!
trap 'kill $FNS $SRV 2>/dev/null || true' EXIT
sleep 1.5

# ---- console debugger scripts --------------------------------------------
# Console N stirs the title RNG (N-1) extra bursts so every GUESTnn name
# and fuzz seed differs (headless runs are otherwise identical).
CONS=""
i=1
while [ "$i" -le "$PLAYERS" ]; do
    {
        printf 'b 14D5\nr 10000000\n'
        j=1
        while [ "$j" -lt "$i" ]; do
            printf 'n 14D5\nr %d\nb 14D5\nr 10000000\n' $((0x49BF0 + i * 4369))
            j=$((j+1))
        done
        # Later consoles launch 2 s apart; shorten their runs so everyone
        # quits at about the same wall moment (a console outliving its
        # peers by more than the gate timeout would count a bogus drop).
        printf 'g 7 14D7\nn 14D5\nr %d\nm 8100 20\nm 8150 60\nm 81C0 30\nm 80C0 2\nm 0160 20\nm 031D 10\nq\n' \
            $(( (RUN_SECS - 2 * (i - 1)) * 200000 ))
    } > "$RIG/c$i.scr"
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
        timeout $((RUN_SECS + 200)) "$JZINTV" -d --script="$RIG/c$i.scr" \
        --fujinet=localhost:1985$i -e rom/exec.bin -g rom/grom.bin \
        "$BUILD/sharkshark_net$i.bin" > "$RIG/c$i.out" 2>&1 &
    CONS="$CONS $!"
    sleep 2
    i=$((i+1))
done
wait $CONS || true

# ---- verdict --------------------------------------------------------------
PLAYERS=$PLAYERS python3 - "$RIG" <<'EOF'
import os, re, sys
rig = sys.argv[1]
players = int(os.environ["PLAYERS"])

def cells(path):
    mem = {}
    for m in re.finditer(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#",
                         open(path).read(), re.M):
        a = int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            mem[a + i] = int(w.rstrip("*"), 16)
    return mem

ok = True
seats = set()
for n in range(1, players + 1):
    m = cells(f"{rig}/c{n}.out")
    tick = m.get(0x8108, 0) | (m.get(0x8109, 0) << 8)
    name = "".join(chr(m.get(0x8150 + i, 0)) for i in range(8)).rstrip("\0")
    active, dropped = m.get(0x8162, 0), m.get(0x8163, 0)
    seat, count = m.get(0x8160, 9), m.get(0x819D, 0)
    # DIAG_SLIP/REJ/TMO/ERR: a healthy session must not resync its framing,
    # refuse a state chunk, or time out a mailbox transaction even once.
    diag = [m.get(0x8180 + i, 0) for i in range(4)]
    roster = ["".join(chr(m.get(0x81C0 + 9 * s + i, 0)) for i in range(8)).rstrip("\0")
              for s in range(count)]
    gtbl = m.get(0x80C0, 0) | (m.get(0x80C1, 0) << 8)
    pcount = m.get(0x172, 0)
    mob0 = any(m.get(a, 0) for a in range(0x31D, 0x325))
    mob1 = any(m.get(a, 0) for a in range(0x325, 0x32D))
    print(f"console {n}: name={name!r} seat={seat} count={count} "
          f"active={active} dropped={dropped} tick={tick} "
          f"diag(slip,rej,tmo,err)={diag} GAME_TBL=${gtbl:04X} "
          f"pcount={pcount} mob0={mob0} mob1={mob1} roster={roster}")
    seats.add(seat)
    ok &= (active == 1 and dropped == 0 and tick > 200
           and diag == [0, 0, 0, 0] and count == players)
    # Destination-phase assertion (PORTING.md §5.5, §7.25).  Any multi-console
    # gate can park identically in a prompt exactly as a det pair can.  This
    # rig build runs masked $3F disc-only fuzz (NET_FUZZ), which can never
    # produce a keypad digit or ENTER on its own -- but the "SELECT 1 OR 2
    # PLAYERS" prompt is answered independently by SS_INJECT (sim-state-
    # driven, not input-driven, src/hook.asm), confirmed live (M3) to get a
    # fuzz-only run all the way into real play with BOTH MOBs populated.
    # So this rig CAN and must assert real progress on both seats.
    #
    # REVISED (M7): fuzz is reckless enough that both divers can legitimately
    # get caught well inside a 100s run -- GAME_TBL landing on SS_HTBL_NULL
    # or SS_HTBL_PLAYAGAIN (game over) is ALSO real-gameplay evidence, and
    # SS_PCOUNT is only meaningful while still in SS_HTBL_LIVE.
    SS_HTBL_PROMPT = 0x5185
    SS_HTBL_LIVE = 0x5193
    SS_HTBL_NULL = 0x1906
    SS_HTBL_PLAYAGAIN = 0x629C
    if gtbl == SS_HTBL_LIVE and not (1 <= pcount <= 2):
        print(f"console {n}: PCOUNT ${pcount:02X} OUT OF RANGE -- the "
              f"player-count prompt was never answered")
        ok = False
    if gtbl == SS_HTBL_PROMPT:
        print(f"console {n}: PARKED ON THE PLAYER-COUNT PROMPT "
              f"(GAME_TBL=$5185) -- every dump agrees trivially")
        ok = False
    elif gtbl not in (SS_HTBL_LIVE, SS_HTBL_NULL, SS_HTBL_PLAYAGAIN):
        print(f"console {n}: GAME_TBL=${gtbl:04X} is none of LIVE/NULL/"
              f"PLAYAGAIN -- unexpected destination")
        ok = False
    if not mob0:
        print(f"console {n}: MOB0 ($031D-$0324, seat 0) never populated")
        ok = False
    if not mob1:
        print(f"console {n}: MOB1 ($0325-$032C, seat 1) never populated -- "
              f"a cross-seat routing bug looks exactly like this (M1c)")
        ok = False
ok &= seats == set(range(players))
if seats != set(range(players)):
    print(f"seat coverage wrong: {sorted(seats)}")

log = open(f"{rig}/server.log").read()
mm = log.count("CRC MISMATCH")
rounds = max([int(x) for x in
              re.findall(r"\((\d+) rounds\)", log)] or [0])
print("server: match" if "match: room" in log else "server: NO MATCH",
      f"crc_mismatches={mm} crc_rounds={rounds}")
ok &= "match: room" in log and mm == 0 and rounds > 0
print(f"RIG PASS ({players} players)" if ok else "RIG FAIL")
sys.exit(0 if ok else 1)
EOF
