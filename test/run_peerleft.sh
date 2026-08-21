#!/bin/sh
# Drop test: the N-player rig, but one console quits mid-game.  Any drop
# ends the match for EVERYONE (user decision): every survivor must notice
# (server PEER_LEFT frame or its own gate timeout), freeze the sim and
# paint the terminal screen naming who left.  Verdict decodes every
# survivor's BACKTAB and requires the mode-appropriate notice + the
# leaver's lobby name + PRESS RESET.
#   PLAYERS fixed at 2 (this cart hard-caps there), LEAVER=console index (default 2)
#   LEAVE_MODE=clean   kill emulator + its FujiNet -> server PEER_LEFT
#                      (expect "PLAYER LEFT" + name)
#   LEAVE_MODE=timeout kill only the emulator; fujinet-pc holds the TCP
#                      session open -> survivors notice by themselves
#                      ("CONNECTION LOST")
set -e
. "$(dirname "$0")/serverlib.sh"
BUILD=build
RIG="$BUILD/rig"
JZINTV="${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}"
RUN_SECS="${RUN_SECS:-90}"
LEAVE_SECS="${LEAVE_SECS:-45}"
LEAVE_MODE="${LEAVE_MODE:-clean}"
PLAYERS="${PLAYERS:-2}"
LEAVER="${LEAVER:-2}"

i=1
while [ "$i" -le "$PLAYERS" ]; do
    [ -d "$RIG/fn$i" ] || { echo "run 'make rig PLAYERS=$PLAYERS' once first"; exit 1; }
    i=$((i+1))
done
if ! grep -q '127\.0\.0\.1' "$BUILD/srv_endpoint.asm" 2>/dev/null; then
    echo "run_peerleft.sh: build/srv_endpoint.asm is not 127.0.0.1 -- rebuild first"
    exit 1
fi

pkill -f 'fujinet -u 127.0.0.1:1808' 2>/dev/null || true
sleep 0.5
i=1
while [ "$i" -le "$PLAYERS" ]; do
    ( cd "$RIG/fn$i" && exec ./fujinet -u 127.0.0.1:1808$i ) > "$RIG/fn$i.log" 2>&1 &
    eval "FN$i=\$!"
    i=$((i+1))
done
( relay_server --port 9113 --auto-go "$PLAYERS" ) \
    > "$RIG/pl_server.log" 2>&1 &
SRV=$!
trap 'pkill -f "fujinet -u 127.0.0.1:1808" 2>/dev/null; kill $SRV 2>/dev/null || true' EXIT
sleep 1.5

i=1
while [ "$i" -le "$PLAYERS" ]; do
    {
        printf 'b 14D5\nr 10000000\n'
        j=1
        while [ "$j" -lt "$i" ]; do
            printf 'n 14D5\nr %d\nb 14D5\nr 10000000\n' $((0x49BF0 + i * 4369))
            j=$((j+1))
        done
        printf 'g 7 14D7\nn 14D5\nr %d\n' $(( (RUN_SECS - 2 * (i - 1)) * 200000 ))
        printf 'm 200 F0\nm 8160 8\nm 8185 2\nm 8180 4\nm 81B0 9\nq\n'
    } > "$RIG/plc$i.scr"
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
        timeout $((RUN_SECS + 200)) "$JZINTV" -d --script="$RIG/plc$i.scr" \
        --fujinet=localhost:1985$i -e rom/exec.bin -g rom/grom.bin \
        "$BUILD/sharkshark_net$i.bin" > "$RIG/plc$i.out" 2>&1 &
    eval "C$i=\$!"
    sleep 2
    i=$((i+1))
done

sleep "$LEAVE_SECS"
echo "console $LEAVER leaving at t+${LEAVE_SECS}s (mode: $LEAVE_MODE)"
eval "CK=\$C$LEAVER"; eval "FK=\$FN$LEAVER"
if [ "$LEAVE_MODE" = timeout ]; then
    kill $CK 2>/dev/null || true
else
    kill $CK $FK 2>/dev/null || true
fi

i=1
while [ "$i" -le "$PLAYERS" ]; do
    [ "$i" != "$LEAVER" ] && { eval "wait \$C$i" || true; }
    i=$((i+1))
done

PLAYERS=$PLAYERS LEAVER=$LEAVER LEAVE_MODE=$LEAVE_MODE python3 - "$RIG" <<'EOF'
import os, re, sys
rig = sys.argv[1]
players = int(os.environ["PLAYERS"])
leaver = int(os.environ["LEAVER"])
mode = os.environ.get("LEAVE_MODE", "clean")

def cells(path):
    mem = {}
    for m in re.finditer(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#",
                         open(path).read(), re.M):
        a = int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            mem[a + i] = int(w.rstrip("*"), 16)
    return mem

ok = True
want = "CONNECTION LOST" if mode == "timeout" else "PLAYER LEFT"
for n in range(1, players + 1):
    if n == leaver:
        continue
    m = cells(f"{rig}/plc{n}.out")
    rows = []
    for r in range(12):
        s = "".join(chr((m.get(0x200 + r * 20 + c, 0) >> 3) + 32)
                    if 32 <= (m.get(0x200 + r * 20 + c, 0) >> 3) + 32 < 127
                    else " " for c in range(20))
        rows.append(s.rstrip())
    screen = "\n".join(rows)
    scr, why = m.get(0x8185, 0), m.get(0x8186, 0)
    diag = [m.get(0x8180 + i, 0) for i in range(4)]
    lname = "".join(chr(m.get(0x81B0 + i, 0)) for i in range(8)).rstrip("\0")
    print(f"survivor {n}: PEER_SCR={scr} PEER_WHY={why} left_name={lname!r} "
          f"diag={diag}")
    for r in rows:
        if r:
            print(f"  |{r}|")
    good = scr == 1 and want in screen and "PRESS RESET" in screen
    if mode == "clean":
        good = good and why == 1 and lname and lname in screen
    if not good:
        print(f"survivor {n}: MISSING {want!r} / name / PRESS RESET")
    ok &= good
print(f"PEER-LEFT PASS ({mode}, {players} players)" if ok else "PEER-LEFT FAIL")
sys.exit(0 if ok else 1)
EOF
