#!/bin/sh
set -e
. "$(dirname "$0")/serverlib.sh"
cd "$(dirname "$0")/.."
BUILD=build; RIG=$BUILD/rig
JZINTV=${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}
pkill -f 'fujinet -u 127.0.0.1:1808' 2>/dev/null || true
sleep 0.5
( cd "$RIG/fn1" && exec ./fujinet -u 127.0.0.1:18081 ) > "$RIG/fn1.log" 2>&1 &
FN1=$!
( relay_server --port 9113 ) > "$RIG/srv1.log" 2>&1 &
SRV=$!
trap 'kill $FN1 $SRV 2>/dev/null || true' EXIT
sleep 2
{
  printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\n'
  printf 'b 600A\nr 2000000\nn 600A\n'        # NET_START reached?
  printf 'b 65A2\nr 2000000\nn 65A2\n'        # SES_MAIN reached?
  printf 'b 673E\nr 4000000\nn 673E\n'        # SES_GETNAME reached?
  printf 'b 6733\nb 67F7\nr 8000000\n'        # SES_EXIT or first SES_PUMP?
  printf 'q\n'
} > $BUILD/probe2.scr
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout 100 "$JZINTV" -d \
    --script=$BUILD/probe2.scr --fujinet=localhost:19851 \
    -e rom/exec.bin -g rom/grom.bin $BUILD/sharkshark_net1.bin \
    > $BUILD/probe2.log 2>&1 || true
grep -E 'Hit breakpoint|RUNNING' $BUILD/probe2.log | head
grep -B1 '^> q' $BUILD/probe2.log | head -3
