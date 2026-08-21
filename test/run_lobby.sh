#!/bin/sh
# Matchmaking-UI test (M7b), both seats of the room flow:
#   Phase 1 (guest): interactive console against three parked players, two
#   of them in a STARTED room (dimmed, ENTER refused).  The console
#   cursors to the idle one, ENTER-joins it (-> waiting room, guest
#   line), and the idler host GOes -> START -> matched roster screen.
#   Phase 2 (host): a hunter idler joins the console's own room; the
#   console sees the GO hint, injected ENTER sends GO -> seat 0.
# Menu keys are injected by breaking after the menu's port read and
# forcing R0; screens are decoded from BACKTAB (text + colour).
set -e
. "$(dirname "$0")/serverlib.sh"
BUILD=build
RIG="$BUILD/rig"
JZINTV="${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}"

[ -d "$RIG/fn1" ] || { echo "run 'make rig' once first (creates fn1)"; exit 1; }
if ! grep -q '127\.0\.0\.1' "$BUILD/srv_endpoint.asm" 2>/dev/null; then
    echo "run_lobby.sh: build/srv_endpoint.asm is not 127.0.0.1 -- rebuild first"
    exit 1
fi

pkill -f 'fujinet -u 127.0.0.1:1808' 2>/dev/null || true
sleep 0.5
( cd "$RIG/fn1" && exec ./fujinet -u 127.0.0.1:18081 ) > "$RIG/fn1.log" 2>&1 &
FN1=$!
( relay_server --port 9113 ) > "$RIG/lb_server.log" 2>&1 &
SRV=$!
trap 'kill $FN1 $SRV $IDLERS 2>/dev/null || true' EXIT
sleep 1.5
python3 test/lobby_idlers.py ALPHA BRAVO CHARLIE --pair \
    --go-name CHARLIE --go-delay 10 > "$RIG/lb_idlers.log" 2>&1 &
IDLERS=$!
sleep 0.5

# A keypress is injected by breaking on the instruction right after the menu's
# `MVI $1FF,R0 / XORI #$FF,R0` and forcing R0 to the value the port would have
# produced; poking $01FF itself does not reach the emulated pad.
MENU_RD=$(awk '/CMP  *MENU_PREV, R0/ {print $1; exit}' "$BUILD/sharkshark_net.lst")
[ -n "$MENU_RD" ] || { echo "run_lobby.sh: cannot find MENU_PREV compare"; exit 1; }
echo "menu read site: \$$MENU_RD"
HOLD_ADDR=$(awk '/ SES_HOLD$/ { sub(/^0+/, "", $1); print $1 }' "$BUILD/sharkshark_net.sym")
[ -n "$HOLD_ADDR" ] || { echo "run_lobby.sh: cannot find SES_HOLD"; exit 1; }
echo "matched-screen hold: \$$HOLD_ADDR"
KEY8=44         # keypad 8   = down
KEYE=28         # ENTER
DISC_S=01       # disc south = down
DISC_N=04       # disc north = up

press() {       # $1 = raw value: stop at the read, force it, resume
    printf 'b %s\nr 10000000\ng 0 %s\nn %s\nr 100000\n' "$MENU_RD" "$1" "$MENU_RD"
}

{
    printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\n'
    # `m 200 F0` opens a snapshot; the cell dumps for a step must follow it
    printf 'r 4000000\nm 200 F0\nm 815A 4\n'            # lobby up
    press "$KEYE"; printf 'm 200 F0\nm 815A 4\n'        # ENTER on busy ALPHA
    press "$DISC_S"; printf 'm 200 F0\nm 815A 4\n'      # disc down -> BRAVO
    press "$DISC_N"; printf 'm 200 F0\nm 815A 4\n'      # disc up   -> ALPHA
    press "$KEY8"; press "$KEY8"                        # keypad down x2 -> CHARLIE
    printf 'm 200 F0\nm 815A 4\n'
    press "$KEYE"; printf 'r 600000\n'                  # join CHARLIE
    printf 'm 200 F0\nm 815A 4\nm 81AA 3\n'             # waiting room (guest)
    printf 'b %s\nr 30000000\nn %s\n' "$HOLD_ADDR" "$HOLD_ADDR"     # host GOes
    printf 'm 200 F0\nm 8160 4\nm 81C0 30\nm 819D 2\n'  # matched screen
    printf 'q\n'
} > "$RIG/lb1.scr"

SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout 240 "$JZINTV" -d --script="$RIG/lb1.scr" \
    --fujinet=localhost:19851 -e rom/exec.bin -g rom/grom.bin \
    "$BUILD/sharkshark_net.bin" > "$RIG/lb1.out" 2>&1 || true

python3 - "$RIG/lb1.out" guest <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()

snaps, sels, cur, seen = [], [], {}, False
for m in re.finditer(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#", text, re.M):
    a = int(m.group(1), 16)
    words = [int(w.rstrip("*"), 16) for w in m.group(2).split()]
    if a <= 0x815A < a + len(words):
        sels.append(words[0x815A - a])
    if a <= 0x200 < a + len(words) and seen:
        snaps.append(cur)
        cur = {}
    if a <= 0x200 < a + len(words):
        seen = True
    for i, w in enumerate(words):
        cur[a + i] = w
snaps.append(cur)

COLNAME = {0: "black", 1: "BLUE", 2: "RED", 3: "TAN", 4: "DKGRN", 5: "GREEN",
           6: "yellow", 7: "white"}

def rowtc(mem, r, from_col=0):
    s, cols = "", set()
    for c in range(20):
        w = mem.get(0x200 + r * 20 + c, 0)
        ch = ((w >> 3) & 0x3F) + 32
        s += chr(ch) if 32 <= ch < 127 else " "
        if ch != 32 and c >= from_col:
            cols.add(w & 7)
    return s.rstrip(), cols

def show(mem, label):
    print(f"--- {label}")
    for r in range(12):
        s, cols = rowtc(mem, r)
        if not s:
            continue
        tag = "/".join(COLNAME.get(c, str(c)) for c in sorted(cols))
        print(f"  {r:2d} |{s:<20}|  {tag}")

labels = ["lobby up", "ENTER on busy ALPHA", "disc down -> BRAVO",
          "disc up -> ALPHA", "keypad down x2 -> CHARLIE",
          "join CHARLIE (waiting room)", "matched (after host GO)"]
for i, mem in enumerate(snaps):
    show(mem, labels[i] if i < len(labels) else str(i))
print(f"--- MENU_SEL over time: {sels}")

ok = True
def check(cond, msg):
    global ok
    ok &= bool(cond)
    print(("  PASS  " if cond else "  FAIL  ") + msg)

print("--- checks")
first = snaps[0]
prompt, _ = rowtc(first, 3)
check("ENTER" in prompt and "DISC" in prompt,
      f"prompt survives the lobby refresh (row 3 = {prompt!r})")
t_alpha, c_alpha = rowtc(first, 4, from_col=2)
t_charlie, c_charlie = rowtc(first, 6, from_col=2)
check(c_alpha == {0} and "ALPHA" in t_alpha,
      f"ALPHA (started room) renders dimmed: {t_alpha!r} {sorted(c_alpha)}")
check(7 in c_charlie and "CHARLIE" in t_charlie,
      f"CHARLIE (idle) renders white: {t_charlie!r} {sorted(c_charlie)}")
busy, _ = rowtc(snaps[1], 3)
check("ALREADY" in busy, f"ENTER on a busy player says so (row 3 = {busy!r})")
check(sels[:5] == [0, 0, 1, 0, 2],
      f"disc down/up and keypad down move the cursor, got {sels[:5]}")
room = snaps[5]
rr, _ = rowtc(room, 1)
gl, _ = rowtc(room, 9)
check("WAITING ROOM" in rr and "2" in rr,
      f"waiting room screen up: row1 = {rr!r}")
check("WAITING FOR HOST" in gl,
      f"guest sees the wait line: row9 = {gl!r}")
check(room.get(0x81AA) == 2 and room.get(0x81AB) == 0,
      f"ROOM_CNT={room.get(0x81AA)} ROOM_HOST={room.get(0x81AB)} (guest of 2)")
last = snaps[-1]
seat, active = last.get(0x8160), last.get(0x8162)
count = last.get(0x819D)
roster = ["".join(chr(last.get(0x81C0 + 9 * s + i, 0)) for i in range(8)).rstrip("\0")
          for s in range(count or 0)]
check(active == 1 and seat == 1 and count == 2 and roster == ["CHARLIE", "GUEST47"],
      f"START: seat={seat} count={count} roster={roster}")
r3, c3 = rowtc(last, 3, from_col=4)
r4, c4 = rowtc(last, 4, from_col=4)
you, _ = rowtc(last, 9)
# Seat colours are this cart's team colours (session.asm SEAT_CLR_TBL):
# seat 0 = YELLOW (6), seat 1 = WHITE (7), derived from the cart's own
# init XORs $0006 / $0017 into the two teams' MOB records.
check("CHARLIE" in r3 and 6 in c3, f"roster row 1 YELLOW CHARLIE: {r3!r} {sorted(c3)}")
check("GUEST" in r4 and 7 in c4, f"roster row 2 WHITE GUEST47: {r4!r} {sorted(c4)}")
check("YOU ARE PLAYER" in you and "2" in you, f"seat line: {you!r}")

print("LOBBY GUEST PASS" if ok else "LOBBY GUEST FAIL")
sys.exit(0 if ok else 1)
PYEOF

# ---- phase 2: host ---------------------------------------------------------
kill $IDLERS 2>/dev/null || true
{
    printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\n'
    printf 'r 4000000\n'                                # lobby up, DELTA joins
    printf 'r 2000000\nm 200 F0\nm 81AA 3\n'            # waiting room (host)
    # Arm the SES_HOLD breakpoint BEFORE the ENTER press: the START can
    # arrive inside the press's own resume, and a breakpoint set after
    # the console is already holding never fires (the game then runs
    # unfed and paints CONNECTION LOST -- seen live).
    printf 'b %s\n' "$HOLD_ADDR"
    printf 'b %s\nr 10000000\ng 0 %s\nn %s\n' "$MENU_RD" "$KEYE" "$MENU_RD"
    printf 'r 30000000\nn %s\n' "$HOLD_ADDR"            # ENTER = GO -> hold
    printf 'm 200 F0\nm 8160 4\nm 81C0 30\nm 819D 2\n'  # matched screen
    printf 'q\n'
} > "$RIG/lb2.scr"

# Console FIRST: fujinet-pc holds the previous run's TCP session open for a
# while, so the server still has a stale GUEST47.  The console's new HELLO
# evicts it -- only then may the hunter start, or it JOINs the ghost and
# becomes host of the wrong room.
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout 240 "$JZINTV" -d --script="$RIG/lb2.scr" \
    --fujinet=localhost:19851 -e rom/exec.bin -g rom/grom.bin \
    "$BUILD/sharkshark_net.bin" > "$RIG/lb2.out" 2>&1 &
C2=$!
sleep 8
python3 test/lobby_idlers.py DELTA --join-guest GUEST > "$RIG/lb_idlers2.log" 2>&1 &
IDLERS=$!
wait $C2 || true

python3 - "$RIG/lb2.out" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
snaps, cur, seen = [], {}, False
for m in re.finditer(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#", text, re.M):
    a = int(m.group(1), 16)
    words = [int(w.rstrip("*"), 16) for w in m.group(2).split()]
    if a <= 0x200 < a + len(words) and seen:
        snaps.append(cur); cur = {}
    if a <= 0x200 < a + len(words):
        seen = True
    for i, w in enumerate(words):
        cur[a + i] = w
snaps.append(cur)

def rowtc(mem, r, from_col=0):
    s = ""
    for c in range(20):
        w = mem.get(0x200 + r * 20 + c, 0)
        ch = ((w >> 3) & 0x3F) + 32
        s += chr(ch) if 32 <= ch < 127 else " "
    return s.rstrip()

ok = True
def check(cond, msg):
    global ok
    ok &= bool(cond)
    print(("  PASS  " if cond else "  FAIL  ") + msg)

room = snaps[0]
for r in range(12):
    s = rowtc(room, r)
    if s: print(f"  {r:2d} |{s}|")
check("WAITING ROOM" in rowtc(room, 1), f"host waiting room: {rowtc(room,1)!r}")
check("ENTER = START" in rowtc(room, 9), f"host GO hint: {rowtc(room,9)!r}")
check(room.get(0x81AA) == 2 and room.get(0x81AB) == 1,
      f"ROOM_CNT={room.get(0x81AA)} ROOM_HOST={room.get(0x81AB)} (host of 2)")
last = snaps[-1]
for r in range(12):
    s = rowtc(last, r)
    if s: print(f"  {r:2d} |{s}|")
seat, active, count = last.get(0x8160), last.get(0x8162), last.get(0x819D)
roster = ["".join(chr(last.get(0x81C0 + 9 * s + i, 0)) for i in range(8)).rstrip("\0")
          for s in range(count or 0)]
check(active == 1 and seat == 0 and count == 2 and roster[1] == "DELTA",
      f"GO started the match: seat={seat} count={count} roster={roster}")
check("YOU ARE PLAYER" in rowtc(last, 9) and "1" in rowtc(last, 9),
      f"seat line: {rowtc(last,9)!r}")
print("LOBBY HOST PASS" if ok else "LOBBY HOST FAIL")
sys.exit(0 if ok else 1)
PYEOF
echo "--- server log:"
tail -5 "$RIG/lb_server.log"
