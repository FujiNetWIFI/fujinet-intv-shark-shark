#!/bin/sh
# Single-console session probe: fn1 + relay + one net console; dumps two
# BACKTAB snapshots so the session screen sequence is visible.
set -e
. "$(dirname "$0")/serverlib.sh"
cd "$(dirname "$0")/.."
BUILD=build
RIG=$BUILD/rig
JZINTV=${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}
pkill -f 'fujinet -u 127.0.0.1:1808' 2>/dev/null || true
sleep 0.5
( cd "$RIG/fn1" && exec ./fujinet -u 127.0.0.1:18081 ) > "$RIG/fn1.log" 2>&1 &
FN1=$!
( relay_server --port 9113 ) > "$RIG/srv1.log" 2>&1 &
SRV=$!
trap 'kill $FN1 $SRV 2>/dev/null || true' EXIT
sleep 2
printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\nr 3000000\nm 200 F0\nm 8100 20\nm 8150 20\nr 6000000\nm 200 F0\nm 8150 20\nm 81AA 4\nq\n' > $BUILD/probe1.scr
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout 100 "$JZINTV" -d \
    --script=$BUILD/probe1.scr --fujinet=localhost:19851 \
    -e rom/exec.bin -g rom/grom.bin $BUILD/sharkshark_net1.bin \
    > $BUILD/probe1.log 2>&1 || true
python3 - <<'EOF'
import re
log = open('build/probe1.log').read()
dumps = re.findall(r'^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#', log, re.M)
mem = {}
screens = []
cur = {}
for a,b in dumps:
    a = int(a,16)
    for i,w in enumerate(b.split()):
        v = int(w.rstrip('*'),16)
        if 0x200 <= a+i < 0x2F0: cur[a+i] = v
        else: mem[a+i] = v
    if a+7 >= 0x2E8 and 0x200 <= a < 0x2F0:
        screens.append(cur); cur = {}
for si, s in enumerate(screens):
    print(f"--- screen {si} ---")
    for row in range(12):
        line = "".join(chr(((s.get(0x200+row*20+c,0)>>3)&0x3F)+32) for c in range(20))
        if line.strip(): print(f"{row:2}: {line}")
name = "".join(chr(mem.get(0x8150+i,0)) for i in range(8)).rstrip("\0")
print("name:", repr(name), "active:", mem.get(0x8162), "roomcnt:", mem.get(0x81AA))
tail = open('build/probe1.log').read().splitlines()[-4:]
print("jz tail:", tail)
EOF
echo "--- server:"
tail -5 "$RIG/srv1.log"
