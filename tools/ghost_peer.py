#!/usr/bin/env python3
"""Scripted lockstep opponent for integration tests.

Connects to bbnet_server, HELLOs, polls the lobby until a console appears,
JOINs it, then behaves as an ideal peer: every INPUT(tick) received is
answered immediately with its own INPUT(tick, idle) -- the console's
watermark always stays ahead, so it never stalls.  Logs INPUT/CRC traffic
and prints a summary; exit 0 if the session reached --want-ticks.
"""
import argparse
import socket
import sys
import time

T_HELLO, T_LIST, T_LOBBY, T_JOIN, T_START = 1, 2, 3, 4, 5
T_INPUT, T_CRC = 6, 7
T_PEER_LEFT, T_PING, T_PONG = 0x0B, 0x0C, 0x0D
IDLE = 0x40


def frame(t, payload=b""):
    body = bytes([t]) + payload
    return bytes([len(body)]) + body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9106)
    ap.add_argument("--name", default="GHOST1")
    ap.add_argument("--want-ticks", type=int, default=1000000)
    ap.add_argument("--timeout", type=float, default=3600.0)
    ap.add_argument("--mirror", action="store_true",
                    help="echo the console's own inputs back as the "
                         "opponent's (one player controls both sides); "
                         "logs each distinct input byte seen")
    ap.add_argument("--pitch-at", type=int, default=0,
                    help="starting at this tick (and every 256 after), "
                         "press keypad 5 for a few ticks -- as guest, "
                         "that's a pitch")
    args = ap.parse_args()

    s = socket.create_connection(("127.0.0.1", args.port), timeout=10)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.sendall(frame(T_HELLO, bytes([1]) + args.name.encode()))

    buf = b""
    matched = False
    last_list = 0.0
    inputs = crcs = 0
    max_tick = 0
    crc_ticks = []
    deadline = time.time() + args.timeout
    s.settimeout(1.0)

    while time.time() < deadline:
        if not matched and time.time() - last_list > 1.0:
            s.sendall(frame(T_LIST))
            last_list = time.time()
        try:
            chunk = s.recv(4096)
            if not chunk:
                print("server closed connection")
                break
            buf += chunk
        except socket.timeout:
            continue
        while buf and len(buf) >= buf[0] + 1:
            n = buf[0] + 1
            t, p = buf[1], buf[2:n]
            buf = buf[n:]
            if t == T_LOBBY and not matched:
                count = p[0]
                for i in range(count):
                    name = p[1 + i * 9:9 + i * 9].rstrip(b"\0")
                    status = p[9 + i * 9]
                    if status == 0 and name != args.name.encode():
                        print(f"joining {name.decode()}")
                        s.sendall(frame(T_JOIN, name))
                        break
            elif t == T_START:
                matched = True
                role, seed = p[0], p[1] | (p[2] << 8)
                opp = p[4:12].rstrip(b"\0").decode()
                print(f"matched vs {opp}: role={role} seed=${seed:04X} d={p[3]}")
            elif t == T_INPUT:
                tick = p[0] | (p[1] << 8)
                inputs += 1
                max_tick = max(max_tick, tick)
                # payload after tick: decoded cell + keypad cell
                if args.mirror:
                    reply = p[2:]
                else:
                    cell = IDLE
                    if args.pitch_at and tick >= args.pitch_at:
                        ph = (tick - args.pitch_at) % 256
                        if ph == 0:
                            cell = 0x85          # fresh keypad 5
                            print(f"tick {tick}: ghost pitches", flush=True)
                        elif ph < 4:
                            cell = 0xC5          # held
                    reply = bytes([cell]) + bytes(max(len(p) - 3, 1))
                if args.mirror and p[2:] != getattr(main, "last", None):
                    main.last = p[2:]
                    vals = " ".join(f"${b:02X}" for b in p[2:])
                    print(f"tick {tick:5d}: input {vals}", flush=True)
                s.sendall(frame(T_INPUT, bytes([p[0], p[1]]) + reply))
            elif t == T_CRC:
                tick = p[0] | (p[1] << 8)
                crc = p[2] | (p[3] << 8)
                crcs += 1
                crc_ticks.append((tick, crc))
            elif t == T_PEER_LEFT:
                print("peer left")
                deadline = min(deadline, time.time() + 1)
        if max_tick >= args.want_ticks:
            break

    print(f"ghost summary: {inputs} INPUTs (max tick {max_tick}), "
          f"{crcs} CRCs {crc_ticks[:4]}")
    ok = max_tick >= args.want_ticks and crcs > 0
    print("GHOST PASS" if ok else "GHOST FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
