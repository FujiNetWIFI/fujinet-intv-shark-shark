#!/usr/bin/env python3
"""M7a off-console protocol gate: simulated consoles against the v2
room-based relay server.  Covers, in order:

  1. hello v2 (and a v1 reject), empty lobby
  2. occupancy statuses: solo=1, forming room counts, bit7 when full/started
  3. join -> ROOM broadcasts to every member, seat order = join order;
     joining a GUEST of a forming room redirects into that room (>=3 seats)
  4. host GO -> per-seat STARTs (seat/count/seed/delay/roster); a guest's
     GO is ignored
  5. INPUT/CRC/STATE fanout to all-others, verbatim
  6. N-way CRC log: agree path and mismatch path
  7. join refusals: full room, started room
  8. pre-start guest leave -> reseat + ROOM rebroadcast (>=3 seats), or
     dissolve when the room drops below two
  9. pre-start host leave -> ROOM count 0 (dissolved) to guests
 10. started drop -> PEER_LEFT(seat, name) to every survivor + dissolve
 11. --auto-go N starts the room automatically at N members

The gate is parameterised by seat count, because the relay is:

    SEATS=2 SERVER=py tools/bbnet_client_sim.py   # Soccer, reference server
    SEATS=2 SERVER=c  tools/bbnet_client_sim.py   # Soccer, C port
    SEATS=4 SERVER=c  tools/bbnet_client_sim.py   # Bowling's shape, one build

SEATS defaults to 2 (this game).  This repo's Python server is pinned at
MAX_SEATS = 2, so SEATS=4 requires SERVER=c.

Exit 0 = all assertions pass.
"""
import os
import socket
import subprocess
import sys
import time

PORT = 9139
SEATS = int(os.environ.get("SEATS", "2"))
SERVER = os.environ.get("SERVER", "py")
ROOM_NAMES = ["ALICE", "BOB", "CAROL", "DAVE"]

T = dict(HELLO=0x01, LIST=0x02, LOBBY=0x03, JOIN=0x04, START=0x05,
         INPUT=0x06, CRC=0x07, STATE=0x08, RESYNC=0x09, BYE=0x0A,
         PEER_LEFT=0x0B, PING=0x0C, PONG=0x0D, ROOM=0x0E, GO=0x0F)


def frame(t, payload=b""):
    body = bytes([t]) + payload
    return bytes([len(body)]) + body


def pad(name):
    return name.encode()[:8].ljust(8, b"\0")


def st(n):
    """Expected LOBBY status byte for a room of n members: bit7 once full."""
    return (0x80 | n) if n >= SEATS else n


class Cli:
    def __init__(self, name, ver=2):
        self.s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buf = b""
        self.name = name
        self.send(frame(T["HELLO"], bytes([ver]) + name.encode()))

    def send(self, data):
        self.s.sendall(data)

    def recv_frame(self, timeout=5):
        self.s.settimeout(timeout)
        while True:
            if self.buf and len(self.buf) >= self.buf[0] + 1:
                n = self.buf[0] + 1
                body, self.buf = self.buf[1:n], self.buf[n:]
                return body[0], body[1:]
            chunk = self.s.recv(4096)
            if not chunk:
                raise EOFError
            self.buf += chunk

    def expect(self, ftype, timeout=5):
        t, p = self.recv_frame(timeout)
        assert t == T[ftype], f"{self.name}: expected {ftype}, got ${t:02X} {p!r}"
        return p

    def drain_lobby(self):
        """Consume any queued LOBBY frames, return the last payload seen."""
        last = None
        try:
            while True:
                t, p = self.recv_frame(timeout=0.3)
                if t == T["LOBBY"]:
                    last = p
                else:
                    self.buf = frame(t, p) + self.buf   # push back
                    break
        except socket.timeout:
            pass
        return last

    def lobby(self):
        self.send(frame(T["LIST"]))
        return self.expect("LOBBY")

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def lobby_status(payload, name):
    n = payload[0]
    for i in range(n):
        e = payload[1 + 9 * i: 1 + 9 * (i + 1)]
        if e[:8].rstrip(b"\0").decode() == name:
            return e[8]
    return None


def roster_names(raw):
    return [raw[i * 8:(i + 1) * 8].rstrip(b"\0").decode() for i in range(4)]


def start_server(*extra):
    if SERVER == "c":
        cmd = ["server/c/intv-relay", "--port", str(PORT),
               "--max-seats", str(SEATS), *extra]
        if not os.access(cmd[0], os.X_OK):
            sys.exit(f"SERVER=c: {cmd[0]} is not built -- run: make -C server/c")
    else:
        cmd = [sys.executable, "server/intv_relay_server.py",
               "--port", str(PORT), *extra]
    srv = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            socket.create_connection(("127.0.0.1", PORT), 0.2).close()
            return srv
        except OSError:
            if srv.poll() is not None:
                sys.exit(f"server exited during boot:\n{srv.communicate()[0]}")
            time.sleep(0.05)
    sys.exit("server never came up")


def expect_silence(cli, why):
    try:
        cli.recv_frame(timeout=0.3)
        raise AssertionError(why)
    except socket.timeout:
        pass


def scenario_main():
    srv = start_server()
    try:
        # -- 1: hello v2 works, v1 is rejected ------------------------------
        a = Cli("ALICE")
        p = a.expect("LOBBY")
        assert p[0] == 0, f"expected empty lobby, got {p!r}"
        v1 = Cli("OLDGUY", ver=1)
        try:
            v1.recv_frame(timeout=2)
            raise AssertionError("v1 hello was not rejected")
        except (EOFError, ConnectionResetError, socket.timeout):
            pass
        v1.close()

        names = ROOM_NAMES[:SEATS]
        clis = [a] + [Cli(n) for n in names[1:]]
        for c in clis[1:]:
            c.expect("LOBBY")
        e = Cli("EVE")                      # the outsider / observer
        e.expect("LOBBY")

        # -- 2/3: joins build a room; ROOM broadcast; occupancy -------------
        assert lobby_status(e.lobby(), "ALICE") == st(1), "solo status wrong"
        clis[1].send(frame(T["JOIN"], pad("ALICE")))
        for cli in clis[:2]:
            p = cli.expect("ROOM")
            assert p[0] == 2 and roster_names(p[1:33])[:2] == names[:2], \
                f"bad ROOM after first join: {p!r}"
        assert lobby_status(e.lobby(), "ALICE") == st(2), "forming status wrong"
        assert lobby_status(e.lobby(), "BOB") == st(2), "guest shares room status"

        # -- 3b: joining a GUEST redirects into the room (needs >= 3 seats) --
        if SEATS >= 3:
            clis[2].send(frame(T["JOIN"], pad("BOB")))
            for cli in clis[:3]:
                p = cli.expect("ROOM")
                assert p[0] == 3 and roster_names(p[1:33])[:3] == names[:3], \
                    f"guest-join redirect failed: {p!r}"
        else:
            print("  (guest-join redirect skipped: needs >= 3 seats)")

        for i in range(3, SEATS):
            clis[i].send(frame(T["JOIN"], pad("ALICE")))
            for cli in clis[:i + 1]:
                p = cli.expect("ROOM")
                assert p[0] == i + 1, f"bad ROOM at {i + 1}: {p!r}"

        # -- 7a: a full room is unjoinable ----------------------------------
        status = lobby_status(e.lobby(), "ALICE")
        assert status == (0x80 | SEATS), \
            f"full status != ${0x80 | SEATS:02X}: {status:#x}"
        e.send(frame(T["JOIN"], pad("ALICE")))
        e.expect("LOBBY")

        # -- 4: host GO -> per-seat STARTs ----------------------------------
        clis[1].send(frame(T["GO"]))        # a non-host GO: must be ignored
        clis[0].send(frame(T["GO"]))
        seeds = set()
        for seat, cli in enumerate(clis):
            p = cli.expect("START")
            assert len(p) == 37, f"START payload must be 37 bytes: {len(p)}"
            assert p[0] == seat, f"seat mismatch: {p!r}"
            assert p[1] == SEATS, f"count mismatch: {p!r}"
            seeds.add((p[2], p[3]))
            assert p[4] >= 1, "delay missing"
            assert roster_names(p[5:37])[:SEATS] == names, \
                f"roster mismatch: {p!r}"
        assert len(seeds) == 1, "seed differed between seats"

        # -- 2b: started room shows bit7 ------------------------------------
        status = lobby_status(e.lobby(), "ALICE")
        assert status == (0x80 | SEATS), f"started status wrong: {status:#x}"

        # -- 7b: joining into a started room is refused ---------------------
        e.send(frame(T["JOIN"], pad("ALICE")))
        e.expect("LOBBY")

        # -- 5: INPUT fanout to all-others, verbatim ------------------------
        inp = bytes([0, 5, 0, 0x44, 0])         # seat 0, tick 5
        clis[0].send(frame(T["INPUT"], inp))
        for cli in clis[1:]:
            p = cli.expect("INPUT")
            assert p == inp, f"INPUT not verbatim: {p!r}"
        expect_silence(clis[0], "sender got its own INPUT back")

        # STATE fanout (host push)
        stt = bytes([0, 0xFF, 9, 0])            # BEGIN-ish
        clis[0].send(frame(T["STATE"], stt))
        for cli in clis[1:]:
            assert cli.expect("STATE") == stt

        # -- 6: N-way CRC agree, then mismatch ------------------------------
        def crc(cli, seat, tick, val):
            cli.send(frame(T["CRC"], bytes([seat, tick & 0xFF, tick >> 8,
                                            val & 0xFF, val >> 8])))
        for rnd in range(4):                    # 4 agreed rounds -> log line
            tick = 64 * (rnd + 1)
            for seat, cli in enumerate(clis):
                crc(cli, seat, tick, 0xBEEF)
            for cli in clis:                    # each sees the others' CRCs
                for _ in range(SEATS - 1):
                    cli.expect("CRC")
        for seat, cli in enumerate(clis):
            crc(cli, seat, 320, 0x2222 if seat == 1 else 0x1111)
        for cli in clis:
            for _ in range(SEATS - 1):
                cli.expect("CRC")

        # -- 10: started drop -> PEER_LEFT(seat,name) to all survivors ------
        clis[1].close()                         # seat 1 walks out
        for cli in [clis[0]] + clis[2:]:
            p = cli.expect("PEER_LEFT")
            assert p[0] == 1 and p[1:9].rstrip(b"\0") == b"BOB", \
                f"bad PEER_LEFT: {p!r}"
        time.sleep(0.2)
        assert lobby_status(e.lobby(), "ALICE") == 1, "not solo after dissolve"
        for cli in clis[2:]:
            assert lobby_status(e.lobby(), cli.name) == 1
        e.close()
        for cli in clis[2:]:
            cli.close()

        # -- 8: pre-start guest leave ---------------------------------------
        host = clis[0]                          # ALICE, solo again
        g1 = Cli("GUESTA"); g1.expect("LOBBY")
        g1.send(frame(T["JOIN"], pad("ALICE")))
        host.expect("ROOM"); g1.expect("ROOM")
        if SEATS >= 3:
            g2 = Cli("GUESTB"); g2.expect("LOBBY")
            g2.send(frame(T["JOIN"], pad("ALICE")))
            for cli in (host, g1, g2):
                cli.expect("ROOM")
            g1.close()                          # guest leaves a room of 3
            p = host.expect("ROOM")
            assert p[0] == 2 and \
                roster_names(p[1:33])[:2] == ["ALICE", "GUESTB"], \
                f"reseat failed: {p!r}"
            g2.expect("ROOM")
            tail = g2
        else:
            g1.close()                          # guest leaves a room of 2
            p = host.expect("ROOM")
            assert p[0] == 0, \
                f"a 2-seat guest leave must dissolve the room: {p!r}"
            tail = Cli("GUESTC"); tail.expect("LOBBY")
            tail.send(frame(T["JOIN"], pad("ALICE")))
            host.expect("ROOM"); tail.expect("ROOM")

        # -- 9: pre-start host leave -> dissolved (count 0) -----------------
        host.close()
        p = tail.expect("ROOM")
        assert p[0] == 0, f"expected dissolved ROOM, got {p!r}"
        tail.close()

        print(f"scenario 1-10 OK ({SEATS} seats, SERVER={SERVER})")
    finally:
        srv.terminate()
        out = srv.communicate(timeout=15)[0]
        for want in ("match: room", "CRC MISMATCH tick 320",
                     "(4 rounds)", "peer left"):
            assert want in out, f"server log missing {want!r}:\n{out}"


def scenario_autogo():
    srv = start_server("--auto-go", "2")
    try:
        a = Cli("EVE"); a.expect("LOBBY")
        b = Cli("FRANK"); b.expect("LOBBY")
        b.send(frame(T["JOIN"], pad("EVE")))
        a.expect("ROOM"); b.expect("ROOM")
        pa = a.expect("START"); pb = b.expect("START")
        assert pa[0] == 0 and pb[0] == 1 and pa[1] == pb[1] == 2, \
            f"auto-go STARTs wrong: {pa!r} {pb!r}"
        a.close(); b.close()
        print("scenario auto-go OK")
    finally:
        srv.terminate()
        srv.communicate(timeout=15)


def scenario_full():
    """--auto-go at capacity, an over-capacity join, and full-width fanout."""
    srv = start_server("--auto-go", str(SEATS))
    try:
        pnames = [f"P{i + 1}{chr(ord('A') + i) * 2}" for i in range(SEATS)]
        clis = [Cli(n) for n in pnames]
        for c in clis:
            c.expect("LOBBY")
        for c in clis[1:]:
            c.send(frame(T["JOIN"], pad(pnames[0])))
        # drain ROOM broadcasts until STARTs arrive
        for seat, c in enumerate(clis):
            while True:
                t, p = c.recv_frame()
                if t == T["START"]:
                    break
            assert p[0] == seat and p[1] == SEATS, f"START wrong: {p!r}"
            assert roster_names(p[5:37])[:SEATS] == pnames
        # one more player cannot join a full/started room
        e = Cli("PZZZ"); e.expect("LOBBY")
        e.send(frame(T["JOIN"], pad(pnames[0])))
        e.expect("LOBBY")
        # full-width input fanout: each send reaches exactly SEATS-1 others
        sender = SEATS - 1
        msg = bytes([sender, 7, 0, 0x40, 0])
        clis[sender].send(frame(T["INPUT"], msg))
        for i, c in enumerate(clis):
            if i == sender:
                continue
            assert c.expect("INPUT") == msg
        expect_silence(clis[sender], "sender got its own INPUT back")
        for c in clis + [e]:
            c.close()
        print(f"scenario {SEATS}-player OK")
    finally:
        srv.terminate()
        srv.communicate(timeout=15)


if __name__ == "__main__":
    if not 2 <= SEATS <= 4:
        sys.exit(f"SEATS must be 2..4 (got {SEATS})")
    if SEATS != 2 and SERVER != "c":
        sys.exit("this repo's Python server is pinned at MAX_SEATS=2; "
                 f"SEATS={SEATS} needs SERVER=c")
    if SERVER not in ("py", "c"):
        sys.exit(f"SERVER must be 'py' or 'c' (got {SERVER!r})")
    scenario_main()
    scenario_autogo()
    scenario_full()
    print(f"SERVER PROTOCOL GATE PASS (SEATS={SEATS}, SERVER={SERVER})")
