#!/bin/sh
# Run one determinism-spike build headless until it parks at TRACE_DONE,
# then dump the checksum ring and tick counter.  Usage: run_det.sh a|b
set -e
V="$1"
BUILD=build
JZINTV="${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}"

DONE_ADDR=$(awk '/ TRACE_DONE$/ { sub(/^0+/, "", $1); print $1 }' "$BUILD/sharkshark_det_$V.sym")
if [ -z "$DONE_ADDR" ]; then
    echo "TRACE_DONE not found in symbol file" >&2
    exit 1
fi

SCR="$BUILD/det_$V.scr"
{
    printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\n'   # skip title wait
    printf 'b %s\nr 200000000\n' "$DONE_ADDR"          # run to park loop
    printf 'm 80C0 8\nm 8100 20\nm 8190 20\n'           # netcode vars incl tick,
                                                        #  virtualized timer tail
    printf 'm 9000 200\n'                              # checksum ring
    printf 'm 100 F0\n'                                # game scratch state
    printf 'm 200 160\n'                                # system RAM state
    printf 'q\n'
} > "$SCR"

SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout 300 "$JZINTV" -d --script="$SCR" -r0 \
    -e rom/exec.bin -g rom/grom.bin "$BUILD/sharkshark_det_$V.bin" \
    > "$BUILD/det_$V.out" 2>&1 || true

if ! grep -q "Hit breakpoint at .$DONE_ADDR" "$BUILD/det_$V.out"; then
    echo "run $V never reached TRACE_DONE (\$$DONE_ADDR); tail of output:" >&2
    tail -5 "$BUILD/det_$V.out" >&2
    exit 1
fi
echo "run $V: parked at TRACE_DONE, dump in $BUILD/det_$V.out"
