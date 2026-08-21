#!/bin/sh
# M2/M3 headless integration: netplay console (jzintv --fujinet against the
# live fujinet-pc BOIP) + relay server + scripted ghost opponent.
# The ghost JOINs the console, so no controller input is needed.
set -e
. "$(dirname "$0")/serverlib.sh"
BUILD=build
JZINTV="${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}"
FN_BOIP="${FN_BOIP:-localhost:9995}"

( relay_server --port 9107 ) > "$BUILD/m2_server.log" 2>&1 &
SRV=$!
sleep 0.5
python3 tools/ghost_peer.py --port 9107 --want-ticks 300 \
    > "$BUILD/m2_ghost.log" 2>&1 &
GHOST=$!
trap 'kill $SRV 2>/dev/null || true; kill $GHOST 2>/dev/null || true' EXIT

SCR="$BUILD/m2.scr"
{
    printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\n'    # skip title wait
    printf 'r 60000000\n'                               # ~65s of session+play
    printf 'm 8108 2\nm 8160 8\nq\n'                    # tick + role/active cells
} > "$SCR"

SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout 100 "$JZINTV" -d --script="$SCR" --fujinet="$FN_BOIP" \
    -e rom/exec.bin -g rom/grom.bin "$BUILD/frogbog_net.bin" \
    > "$BUILD/m2_run.out" 2>&1 || true

wait $GHOST 2>/dev/null || true
grep -q "GHOST PASS" "$BUILD/m2_ghost.log" && GRC=0 || GRC=1
echo "--- ghost:"; cat "$BUILD/m2_ghost.log"
echo "--- server tail:"; tail -6 "$BUILD/m2_server.log"
echo "--- console cells (8108/9=tick; 8160=role 8161=d 8162=active 8163=dropped):"
grep -E '^81[0-6][0-9A-F]:' "$BUILD/m2_run.out" | head -8
exit $GRC
