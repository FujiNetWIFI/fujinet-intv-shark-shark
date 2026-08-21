#!/usr/bin/env python3
"""Resource soak for one relay implementation.

Holds a realistic load -- IDLE clients parked in the lobby plus one live
lockstep match pumping INPUT+CRC at 20 Hz -- and samples the server's
VmRSS/VmHWM out of /proc while it runs.  Prints a one-line summary that
test/run_soak.sh turns into a py-vs-c comparison.

This is the gate for the reason the C port exists.  RSS is the claim; a
number nobody measured is not a claim, it is a hope.

    tools/soak.py --impl c --secs 120
"""
import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELAY_C = os.path.join(REPO, "server", "c", "intv-relay")
RELAY_PY = os.path.join(REPO, "server", "intv_relay_server.py")

T_HELLO, T_JOIN, T_GO, T_INPUT, T_CRC = 0x01, 0x04, 0x0F, 0x06, 0x07


def frame(t, payload=b""):
    return bytes([len(payload) + 1, t]) + payload


def pad(n):
    return n.encode()[:8].ljust(8, b"\0")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def vm_kb(pid, field):
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith(field):
                    return int(line.split()[1])
    except OSError:
        pass
    return 0


def hello(port, name):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.sendall(frame(T_HELLO, bytes([2]) + name.encode()))
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--impl", choices=("py", "c"), required=True)
    ap.add_argument("--secs", type=float, default=120.0)
    ap.add_argument("--idle", type=int, default=32)
    ap.add_argument("--hz", type=float, default=20.0)
    ap.add_argument("--sample-every", type=float, default=5.0)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    port = free_port()
    if args.impl == "py":
        cmd = [sys.executable, RELAY_PY, "--port", str(port)]
    else:
        if not os.access(RELAY_C, os.X_OK):
            sys.exit(f"{RELAY_C} is not built -- run: make -C server/c")
        cmd = [RELAY_C, "--port", str(port), "--max-seats", "2"]

    proc = subprocess.Popen(cmd, cwd=REPO, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    socks = []
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                socket.create_connection(("127.0.0.1", port), 0.2).close()
                break
            except OSError:
                if proc.poll() is not None:
                    sys.exit("server exited during boot")
                time.sleep(0.05)
        else:
            sys.exit("server never came up")

        # One live match ...
        a = hello(port, "MATCHA")
        b = hello(port, "MATCHB")
        socks += [a, b]
        time.sleep(0.2)
        b.sendall(frame(T_JOIN, pad("MATCHA")))
        time.sleep(0.2)
        a.sendall(frame(T_GO))
        time.sleep(0.3)

        # ... plus a lobby full of parked clients.
        for i in range(args.idle):
            socks.append(hello(port, f"IDLE{i:02d}"))
        time.sleep(0.5)
        for s in socks:
            s.setblocking(False)

        rss, hwm = [], 0
        t0 = time.monotonic()
        next_sample = t0
        tick = 0
        period = 1.0 / args.hz
        next_tick = t0

        while time.monotonic() - t0 < args.secs:
            now = time.monotonic()
            if now >= next_tick:
                next_tick += period
                tick = (tick + 1) & 0xFFFF
                lo, hi = tick & 0xFF, tick >> 8
                try:
                    a.sendall(frame(T_INPUT, bytes([0, lo, hi, 0x40, 0])))
                    a.sendall(frame(T_CRC, bytes([0, lo, hi, 0x11, 0x22])))
                    b.sendall(frame(T_INPUT, bytes([1, lo, hi, 0x20, 0])))
                    b.sendall(frame(T_CRC, bytes([1, lo, hi, 0x11, 0x22])))
                except OSError:
                    break
            for s in socks:                     # keep the relay's tx drained
                try:
                    while s.recv(65536):
                        pass
                except OSError:
                    pass
            if now >= next_sample:
                next_sample += args.sample_every
                r = vm_kb(proc.pid, "VmRSS:")
                if r:
                    rss.append(r)
                hwm = max(hwm, vm_kb(proc.pid, "VmHWM:"))
            time.sleep(0.002)

        if not rss:
            sys.exit("no RSS samples (did the server die?)")
        # Growth over the run: first third vs last third.
        third = max(1, len(rss) // 3)
        growth = sum(rss[-third:]) / third - sum(rss[:third]) / third
        out = {"impl": args.impl, "idle": args.idle, "secs": args.secs,
               "samples": len(rss), "rss_first_kb": rss[0],
               "rss_last_kb": rss[-1], "rss_max_kb": max(rss),
               "hwm_kb": hwm, "growth_kb": round(growth, 1),
               "ticks": tick}
        if args.json:
            print(json.dumps(out))
        else:
            print(f"{args.impl}: rss {rss[0]}K -> {rss[-1]}K "
                  f"(max {max(rss)}K, hwm {hwm}K), growth {growth:+.1f}K "
                  f"over {len(rss)} samples")
        return 0
    finally:
        for s in socks:
            try:
                s.close()
            except OSError:
                pass
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)


if __name__ == "__main__":
    sys.exit(main())
