# intv-relay — the C relay

A C port of the Python relays. They stay canonical: they are the reference
every behaviour here is derived from, and `tools/server_diff.py` holds this
binary to byte-for-byte equality with them on the wire and in the log. If they
ever disagree, **the Python is right and this is a bug** — except for the
differences listed under "Deliberate divergences".

Unlike the Python, this binary covers **every game**, both protocol
generations. `--proto` picks the wire format and `--max-seats` the room
capacity:

| `--proto` | games | reference implementation |
|---|---|---|
| `2` (default) | PBA Bowling (4 seats), NASL Soccer (2) | `../intv_relay_server.py` |
| `1` | Baseball, Auto Racing, NFL Football, Armor Battle, Utopia, Frog Bog | any of those repos' `server/bbnet_server.py` |

**Pick the right one — a mismatch is silent from the couch.** A v1 console
against a `--proto 2` port completes its TCP connect and is then dropped on
the HELLO, which looks exactly like a lobby nobody ever joins. The server says
so once per process in the log, and `drop ...: protocol version 1, want 2`
names it per connection.

The two generations differ in far more than the seat count, which is why they
are a flag and not an inference:

| | v1 | v2 |
|---|---|---|
| HELLO version byte | **not checked at all** | must be 2 |
| matchmaking | JOIN pairs and starts the match at once | JOIN builds a room; host sends GO |
| START body | `role seed_lo seed_hi delay opponent(8)` = 13 | `seat count seed_lo seed_hi delay roster(32)` = 38 |
| INPUT / CRC | 4 bytes, untagged | 5 bytes, seat-tagged |
| CRC comparator | per-client logs; the second reporter pops the partner's entry | per-room tick table, N-way |
| CRC log line | `(%d pairs)` | `(%d rounds)` |
| PEER_LEFT | empty | `seat(1) name(8)` |
| LOBBY status byte | `0` idle / `1` busy | member count, bit7 = unjoinable |
| ROOM `$0E`, GO `$0F` | do not exist (GO drops the connection) | exist |

`--proto` is deliberately **not** auto-detected from the HELLO. A relay serves
one game per port, and a v1 console can never be paired with a v2 one, so
guessing would only convert a clean rejection into a corrupt match.

## Build

```sh
make -C server/c            # -> server/c/intv-relay
make -C server/c strict     # the same, with -Werror  (gate 0)
make -C server/c asan       # ASan + UBSan build      (gate 0)
```

No external dependencies. `cc`, libc, and `-lpthread`; the binary links
nothing else. The Lobby POST is hand-rolled plain HTTP over a socket, the same
approach as `servers/examples/two-players/src/lobby-update.c`, because the
Lobby's Go server binds `:8080` (`fujinet-lobby/server/main.go:57`) and the
relay reaches it directly. There is no TLS to terminate and therefore no TLS
to link.

## Running it

```sh
server/c/intv-relay --port 9109 --max-seats 2          # Soccer
server/c/intv-relay --port 9108 --max-seats 4 \
    --game-name "PBA Bowling" --lobby-appkey 16        # Bowling
server/c/intv-relay --port 9100 --proto 1 \
    --game-name "Baseball" --lobby-appkey 10           # Baseball, and the
                                                       # other five v1 games
```

The test scripts and the production launcher select the implementation by
environment variable, defaulting to the Python:

```sh
SERVER=c make rig            # and m4, peerleft, lobby
RELAY=c server/run_production.sh
SEATS=4 SERVER=c tools/bbnet_client_sim.py
```

The differential covers both generations.  The v1 oracle lives in a sibling
repo, so that run is opt-in on having it checked out:

```sh
make server-diff                                  # v2, against ../intv_relay_server.py
tools/server_diff.py --proto 1 --python-server \
    ../intv-baseball-experiment/server/bbnet_server.py
```

### Flags

Every flag the Python takes, with the same defaults, plus four.

| flag | default | notes |
|---|---|---|
| `--port N` | 9109 | |
| `--proto N` | 2 | **new** — 1 or 2; see the table above |
| `--max-seats N` | 2 | **new** — 2..4; room capacity, *not* the wire roster. v2 only |
| `--game-name S` | `NASL Soccer` | Lobby registration |
| `--server-name S` | `Soccer Netplay` | Lobby registration |
| `--delay N` | 3 | lockstep input delay, byte [4] of START |
| `--auto-go N` | 0 | rig only; clamped to `--max-seats` (the Python is not). Ignored with `--proto 1`, where JOIN already starts the match |
| `--debug` | off | |
| `--lobby-enabled` | off | |
| `--lobby-url URL` | `http://fujinet.online:8080` | **http:// only** |
| `--lobby-serverurl URL` | `TCP://fujinet.online:9109/` | |
| `--lobby-client-url URL` | the TNFS ROM path | |
| `--lobby-appkey N` | 17 | the Lobby rejects 0 |
| `--lobby-region S` | `us` | **new** |
| `--lobby-keepalive SECS` | 300 | **new**, test hook — a subprocess cannot be monkeypatched the way `tools/test_lobby_pub.py` patches the Python class attribute |
| `--fixed-seed N` | off | **new**, test only — pin the match seed |

## `ROSTER_SLOTS` is 4 no matter what `--max-seats` says

This is the one thing in the file that will look wrong and is not.

`ROSTER_SLOTS` is a **protocol constant**, not a capacity. The console's
`SES_FLEN` table (`src/netcode/session.asm:1063-1080`) pins START at 38 bytes
and ROOM at 34, which is `seat + count + seed + delay + 4×8 name slots`. A
2-seat room still emits four roster slots with the last two all-NUL. Shrinking
it to match `--max-seats` would save 16 bytes and silently misframe every
console on the wire — the client would read the next frame's length byte out
of the middle of this one.

## The defect this fixes

**This is a v2-only defect.** `intv_relay_server.py:333-348` has no
partial-frame guard — it is missing the `if len(client.rx) < need: return`
that every v1 server still has (`intv-baseball-experiment/server/
bbnet_server.py:254`). The v2 room rewrite dropped it, and Bowling and Soccer
both inherited the loss.

Consequence in the Python: a TCP segment boundary in the middle of a frame
hands `handle()` a truncated payload, which is then relayed to the peer
verbatim; or, when only the length byte has arrived, `body[0]` raises
`IndexError`, which is not a `ProtocolError`, so it escapes to the event
loop's bare `except Exception` and the client is dropped with "internal
protocol error". Most likely to bite on the 99-byte STATE chunks during
resync, which are the largest frames on the wire.

`tools/server_diff.py --scenario framing` demonstrates it: dribbling a single
PING frame in one-byte writes kills the v2 Python connection outright and is
handled correctly here. Under `--proto 2` that scenario is expected to diverge
and is reported, not failed, unless you pass `--strict`. Under `--proto 1` the
very same scenario **passes byte-for-byte**, which is the cleanest evidence
that the guard belongs there and v2 simply lost it.

## Log output is a contract

`test/run_rig.sh:150-156`, `test/run_m4.sh:143-148` and
`tools/bbnet_client_sim.py` parse the server log. The format matches
`logging.basicConfig(format="%(asctime)s %(levelname)s %(message)s")` exactly,
on **stderr**, line-buffered so each record is one `write(2)` — the harnesses
read the log while the server is still running.

Four `%r`-evaluation-order traps in the Python are reproduced deliberately:

- `rename %r -> %s` is logged **before** the assignment, so it shows the **old** name.
- `join: %r -> room %r` is logged **after** the append, so the room repr **includes** the joiner.
- `room %r dissolved (host left)` is logged **after** `members.remove`, so the host is **already gone** from it.
- the `stats:` tail is `sorted(counts.items())` — alphabetical by key.

## Deliberate divergences

1. **SIGTERM shuts down gracefully.** The Python only handles SIGINT; SIGTERM
   kills it outright, so `subprocess.terminate()` never produces the Lobby's
   `status:"offline"` POST. Here both signals run the full shutdown. This is
   what makes a process-level `tools/test_lobby_pub.py` possible.
2. **`--auto-go` is clamped to `--max-seats`**, with a warning. In the Python
   `--auto-go 5 --max-seats 4` silently never fires.
3. **`maxplayers` in the Lobby payload tracks `--max-seats`.** The Python
   hardcodes 2 (`intv_relay_server.py:526`), which is right for this game and
   wrong for a shared binary.
4. **Send loops snapshot the member list first.** The Python iterates
   `room.members` while `send()` can `drop()` a member out of that same list.
   Only reachable via a 64 KiB backlog overrun mid-broadcast, and the C
   behaviour is the one a reader would intend.
5. **One extra log line**, once per process: a v1 console arriving on a
   `--proto 2` port says so in words. `tools/server_diff.py` filters it by
   name from its `C_ONLY_LINES` list and prints how many lines it dropped, so
   that list cannot grow without someone noticing.

Three smaller, bounded ones:

- **CRC seats per tick are capped at 8.** `payload[0]` is wire-supplied (0-255)
  and the Python uses it as a dict key, so a client can report a seat it does
  not own and it appears verbatim in the mismatch line. Eight insert-or-replace
  pairs reproduce that at 1.6 KiB/room; a faithful 256-entry table would cost
  1.1 MB/room. Beyond 8 *distinct* seats in one tick the extra is dropped
  silently — unreachable with ≤4 real seats.
- **`bad name %s` uses a simplified repr.** Python renders U+FFFD for a
  non-ASCII byte; this renders `\xNN`. Nothing greps that line. The
  accept/reject *decision* is provably identical: bytes ≥0x80 each decode to
  exactly one U+FFFD character, so character count always equals byte count,
  and any such character fails the `A-Z0-9` test anyway.
- **No `log.exception` equivalent** — see below.

## The real risk

The Python's event loop wraps every client's service call in
`except Exception: log.exception(...); drop(client, "internal protocol error")`.
Any latent bug there costs one connection and leaves a traceback in the log.
**There is no such net here.** The same bug is a crash or memory corruption
that takes down every match on the port.

That is mitigated, not eliminated:

- every wire-derived index is bounds-checked at the point of use (frame
  length, name length, join-name length, CRC seat);
- allocation is fully static — fixed arrays sized by `MAX_CLIENTS`, no `malloc`
  in the steady state, so there is no allocator state to corrupt;
- gate 0 builds with ASan + UBSan and runs the full differential under it,
  leak detection on;
- `test/run_soak.sh` holds both servers under load and fails on any RSS growth
  trend.

If you change this file, re-run `tools/server_diff.py` and the ASan build. The
gates are cheap; the failure mode is not.

## Memory

Measured by `test/run_soak.sh` (32 idle lobby clients plus one live match
pumping INPUT+CRC at 20 Hz):

| | RSS start | RSS end | high-water | growth |
|---|---|---|---|---|
| `intv_relay_server.py` | 27048 K | 27056 K | **27056 K** | +4 K |
| `intv-relay` | 2896 K | 2896 K | **2896 K** | +0 K |

9.3x smaller — 23.6 MB saved per relay, and neither implementation grows over
the run. The shared host runs one relay per game on ports 9100-9109, so
converting the fleet is roughly 264 MB → 28 MB.

(90-second run; `SOAK_SECS=600 test/run_soak.sh` for a longer one.)

`.bss` is ~4.1 MB, almost all of it the 64 × 64 KiB transmit buffers, and it is
demand-paged. `flush()` compacts with `memmove` (the Python's `del tx[:n]`), so
`tx_len` returns to 0 after nearly every flush and a steady-state client only
ever touches the first page of its buffer. The array bound *is* the backlog
cap: `tx_len + n > MAX_TX_BACKLOG` failing is precisely "the memcpy would not
fit".

**What this does not buy:** throughput or latency. Two consoles trading 7-byte
frames at ~20 Hz is under 300 frames/second; the Python spends tens of
microseconds of interpreter overhead per frame and C spends well under one, and
both are a rounding error against a single core. Both set `TCP_NODELAY`, and
the relay hop is one RTT either way. The port is worth doing for footprint,
for being one binary across games, and for the framing fix — not for speed.

## Structure

`src/intv-relay.c` keeps the Python's function names *and their order in the
file* (`frame_build`, `pad_name`, `run`, `accept_client`, `send_raw`, `flush`,
`update_events`, `sweep`, `log_stats`, `room_broadcast`, `dissolve`, `drop`,
`service`, `handle`, `on_hello`, `status_byte`, `on_list`, `on_join`, `on_go`,
`start_room`, `log_crc`). Two implementations only stay in sync if the diff
between them is mechanical — keep it that way.

Two structures deserve attention:

- **`by_name` is an insertion-ordered array, never a hash.** `on_list` slices
  the first 8 entries, so the dict order *is* the lobby a console displays.
  Setting an existing key must keep its position; deleting must preserve the
  relative order of the rest. A hash map gets this wrong in a way no console
  gate would attribute to the server —`tools/server_diff.py` scenario `roster`
  exists specifically to catch it.
- **The epoll tag is `(generation << 32) | slot`.** A client can be dropped and
  its slot reused by an `accept()` inside the same `epoll_wait` batch; the
  Python is immune by object identity, and the generation counter is what makes
  this immune. The `dead` flag handles the not-yet-reused case. Both are
  needed; neither alone is sufficient.
