#!/usr/bin/env python3
"""Byte-for-byte differential between the two relay implementations.

server/intv_relay_server.py is canonical.  server/c/intv-relay is a C port of
it.  This tool drives BOTH through identical scripted scenarios and compares
every frame the clients receive and every line the server logs.  A non-empty
diff is a bug in the C port -- there is no "close enough" here: the console's
frame reader is a hand-written state machine that misframes on a single
unexpected byte.

Steps are strictly synchronous: after each one, every client socket is drained
until it has been quiet for QUIET seconds, and the received frames are
recorded in a fixed client order.  That determinism is what makes an exact
diff possible.

Only three things may legitimately differ, and each is normalized:
  * the START seed (random per match)     -> payload bytes [2:4] become SEED
  * log timestamps                        -> the prefix is stripped
  * ephemeral ports and the listen port   -> tokenized

Anything else that differs is a real divergence.

Usage:
    tools/server_diff.py                    # all scenarios, 2 seats
    tools/server_diff.py --seats 4          # Bowling's shape (C only)
    tools/server_diff.py --scenario framing # just the reassembler torture
    tools/server_diff.py --list
"""
import argparse
import difflib
import os
import re
import select
import signal
import socket
import subprocess
import sys
import threading
import time

QUIET = 0.15            # seconds of silence that ends a drain
BOOT_TIMEOUT = 10.0     # seconds to wait for "listening on :"

T = {"HELLO": 0x01, "LIST": 0x02, "LOBBY": 0x03, "JOIN": 0x04, "START": 0x05,
     "INPUT": 0x06, "CRC": 0x07, "STATE": 0x08, "RESYNC": 0x09, "BYE": 0x0A,
     "PEER_LEFT": 0x0B, "PING": 0x0C, "PONG": 0x0D, "ROOM": 0x0E, "GO": 0x0F}
TNAME = {v: k for k, v in T.items()}

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELAY_C = os.path.join(REPO, "server", "c", "intv-relay")
RELAY_PY = os.path.join(REPO, "server", "intv_relay_server.py")

# Set from --proto / --python-server.  The v1 oracle lives in a sibling repo
# (any of the six pre-Bowling ports ships an identical server/bbnet_server.py),
# so the v1 gate is opt-in on that repo being checked out.
PROTO = 2

LOGLINE = re.compile(
    r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d,\d{3} (INFO|WARNING|DEBUG|ERROR) (.*)$")


def frame(ftype, payload=b""):
    return bytes([len(payload) + 1, ftype]) + payload


def pad(name):
    return name.encode()[:8].ljust(8, b"\0")


def free_port():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


# ---------------------------------------------------------------------------


class Client:
    def __init__(self, ctx, label):
        self.label = label
        self.buf = bytearray()
        self.closed = False
        self.eof_seen = False
        self.sock = socket.create_connection(("127.0.0.1", ctx.port))
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def send(self, data):
        if not self.closed:
            self.sock.sendall(data)

    def close(self):
        if not self.closed:
            self.closed = True
            self.sock.close()


class Ctx:
    """One server process plus the clients talking to it."""

    def __init__(self, impl, seats, extra):
        self.impl = impl
        self.seats = seats
        self.port = free_port()
        self.clients = []
        self.transcript = []
        self.loglines = []
        self._step = 0

        if impl == "py":
            cmd = [sys.executable, RELAY_PY, "--port", str(self.port)]
        elif PROTO == 1:
            # v1 has no seats to configure; --max-seats is refused there.
            cmd = [RELAY_C, "--port", str(self.port), "--proto", "1"]
        else:
            cmd = [RELAY_C, "--port", str(self.port),
                   "--max-seats", str(seats)]
        cmd += list(extra)

        self.proc = subprocess.Popen(cmd, cwd=REPO, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.PIPE, text=True,
                                     bufsize=1)
        self._raw_log = []
        self._reader = threading.Thread(target=self._pump, daemon=True)
        self._reader.start()
        self._await_boot()

    def _pump(self):
        for line in self.proc.stderr:
            self._raw_log.append(line.rstrip("\n"))

    def _await_boot(self):
        # Waiting for the log line rather than probing with TCP keeps the
        # readiness check from injecting a connect/drop pair into the
        # transcript -- and it works identically for both implementations,
        # which a fixed sleep would not (Python takes ~80ms to import, the
        # C binary ~2ms).
        t0 = time.monotonic()
        while time.monotonic() - t0 < BOOT_TIMEOUT:
            if any("listening on :" in l for l in self._raw_log):
                return
            if self.proc.poll() is not None:
                raise RuntimeError(f"{self.impl} server exited during boot:\n"
                                   + "\n".join(self._raw_log))
            time.sleep(0.01)
        raise RuntimeError(f"{self.impl} server never logged 'listening on :'")

    # -- scripting ---------------------------------------------------------

    def connect(self, label):
        c = Client(self, label)
        self.clients.append(c)
        return c

    def hello(self, label, name=None, ver=None):
        """Connect, identify, and sync.

        The sync is not optional.  With two connects in flight at once, the
        interleaving of accept() against the first client's readable data is
        genuinely timing-dependent in BOTH implementations -- Python accepts
        one connection per select() pass, so whether "hello A" lands before or
        after "connect B" is a race, not a semantic.  Syncing after every
        connect removes the race instead of papering over it in the diff.
        """
        c = self.connect(label)
        if ver is None:
            ver = PROTO
        c.send(frame(T["HELLO"], bytes([ver]) + (name or label).encode()))
        self.sync(f"hello {label}")
        return c

    def sync(self, step):
        """Drain every client until quiet, then record what arrived."""
        self._step += 1
        tag = f"{self._step:02d} {step}"
        while True:
            live = [c for c in self.clients if not c.closed]
            if not live:
                break
            r, _, _ = select.select([c.sock for c in live], [], [], QUIET)
            if not r:
                break
            for s in r:
                c = next(x for x in live if x.sock is s)
                try:
                    data = s.recv(65536)
                except OSError:
                    data = b""
                if not data:
                    c.eof_seen = True
                    c.closed = True
                    try:
                        c.sock.close()
                    except OSError:
                        pass
                else:
                    c.buf += data

        for c in self.clients:          # fixed order: creation order
            while len(c.buf) >= 1 and len(c.buf) >= c.buf[0] + 1:
                need = c.buf[0] + 1
                body = bytes(c.buf[1:need])
                del c.buf[:need]
                self.transcript.append(
                    f"{tag} | {c.label} <- {render(body)}")
            if c.buf:
                self.transcript.append(
                    f"{tag} | {c.label} <- PARTIAL {bytes(c.buf).hex()}")
                c.buf.clear()
            if c.eof_seen:
                self.transcript.append(f"{tag} | {c.label} <- EOF")
                c.eof_seen = False

    def finish(self):
        for c in self.clients:
            c.close()
        time.sleep(0.2)
        self.proc.send_signal(signal.SIGINT)
        try:
            self.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)
        self._reader.join(timeout=5)
        # Only real log records.  Python's SIGINT path prints a KeyboardInterrupt
        # traceback (it has no handler); the C build shuts down gracefully.
        # That difference is deliberate and documented -- filtering to
        # timestamped records is the rule that ignores it.
        for line in self._raw_log:
            m = LOGLINE.match(line)
            if m:
                self.loglines.append(f"log {m.group(1)} {m.group(2)}")
        return self.transcript + self.loglines


def render(body):
    """One received frame as a comparable string, with the seed masked."""
    t = body[0]
    p = bytearray(body[1:])
    name = TNAME.get(t, f"${t:02X}")
    if t == T["START"] and len(p) >= 4:
        # v2: seat count seed_lo seed_hi delay roster(32)  -> seed at [2:4]
        # v1: role seed_lo seed_hi delay opponent(8)       -> seed at [1:3]
        lo = 1 if PROTO == 1 else 2
        p[lo:lo + 2] = b"\xAA\xAA"      # seed is random per match
        return f"START {p.hex()} (seed masked)"
    return f"{name} {bytes(p).hex()}"


# Log lines the C emits that the Python has no equivalent for.  Every entry
# here is a DELIBERATE addition, listed by name so the set cannot grow
# silently -- compare() reports how many lines each run filtered.  Keep this
# list empty unless a line genuinely helps an operator and has nowhere else
# to go.
C_ONLY_LINES = [
    # Emitted once per process when a v1 console hits a --proto 2 port.  The
    # console connects successfully and is then dropped, which looks from the
    # couch like a lobby nobody ever joins; without this the only clue is a
    # bare version number in a drop reason.
    re.compile(r"^log WARNING a protocol v1 console tried to connect"),
]


def normalize_log(lines):
    out = []
    filtered = 0
    for l in lines:
        if any(pat.match(l) for pat in C_ONLY_LINES):
            filtered += 1
            continue
        l = re.sub(r"\(seed \$[0-9A-F]{4}\)", "(seed $SEED)", l)
        l = re.sub(r"\('127\.0\.0\.1', \d+\)", "('127.0.0.1', PORT)", l)
        l = re.sub(r"listening on :\d+", "listening on :PORT", l)
        out.append(l)
    return out, filtered


# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------


def s1_roster_order(x):
    """by_name insertion order -- the gate a hash map fails and nothing else."""
    a = x.hello("ALICE")
    b = x.hello("BOB")
    c = x.hello("CAROL")
    d = x.hello("DAVE")

    v1 = x.connect("OLDGUY")             # protocol v1 must be refused
    v1.send(frame(T["HELLO"], bytes([1]) + b"OLDGUY"))
    x.sync("v1 hello refused")

    for cl in (a, b, c, d):
        cl.send(frame(T["LIST"]))
    x.sync("LIST from each")

    # A repeated HELLO with a new name keeps the dict position; a duplicate
    # name evicts the holder.
    c.send(frame(T["HELLO"], bytes([2]) + b"CAROL2"))
    x.sync("CAROL renames to CAROL2")

    e = x.hello("EVE")
    e.send(frame(T["HELLO"], bytes([2]) + b"BOB"))
    x.sync("EVE steals the name BOB")

    for cl in (a, d, e):
        cl.send(frame(T["LIST"]))
    x.sync("LIST after the churn")

    a.close()
    x.sync("ALICE disconnects")
    for cl in (d, e):
        cl.send(frame(T["LIST"]))
    x.sync("LIST after a drop")


def s2_rooms(x):
    """Join redirect, ROOM broadcasts, status bytes, every refusal path."""
    a = x.hello("ALICE")
    b = x.hello("BOB")
    c = x.hello("CAROL")

    b.send(frame(T["JOIN"], pad("ALICE")))
    x.sync("BOB joins ALICE")

    c.send(frame(T["LIST"]))
    x.sync("status: forming room")

    if x.seats >= 3:
        # Joining a GUEST redirects into that guest's room.
        c.send(frame(T["JOIN"], pad("BOB")))
        x.sync("CAROL joins the guest BOB (redirect)")
    else:
        c.send(frame(T["JOIN"], pad("ALICE")))
        x.sync("CAROL joins a full room (refused -> LOBBY)")

    # A client already in a room gets NO reply at all.
    b.send(frame(T["JOIN"], pad("ALICE")))
    x.sync("in-room JOIN is silent")

    # Refusal paths: unknown target, and self-join.
    c.send(frame(T["JOIN"], pad("NOBODY")))
    x.sync("JOIN unknown name -> LOBBY")
    a.send(frame(T["JOIN"], pad("ALICE")))
    x.sync("self-join from an in-room client")

    d = x.hello("DAVE")
    d.send(frame(T["JOIN"], pad("DAVE")))
    x.sync("DAVE self-join -> LOBBY")
    d.send(frame(T["JOIN"], b"THISNAMEISWAYTOOLONG"))
    x.sync("JOIN an over-long name -> LOBBY")


def s3_go_start(x):
    """GO authority and the 38-byte START."""
    a = x.hello("ALICE")
    b = x.hello("BOB")

    a.send(frame(T["GO"]))
    x.sync("GO with no room (ignored)")

    b.send(frame(T["JOIN"], pad("ALICE")))
    x.sync("BOB joins ALICE")

    b.send(frame(T["GO"]))
    x.sync("guest GO (ignored)")

    a.send(frame(T["GO"]))
    x.sync("host GO -> START")

    a.send(frame(T["GO"]))
    x.sync("second GO on a started room (ignored)")

    c = x.hello("CAROL")
    c.send(frame(T["JOIN"], pad("ALICE")))
    x.sync("join a started room -> LOBBY")

    a.send(frame(T["PING"]))
    x.sync("PING -> PONG")


def s4_relay_crc(x):
    """Verbatim fanout, the CRC comparator, and the 64-tick eviction."""
    a = x.hello("ALICE")
    b = x.hello("BOB")

    a.send(frame(T["INPUT"], bytes([0, 1, 0, 0x40, 0])))
    x.sync("relay before a room exists (dropped)")

    b.send(frame(T["JOIN"], pad("ALICE")))
    x.sync("BOB joins ALICE")

    a.send(frame(T["INPUT"], bytes([0, 1, 0, 0x40, 0])))
    x.sync("relay before start (dropped)")

    a.send(frame(T["GO"]))
    x.sync("host GO -> START")

    a.send(frame(T["INPUT"], bytes([0, 7, 0, 0x40, 0])))
    x.sync("INPUT fanout")
    b.send(frame(T["STATE"], bytes([0, 0]) + bytes(range(96))))
    x.sync("96-byte STATE fanout")
    a.send(frame(T["RESYNC"], bytes([5, 0])))
    x.sync("RESYNC fanout")

    for t in range(4):                  # four agreed rounds -> one "crc ok"
        a.send(frame(T["CRC"], bytes([0, t, 0, 0x11, 0x22])))
        b.send(frame(T["CRC"], bytes([1, t, 0, 0x11, 0x22])))
    x.sync("four agreed CRC rounds")

    a.send(frame(T["CRC"], bytes([0, 9, 0, 0xAA, 0x00])))
    b.send(frame(T["CRC"], bytes([1, 9, 0, 0xBB, 0x00])))
    x.sync("a CRC mismatch")

    # 70 half-reported ticks overflow the 64-tick table; completing an
    # evicted one must produce no line.
    for t in range(100, 170):
        a.send(frame(T["CRC"], bytes([0, t & 0xFF, t >> 8, 0x33, 0x44])))
    x.sync("70 half-reported ticks (eviction)")
    b.send(frame(T["CRC"], bytes([1, 100, 0, 0x33, 0x44])))
    x.sync("complete an evicted tick (no line)")
    b.send(frame(T["CRC"], bytes([1, 169, 0, 0x33, 0x44])))
    x.sync("complete a surviving tick")

    # A seat the sender does not own is legal on the wire and shows up
    # verbatim in the mismatch line.
    a.send(frame(T["CRC"], bytes([3, 200, 0, 0x01, 0x00])))
    b.send(frame(T["CRC"], bytes([1, 200, 0, 0x02, 0x00])))
    x.sync("a lying seat index")


def s5_drop_matrix(x):
    """Every drop path, and the %r-evaluation-order traps in the log."""
    a = x.hello("ALICE")
    b = x.hello("BOB")
    b.send(frame(T["JOIN"], pad("ALICE")))
    x.sync("BOB joins ALICE")
    a.send(frame(T["GO"]))
    x.sync("host GO -> START")
    b.close()
    x.sync("guest leaves a STARTED room -> PEER_LEFT")

    c = x.hello("CAROL")
    d = x.hello("DAVE")
    d.send(frame(T["JOIN"], pad("CAROL")))
    x.sync("DAVE joins CAROL")
    c.close()
    x.sync("host leaves a FORMING room -> ROOM 0")

    e = x.hello("EVE")
    f = x.hello("FRANK")
    f.send(frame(T["JOIN"], pad("EVE")))
    x.sync("FRANK joins EVE")
    f.close()
    x.sync("guest leaves a FORMING room of 2 -> dissolve")

    g = x.hello("GRACE")
    g.send(frame(T["BYE"]))
    x.sync("BYE")

    h = x.hello("HEIDI")
    h.send(frame(T["HELLO"], bytes([2]) + b"!!"))
    x.sync("a bad name drops the connection")


def s6_framing(x):
    """Reassembler torture.  This is the defect the C port fixes."""
    a = x.hello("ALICE")

    # A whole frame delivered one byte at a time, with real gaps.
    f = frame(T["PING"])
    for byte in f:
        a.send(bytes([byte]))
        time.sleep(0.02)
    x.sync("PING dribbled one byte at a time")

    # Two frames in one write.
    a.send(frame(T["PING"]) + frame(T["PING"]))
    x.sync("two frames in one write")

    # A long frame split on an awkward boundary.
    big = frame(T["LIST"])
    listx3 = big * 3
    a.send(listx3[:2])
    time.sleep(0.05)
    a.send(listx3[2:])
    x.sync("three LISTs split mid-frame")

    # A JOIN whose payload arrives after its header.
    j = frame(T["JOIN"], pad("NOBODY"))
    a.send(j[:1])
    time.sleep(0.05)
    a.send(j[1:4])
    time.sleep(0.05)
    a.send(j[4:])
    x.sync("JOIN in three fragments")

    b = x.connect("BADLEN")
    b.send(b"\x00")
    x.sync("length byte 0 -> bad frame length")

    c = x.connect("BADLEN2")
    c.send(b"\xC9")
    x.sync("length byte 201 -> bad frame length")

    d = x.hello("DAVE")
    d.send(frame(0x7F))
    x.sync("unknown type $7F")


def s7_limits(x):
    """Connection caps.  Timing-sensitive: compared as a normalized set."""
    extra = []
    for i in range(9):                  # MAX_CONNECTIONS_PER_IP is 8
        extra.append(x.connect(f"IP{i}"))
    x.sync("9 connections from one IP")


# ---------------------------------------------------------------------------
# Protocol v1 scenarios (Baseball et al).  Different enough to be worth their
# own set rather than conditionals: no rooms, no GO, JOIN starts the match,
# START names one opponent, INPUT/CRC are untagged.
# ---------------------------------------------------------------------------


def v1_roster_order(x):
    """by_name insertion order, rename, duplicate-name eviction."""
    a = x.hello("ALICE")
    b = x.hello("BOB")
    c = x.hello("CAROL")

    for cl in (a, b, c):
        cl.send(frame(T["LIST"]))
    x.sync("LIST from each")

    c.send(frame(T["HELLO"], bytes([1]) + b"CAROL2"))
    x.sync("CAROL renames to CAROL2")

    d = x.hello("DAVE")
    d.send(frame(T["HELLO"], bytes([1]) + b"BOB"))
    x.sync("DAVE steals the name BOB")

    for cl in (a, d):
        cl.send(frame(T["LIST"]))
    x.sync("LIST after the churn")

    a.close()
    x.sync("ALICE disconnects")
    d.send(frame(T["LIST"]))
    x.sync("LIST after a drop")

    # v1's on_hello never inspects the version byte -- payload[1:] is the
    # name and payload[0] is ignored.  Any value must be accepted.
    e = x.hello("EVE", ver=7)
    e.send(frame(T["LIST"]))
    x.sync("HELLO with an absurd version byte is accepted")


def v1_pairing(x):
    """JOIN pairs immediately: no ROOM, no GO, a 13-byte START each way."""
    a = x.hello("ALICE")
    b = x.hello("BOB")
    c = x.hello("CAROL")

    c.send(frame(T["LIST"]))
    x.sync("status: everyone idle (0)")

    b.send(frame(T["JOIN"], pad("ALICE")))
    x.sync("BOB joins ALICE -> both START")

    c.send(frame(T["LIST"]))
    x.sync("status: both busy (1)")

    # Refusals: busy target, unknown target, self, and an in-match JOIN.
    c.send(frame(T["JOIN"], pad("ALICE")))
    x.sync("JOIN a busy player -> LOBBY")
    c.send(frame(T["JOIN"], pad("NOBODY")))
    x.sync("JOIN an unknown name -> LOBBY")
    c.send(frame(T["JOIN"], pad("CAROL")))
    x.sync("self-join -> LOBBY")
    c.send(frame(T["JOIN"], b"THISNAMEISWAYTOOLONG"))
    x.sync("JOIN an over-long name -> LOBBY")
    b.send(frame(T["JOIN"], pad("CAROL")))
    x.sync("JOIN while matched is silent")

    a.send(frame(T["PING"]))
    x.sync("PING -> PONG")

    # GO does not exist in v1: it must drop the connection.
    c.send(frame(T["GO"]))
    x.sync("GO is an unknown type in v1")


def v1_relay_crc(x):
    """Verbatim relay to the partner, and the pop-from-partner comparator."""
    a = x.hello("ALICE")
    b = x.hello("BOB")

    a.send(frame(T["INPUT"], bytes([1, 0, 0x40, 0])))
    x.sync("relay before a match (dropped)")

    b.send(frame(T["JOIN"], pad("ALICE")))
    x.sync("BOB joins ALICE")

    a.send(frame(T["INPUT"], bytes([7, 0, 0x40, 0])))
    x.sync("INPUT fanout (untagged, 4 bytes)")
    b.send(frame(T["STATE"], bytes([0, 0]) + bytes(range(96))))
    x.sync("96-byte STATE fanout")
    a.send(frame(T["RESYNC"], bytes([5, 0])))
    x.sync("RESYNC fanout")

    for t in range(4):                  # four agreed pairs -> one "crc ok"
        a.send(frame(T["CRC"], bytes([t, 0, 0x11, 0x22])))
        b.send(frame(T["CRC"], bytes([t, 0, 0x11, 0x22])))
    x.sync("four agreed CRC pairs")

    a.send(frame(T["CRC"], bytes([9, 0, 0xAA, 0x00])))
    b.send(frame(T["CRC"], bytes([9, 0, 0xBB, 0x00])))
    x.sync("a CRC mismatch")

    # 70 unanswered ticks overflow the 64-entry per-client log.
    for t in range(100, 170):
        a.send(frame(T["CRC"], bytes([t & 0xFF, t >> 8, 0x33, 0x44])))
    x.sync("70 unanswered ticks (eviction)")
    b.send(frame(T["CRC"], bytes([100, 0, 0x33, 0x44])))
    x.sync("answer an evicted tick")
    b.send(frame(T["CRC"], bytes([169, 0, 0x33, 0x44])))
    x.sync("answer a surviving tick")


def v1_drops(x):
    """Started drop -> an EMPTY PEER_LEFT, and the bad-name/BYE paths."""
    a = x.hello("ALICE")
    b = x.hello("BOB")
    b.send(frame(T["JOIN"], pad("ALICE")))
    x.sync("BOB joins ALICE")
    b.close()
    x.sync("partner leaves -> PEER_LEFT")

    a.send(frame(T["LIST"]))
    x.sync("ALICE is idle again")

    c = x.hello("CAROL")
    c.send(frame(T["BYE"]))
    x.sync("BYE")

    d = x.hello("DAVE")
    d.send(frame(T["HELLO"], bytes([1]) + b"!!"))
    x.sync("a bad name drops the connection")

    e = x.connect("NOHELLO")
    e.send(frame(T["JOIN"], pad("ALICE")))
    x.sync("JOIN before HELLO drops")


SCENARIOS_V2 = {
    "roster":  s1_roster_order,
    "rooms":   s2_rooms,
    "start":   s3_go_start,
    "relay":   s4_relay_crc,
    "drops":   s5_drop_matrix,
    "framing": s6_framing,
    "limits":  s7_limits,
}
SCENARIOS_V1 = {
    "roster":  v1_roster_order,
    "pairing": v1_pairing,
    "relay":   v1_relay_crc,
    "drops":   v1_drops,
    "framing": s6_framing,
    "limits":  s7_limits,
}
SCENARIOS = SCENARIOS_V2
DEFAULT_ORDER_V2 = ["roster", "rooms", "start", "relay", "drops", "framing"]
DEFAULT_ORDER_V1 = ["roster", "pairing", "relay", "drops", "framing"]
DEFAULT_ORDER = DEFAULT_ORDER_V2


# ---------------------------------------------------------------------------


def run(impl, name, seats, extra=()):
    x = Ctx(impl, seats, extra)
    try:
        SCENARIOS[name](x)
        x.sync("final")
    finally:
        lines = x.finish()
    return normalize_log(lines)


def compare(name, seats, strict):
    py, _ = run("py", name, seats)
    c, c_filtered = run("c", name, seats)
    note = f" [+{c_filtered} deliberate C-only line(s)]" if c_filtered else ""
    if name == "limits":
        # Nine simultaneous connects: which one loses the per-IP race, and the
        # order accepts interleave with reads, is genuinely nondeterministic in
        # both implementations.  Compared as a multiset, and labelled as such
        # rather than passed off as a transcript match.
        py, c = sorted(py), sorted(c)
        if py == c:
            print(f"  {name}: PASS (multiset, {len(py)} records -- order is "
                  f"racy by nature){note}")
            return True
    elif py == c:
        print(f"  {name}: PASS ({len(py)} records){note}")
        return True

    diff = list(difflib.unified_diff(py, c, "python", "c", lineterm="", n=2))
    if name == "framing" and PROTO == 2:
        # The v2 Python has no partial-frame guard
        # (intv_relay_server.py:333-348).  Every pre-v2 sibling HAS one, so
        # under --proto 1 this scenario must match exactly and a difference
        # there is a real failure.
        print(f"  {name}: DIVERGES -- known Python defect "
              f"(missing partial-frame guard)")
        for l in diff[:30]:
            print(f"      {l}")
        return not strict

    print(f"  {name}: FAIL -- {sum(1 for l in diff if l[:1] in '+-') - 2} "
          f"differing records")
    for l in diff[:40]:
        print(f"      {l}")
    return False


def main():
    global PROTO, RELAY_PY, SCENARIOS

    ap = argparse.ArgumentParser()
    ap.add_argument("--seats", type=int, default=2)
    ap.add_argument("--proto", type=int, choices=(1, 2), default=2,
                    help="wire protocol to diff (default 2)")
    ap.add_argument("--python-server", metavar="PATH",
                    help="the reference server to diff against.  Required for "
                         "--proto 1, whose oracle lives in a sibling repo, "
                         "e.g. ../intv-baseball-experiment/server/"
                         "bbnet_server.py")
    ap.add_argument("--scenario", action="append",
                    help="run only this scenario (repeatable)")
    ap.add_argument("--strict", action="store_true",
                    help="fail on the known Python framing defect too")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    PROTO = args.proto
    SCENARIOS = SCENARIOS_V1 if PROTO == 1 else SCENARIOS_V2

    if args.list:
        for k in SCENARIOS:
            print(k)
        return 0

    if args.python_server:
        RELAY_PY = os.path.abspath(args.python_server)
        if not os.path.exists(RELAY_PY):
            sys.exit(f"no such reference server: {RELAY_PY}")
    elif PROTO == 1:
        sys.exit("--proto 1 needs --python-server: this repo ships the v2\n"
                 "reference only.  Point it at any pre-Bowling sibling, e.g.\n"
                 "  tools/server_diff.py --proto 1 --python-server \\\n"
                 "      ../intv-baseball-experiment/server/bbnet_server.py")

    if not os.path.exists(RELAY_C):
        sys.exit(f"{RELAY_C} is not built -- run: make -C server/c")

    names = args.scenario or (DEFAULT_ORDER_V1 if PROTO == 1
                              else DEFAULT_ORDER_V2)
    for n in names:
        if n not in SCENARIOS:
            sys.exit(f"unknown scenario {n!r} for v{PROTO}; try --list")

    if PROTO == 2 and args.seats != 2:
        # This repo's Python is pinned at MAX_SEATS = 2, so there is nothing
        # to diff against at any other width.
        sys.exit("--seats is only diffable at 2 (the Python here is pinned "
                 "at MAX_SEATS=2); use tools/bbnet_client_sim.py SEATS=4 "
                 "SERVER=c for the 4-seat claim")

    print(f"server_diff: protocol v{PROTO}, {len(names)} scenario(s)"
          + (f", {args.seats} seats" if PROTO == 2 else "")
          + f"\n  reference: {os.path.relpath(RELAY_PY, REPO)}")
    ok = True
    for n in names:
        ok &= compare(n, args.seats, args.strict)
    print("SERVER DIFF PASS" if ok else "SERVER DIFF FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
