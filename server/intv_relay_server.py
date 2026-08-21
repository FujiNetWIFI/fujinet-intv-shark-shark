#!/usr/bin/env python3
"""Intellivision netplay matchmaking + relay server (Shark! Shark! instance).

Single-file, stdlib-only, selectors-based non-blocking TCP (the FujiRealm
hybrid_server.py pattern).  Clients are Intellivision consoles connecting
outbound through FujiNet N:TCP -- the server is a mandatory relay (FujiNet
has no listener/NAT story).

Matchmaking is room-based (inherited from the Bowling port, which
generalized the engine to N seats).  Any idle player is implicitly a
joinable room of one; JOINing them creates/extends the room (join order =
seat order, seat 0 = host).  The host starts the match with GO once the
room is full (the rig's --auto-go N starts it automatically).  All relayed
game frames are seat-tagged by the SENDER and fanned out verbatim to every
other room member.

SHARK SHARK IS 1-2 PLAYERS, SIMULTANEOUS -- the cart's own boot prompt
("SELECT 1 OR 2 PLAYERS") hard-caps it at 2, and there is no turn
arbiter: both seats' input reaches the sim every tick via the EXEC's own
controller-index handoff (the Boxing/Baseball shape, not Bowling/Golf's
turn-arbiter shape). MAXPLAYERS is 2 here; the seat plumbing (room-based
matchmaking, seat-tagged frames) is unchanged from the Bowling/Golf
lineage even though this port doesn't need the arbiter layer they added.

Wire format, both directions: length-prefixed frames over TCP.
    frame := len(1) type(1) payload(len-1 bytes)
`len` counts type+payload.  TCP provides ordering/integrity; frames are
validated structurally and a malformed stream drops the connection.

Types (protocol v2 -- HELLO ver must be 2):
    C->S  $01 HELLO      ver(1)=2 name(ASCII, 2-8 chars A-Z0-9)
    C->S  $02 LIST
    S->C  $03 LOBBY      count(1) then per entry: name(8, NUL-padded)
                         status(1): low 3 bits = room member count (1 =
                         solo idle), bit7 = unjoinable (started or full)
    C->S  $04 JOIN       name(ASCII) -- join that player's room
    S->C  $05 START      seat(1) count(1) seed_lo seed_hi delay(1)
                         roster(4 x name8, seat-ordered, unused all-NUL)
    C<->C $06 INPUT      seat tick_lo tick_hi in11F(1) inKP(1) (fanout)
    C<->C $07 CRC        seat tick_lo tick_hi crc_lo crc_hi (fanout+logged)
    C<->C $08 STATE      chunk data                         (fanout)
    C<->C $09 RESYNC     tick_lo tick_hi                    (fanout)
    C->S  $0A BYE
    S->C  $0B PEER_LEFT  seat(1) name(8) -- who left; match over
    C->S  $0C PING   ->  S->C $0D PONG
    S->C  $0E ROOM       count(1) roster(4 x name8) -- membership change;
                         count 0 = room dissolved, back to the lobby
    C->S  $0F GO         host only: start the match now (2-4 members)
"""
import argparse
import json
import logging
import random
import selectors
import socket
import threading
import time
import urllib.request

log = logging.getLogger("intvnet")

T_HELLO, T_LIST, T_LOBBY, T_JOIN, T_START = 0x01, 0x02, 0x03, 0x04, 0x05
T_INPUT, T_CRC, T_STATE, T_RESYNC = 0x06, 0x07, 0x08, 0x09
T_BYE, T_PEER_LEFT, T_PING, T_PONG = 0x0A, 0x0B, 0x0C, 0x0D
T_ROOM, T_GO = 0x0E, 0x0F

RELAY_TYPES = {T_INPUT, T_CRC, T_STATE, T_RESYNC}
NAME_CHARS = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
PROTO_VER = 2
DEFAULT_DELAY = 3
# Room capacity.  Shark Shark hard-caps at 2 players (the cart's own boot
# prompt rejects any value > 2) and both play simultaneously.
MAX_SEATS = 2
# Roster slots ON THE WIRE.  This is a PROTOCOL constant, not a capacity:
# the client's SES_FLEN pins START at 38 bytes (seat+count+seed+delay+4x8
# name slots).
ROSTER_SLOTS = 4

MAX_TX_BACKLOG = 64 * 1024      # bytes queued per client before drop
MAX_CLIENTS = 64                # global established-connection cap
MAX_CONNECTIONS_PER_IP = 8      # generous: FujiNets can share a NAT address
HELLO_TIMEOUT = 60              # seconds to identify before drop (pre-HELLO only)
STATS_INTERVAL = 60             # seconds between abuse-counter summaries


def frame(ftype, payload=b""):
    body = bytes([ftype]) + payload
    assert len(body) <= 255
    return bytes([len(body)]) + body


def pad_name(name):
    return name.encode("ascii")[:8].ljust(8, b"\0")


class Room:
    """Join order = seat order; members[0] is host.  Implicit: a solo idle
    client has no Room at all -- one is created by the first JOIN."""

    def __init__(self, host):
        self.members = [host]
        self.started = False
        self.seed = 0
        self.crc = {}           # tick -> {seat: crc}
        self.crc_ok = 0         # fully-agreed CRC rounds this match

    def roster(self):
        pads = b"".join(pad_name(m.name) for m in self.members)
        return pads + b"\0" * 8 * (ROSTER_SLOTS - len(self.members))

    def __repr__(self):
        return "[" + " ".join(m.name or "?" for m in self.members) + "]"


class Client:
    def __init__(self, sock, addr):
        self.sock = sock
        self.addr = addr
        self.rx = bytearray()
        self.tx = bytearray()
        self.name = None
        self.room = None             # Room when hosting/joined/matched
        self.connected_at = time.time()
        self.dead = False            # set by drop(); guards late events

    @property
    def seat(self):
        return self.room.members.index(self) if self.room else None

    @property
    def solo(self):
        return self.name is not None and self.room is None

    def __repr__(self):
        return f"<{self.name or self.addr}>"


class Server:
    def __init__(self, port, delay=DEFAULT_DELAY, lobby=None, auto_go=0):
        self.sel = selectors.DefaultSelector()
        self.port = port
        self.delay = delay
        self.auto_go = auto_go       # rig only: GO when a room reaches N
        self.by_name = {}
        self.lobby = lobby
        self.clients = set()
        self.stats = {
            "tx_backlog_drops": 0,
            "hello_timeouts": 0,
            "connection_limit_rejections": 0,
        }
        self._last_stats = {**self.stats, "lobby_publish_failures": 0}

    def lobby_update(self):
        if self.lobby:
            self.lobby.update(len(self.by_name))

    # ---- plumbing ---------------------------------------------------------
    def run(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", self.port))
        srv.listen(8)
        srv.setblocking(False)
        self.sel.register(srv, selectors.EVENT_READ, None)
        log.info("listening on :%d", self.port)
        last_sweep = last_stats = time.time()
        while True:
            for key, mask in self.sel.select(timeout=1.0):
                if key.data is None:
                    self.accept(srv)
                    continue
                client = key.data
                try:
                    if mask & selectors.EVENT_WRITE and not client.dead:
                        self.flush(client)
                    if mask & selectors.EVENT_READ and not client.dead:
                        self.service(client)
                except Exception:
                    log.exception("unexpected error serving %r", client)
                    self.drop(client, "internal protocol error")
            now = time.time()
            if now - last_sweep >= 1.0:
                last_sweep = now
                self.sweep(now)
            if now - last_stats >= STATS_INTERVAL:
                last_stats = now
                self.log_stats()

    def accept(self, srv):
        sock, addr = srv.accept()
        if len(self.clients) >= MAX_CLIENTS:
            self.stats["connection_limit_rejections"] += 1
            log.warning("reject %s: server full (%d clients)",
                        addr, len(self.clients))
            sock.close()
            return
        per_ip = sum(1 for c in self.clients if c.addr[0] == addr[0])
        if per_ip >= MAX_CONNECTIONS_PER_IP:
            self.stats["connection_limit_rejections"] += 1
            log.warning("reject %s: per-IP limit (%d)", addr, per_ip)
            sock.close()
            return
        sock.setblocking(False)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        client = Client(sock, addr)
        self.clients.add(client)
        self.sel.register(sock, selectors.EVENT_READ, client)
        log.info("connect from %s", addr)

    def send(self, client, data):
        if client.dead:
            return
        if len(client.tx) + len(data) > MAX_TX_BACKLOG:
            self.stats["tx_backlog_drops"] += 1
            self.drop(client, "transmit backlog exceeded")
            return
        client.tx += data
        self.flush(client)

    def flush(self, client):
        while client.tx:
            try:
                n = client.sock.send(client.tx)
            except BlockingIOError:
                break
            except OSError:
                self.drop(client, "send error")
                return
            if n == 0:
                self.drop(client, "send returned 0")
                return
            del client.tx[:n]
        self._update_events(client)

    def _update_events(self, client):
        events = selectors.EVENT_READ
        if client.tx:
            events |= selectors.EVENT_WRITE
        try:
            self.sel.modify(client.sock, events, client)
        except (KeyError, ValueError):
            pass                # already unregistered by drop()

    def sweep(self, now):
        for client in list(self.clients):
            if client.name is None and now - client.connected_at > HELLO_TIMEOUT:
                self.stats["hello_timeouts"] += 1
                self.drop(client, f"no hello within {HELLO_TIMEOUT}s")

    def log_stats(self):
        counts = dict(self.stats)
        counts["lobby_publish_failures"] = self.lobby.failures if self.lobby else 0
        if counts == self._last_stats:
            return
        self._last_stats = counts
        unidentified = sum(1 for c in self.clients if c.name is None)
        log.info("stats: active_clients=%d unidentified_clients=%d %s",
                 len(self.clients), unidentified,
                 " ".join(f"{k}={v}" for k, v in sorted(counts.items())))

    def room_broadcast(self, room):
        payload = bytes([len(room.members)]) + room.roster()
        for m in room.members:
            self.send(m, frame(T_ROOM, payload))

    def dissolve(self, room, notify):
        """Return every member to solo; `notify` get ROOM count=0."""
        for m in list(room.members):
            m.room = None
        for m in notify:
            self.send(m, frame(T_ROOM, bytes([0]) + b"\0" * 32))
        room.members.clear()

    def drop(self, client, why):
        if client.dead:
            return
        client.dead = True
        log.info("drop %r: %s", client, why)
        try:
            self.sel.unregister(client.sock)
        except (KeyError, ValueError):
            pass
        try:
            client.sock.close()
        except OSError:
            pass
        self.clients.discard(client)
        # remove every alias, not just the current name: repeated HELLOs may
        # have left more than one entry pointing here
        stale = [n for n, c in self.by_name.items() if c is client]
        for n in stale:
            del self.by_name[n]
        if stale:
            self.lobby_update()
        room = client.room
        if room is None:
            return
        seat = client.seat
        client.room = None
        room.members.remove(client)
        if room.started:
            # any drop ends the match for everyone (user decision):
            # name the leaver, dissolve, all survivors back to the lobby
            log.info("match ended: %d CRC rounds verified; %r (seat %d) left",
                     room.crc_ok, client, seat)
            pl = frame(T_PEER_LEFT, bytes([seat]) + pad_name(client.name))
            survivors = list(room.members)
            self.dissolve(room, notify=())
            for m in survivors:
                self.send(m, pl)
                log.info("%r back to lobby (peer left)", m)
        elif seat == 0:
            # host left a forming room: dissolve it
            log.info("room %r dissolved (host left)", room)
            self.dissolve(room, notify=list(room.members))
        else:
            # guest left a forming room: reseat and re-announce
            if len(room.members) < 2:
                self.dissolve(room, notify=list(room.members))
            else:
                self.room_broadcast(room)
        self.lobby_update()

    def service(self, client):
        try:
            data = client.sock.recv(4096)
        except BlockingIOError:
            return
        except OSError:
            self.drop(client, "recv error")
            return
        if not data:
            self.drop(client, "closed")
            return
        client.rx += data
        while True:
            if not client.rx:
                return
            need = client.rx[0] + 1
            if need < 2 or client.rx[0] > 200:
                self.drop(client, f"bad frame length {client.rx[0]}")
                return
            if len(client.rx) < need:
                return          # wait for the rest of the frame
            body = bytes(client.rx[1:need])
            del client.rx[:need]
            try:
                self.handle(client, body[0], body[1:])
            except ProtocolError as e:
                self.drop(client, str(e))
                return
            if client.dead:
                return          # relay side effects can drop us mid-batch

    # ---- protocol ---------------------------------------------------------
    def handle(self, client, ftype, payload):
        if ftype in RELAY_TYPES:
            room = client.room
            if room is None or not room.started:
                return          # match just ended; console hasn't noticed yet
            if ftype == T_CRC and len(payload) == 5:
                self.log_crc(client, payload)
            data = frame(ftype, payload)
            for m in room.members:
                if m is not client:
                    self.send(m, data)
            return
        if ftype == T_HELLO:
            self.on_hello(client, payload)
        elif ftype == T_LIST:
            self.on_list(client)
        elif ftype == T_JOIN:
            self.on_join(client, payload)
        elif ftype == T_GO:
            self.on_go(client)
        elif ftype == T_BYE:
            self.drop(client, "bye")
        elif ftype == T_PING:
            self.send(client, frame(T_PONG))
        else:
            raise ProtocolError(f"unknown type ${ftype:02X}")

    def on_hello(self, client, payload):
        if len(payload) < 3:
            raise ProtocolError("short hello")
        if payload[0] != PROTO_VER:
            raise ProtocolError(f"protocol version {payload[0]}, want {PROTO_VER}")
        name = payload[1:].decode("ascii", "replace").rstrip("\0 ")
        if not (2 <= len(name) <= 8) or not set(name) <= NAME_CHARS:
            raise ProtocolError(f"bad name {name!r}")
        old = self.by_name.get(name)
        if old is not None and old is not client:
            self.drop(old, "replaced by new connection")
        if client.name is not None and client.name != name:
            # repeated HELLO with a new name: clean up the old alias
            if self.by_name.get(client.name) is client:
                del self.by_name[client.name]
            log.info("rename %r -> %s", client, name)
        client.name = name
        self.by_name[name] = client
        log.info("hello %r", client)
        self.lobby_update()
        self.on_list(client)

    def _status(self, c):
        """LOBBY status byte: low 3 bits = room member count (1 = solo
        idle), bit7 = unjoinable (match started or room full)."""
        if c.room is None:
            return 1
        n = len(c.room.members)
        busy = 0x80 if (c.room.started or n >= MAX_SEATS) else 0
        return busy | n

    def on_list(self, client):
        others = [c for c in self.by_name.values()
                  if c is not client and c.name]
        others = others[:8]     # INTV client frame buffer sizing
        payload = bytes([len(others)])
        for c in others:
            payload += pad_name(c.name) + bytes([self._status(c)])
        self.send(client, frame(T_LOBBY, payload))

    def on_join(self, client, payload):
        if client.name is None:
            raise ProtocolError("join before hello")
        if client.room is not None:
            return              # already in a room; ignore crossed join
        name = payload.decode("ascii", "replace").rstrip("\0 ")
        target = self.by_name.get(name)
        # Joining ANY member of a forming room joins that room (the join
        # redirects to the room, not the individual) -- what the lobby's
        # occupancy display implies, and what keeps the rig's auto-join
        # consoles from ping-ponging on a guest's entry.
        if (target is None or target is client or target.name is None
                or (target.room is not None
                    and (target.room.started
                         or len(target.room.members) >= MAX_SEATS))):
            self.on_list(client)      # refresh; target gone or unjoinable
            return
        room = target.room
        if room is None:
            room = Room(target)
            target.room = room
        room.members.append(client)
        client.room = room
        log.info("join: %r -> room %r", client, room)
        self.room_broadcast(room)
        self.lobby_update()
        if self.auto_go and len(room.members) >= self.auto_go:
            self.start_room(room)

    def on_go(self, client):
        room = client.room
        if room is None or room.started or client.seat != 0:
            return
        if not (2 <= len(room.members) <= MAX_SEATS):
            return
        self.start_room(room)

    def start_room(self, room):
        room.started = True
        room.seed = random.randrange(1, 0x10000)
        room.crc.clear()
        room.crc_ok = 0
        common = bytes([len(room.members), room.seed & 0xFF,
                        room.seed >> 8, self.delay]) + room.roster()
        for seat, m in enumerate(room.members):
            self.send(m, frame(T_START, bytes([seat]) + common))
        log.info("match: room %r started, %d players (seed $%04X)",
                 room, len(room.members), room.seed)
        self.lobby_update()

    def log_crc(self, client, payload):
        room = client.room
        seat = payload[0]
        tick = payload[1] | (payload[2] << 8)
        crc = payload[3] | (payload[4] << 8)
        entry = room.crc.setdefault(tick, {})
        entry[seat] = crc
        if len(room.crc) > 64:
            room.crc.pop(min(room.crc))
        if len(entry) < len(room.members):
            return
        vals = set(entry.values())
        room.crc.pop(tick, None)
        if len(vals) != 1:
            log.warning("CRC MISMATCH tick %d: %s", tick,
                        " ".join(f"seat{s}=${c:04X}"
                                 for s, c in sorted(entry.items())))
        else:
            room.crc_ok += 1
            if room.crc_ok % 4 == 0:
                log.info("crc ok through tick %d (%d rounds)",
                         tick, room.crc_ok)


class ProtocolError(Exception):
    pass


class LobbyPublisher:
    """Registers this server as a room on the FujiNet Lobby
    (https://lobby.fujinet.online): POST /server on state changes AND on a
    periodic keepalive, status:"offline" POST on shutdown.

    The Lobby tracks a lastping per entry, so a quiet server that never
    re-POSTs goes stale in every client's list -- the keepalive re-POST
    (KEEPALIVE_SECS) is what keeps the room visible between matches.

    The platform string must be "intv": that is what the Intellivision
    Lobby client queries (`/view?bin=1&platform=intv`, fujinet-lobby
    intv/st_list.bas); "intellivision" entries never show up in it.

    One worker thread owns all HTTP traffic: updates are coalesced under a
    condition variable and only the newest player count is published, at most
    once per second, so connection churn can never fan out into unbounded
    threads or overlapping requests."""

    KEEPALIVE_SECS = 300.0

    def __init__(self, base_url, serverurl, client_url, appkey, region="us",
                 game_name="Shark! Shark!", server_name="Shark Shark Netplay"):
        self.base_url = base_url.rstrip("/")
        self.payload = {
            "game": game_name,
            "appkey": appkey,
            "server": server_name,
            "region": region,
            "serverurl": serverurl,
            "status": "online",
            "maxplayers": 2,
            "curplayers": 0,
            "clients": [{"platform": "intv", "url": client_url}],
        }
        self.failures = 0
        self._cond = threading.Condition()
        self._dirty = False
        self._stopping = False
        self._stop_evt = threading.Event()
        self._worker = threading.Thread(target=self._run, daemon=True)
        self._worker.start()

    def update(self, curplayers):
        with self._cond:
            if self._stopping:
                return
            self.payload["curplayers"] = curplayers
            self._dirty = True
            self._cond.notify()

    def shutdown(self):
        with self._cond:
            self._stopping = True
            self.payload["status"] = "offline"
            snapshot = dict(self.payload)
            self._cond.notify()
        self._stop_evt.set()
        self._worker.join(timeout=12)   # let an in-flight POST finish first
        self._post(snapshot)

    def _run(self):
        while True:
            with self._cond:
                deadline = time.monotonic() + self.KEEPALIVE_SECS
                while not self._dirty and not self._stopping:
                    if not self._cond.wait(deadline - time.monotonic()):
                        self._dirty = True      # keepalive: re-POST as-is
                self._dirty = False
                if self._stopping:
                    return
                snapshot = dict(self.payload)
            self._post(snapshot)
            self._stop_evt.wait(1.0)    # debounce; returns early on shutdown

    def _post(self, payload):
        try:
            req = urllib.request.Request(
                self.base_url + "/server",
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                log.debug("lobby POST -> %d", resp.status)
        except OSError as e:
            self.failures += 1
            log.warning("lobby POST failed: %s", e)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9113)
    ap.add_argument("--game-name", default="Shark! Shark!",
                    help="game name for the FujiNet Lobby registration")
    ap.add_argument("--server-name", default="Shark Shark Netplay",
                    help="server name for the FujiNet Lobby registration")
    ap.add_argument("--delay", type=int, default=DEFAULT_DELAY,
                    help="lockstep input delay in game ticks")
    ap.add_argument("--auto-go", type=int, default=0, metavar="N",
                    help="rig only: start a room automatically once it has "
                         "N members (production uses the host's GO)")
    ap.add_argument("--debug", action="store_true")
    ap.add_argument("--lobby-enabled", action="store_true",
                    help="register with the FujiNet Lobby (production runs: "
                         "server/run_production.sh passes this)")
    ap.add_argument("--lobby-url", default="https://lobby.fujinet.online")
    ap.add_argument("--lobby-serverurl",
                    default="TCP://fujinet.online:9113/",
                    help="public endpoint clients should use")
    ap.add_argument("--lobby-client-url",
                    default="TNFS://apps.irata.online/Intellivision/Games/"
                            "SharkShark.rom",
                    help="TNFS path of the client ROM for Lobby boot")
    ap.add_argument("--lobby-appkey", type=int, default=21,
                    help="FujiNet-registry appkey id for this game "
                         "(Shark! Shark! = 21; the Lobby rejects 0)")
    args = ap.parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s")
    lobby = None
    if args.lobby_enabled:
        lobby = LobbyPublisher(args.lobby_url, args.lobby_serverurl,
                               args.lobby_client_url, args.lobby_appkey,
                               game_name=args.game_name,
                               server_name=args.server_name)
        lobby.update(0)
    try:
        Server(args.port, args.delay, lobby, auto_go=args.auto_go).run()
    finally:
        if lobby:
            lobby.shutdown()


if __name__ == "__main__":
    main()
