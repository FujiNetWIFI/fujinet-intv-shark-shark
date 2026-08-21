#!/bin/sh
# Resource gate: hold both relays under the same load and measure.
#
# Memory is the reason the C port exists, so it gets a gate rather than a
# footnote.  Load is 32 idle lobby clients plus one live lockstep match
# pumping INPUT+CRC at 20 Hz -- more than the shared host ever sees per game.
#
# Pass criteria:
#   * neither server grows across the run (a leak shows up as growth_kb)
#   * the C server's high-water mark is materially below the Python's
#
# SOAK_SECS=120 (default), IDLE=32
set -e
BUILD=build
SOAK_SECS="${SOAK_SECS:-120}"
IDLE="${IDLE:-32}"
mkdir -p "$BUILD"

[ -x server/c/intv-relay ] || { echo "build it first: make -C server/c"; exit 1; }

echo "soak: ${SOAK_SECS}s, $IDLE idle clients + 1 live match at 20 Hz"
python3 tools/soak.py --impl py --secs "$SOAK_SECS" --idle "$IDLE" --json \
    > "$BUILD/soak_py.json"
python3 tools/soak.py --impl c  --secs "$SOAK_SECS" --idle "$IDLE" --json \
    > "$BUILD/soak_c.json"

python3 - "$BUILD/soak_py.json" "$BUILD/soak_c.json" <<'EOF'
import json, sys
py = json.load(open(sys.argv[1]))
c  = json.load(open(sys.argv[2]))
print(f"{'':8} {'rss start':>10} {'rss end':>10} {'hwm':>10} {'growth':>10}")
for r in (py, c):
    print(f"{r['impl']:8} {r['rss_first_kb']:>9}K {r['rss_last_kb']:>9}K "
          f"{r['hwm_kb']:>9}K {r['growth_kb']:>+9}K")
ratio = py['hwm_kb'] / max(c['hwm_kb'], 1)
print(f"\nC high-water is {ratio:.1f}x smaller "
      f"({py['hwm_kb']}K -> {c['hwm_kb']}K, saving "
      f"{(py['hwm_kb']-c['hwm_kb'])/1024:.1f} MB per relay)")
print(f"ticks pumped: py={py['ticks']} c={c['ticks']}")

ok = True
# A leak is the thing this gate exists to catch.  Allow a little slack for
# allocator noise, but not a trend.
for r in (py, c):
    if r['growth_kb'] > 512:
        print(f"FAIL: {r['impl']} grew {r['growth_kb']}K across the run")
        ok = False
if c['hwm_kb'] >= py['hwm_kb']:
    print("FAIL: the C server is not smaller -- the port's premise is unmet")
    ok = False
print("SOAK PASS" if ok else "SOAK FAIL")
sys.exit(0 if ok else 1)
EOF
