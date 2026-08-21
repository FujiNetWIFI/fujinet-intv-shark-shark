#!/usr/bin/env python3
"""Park idle clients in the lobby so a console under test sees a multi-entry
list.  They HELLO (protocol v2) and then only drain their sockets.

--pair: the first player JOINs the second, and once the room forms the
second (its host) sends GO -- the pair becomes a STARTED room, so both
show up with status bit7 (unjoinable) while the rest stay selectable.

--go-name NAME [--go-delay S]: the idler NAME sends GO S seconds after
its room reaches 2 members -- used to start a room the console under
test JOINed as a guest (the delay leaves the test time to snapshot the
waiting-room screen first).

--join-guest PREFIX: the last player polls LIST and JOINs the first
joinable entry whose name starts with PREFIX -- makes the console under
test the room HOST (seat 0).
"""
import argparse
import socket
import time

ap = argparse.ArgumentParser()
ap.add_argument("names", nargs="*", default=["ALPHA", "BRAVO"])
ap.add_argument("--pair", action="store_true",
                help="first joins second; second GOes -> started room")
ap.add_argument("--go-name", metavar="NAME",
                help="this idler sends GO once its room has 2+ members")
ap.add_argument("--go-delay", type=float, default=5.0)
ap.add_argument("--join-guest", metavar="PREFIX",
                help="last player hunts a joinable entry starting with "
                     "PREFIX and JOINs it (console under test = host)")
ap.add_argument("--port", type=int, default=9113)
args = ap.parse_args()


def frame(t, payload=b""):
    body = bytes([t]) + payload
    return bytes([len(body)]) + body


socks = {}
for n in args.names:
    s = socket.create_connection(("127.0.0.1", args.port))
    s.sendall(frame(0x01, bytes([2]) + n.encode()))
    socks[n] = s

if args.pair and len(args.names) >= 2:
    time.sleep(0.3)
    joiner, target = args.names[0], args.names[1]
    socks[joiner].sendall(frame(0x04, target.encode("ascii").ljust(8, b"\0")))
    time.sleep(0.4)
    socks[target].sendall(frame(0x0F))          # host GO -> started room
    print(f"paired+started: {joiner} -> {target}", flush=True)

for s in socks.values():
    s.setblocking(False)
print("idlers:", ", ".join(args.names), flush=True)

hunter = socks[args.names[-1]] if args.join_guest else None
goer = socks.get(args.go_name) if args.go_name else None
bufs = {n: bytearray() for n in args.names}
joined = False
go_at = None
while True:
    now = time.time()
    for name, s in socks.items():
        try:
            data = s.recv(4096)
        except (BlockingIOError, OSError):
            continue
        bufs[name] += data
        # parse this idler's frames
        buf = bufs[name]
        while len(buf) >= 2 and len(buf) >= buf[0] + 1:
            need = buf[0] + 1
            body = bytes(buf[1:need])
            del buf[:need]
            if s is goer and body[0] == 0x0E and body[1] >= 2 and go_at is None:
                go_at = now + args.go_delay
                print(f"{name}: room formed, GO in {args.go_delay}s", flush=True)
            if s is hunter and body[0] == 0x03 and not joined:
                for i in range(body[1]):
                    entry = body[2 + 9 * i:2 + 9 * i + 9]
                    nm = entry[:8].rstrip(b"\0").decode("ascii", "replace")
                    if nm.startswith(args.join_guest) and not (entry[8] & 0x80):
                        hunter.sendall(frame(0x04, entry[:8]))
                        print(f"joined: {args.names[-1]} -> {nm}", flush=True)
                        joined = True
                        break
    if goer is not None and go_at is not None and now >= go_at:
        goer.sendall(frame(0x0F))
        print(f"{args.go_name}: GO sent", flush=True)
        go_at = None
        goer = None
    if hunter is not None and not joined:
        try:
            hunter.sendall(frame(0x02))         # LIST
        except OSError:
            pass
    time.sleep(0.2)
