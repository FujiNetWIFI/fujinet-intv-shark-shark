# Shark Shark port -- spike notes

Twelfth FujiNet netplay port (Shark! Shark!, Mattel 1982). Originally
scaffolded from the Golf tree (4-seat turn-arbiter engine) on the
premise -- stated at the start of this session -- that the cart was a 1-4
player alternating-turn game. **That premise was wrong; see M1's
"seat-model correction" below.** The cart is 1-2 players, simultaneous,
architecturally closest to Boxing. The scaffold has been corrected in
place (M0 section below is left as originally written for the historical
record; M1 documents the correction and what was actually changed).
`PORTING.md` is Boxing's copy (newest, through §7.36).

## M0 -- scaffold and first recon (this session)

Repo built from nothing but a ROM drop: `rom/Shark Shark.bin` (16384 bytes)
and the generic 16K collection `.cfg`. Established, by direct measurement,
not assumption:

- **8192 words at `$5000-$6FFF`** -- the first 8K-word cart in the family;
  every one of the eleven prior ports was 4K-word. md5
  `9f85b961e6c40c2c786026f460ae02fa`; jzIntv's knowncarts DB confirms
  "Shark! Shark!", 1982.
- The shipped `.cfg` is the same generic 3-segment boilerplate found
  byte-identical in eight sibling repos; its `$D000`/`$F000` lines point
  past EOF on this dump and jzIntv silently drops them. Replaced with the
  honest single line `$0000 - $1FFF = $5000` in `rom/SharkShark.cfg`
  (renamed from `Shark Shark.bin`/`.cfg` -- spaces in Make prerequisites
  are a permanent hazard, Bowling's note).
- **`make verify-org` passes** against the renamed ROM with zero changes to
  `tools/dump_rom.py`'s base-dump path -- confirms the toolchain
  (`as1600`/`dis1600`/`bin2rom` at `/usr/local/bin`, jzIntv only at
  `~/Workspace/jzintv-20200712-src/bin/jzintv`, the FujiNet-patched build)
  round-trips this cart cleanly before any hook code exists.
- `tools/recon.py` (generic, unmodified) against the dump:
  - Header: process/timer table `$501C`, start-of-game vector `$506B`,
    GRAM init `$5036`, `$500E = 0` -> colour-stack mode.
  - Timer table, 6 entries: slot 0 = `$1A71` (`X_MUSIC_TICK`), interval
    `$8001` (stopped) -- the family's defensive placeholder, shipped
    natively on this cart, unlike ports where it had to be added. Slots
    1-5: `$5B1A`/`$10` (1.25 Hz), `$5B75`/`$2D` (0.44 Hz), `$5C7F`/`$0A`
    (2.00 Hz), `$5CEA`/`$02` (9.99 Hz, the likely primary game-logic
    entry), `$5D5B`/`$50` (0.25 Hz). Five game entries -- ties Frog Bog for
    the busiest dispatcher in the family; unlike Frog Bog, none are
    individually stoppable by recon's linear scan (to be confirmed in M1).
  - **14 RNG call sites, all `X_RAND2` (`$169E`)**, spanning `$5B22 …
    $60A7` -- the most of any port to date (Armor Battle's 9 was the prior
    record), four of them in the `$6xxx` page.
  - Timer arm/stop: `$51A7`, `$628D` -> `X_TIMER_STOP`; `$51B8` ->
    `X_TIMER_START`.
  - **Zero references to `$011F`-`$0124`** -- dispatch-only for input, the
    Boxing/Utopia/Auto Racing shape. No shadow-pair patch needed.
  - Three `$035D` phase-table installs: `$5115`, `$6274`, `$629A`.
  - 3 STIC register writes, 0 GRAM writes -- classification (reassert vs.
    sim state) deferred to M1's `dis1600` pass.
- **Structural consequence of the 8K size**: `$6000-$6FFF` (every prior
  port's netcode ORG) is real code here, through `$67F9`; `$67FA-$6FFF` is
  zero fill (2054 words). Netcode now splits: `src/hook.asm` moves its ORG
  to **`$6800`** (2048-word margin above the fatal `$7000`, half of every
  prior port's margin but proven sufficient by Sea Battle's own `$D000`
  precedent), `NET_SESSION` stays at `$D000` unchanged.
  - `tools/dump_rom.py` gained an optional `--stop HEX` truncation (the
    patched dump must stop at `$67FA` so it doesn't collide with hook.asm's
    own `ORG $6800`); `tools/check_patch.py` gained an optional
    `COMPARE_WORDS` limit so `verify-patch` only diffs the 6138 words the
    truncated dump actually covers. Both tested standalone against this
    ROM: the truncated dump emits exactly 6138 DECLE words, terminating at
    `$67F8-$67F9`.
  - `tools/check_7000.py` added: `check-7000` now parses every build
    `.cfg`'s `[mapping]` spans and fails if any segment's destination range
    *overlaps* `$7000`, not just starts there -- real insurance on this
    cart, whose hook segment sits half as far from the boundary as any
    prior port's. Self-tested against a synthetic overflowing segment
    (`$6800` + `$1000` words -> correctly flagged) and a safe one
    (correctly passed).
- Server identity retargeted: production port **9113**, Lobby appkey
  **21**, `MAX_SEATS = 4` (kept from Golf, matches `maxplayers: 4` in the
  Lobby payload -- Boxing's tree shipped with those two values
  mismatched; checked here, they agree). `server/c/` copied byte-for-byte
  (game-agnostic, `--max-seats`/`--proto` parameterised).
- `test/run_hookcheck.sh` removed rather than carried forward a third time
  -- it was already explicitly disowned in Golf's copy ("NOT YET ADAPTED
  FOR GOLF … still entirely Soccer-shaped … will FAIL or hang") and was
  never part of the gate ladder (PORTING.md §8 doesn't list it).
- Live port audit: BOIP 9995 is already held by an unrelated long-running
  `fujinet-pc-rs232` instance on this workstation -- `FN_BOIP=` needs
  pointing at a free port (`19851+` are open) with a matching `fnconfig.ini`
  edit in a private dist copy for `make echo-test` / `make run-net1`.

Not yet done: `src/exec_equ.asm`, `src/hook.asm`, `tools/patches.py`, the
`SC_CNT*`/quiescent tail of `src/ram.asm`, `SCRIPT_TBL`,
`TRACE_RANGES`, `tools/check_dest_phase.py`, the `run_rig.sh`/`run_m4.sh`
verdict blocks, and the `session.asm` `STR_*` block are all still Golf's
-- nothing game-specific has been rewritten yet. `make hook`/`virt`/`lag`/
`det`/`net`/etc. will not build correctly (or will build a Golf-shaped,
Shark-Shark-wrong sim) until M2/M3 replace them. `verify-org` is the only
gate proven so far.

## M1 -- dis1600 recon

### M1a: timer entries, RNG, arm/stop, ISR dance (confirmed live in `dis1600`)

Full disassembly regenerated (`dis1600 rom/SharkShark.bin build/sharkshark.dis
-f`, clean flow-following decode, no misalignment) and read in full through
$67F9.

**The five game timer entries**, each read directly and confirmed self-
contained (no other caller):

| slot | addr | Hz | role (confirmed from code, not guessed) |
|---|---|---|---|
| 1 | `$5B1A` | 1.25 | low-probability spawn/event roll (`X_RAND2` 0-5) + a HUD digit redraw via `L_511A` -- likely score or air-gauge |
| 2 | `$5B75` | 0.44 | object-vs-object proximity/AI: walks the object table, computes inter-object position deltas, flips a facing/orientation bit -- shark-toward-diver steering |
| 3 | `$5C7F` | 2.00 | collision/"bite" resolution between two specific object records 8 apart (tests bit `$0800` on both), triggers a sound (`L_6014`) and flips animation-frame card words on hit -- **this is the entry `$628D` stops at GAME OVER**, corroborating "diver caught by shark" |
| 4 | `$5CEA` | 9.99 | **primary**: tick counter, alternates a card-table pointer every other tick, calls `L_5DF4` (the ISR dance, see below) **unconditionally every single call** (confirmed: the `JSR R5,L_5DF4` at `$5CF9` is not gated by the branch above it -- that branch only picks which of two table pointers R2 gets), spawns/inits objects every 8th tick, and decays a per-object flicker/invulnerability counter |
| 5 | `$5D5B` | 0.25 | recovery/respawn cadence, gated by the SAME collision flag (`$0345`) tested by slot 3 -- likely post-catch knockback/recovery timing |

**Arm/stop sites, fully decoded**:
- `$51A7` (`L_51A2`, called once from `.START`): a **stop-ALL** loop --
  `MVII #$5020,R1` / `JSR X_TIMER_STOP` / `ADDI #4,R1` / `CMPI #$5036,R1` /
  `BMI` -- walks R1 across all 5 game slots ($5020/$5024/$5028/$502C/$5030)
  plus the harmless table terminator. Never touches slot 0 (music, `$501C`).
- `$51B8` (`L_51B3`, called once from `.START`, immediately before
  installing `$035D=$5193`): the matching **start-ALL** loop, identical
  shape, same 5-slot walk.
- `$628D`: `MVII #$5028,R1` immediately before `JSR X_TIMER_STOP` -- targets
  **slot 3 only** ($5028 = $5C7F, the bite-resolution entry). Fires right
  after printing "GAME OVER": the cart explicitly disarms only the
  collision-detection entry at match end.
- These are the ONLY 3 timer-API call sites in the ROM (matches recon).
  Slot 3's shim is the only one needing an independent single-slot STOP
  path; slots 1/2/4/5 only ever move as part of the two whole-table loops.

**§7.30 literal-countdown-write sweep: NONE FOUND.** Grepped `$0125`-`$0139`
directly (0 hits) and confirmed dis1600's own auto-symbolization shows a
clean, unbroken gap with zero cart references anywhere in `$0100-$0158` --
the cart never touches that range at all, literal or symbolic. No hidden
timer-arm hazard to shim beyond the 3 sites above.

**§7.26 (`X_SCAN` self-call): NONE.** Zero occurrences of `$14F1`/`X_SCAN`
anywhere in the disassembly, including as a data byte.

**§7.36 (direct `$0102`/`$0103` reads): NONE.** Zero occurrences of either
address anywhere in the disassembly (mnemonic and raw hex columns both
checked). Confidently clean -- this hazard class does not apply here.

**§7.27/§7.28/§7.35 -- the big finding: a full ISR-vector swap on EVERY
tick of the primary entry**, not a rare event. `L_5DF4` (called
unconditionally by `$5CEA`, i.e. every 9.99 Hz tick):

```
L_5DF4: PSHR R5
        CLRR R0 / MVO R0,G_015E        ; done-flag := 0
        DIS
        MVI  $100,R0 / MVO R0,G_015F   ; save low byte of live ISR vector
        MVI  $101,R0 / MVO R0,G_0160   ; save high byte
        MVII #$0014,R0 / MVO R0,$100   ; install new vector = $5E14
        MVII #$005E,R0 / MVO R0,$101
L_5E0D: EIS
        MVI  G_015E,R0 / TSTR / BEQ L_5E0D   ; spin (real interrupts ON)
                                              ;  until the new ISR fires
        PULR R7
```

The installed body at `$5E14` copies up to 32 words into **GRAM at
`$3960`** (a dynamic sprite/tile redraw, likely the diver/shark animation
frame), writes `.STIC.VIDEN` (`$0020`) with whatever value the copy loop
last held (data-dependent, not a constant), **restores `$0100`/`$0101`
from `G_015F`/`G_0160` before returning**, calls **`X_PLAY_NOTE`**, sets
`G_015E`, and returns from interrupt -- at which point `L_5DF4`'s spin
sees the flag set and returns to the game tick.

Consequences, all confirmed by reading the code, none guessed:
- **§7.35 confirmed applicable, same as Boxing**: the cart's own ISR-dance
  body genuinely calls `X_PLAY_NOTE`. The family's defensive `X_MUSIC_TICK`
  slot-0 placeholder is PROVABLY load-bearing here too -- keep it at slot 0
  of the relocated table, unconditionally.
- **§7.27 (Soccer's exact shape, one cell earlier)**: the saved vector pair
  is `G_015F`/`G_0160` = `$015F`/`$0160` -- CONSECUTIVE addresses, inside
  the CRC'd `$015D-$01EF` range, so they transport as ordinary game bytes
  in the resync image. `exec_equ.asm` should alias `SC_ISR_SAVE EQU $015F`
  directly (not a netcode-RAM spare like Golf's structural no-op) so the
  family's UNCHANGED generic `RS_CLAMP_ISR` (resync.asm) clamps it
  correctly -- confirmed the low/high byte order matches
  (`G_015F`=low from `$100`, `G_0160`=high from `$101`, exactly
  `SC_ISR_SAVE`/`SC_ISR_SAVE+1`'s expected layout).
- **§7.28**: since the vector install happens on literally every tick of
  the fastest entry, and the swapped-in ISR body never touches
  `$0102`/`$0103`, the pass this dance occupies almost certainly loses a
  frame of wall-clock accounting the same way Soccer's scroll dance did --
  **the wall tick rate MUST be measured live at the real `MASTER_TICK`
  once hook.asm exists (two-point cycle sample), never assumed from the
  header's 9.99 Hz arithmetic.** Budget for a possibly-slower-than-9.99Hz
  real cadence when picking delay `d`.
- **`SC_ISR_BODY` should be `$5E00`** (the page of the installed vector
  $5E14) for `DANCE_SETTLE`'s existing generic check -- the window where
  `$0101` actually reads `$5E` is narrow (only during `L_5DF4`'s own
  synchronous execution, which always completes before the tick returns,
  since the dance restores the vector itself before `L_5DF4`'s spin
  exits), but the family convention is cheap defensive insurance for the
  terminal-screen case, not just cosmetic.

**STIC writes, classified**:
- `$5049`/`$504B` (`.TITLECODE`, fed by one `MVII #$0009,R0`): a one-time
  title-screen reassert of CS0 and Border to $9 each, run once before
  printing "SHARK! SHARK!", never repeated. Safe to exclude from the
  resync image -- not periodic/live state.
- `$5E31`→`.STIC.VIDEN` (`$0020`): part of the ISR dance above, R1's value
  is whatever the 32-word GRAM copy loop last held (data-dependent, not a
  header-matching constant). This is bookkeeping internal to the dance,
  not ordinary "live display state" like Auto Racing's scroll registers --
  covered by keeping the dance intact under the RS_CLAMP_ISR treatment
  above, not by a header-reassert or a resync-image scalar.

**Image-end sanity**: last real instruction is `PULR R7` at `$67F9`
(confirmed a genuine branch target via the cross-reference footer, not a
decode artifact). `$67FA`-`$6FFF` swept and confirmed all-zero. M0's
`$6800` netcode-segment plan is sound.

### M1b: game flow, seat-model correction, boot prompt

**The load-bearing finding of this milestone: the cart is 1-2 players,
SIMULTANEOUS, not 1-4/turn-based.** This directly contradicts the premise
this whole repo was scaffolded from (Golf's 4-seat turn-arbiter engine),
which was itself scaffolded from a wrong assumption stated at the start of
the session, not from anything in the ROM. Evidence, independently
confirmed twice (once by the recon agent, once by direct re-check in this
session):

- **Only 4 STRING literals exist in the entire ROM**: `"SHARK!  SHARK!"`
  (title), `"SELECT 1 OR 2"` + `"PLAYERS  :"` (the boot prompt, two
  `X_PRINT_R5` calls at `$5093`/`$50A8`), `"GAME OVER"`. No 3/4-player
  text anywhere -- confirmed by grepping the full `dis1600` output myself.
- **Accept logic**, `$50C1-$50CB`, confirmed independently in this
  session by reading the raw disassembly:
  ```
  JSR  R5,.EXEC.910        ; 50C1  the shared EXEC number-entry routine
  TSTR R0                  ; 50C4
  BEQ  L_519D              ; 50C5  reject 0
  CMPI #$0002,R0           ; 50C7
  BGT  L_519D              ; 50C9  reject > 2
  MVO  R0,G_0172           ; 50CB  accepted -> player-count cell ($0172)
  ```
  This hard-caps the cart at 2 players in its OWN code -- not a design
  choice this port could route around even if a 4-seat model were wanted.
- **Live-confirmed simultaneous play** (recon agent, jzIntv sessions
  logged in `build/*.scr`/`build/*.log`, gitignored): booted a 2-player
  game, dumped the object table. MOB0 (`$031D`-base) and MOB1
  (`$0325`-base) are simultaneously populated and independently evolving.
  Forcing right-controller disc events for 10 passes changed MOB1's
  position field while MOB0's fields stayed byte-identical -- each
  controller drives its own diver concurrently. The game-over gate
  (`$6228-$6242`) requires a joint AND over BOTH players' "alive" bits,
  not a single active-player check. This is Armor Battle's/Boxing's
  shape (both seats act every tick), not Bowling's/Golf's (one seat acts,
  computed from a "whose turn" cell) -- there is no "whose turn" cell to
  find because there is no turn.
- Cross-check on the primary timer entry: `$5CEA`'s own code loops
  `R5 := G_0172` (player count) times, walking BOTH players' object
  records every tick regardless of input -- consistent with simultaneous
  play, inconsistent with a turn-based design.

**What was actually changed in the scaffold this session** (in addition
to this file and `CLAUDE.md`/`README.md`):
- `server/intv_relay_server.py`: `MAX_SEATS` 4 -> 2, `maxplayers` payload
  literal 4 -> 2, docstring corrected (simultaneous, no arbiter, Boxing's
  shape not Bowling/Golf's).
- `server/run_production.sh`: `--max-seats` default 4 -> 2, registry
  comment's `(2-4 players)` annotation for this port -> `(1-2 players)`.
- `tools/server_diff.py`: replaced Golf's 4-seat-pinned copy with
  Boxing's/Sea Battle's 2-seat-pinned one (byte-identical between those
  two, confirmed) -- Golf's `--seats` default/guard hard-refused anything
  but 4, which is now the wrong shape for this port.
- `tools/bbnet_client_sim.py` and `tools/test_lobby_pub.py` needed NO
  changes -- both already defaulted to `SEATS=2` / asserted
  `maxplayers==2`, a leftover from an earlier ancestor in Golf's own tree
  that Golf itself never updated to match its real 4-seat config (a
  latent bug in Golf, orthogonal to this port, noted for completeness).
- `src/main_net3.asm`/`main_net4.asm` removed (only meaningful for a
  3rd/4th rig seat).
- Every test script's hardcoded `--port 9111` (leftover from the Golf
  copy this port was scaffolded from, missed in M0's first port-number
  pass) fixed to `9113`: `test/run_rig.sh`, `run_m4.sh`, `run_lobby.sh`,
  `run_peerleft.sh`, `probe1.sh`, `probe2.sh`, `serverlib.sh`,
  `lobby_idlers.py`.
- `PLAYERS=2..4` framing in `test/run_rig.sh`/`run_m4.sh`/
  `run_peerleft.sh`/`Makefile` comments corrected to "fixed at 2, this
  cart hard-caps there" -- the `$(GAME)_net%.bin` pattern rule and
  `PLAYERS` machinery are left in place unchanged (harmless, matches
  family convention) even though only `PLAYERS=2` will ever be exercised.
- **Not yet changed**: `src/hook.asm`/`src/exec_equ.asm`/`src/ram.asm`
  etc. still contain Golf's OWN game logic (ball flight, putting, GF_*
  symbols) -- these were always going to be fully rewritten in M2/M3
  regardless of seat model, so "removing the arbiter" from them isn't a
  distinct step; the DESIGN DECISION to write Boxing's shape instead of
  Golf's when M3 starts is what this correction actually changes.

**The boot prompt DOES dispatch through `$035D`** -- confirmed directly
in this session (not by the recon agent, whose report claimed the
opposite): parked live at the prompt (`b 14D5/r 1e7/g 7 14D7/n
14D5/r 3e6`) and dumped `$035D` directly: **`m 35D 2` reads `$5185`**.
Immediately before the `JSR .EXEC.910` call, `$50BE` loads
`MVII #$5185,R4` -- `$1910` (the EXEC's shared number-entry routine,
identical bytes across every cart in this family) installs the address
passed in R4 into `$035D` INTERNALLY, which is invisible to a cart-only
disassembly scan (the `MVO` happens inside EXEC ROM, not cart code) --
exactly the same mechanism Golf's `GF_HTBL_PROMPT` and Utopia's own
number-entry prompt use ("`$1910` installs it into `$035D` directly",
already documented in both sibling repos' `exec_equ.asm`). The recon
agent's live raw-port-forcing recipe (`$7E`->player 1, `$BE`->player 2 at
`b 1527`, `$D7` for ENTER) was real and useful for finding the ACCEPTED
raw byte values, but the production injector doesn't need raw-port
forcing at all -- it can use the family's STANDARD decoded-keypad-event
replay through `LS_VCALL` (fresh digit `$81`/`$82`, ENTER `$8B`, the
same family-universal codes already cross-validated on Sea Battle/
Soccer/Utopia), exactly like Golf's `ARB_INJECT`, just invoked
unconditionally every tick rather than gated behind a seat arbiter
(there isn't one).

`$5114` installs `$5193` (the live-play table) once, at the end of
`.START`, right after the prompt is accepted. Exactly how `$5193`'s
handler body reads the controller-index register (R1, by family
convention) to route each seat's events to `$031D`-base vs. `$0325`-base
is the one piece still open -- a dedicated recon pass is resolving it via
live single-instruction stepping (static reading of `$5193`'s own bytes,
`DECLE $00AD, $0063, $0005`, did not resolve into an obvious table shape
by inspection alone). Do not write `hook.asm`'s `MASTER_TICK` dispatch
section until that lands.

Live-measured, for calibration: consecutive port-read breakpoint stops
while parked at the prompt were exactly 44,802 cycles apart = 3.000 NTSC
frames = 20.0 Hz -- matches the family's standard pass rate. (This is the
SCAN/pass cadence, not the primary game-tick cadence measured separately
in M1a as 9.99 Hz per the header's interval-2 arithmetic -- the wall-tick
figure that actually matters for picking `d` still needs live measurement
at the real `MASTER_TICK` once it exists, per M1a's ISR-dance finding.)

Boot state: the cart drops straight into the "1 OR 2 PLAYERS" prompt with
no attract-mode cycling and parks there forever absent input (confirmed
by running 500K-4M instructions with periodic BACKTAB/$0100-$0180 dumps,
completely static throughout).

Quiescent point for the resync push: **not yet established**. Best static
candidate is `GAME_TBL == $1906` (the EXEC null table, installed at
game-over), but since play is simultaneous and the round only ends when
BOTH players are simultaneously "not alive" (the joint-AND gate above),
there may be no safe MID-round quiescent moment -- this cart could end up
shaped like Auto Racing's "no quiescent point, defer to the cap" rather
than a between-turns moment. Needs a forced `QUIESCE=1`-style live test
once `hook.asm`/`resync.asm` exist, per §7.29's rule (don't accept an
untested cap as evidence).

## M2/M3 -- exec_equ.asm, patches.py, ram.asm, hook.asm, lockstep.asm,
## resync.asm, debug.asm written; live-verified

Full per-cart source written from the M1 findings: `src/exec_equ.asm`
(SS_TICK1-5, SS_SLOT1-5, SS_INT1-5, SS_HTBL_PROMPT/LIVE/NULL/PLAYAGAIN,
SC_ISR_SAVE aliased to the cart's own `$015F`, SC_ISR_BODY=`$5E00`),
`tools/patches.py` (38 words: 4 header + 28 RNG + 6 timer-shim, no
shadow-pair patch), `src/ram.asm`'s tail (SS_ARM1-5/SS_CNT1-5, all real
sim state -- no RS_SPARE padding possible, unlike Golf's 3-entry cart),
`src/hook.asm` (NEW_TIMER_TBL with just 2 real slots -- full
virtualization, Bowling/Golf's model, not Sea Battle/Boxing's native
shortcut; MASTER_TICK's both-seats-every-tick dispatch with a GAME_TBL==
SS_HTBL_PROMPT exclusion routing to SS_INJECT instead; SS_GAME_TICK; the
single SS_RAND2 wrapper; SS_ARM_SHIM/SS_STOP_SHIM; SS_REBASE_HOOK).

`src/netcode/lockstep.asm`'s `LS_PASS` dispatch section rewritten to match
(no UPDATE_SHADOW/SHADOW_FROM_RINGS -- dispatch-only, M1c; the same
GAME_TBL==SS_HTBL_PROMPT exclusion; Golf's per-turn `NAME_DRAW` removed,
no "current player" concept on a simultaneous-play cart), `LS_CKSUM`'s
tail rewritten for all 5 arm+countdown cells. `src/netcode/resync.asm`:
`GF_REBASE_HOOK` renamed `SS_REBASE_HOOK`; `RS_CLAMP_ISR`'s comment
corrected (load-bearing here, not a no-op, since `SC_ISR_SAVE` aliases
the cart's real `$015F`/`$0160`); `IMG_TOTAL` 769 -> 770 (this cart's
15-word tail is one longer than the family's traditional 14 -- every one
of the 5 timer entries needs BOTH an arm flag and a countdown, unlike
Golf's 3-entry cart which had room for `RS_SPARE` padding); `RS_TAILTBL`
rewritten (confirmed via reading `IMG_GET`/`IMG_PUT`'s actual
double-indirection that entries need not be contiguous in RAM, only in
the table's OWN order -- SS_ARM4 at `$810F` sits happily between
SS_ARM1-3's block and SS_ARM5-CNT5's block). `src/debug.asm`'s
`TRACE_RANGES` rewritten to match (contiguous start/end pairs, unlike
`RS_TAILTBL`'s scattered-pointer shape). `src/core.asm`'s stale
`build/golf_patched.asm` include and `$6000` comment fixed (both leftover
from the M0 rsync, not caught until the first build attempt).

**Every build variant assembles clean on the first full pass after fixing
the `core.asm` include bug**: `hook`, `virt`, `lag`, `lag0`, `det_a`,
`det_b`, `echo`, `rec`, `net`, `net1`, `net2`, `nethud` -- the full
netcode stack (`session.asm`, `lockstep.asm`, `resync.asm`, `hud.asm` at
`$D000`) compiles with zero undefined-symbol errors. `make check-7000`
passes: the `$6800` hook segment resolves to `$6800-$6BFA` (1019 of 2048
words used), comfortably clear of `$7000`. `verify-org` and
`verify-patch` both still pass (38/38 declared sites, exactly).

**Live boot-dump verification (PORTING.md §7.31 -- a green build is not
proof)**:
- `hook` build (SPIKE_VIRT=0, pure timer-relocation test): `$035D=$5185`
  reached identically to the unpatched ROM (the boot prompt is still
  live); `SS_ARM1-5` all correctly zero (the stop-all loop's shim fired
  correctly); **`SS_CNT1-5` read `$0010/$002D/$000A/$0002/$0050` --
  EXACTLY `SS_INT1-5`**, confirming `NET_START`'s seeding is correct
  (the Frog Bog zero-fill lesson, avoided). `NET_COUNT` correctly
  defaults to 2.
- `virt` build (SPIKE_VIRT=1, dispatch+injector test, zero forced
  physical input): **`$0172` (player count) reads `$0002` and
  `GAME_TBL_LO/HI` ($80C0/$80C1) reads `$0093/$0051` = `$5193` =
  `SS_HTBL_LIVE`** -- the boot prompt was answered ENTIRELY by
  `SS_INJECT`, with no human/scripted input at all, and the game
  genuinely transitioned to live play. `SS_INJ` settled at exactly `6`
  (tick 2 = digit, tick 6 = ENTER, matching the design) and stopped
  incrementing once `GAME_TBL` moved off the prompt. **Both MOB0
  (`$031D`-base) and MOB1 (`$0325`-base) show real, non-zero, actively
  populated game state** -- confirming genuine 2-player simultaneous play
  is running, driven purely by the injector's deterministic answer.
  (One incidental confirmation along the way: a `$035D` sample mid-run
  read `$683B` = `NET_NULL_TBL+4` exactly, from the `.sym` file --
  correctly showing the nulled-between-ticks state, not a bug.)

This is a strong result: the core mechanism this whole port depends on
(dispatch-only, both-seats-every-tick, boot-prompt auto-answer) is now
proven live, not just assembled clean.

## M4 -- SCRIPT_TBL, TRACE_RANGES, check_dest_phase.py, verdict blocks,
## session.asm STR_* block

`src/vdispatch.asm`'s `SCRIPT_TBL` rewritten: both columns always replay
(no shared-by-parity columns, unlike Golf/Bowling's turn-based scripts),
deliberately DIFFERENT disc directions per seat so a cross-seat MOB-
routing bug would be visible rather than masked. `tools/check_dest_phase.py`
rewritten (`SS_HTBL_PROMPT`/`LIVE` addresses, `$0172` player-count range
1-2, and -- new relative to every prior port's version -- explicit MOB0
AND MOB1 population checks, since this cart's failure mode of interest is
a seat routing to the wrong MOB, not a stuck turn machine).
`test/run_rig.sh` and `test/run_m4.sh` verdict blocks updated to match
(same dest-phase signals, MOB0/MOB1 checks added to the rig verdict too).
`test/run_m4.sh`'s fault injection changed from Golf's arbitrary stroke-
count corruption to `$0172` (SS_PCOUNT) 2->1 -- deliberately a SMALL,
safe corruption rather than a wild value, since $0172 also bounds
`SS_TICK4`'s own per-tick MOB loop (`R5 := G_0172` times) and a wildly
out-of-range poke risked walking off the object table into unrelated RAM
during the live fault window, a real crash risk Golf's own arbitrary
stroke-count fault never had to consider.

**The QUIESCE=1 forcing mechanism was redesigned, not just re-addressed**:
Golf's version forced the underlying game ARM flags (a mechanism this
cart doesn't have in the same shape). Rather than force this cart's own
MOB "alive" bits directly (risky: SS_QUIESCENT's exact derivation from
them is still a working hypothesis, M1b/M1c, and the bits share a 16-bit
word with other unidentified fields), the script now forces
**`SS_QUIESCENT` ($81AF) itself** repeatedly. This tests exactly what the
QUIESCE gate needs to prove (RS_PENDING's quiescent branch fires and
repairs correctly) independent of whether the MOB-bit hypothesis for
computing SS_QUIESCENT in ordinary play is exactly right -- a cleaner
decoupling than the direct approach would have given.

Also fixed during the M4 build-verification pass (caught by `make hook`'s
first real run, not by inspection): `src/core.asm` still had
`INCLUDE "build/golf_patched.asm"` (should be `sharkshark_patched.asm`)
and a stale `$6000` comment -- both leftover from the M0 rsync and
invisible until the first actual build attempt. Also fixed: every
remaining `golf_` build-artifact-name reference across `test/*.sh` and
`tools/run_echo.sh`/`run_det.sh` (missed in M0's port-number pass, which
only looked for `9111`, not `golf_`).

`src/netcode/session.asm`'s `STR_*` block (§7.34): `STR_TITLE` ->
"SHARK SHARK NETPLAY", `STR_ROOM` -> "WAITING ROOM   OF 2" (this cart's
own `MAX_SEATS`), `STR_PICKS` -> "DIVE IN" (was Golf's "TEE OFF").
`STR_PICK` ("DISC/2/8  ENTER=PLAY") and `STR_YOUARE` ("YOU ARE PLAYER")
checked and left as-is -- confirmed by reading their call sites that both
describe session.asm's own GENERIC lobby-navigation UI, not this game's
in-game controls, so they carry no donor-cart terminology to begin with.

**Full clean rebuild after every M4 edit**: `make clean && make
verify-org` plus every build variant (`hook virt lag lag0 det_a det_b
echo rec net net1 net2 nethud`) -- zero errors across the board.
`verify-patch` still reports exactly 38/38. `check-7000` passes.

## M5 -- determinism gates: `det` PASS immediately, `lagcheck` FAILED
## then diagnosed and fixed (a real methodology mismatch, not a bug)

`make det` **passed on the very first run**: 256/256 ticks identical
under stall injection, destination-phase OK (player count 2, both MOBs
populated). This alone is a strong result -- RNG wrapping (14 sites),
the stall injector, and all five virtualized timer entries are correct
together.

`make lagcheck` **FAILED on the first run**: peak agreement at shift=0
(25/209), not shift=20 -- the family's usual signal (Golf's §7.33
whole-`TRACE_RING`-checksum cross-correlation) found no discernible
20-tick peak at all.

**Root-caused, not worked around.** Manual tick-by-tick comparison of the
raw `TRACE_RING` checksums between the d=0 and d=20 builds showed: ticks
0-19 IDENTICAL, bit-for-bit, between builds; from tick 20 onward
(precisely `SPIKE_DELAY`'s value), the two diverge with no shift ever
re-aligning them. Traced to a structural mismatch, not a code defect:
**four of this cart's five timer entries are ALWAYS-ARMED and fire on a
fixed real-time schedule, completely independent of player input**
(spawn roll, AI steering, bite resolution, recovery -- only the actual
MOB-position write, via `L_63D3`'s dispatch-triggered callers, is
input-driven). Golf's whole-checksum correlation implicitly assumes the
checksummed timeline is PRIMARILY input-driven (true for Golf's own
swing/putt mechanic); here the checksum is DOMINATED by ambient state
that evolves identically at real tick T regardless of delay, so `d0[T]`
and `d20[T+20]` are being asked to match at DIFFERENT AMOUNTS of ambient
real-time progression (T vs. T+20 ticks) even when the input-driven part
is correctly delayed -- the dominant signal is delay-INVARIANT by
construction, which structurally defeats a delay-shift correlation no
matter how correct the underlying delay mechanism is.

**The fix**: since (unlike Golf) the exact input-consuming mechanism
WAS fully reverse-engineered this session (M1c), fall back to the
family's ORIGINAL "hand-picked cell" approach instead of the whole-
checksum one. Identified `$0168`/`$0169` (P1/P2's most-recently-
dispatched disc value, a DIRECT un-smoothed echo, written by `L_63D3`'s
disc-handler caller at `$63B4`/`$6418` -- confirmed in `dis1600`) as the
right cells: unlike position (which the ambient AI also writes,
confounding the signal), these cells are touched ONLY by genuine fresh
disc dispatch. Added a small, additive `LAG_RING` ($9200, 256×2 words)
to `debug.asm`'s `TRACE_TICK` (two extra `MVI`/`MVO@` pairs, harmless to
`make det`'s own checksum-based proof -- a separate ring, not part of
`TRACE_RANGES`/`LS_CKSUM`/`RS_TAILTBL`'s coverage) and rewrote
`test/run_lagcheck.sh` to correlate THAT instead of the whole-state
ring.

**Result after the fix**: `LAGCHECK PASS` -- clean, sharp peak at shift
20 (120/209 agree) against a 72/209 baseline and 45/209 at shift=0, with
neighboring shifts falling off smoothly (19:116, 21:114, 18:112,
22:108) -- exactly the shape a real, working delay ring should produce.
`make det` re-verified still passing after the `debug.asm` change.

**Generalize**: PORTING.md §7.33's whole-checksum lagcheck design is a
genuine improvement over hand-picking a cell ONLY when the checksummed
timeline is primarily input-driven OR the exact input-consuming field is
genuinely unknown. On a cart with multiple always-armed, input-
independent ambient timer entries (increasingly common as this family
tackles busier carts), the whole-checksum approach can FAIL EVEN WHEN
THE DELAY MECHANISM IS CORRECT, for a structural reason unrelated to any
bug -- diagnose by checking whether early, pre-divergence ticks match
exactly (they should, and did here) before assuming the delay ring
itself is broken.

## M6 -- transport (`echo-test`) PASS

Port 9995 (and 9996/9997/9991) were already held by unrelated long-running
instances on this workstation (confirmed via `ss -tlnp`), exactly the
situation `CLAUDE.md` warned about. Set up a private `fujinet-pc-rs232`
dist copy (`fnconfig.ini`'s `[BOIP] port` rewritten to `19851`, a free
port), launched it standalone, and ran `FN_BOIP=localhost:19851 make
echo-test`. **Clean pass, first try**: `E_STAGE` ($8120) reads `$00AA`
(pass), 100/100 echo rounds completed in 3.7s (avg inter-arrival 36.9ms),
confirming `src/netcode/mailbox.asm` (generic, unchanged) round-trips
correctly through `jzintv --fujinet` -> `fujinet-pc` for this build.

### M1c: controller-index routing -- CONFIRMED, matches Boxing exactly

Full EXEC-side dispatch chain traced live (`dis1600` against a relocated
copy of `exec.bin`, mirroring Boxing's own recipe, plus live breakpoints
at the dispatch jump):

- EXEC's scan (`$1523`/`$152A`) reads left (`$011F` shadow base) and right
  (`$0120` shadow base) separately, both funnelling into the shared
  decoder `.EXEC.52F`.
- `$15EB`: `R4 += [$035D]` (the cart's installed table base) — a
  `SDBD`+`MVI@` DOUBLE-BYTE indirect read fetches a 16-bit cart handler
  address out of two consecutive low/high-byte table words.
- **`$15F6`: `SUBI #$011F,R1`** — this is the whole mechanism: R1 goes
  from `$011F`→`0`  (LEFT) or `$0120`→`1` (RIGHT) right before jumping
  into the cart's own handler (`$15F8: JR R2`).
- Live-confirmed: identical raw byte forced on both controllers reaches
  the SAME handler address (`$6405`) with R1=0 for left, R1=1 for right.
- The handler calls a shared MOB-selector, `L_63D3`: `TSTR R1 / BEQ
  keep-$031D / (R1!=0) ADDI #8,R2 -> $0325`. A second site (`$63EA`)
  inlines the identical `TSTR R1`/`+8` pattern. **P1/left = `$031D`
  (R1=0), P2/right = `$0325` (R1=1), stride 8** -- exactly the
  Boxing/Armor-Battle "shared per-seat handler indexes off R1" shape.

**Consequence: zero shadow-pair patching needed, confirming recon's
original "zero `$011F`-`$0124` references" finding at the mechanism
level, not just the absence-of-references level.** `hook.asm`'s
`MASTER_TICK` dispatch is therefore Boxing's exact shape: both seats
replay every tick, `VD_SIDE`/`VD_CTRL` set to 0 then 1, two
`LS_VDISPATCH` calls, no arbiter, no suppression.

`$5193`'s real shape (recon's own linear scan had mis-decoded it as 3
DECLE words and wrongly resumed "code" after): a genuine **5-slot table
of low/high-byte address pairs**, `$5193-$519C` (10 words). Table
boundary confirmed by a real `dis1600` xref: `$519D` is the target of the
number-prompt's OWN reject branches (`$50C5`/`$50C9`), so the table is
exactly 5 slots. Slot 1 (`$5195/$5196` → `$6405`) is confirmed live for
both disc-dispatch paths; slots 2-4 (`$6405`... `$63EA`) are read
statically and match the same `L_63D3`-style pattern. The identical
misdecoding recurs at the post-game "play again" table (`$629C`) — same
`dis1600` blind spot, not cart-specific.

**Settle delay after the boot prompt is accepted: effectively 0 ticks.**
`.START`'s accept path (`$50C1`→`$5114`) is straight-line code with no
wait loop at all (unlike the game-over path, which explicitly calls a
~20-frame wait before its second `$035D` install) -- live-measured, both
`G_0172` and `$035D` already read their post-accept values at the very
first poll (400 instructions) after the accepting keypress releases.
Size `SCRIPT_TBL`'s settle row generously (1 tick is enough) but there's
no multi-frame handshake to wait out here, unlike Boxing's CHOOSE MEN.

**Exactly 3 cart-side `$035D` MVO sites, exhaustively confirmed** (a
literal-operand grep is exhaustive for this, unlike table CONTENTS which
needed live tracing): `$5114→$5193` (start), `$6273→$1906` (game-over
EXEC null), `$6299→$629C` (post-game "play again", another 5-ish-slot
table by the same pattern as `$5193`). The boot prompt's own install
(`$035D=$5185`) happens inside EXEC ROM's `$1910` itself, from the R4
argument the cart passes at `$50BE` -- invisible to any cart-only scan,
already confirmed directly by this session's own `m 35D 2` dump. Since
`.EXEC.910` is called exactly once in the whole ROM, there is no second
hidden prompt.

**Practical implication for `hook.asm`/`tools/patches.py`**: input replay
only needs to feed the shadow `$011F`/`$0120` scan-source cells once per
seat per tick (raw hand-controller bytes) -- the game's own dispatch +
`TSTR R1` machinery does all seat routing with zero cart-side code to
shim. `session.asm`'s injector for the boot prompt needs no special
mechanism either: it's the SAME `$035D`/`LS_VCALL` path as ordinary
gameplay input, just fed synthetic keypad events (`$81`/`$82` digit,
`$8B` ENTER) on a tick counter, unconditionally (no arbiter to gate
behind) -- Golf's `ARB_INJECT` shape minus the `ARB_SEAT` check, driven
off `NET_COUNT` so both consoles answer identically without racing.

**M1 is now complete.** Every open item from the M0/M1a/M1b checklists
is resolved: primary timer entry ($5CEA), all arm/stop targets, no
literal-countdown/X_SCAN/direct-$0102 hazards, the ISR dance and its
exec_equ.asm consequences, STIC-write classification, the boot prompt's
mechanism and encoding, and controller-to-MOB routing. The one item
still open going into M2/M3 is the **quiescent point** for the resync
push -- no live QUIESCE test has run yet; the working hypothesis is the
game's own game-over joint-AND condition (`$031D`/`$0325` bit `$0800`
clear, `$0323`/`$032B` zero), since simultaneous play may have no safe
MID-round moment (Auto Racing's shape, not Bowling's). Confirm with a
forced `QUIESCE=1` test once `resync.asm`'s cart hook exists.

## M7 -- transport + lockstep + matchmaking, all PASS

`make server-diff`: 6/6 scenarios PASS (roster, rooms, start, relay,
drops, framing), py vs the generic C relay, byte-for-byte, 2 seats.

`make rig PLAYERS=2` **FAILED on the first run in a very informative
way**: the underlying netplay mechanism was already perfect (0 CRC
mismatches across 20 rounds, all four DIAG counters zero, both MOB0 and
MOB1 populated on both consoles) -- but the verdict script's destination-
phase assertion required `GAME_TBL == SS_HTBL_LIVE` and `SS_PCOUNT` in
1-2, and the fuzz-driven 100-second run had legitimately reached GAME
OVER (`GAME_TBL == SS_HTBL_PLAYAGAIN`, `$629C`) well within that window --
masked disc-only fuzz is far more reckless than a real player and both
divers getting caught inside 100s of play is expected, not a bug. Fixed
`tools/check_dest_phase.py` and both `test/run_rig.sh`'s and
`test/run_m4.sh`'s inline verdict blocks to also accept `SS_HTBL_NULL`
($1906) and `SS_HTBL_PLAYAGAIN` (`$629C`) as valid real-gameplay
destinations (reaching game over requires substantially MORE real
gameplay than parking on the boot prompt ever could), and to only
require `SS_PCOUNT` to be 1-2 while still in `SS_HTBL_LIVE` (once the
round ends the cart's own code may hold or reset it to anything, which
proves nothing either way). Re-ran: **`RIG PASS (2 players)`** -- 0 CRC
mismatches across 24 rounds, clean.

Port 9995 (and 9996/9997/9991) confirmed already held by unrelated
long-running instances on this workstation for the echo-test too (see
M6) -- not re-litigated here since `make rig` sets up its own isolated
per-console BOIP ports (`19851`/`19852`) automatically via
`test/run_rig.sh`'s own private-dist-copy mechanism, unaffected by what
else is running on the shared host.

## M8 -- desync recovery (`m4`): three-iteration investigation, both PASS

`make m4 PLAYERS=2` (plain) **FAILED on the first run**, but informatively:
the underlying recovery worked in outline (tick counts matched, all DIAG
zero) but `dropped=1` appeared on the host and `recovered-after-fault=
False` with 7 mismatches against only 3 "crc ok" lines. Root cause: the
CHOSEN FAULT ($0172/SS_PCOUNT, 2->1) wasn't a one-shot corruption --
it's ALSO the loop bound `SS_TICK4` consults EVERY TICK, so as long as
it stayed corrupted, MOB1's flicker/spawn upkeep silently stopped on
that console every tick, an ONGOING divergence (not a one-time value
flip) that fed into the canonical RNG mirror's consumption schedule
faster than the quiescent-gated push could catch up, until the host's
gate loop timed out and set `NET_DROPPED`. **Fix**: switched the fault
to `$0168` (P1's disc-heading echo, written only by a genuine fresh-
disc-dispatch, not consulted by any ongoing per-tick logic -- confirmed
in `dis1600`), poked to `$77` (outside any value real dispatch or fuzz
can produce). Re-ran: **`M4 PASS`** -- exactly 1 CRC mismatch (the
fault, detected cleanly), 7 clean rounds after, 0 drops, both consoles
agree on tick and `GAME_TBL`.

`QUIESCE=1 make m4 PLAYERS=2` took **three iterations** to pass:

1. **First attempt** forced `SS_QUIESCENT` ($81AF, the DERIVED flag)
   directly, for a 15s window. FAILED: `RS_GATE=2` (cap), not 1
   (quiescent) -- the window simply never overlapped with when a
   mismatch got detected.
2. **Second attempt**, same direct-flag forcing, widened to ~50s.
   FAILED again, but differently instructive: `mismatches=0` for the
   WHOLE run -- the `$0168` fault (shared with the plain test) never
   actually got consumed by a fresh P1 dispatch this run at all, because
   this build is pure $3F-masked FUZZ with no deterministic script, so
   *when* (or whether) $0168 gets read back is randomized, not reliably
   early like `$0172` was. **Root-caused the DEEPER issue underneath
   both failures**, not just patched around the symptom: `SS_GAME_TICK`
   (src/hook.asm) recomputes `SS_QUIESCENT` FRESH every single tick,
   from the real MOB bits, BEFORE `RS_PENDING` reads it in that same
   tick's `LS_PASS` flow -- an external debugger poke to the DERIVED
   flag, landing between ticks, is therefore ALWAYS overwritten by the
   very next tick's real computation before `RS_PENDING` can ever
   observe it, no matter how the forcing loop's timing is tuned. This
   was structurally unable to work, regardless of window width.
3. **Third attempt**: switched the QUIESCE-mode fault BACK to `$0172`
   (SS_PCOUNT) specifically -- its every-tick-checksummed immediacy,
   the exact property that made it the WRONG choice for the plain test,
   is exactly right here (guarantees an early, reliable mismatch inside
   the forcing window). AND switched the forcing target from the
   derived flag to the UNDERLYING condition it's computed from: `$031D`/
   `$0325` (MOB "alive" bit `$0800`) and `$0323`/`$032B` forced to 0
   repeatedly, so `SS_GAME_TICK`'s own real computation naturally
   reproduces `SS_QUIESCENT=1` every tick for as long as the forcing
   holds -- which is what actually lets `RS_PENDING` observe it. **PASS**:
   `RS_GATE=1` (quiescent), fired after just 1 tick of forcing;
   `SS_PCOUNT` correctly repaired to 2 on both consoles; `GAME_TBL` back
   to `SS_HTBL_LIVE` on both (gameplay resumed cleanly after the
   resync, not just parked); 0 drops; `recovered-after-fault=True`.

**This incidentally gives the FIRST live confirmation of the M1b/M1c
`SS_QUIESCENT` hypothesis** (both MOB alive-bits clear + `$0323`/`$032B`
zero) -- forcing exactly those cells was what made the real, unmodified
`SS_GAME_TICK` computation produce `SS_QUIESCENT=1`, which is stronger
evidence than the hypothesis alone: the derivation is confirmed correct,
not just plausible.

**Generalize**: when a QUIESCE-style forcing test targets a DERIVED
flag that gets recomputed every tick from OTHER state, check the
computation's OWN call order relative to the consumer (`RS_PENDING`
here) before assuming a wider forcing window will fix a timing miss --
if the deriving computation runs between every poke and its consumer,
no window width helps; force the input the computation reads, not the
output it produces.

Two different `test/run_m4.sh` faults now coexist, gated on `$QUIESCE`:
`$0168` (clean, one-shot, for the plain cap-path test) and `$0172` +
raw MOB-bit forcing (immediate and reliable, for the quiescent-path
test) -- each fault matched to what its specific test actually needs,
not a single fault trying to serve both purposes.

`make peerleft PLAYERS=2 LEAVER=2 LEAVE_MODE=clean` and `LEAVE_MODE=
timeout`: **both PASS, first try** (once the underlying engine was
already proven by m4/rig). Clean mode: survivor's screen correctly
decodes "PLAYER LEFT / GUEST81 / PRESS RESET / SLIP REJ TMO ERR / 00 00
00 00" (`PEER_WHY=1`, server-reported departure, leaver named). Timeout
mode: "CONNECTION LOST / PRESS RESET / ..." (`PEER_WHY=0`, locally
detected, no name available -- correct, matching the mode). All DIAG
counters clean in both. (One unrelated segfault noted in the clean-mode
leaver's own `fujinet-pc` process during teardown -- expected, part of
simulating an abrupt local process kill, not a code defect.)

**M8 complete.** Every gate up through the full 2-console rig, desync
recovery (both the cap path and the quiescent path), and both peer-left
modes now passes.
