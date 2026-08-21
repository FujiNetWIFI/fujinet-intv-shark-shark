# Claude guidance for fujinet-intv-shark-shark

Twelfth FujiNet netplay port (Shark! Shark!, Mattel 1982). **Read
`PORTING.md` before touching anything** — it is the accumulated
methodology of all eleven prior ports (this repo's copy is Boxing's, the
newest, through §7.36); `spikes/NOTES.md` has this cart's own evidence
trail (M0-M8, including two real methodology corrections made and
verified live in the same session — read it before trusting a stale
comment anywhere that still talks about a turn arbiter, a 4-seat rig, or
whole-checksum lagcheck).

**Working. Every automated gate in the ladder passes, run for real this
session**: `verify-org` → `verify-patch` (38 words) → `check-7000` →
every build variant assembles clean → live boot-dump matches the
recon-predicted state → `lagcheck` (peak 120/209 at shift=20 via a
dedicated `LAG_RING`, not the family's usual whole-checksum correlation
— see below) → `det` (256/256 ticks identical under stall, destination-
phase asserted) → `echo-test` (100 clean rounds) → `server-diff` (6/6
scenarios, 2 seats) → `rig PLAYERS=2` (0 CRC mismatches across 24 rounds)
→ `m4 PLAYERS=2`, both the plain cap-path AND `QUIESCE=1`'s quiescent
path (both PASS, 0 drops, full repair confirmed) → `peerleft PLAYERS=2`,
both leave modes → hardware images built (`build/sharkshark_net.rom`,
`build/sharkshark_nethud.rom`). **Not yet run on real hardware** — that
needs the user. Port 9113 / Lobby appkey 21 need provisioning on
`fujinet.online` before a production launch.

**This cart is 1-2 players, SIMULTANEOUS — not 2-4/turn-based.** The
cart's own boot prompt reads "SELECT 1 OR 2 PLAYERS" and its accept logic
rejects anything above 2. Both controllers drive independent,
simultaneously-active divers every tick (Boxing's shape, not Golf's
turn-arbiter shape) — confirmed live, not just from the accept logic:
the EXEC's own `SUBI #$011F,R1` scan mechanism hands the shared per-seat
handler R1=0/1 directly, and `L_63D3` branches on it to pick `$031D`
(MOB0) vs. `$0325` (MOB1, stride 8). **The scaffold was originally built
from Golf's 4-seat turn-arbiter tree on a mistaken premise and was
corrected mid-session** — `MAX_SEATS=2` everywhere, `tools/server_diff.py`
swapped to Boxing's/Sea Battle's 2-seat-pinned copy, `main_net3.asm`/
`main_net4.asm` removed, all test scripts' hardcoded ports fixed. See
`spikes/NOTES.md` M1 for the full trail.

**This is the first 8K-word cart in the family** — every one of the
eleven prior ports was 4K-word, and this one already occupies
`$5000-$67F9` (real code; `$67FA-$6FFF` is zero fill), the exact page
every prior port's netcode ORG'd into. `src/hook.asm`'s ORG moved to
**`$6800`** (the cart's own unused tail) — resolves to `$6800-$6BFA`
(1019 of 2048 words used), comfortably clear of the fatal `$7000`.
`NET_SESSION` stays at `$D000`, unchanged from every prior port.

Hard rules and confirmed findings:

- Never let any segment map, or overflow into, `$7000`. `make check-7000`
  does a full SPAN check (`tools/check_7000.py`), not just a
  start-address grep — real insurance here, since this cart's netcode
  segment sits half as close to the boundary as any prior port's.
- Never put netcode RAM below `$8080` (STIC alias).
- The patched dump (`build/sharkshark_patched.asm`) is **truncated at
  `$67FA`** (`tools/dump_rom.py --stop 67FA`, 6138 words) so it doesn't
  collide with `hook.asm`'s own `ORG $6800`. `verify-patch` compares only
  those 6138 words (`tools/check_patch.py`'s `COMPARE_WORDS` arg).
- Zero references to `$011F`-`$0124` anywhere — dispatch-only for input,
  like Boxing/Utopia/Auto Racing. No shadow-pair patch.
- **14 RNG call sites**, all `X_RAND2`, the most of any port to date
  (previous record: Armor Battle's 9). One `SS_RAND2` wrapper.
- **Five game timer entries**, ALL fully virtualized (Bowling/Golf's
  model — 5 real entries, only 2 table slots free after the music
  placeholder + `MASTER_TICK`, so native dispatch doesn't fit): `$5B1A`
  (1.25Hz, spawn roll + HUD digit), `$5B75` (0.44Hz, shark-vs-diver
  steering AI), `$5C7F` (2.00Hz, bite/collision — the one `$628D` stops
  at game over), `$5CEA` (9.99Hz, **primary**: tick/spawn/flicker, calls
  the ISR dance below unconditionally every tick), `$5D5B` (0.25Hz,
  post-catch recovery). Ties Frog Bog's five-entry dispatcher, the
  busiest to date — none has interval 1, so ALL FIVE need a countdown
  (`SS_ARM1-5`/`SS_CNT1-5`, `src/ram.asm`).
- **Arm/stop**: `$51A7`/`$51B8` are one-time stop-ALL/start-ALL loops
  across all 5 slots; `$628D` stops slot 3 only, at game over. Only 3
  timer-API sites total.
- **The ISR dance**: `$5CEA` calls `L_5DF4` unconditionally every tick,
  saving `$0100`/`$0101` into `$015F`/`$0160` (inside the CRC'd range —
  Soccer's exact §7.27 shape) before installing `$5E14` as a temp ISR
  that copies GRAM data, writes `.STIC.VIDEN`, restores the vector,
  **calls `X_PLAY_NOTE`**, and returns. `SC_ISR_SAVE` is aliased directly
  onto `$015F` (not a spare cell) so the family's unchanged
  `RS_CLAMP_ISR` clamps it correctly; `SC_ISR_BODY = $5E00` for
  `DANCE_SETTLE`; the `X_MUSIC_TICK` slot-0 placeholder is **provably
  load-bearing** (§7.35, same finding as Boxing).
- **The boot prompt dispatches through the standard `$035D` mechanism**
  (confirmed live: `$035D=$5185` while parked at the prompt) — `$1910`
  installs the R4-supplied table internally, invisible to a cart-only
  scan. `SS_INJECT` (`src/hook.asm`) answers it deterministically from
  `NET_COUNT`, unconditionally (no arbiter to gate it on) — confirmed
  live to drive the ENTIRE boot sequence with zero forced/scripted input
  at all (`$0172` lands at 2, `GAME_TBL` moves to `SS_HTBL_LIVE`, both
  MOB0 and MOB1 populate).
- **`lagcheck` does NOT use the family's usual whole-`TRACE_RING`-
  checksum correlation** (Golf's §7.33 design) — investigated and
  rejected: this cart's checksummed state is dominated by four
  always-armed, real-time-scheduled timer entries (ambient AI/spawn,
  independent of input), which structurally defeats a delay-shift
  correlation regardless of whether the delay ring itself is correct.
  Instead correlates a dedicated `LAG_RING` (`$9200`, `src/ram.asm`,
  written by `debug.asm`'s `TRACE_TICK`) tracking `$0168`/`$0169` (P1/P2's
  most-recently-dispatched disc heading, a direct un-smoothed input
  echo). See `spikes/NOTES.md` M5 for the full diagnosis.
- **`test/run_m4.sh` uses TWO DIFFERENT faults**, gated on `$QUIESCE`:
  plain mode pokes `$0168` (one-shot, contained — safe because nothing
  reads it every tick); `QUIESCE=1` mode pokes `$0172`/SS_PCOUNT instead
  (immediate and reliable — the same property that made it the WRONG
  choice for the plain test is exactly right here) AND forces the
  underlying MOB "alive" bits (`$031D`/`$0325`/`$0323`/`$032B`), not the
  derived `SS_QUIESCENT` flag directly — `SS_GAME_TICK` recomputes that
  flag fresh every tick, before `RS_PENDING` ever reads it, so forcing
  the flag itself is structurally unable to work regardless of window
  width; forcing the inputs it's computed from is what actually works.
  See `spikes/NOTES.md` M8 for the three-iteration investigation — this
  also gives the first live confirmation that the `SS_QUIESCENT`
  derivation hypothesis (both MOB alive-bits clear) is correct.
- `test/run_rig.sh`/`run_m4.sh`/`tools/check_dest_phase.py` accept
  `GAME_TBL` landing on `SS_HTBL_LIVE` (with `$0172` in 1-2), `SS_HTBL_NULL`
  ($1906), or `SS_HTBL_PLAYAGAIN` (`$629C`) as valid real-gameplay
  evidence — masked fuzz is reckless enough that both divers can
  legitimately get caught well inside a 100s rig run; reaching game over
  requires MORE real gameplay than parking on the boot prompt ever could.
- `r N` in jzIntv scripts counts INSTRUCTIONS (~200k/emulated second);
  breakpoint-forced injection is exploration-only (§7.17); exact-tick
  gates use the in-ROM `SCRIPT_TBL` or `TRACE_DONE` parks.
- Rig scripts pkill `fujinet -u 127.0.0.1:1808` — never type that pattern
  in an interactive shell command line (`pkill -f` matches your own shell
  and kills it).
- The default FujiNet-workspace BOIP port (9995) is already held by an
  unrelated long-running `fujinet-pc-rs232` instance on this workstation —
  `make echo-test`/`run-net1` need `FN_BOIP=` pointed at a free port
  (`19851+` are open) with a matching `fnconfig.ini` edit in a private
  dist copy; `make rig`/`m4`/`peerleft` set up their own isolated private
  copies automatically and are unaffected.
- `test/run_hookcheck.sh` was removed rather than carried forward — it
  was already explicitly disowned in Golf's copy and isn't part of the
  gate ladder.

Gate ladder, all PASS: verify-org → verify-patch → check-7000 → every
build variant assembles → live boot-dump vs. recon-predicted state →
lagcheck → det (+ dest-phase) → echo-test → server-diff --seats 2 → rig
PLAYERS=2 → m4 (+ QUIESCE=1) PLAYERS=2 → peerleft PLAYERS=2 (both leave
modes) → hardware images built.

Assignments: production port 9113, FujiNet Lobby appkey 21, maxplayers 2.
The server (`server/intv_relay_server.py`) is protocol v2 (seat-tagged,
rooms), `MAX_SEATS=2` (agrees with the Lobby payload's `maxplayers: 2`);
`server/c/` is the generic C relay, held to byte-for-byte equality by
`tools/server_diff.py --seats 2`.

Known open item (not blocking): the wall tick rate was never measured
live at `MASTER_TICK` with a two-point cycle sample this session (the
header's 9.99Hz arithmetic was used to pick `d`, per `main_net.asm`'s
default) — given the ISR dance runs every tick, the REAL rate is likely
somewhat slower than 9.99Hz (§7.28, matching Soccer's precedent). Every
emulated gate passed regardless, but tune `d` from the HUD's live `L`
figure during real hardware bring-up rather than trusting the header
figure at face value.
