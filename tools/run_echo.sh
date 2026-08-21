#!/bin/sh
# Transport spike runner: echo server + jzintv --fujinet against a running
# fujinet-pc BOIP instance (FN_BOIP, default localhost:9995).
set -e
BUILD=build
JZINTV="${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}"
FN_BOIP="${FN_BOIP:-localhost:9995}"

PARK=$(awk '/ ECHO_PARK$/ { sub(/^0+/, "", $1); print $1 }' "$BUILD/sharkshark_echo.sym")
[ -n "$PARK" ] || { echo "ECHO_PARK not in sym file" >&2; exit 1; }

python3 tools/latency_probe_server.py 9105 > "$BUILD/echo_server.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 0.3

SCR="$BUILD/echo.scr"
{
    printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\n'    # skip title wait
    printf 'b %s\nr 40000000\n' "$PARK"                 # run to park (1x speed)
    printf 'm 8110 30\n'                                # results block
    printf 'q\n'
} > "$SCR"

SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout 120 "$JZINTV" -d --script="$SCR" --fujinet="$FN_BOIP" \
    -e rom/exec.bin -g rom/grom.bin "$BUILD/sharkshark_echo.bin" \
    > "$BUILD/echo_run.out" 2>&1 || true

echo "--- echo server log:"
cat "$BUILD/echo_server.log"
echo "--- result cells (E_STAGE at \$8120; \$AA = pass):"
grep -E '^81[12][0-9A-F]:' "$BUILD/echo_run.out" || tail -5 "$BUILD/echo_run.out"
