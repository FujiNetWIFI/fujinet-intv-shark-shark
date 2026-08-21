# Shark! Shark! (Mattel, 1982) — FujiNet netplay, 1-2 players

The twelfth FujiNet netplay port of an EXEC-era Intellivision cart. Two
consoles run the whole original Shark! Shark! in delay-based lockstep,
matched through a room-based lobby. Play is **simultaneous, not
turn-based** — the cart's own boot prompt ("SELECT 1 OR 2 PLAYERS") caps
it at 2, and both players' divers are live and independently
controllable every tick, exactly like Boxing's two boxers. There is no
turn arbiter: both seats' controller events replay every tick via the
EXEC's own controller-index handoff.

## Status

**Working. Every emulated gate passes** (2026-08-20):

| gate | result |
|---|---|
| `make verify-org` | byte-identical rebuild |
| `make verify-patch` | exactly the 38 declared words differ |
| `make check-7000` | no build maps or overflows into `$7000` |
| live boot-dump | `SS_CNT1-5` correctly seeded to their real intervals, boot prompt reached identically to the unpatched ROM |
| `make lagcheck` | dedicated `LAG_RING` (input-echo cells, not the family's usual whole-checksum correlation — see below) peaks at shift=20 (120/209 agree vs. a 72/209 baseline) |
| `make det` | 256/256 tick checksums identical under stall injection, dest-phase asserted |
| `make echo-test` | 100 clean transport rounds |
| `make server-diff` | 6/6 scenarios, 2 seats |
| `make rig PLAYERS=2` | live lockstep, 0 CRC mismatches across 24 rounds |
| `make m4 PLAYERS=2` (+ `QUIESCE=1`) | desync injected, detected, repaired — both the cap-path AND the quiescent-path proven, 0 drops |
| `make peerleft PLAYERS=2` | drop ends the match for the survivor, both leave modes, correct terminal screens |

Not yet done: real-hardware bring-up (`make rom SRV_HOST=...` already
built the images; PiRTO II, HUD on, tune `d` from the L/S/T/R/H row) and
a live two-point wall-tick-rate measurement at `MASTER_TICK` (the header's
9.99Hz arithmetic was used to pick the default delay; given this cart's
ISR dance runs every tick, the real rate is likely somewhat slower,
matching Soccer's precedent — every emulated gate passed regardless).

This port needed two real mid-session corrections, both investigated and
resolved, not worked around — see `spikes/NOTES.md` for the full trail:

1. **Seat model**: the repo was originally scaffolded from Golf's 4-seat
   turn-arbiter engine on the mistaken premise that this was a 1-4 player
   alternating-turn cart. The cart's own boot prompt and live testing
   showed it's 1-2 players, simultaneous — Boxing's shape. Corrected
   mid-session (`MAX_SEATS=2`, 2-seat `server_diff.py`, no arbiter).
2. **`lagcheck` methodology**: the family's usual whole-state checksum
   cross-correlation failed even though the delay mechanism was correct,
   because this cart's checksummed state is dominated by four
   always-armed, real-time-scheduled ambient timer entries that are
   (correctly) invariant to input delay. Fixed by tracking a direct
   input-echo cell instead of the whole checksum.

## Build & run

Prereqs: as1600/dis1600/bin2rom (jzIntv SDK), jzIntv with `--fujinet`,
fujinet-pc-rs232 dist, Python 3.

```sh
make verify-org                    # gate 0: byte-identical rebuild
make hook && make run-hook          # patched-but-local build (feel test)
make det                            # determinism proof, 256/256 ticks
make lagcheck                       # interception + delay ring proof
make rig PLAYERS=2                  # full 2-console local netplay rig, headless
make m4 PLAYERS=2                   # desync inject + repair (cap path)
QUIESCE=1 make m4 PLAYERS=2         # desync inject + repair (quiescent path)
make peerleft PLAYERS=2 LEAVER=2 LEAVE_MODE=clean    # or timeout
make rom SRV_HOST=fujinet.online    # hardware image -> build/sharkshark_net.rom
make rom-hud                        # same with the live HUD row (bring-up)
server/run_production.sh            # relay on :9113, registered on the FujiNet Lobby
```

Port 9113 / Lobby appkey 21 are this port's assignments on the shared
host, once provisioned. `FN_BOIP` (9995 by default) may need pointing at
a free port for `echo-test`/`run-net1` if another instance holds it —
`rig`/`m4`/`peerleft` set up their own isolated private copies
automatically and are unaffected.

## What is different from the sibling ports

- **Simultaneous 2-player, no turn arbiter** — closest structural match
  in the family is Boxing (dispatch-only input, both seats replay every
  tick via the controller-index register), not Bowling/Golf's
  turn-arbiter model. `MAX_SEATS=2`, matching the cart's own hard cap.
- **A boot-time keypad prompt answered through the standard dispatch
  mechanism**: "SELECT 1 OR 2 PLAYERS" is accepted by the EXEC's shared
  `$1910` number-entry routine, which installs a cart-supplied table
  (`$5185`) into `$035D` internally — invisible to a cart-only
  disassembly scan, only found by directly dumping `$035D` live while
  parked at the prompt. `SS_INJECT` answers it deterministically from
  `NET_COUNT`, confirmed live to drive the whole boot sequence with zero
  forced input.
- **The busiest timer dispatcher yet, tied with Frog Bog**: five game
  timer entries, ALL fully virtualized (no native-dispatch shortcut fits
  — 5 real entries, only 2 free table slots), none with interval 1, so
  all five need their own countdown.
- **The largest RNG surface yet**: 14 call sites, all `X_RAND2`, vs.
  Armor Battle's previous high of 9.
- **An ISR-vector swap on every tick of the primary entry** — Soccer's
  §7.27/§7.28 hazard shape, but firing unconditionally every tick rather
  than on a rare event, and the dance's own ISR body calls `X_PLAY_NOTE`,
  making the family's defensive music-placeholder slot provably
  load-bearing here too (same finding as Boxing).
- **A netcode segment layout no prior port needed**: the first 8K-word
  cart in the family — it already fills `$5000-$67F9`, so the hook
  segment moves from the family's usual `$6000` to `$6800` (the cart's
  own unused tail) while `NET_SESSION` keeps the standard `$D000` window.
- **`lagcheck` needed a genuinely different design**, not just different
  addresses: the family's whole-checksum cross-correlation is structurally
  defeated by this cart's ambient, real-time-scheduled AI/spawn logic. A
  dedicated `LAG_RING` tracking direct input-echo cells replaces it.
- **The `m4` desync-recovery test uses two different faults**, matched to
  what each specific sub-test needs (a clean one-shot corruption for the
  plain test; an immediate, reliable one plus direct MOB-bit forcing for
  the `QUIESCE=1` quiescent-branch proof) — see `CLAUDE.md`/`spikes/
  NOTES.md` for why a single fault couldn't serve both.

## Layout

Same tree as the sibling ports (see `PORTING.md`, the canonical
methodology — this repo's copy is Boxing's, the newest, through §7.36).
`spikes/NOTES.md` holds the full per-milestone evidence trail, including
both mid-session corrections and the three-iteration `m4`/`QUIESCE`
investigation.
