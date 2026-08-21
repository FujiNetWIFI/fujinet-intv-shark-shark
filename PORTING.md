# Porting FujiNet netplay to another EXEC game

Written in the Baseball port repo (a working two-player netplay port of
Mattel Baseball (1978), validated on real PiRTO II hardware); updated by the
Auto Racing and Football ports (§2.1 caveat, §3 false-positive classes, §4
vdispatch/text-variant entries, §5.5 refinements, §5.6, §7.8-§7.13);
updated by the Armor Battle port (§5.7 replay-order rule, §7.15 cart
main-loop clones, §7.16 bounds sweeps, §7.17 in-ROM scripting for exact
gates); updated by the Utopia port (§5.5 destination-phase assertion,
§5.7 EXEC-loop confirmation of replay-before, §7.19 animation-field
exclusion); and updated by the Frog Bog port (§7.20 SHADOW_FROM_RINGS under
lockstep too; §7.21 sound-effect triggers as determinism leaks distinct
from RNG); and updated again in this repo by the Bowling port — the
FIRST 2-4 PLAYER PORT — with §7.22 (the EXEC boot EXECUTES the word at
$7000: never let a segment spill there), §7.23 (the seat-generalized
engine + turn arbiter for N players and turn-based carts), §7.24 (use
the EXACT EXEC countdown-reload semantics — fire on ==0, reload full —
when the virtualized entries pace gameplay-visible motion), and a
sharpened §5.5 form (a keypad-free fuzz can park a prompt-driven cart
in registration forever while every CRC gate "passes"); and updated again
in this repo by the NASL Soccer port with §7.26 (a cart may call X_SCAN
from inside its own timer entry, so $035D must be nulled BEFORE the game
tick as well as after), §7.27 (a transported cell can be a CODE POINTER —
clamp it), §7.28 (measure the wall tick rate: an ISR dance can steal a
frame the EXEC never counts) and §7.29 (when the quiescent point is
unreachable under fuzz, test the gate deliberately rather than accepting
the cap as evidence); and updated again in this repo by the Sea Battle
port (the first cart needing ZERO RNG wrappers) with §7.30 (a cart can
arm/stop a timer entry's countdown as a HARDCODED LITERAL RAM ADDRESS,
bypassing the timer API entirely and invisible to recon.py's JSR-only
scan — relocating the table without also relocating that literal breaks
silently) and §7.31 (removing a JSR to let an entry dispatch natively is
easy to get subtly wrong in a way `make det` cannot catch on its own —
verify against a live boot dump, not just a green gate); and updated
again in this repo by the PGA Golf port (the SECOND 2-4 player port, and
the first to combine the 4-seat engine with the C-relay-diff tooling)
with §7.32 (a recon false positive can be correctly CLASSIFIED and still
need patching — a loop terminator expressed relative to a base address
must move WITH that base even when it is, correctly, "not a read"),
§7.33 (when a cart's exact input-consuming field isn't known, cross-
correlate the determinism ring instead of guessing a game cell for
`lagcheck` — more robust, and reuses machinery `make det` already proved)
and §7.34 (a file that is "copy unchanged" at the CODE level can still
carry the donor cart's own literal UI strings — grep every `STRING` for
the donor's name/terminology, not just the symbols); and updated again in
this repo by the Boxing port (the FIFTH 2-player port, and the first to
apply native dispatch — §7.31 — to four of five timer entries, more than
Sea Battle's two of three) with §7.35 (the family's defensive
`X_MUSIC_TICK` slot-0 placeholder can be PROVABLY load-bearing, not just
precautionary, on a cart whose own ISR calls into the EXEC note engine)
and §7.36 (game logic can busy-wait on the ISR phase counter `$0102`
DIRECTLY, with its own `EIS`, entirely outside the documented timer API
and invisible to any JSR-based recon — a determinism leak distinct from
both RNG and the sound-engine class, found only by live single-
instruction stepping); and updated again in this repo by the Shark Shark
port (the twelfth port, and the first 8K-word cart in the family) with
§7.37 (a cart whose own image already fills the page every prior port's
netcode ORG'd into needs the hook segment relocated to its own unused
tail, not the collection cfg's other declared windows), §7.38 (the
family's whole-`TRACE_RING`-checksum `lagcheck` design, §7.33's own
generalization, can FAIL even when the delay mechanism is CORRECT, on a
cart whose checksummed state is dominated by always-armed, real-time-
scheduled ambient logic — diagnose by checking whether early ticks match
exactly before assuming the ring itself is broken), and §7.39 (forcing a
DERIVED flag for a `QUIESCE`-style test doesn't work if the deriving
computation runs, unconditionally, between every poke and its consumer —
force the inputs it's computed from instead).  Almost none of
it is about any one cart. This
document separates the part that transfers — the engine,
the server, the test rig, and the expensive lessons — from the part that
has to be re-derived for each new cart, and gives the procedure for
re-deriving it.

Target audience: you, six months from now, starting the thirteenth port.

Everything here is verified against real ROMs and live runs. Where a number
came from a measurement, the measurement is shown, because two of the worst
detours in the Baseball port came from believing a documented number instead
of measuring it.

---

## 1. The model in one page

Both consoles run the **whole original game**, lightly patched, and stay in
lockstep by exchanging one controller byte per player per sim tick.

- **Sim clock = one EXEC main-loop pass.** The EXEC's loop at `$108F` waits
  for the ISR phase counter `$0102` to go negative, reloads it from `$0103`,
  then does: RNG stir → **timer-table dispatch (all game logic)** → controller
  scan → sound. Everything the game does happens inside that dispatch.
- **The game tick** is whichever timer-table entry holds the game logic,
  divided down by that entry's interval.
- **Input** is captured at tick `T`, sent tagged for tick `T+d`, and applied
  on both consoles at `T+d`. `d` (the delay) is what hides network latency.
- **A stall** — remote input for tick `T` has not arrived — is a busy-spin
  *inside* the dispatch with `$0102` saved, forced to 0, and restored
  (DIS-wrapped). Display and sound keep running off the ISR; object motion,
  game logic, RNG and music all freeze together and coherently.
- **Desync** is detected by exchanging a state CRC every 64 ticks and repaired
  by the host pushing a full state image at a quiescent moment.

The consequence that matters for feel: **the sim advances at the rate of the
slower console, and input lag is `d` ticks**. Both of those are measured in
*ticks*, so the first thing to know about a new game is how long a tick is.

---

## 2. Know your numbers before you write any code

### 2.1 The pass is 3 frames, not 1

The EXEC main loop looks like it runs once per frame. It does not. It runs
once per `$0103` frames, and `$0103` measured **3** on every cart tested:

| cart | `$0103` |
|------|---------|
| Baseball | 3 |
| Auto Racing | 3 |
| Boxing | 3 |
| NFL Football | 3 |
| Armor Battle | 3 |
| Utopia | 3 |

So a pass is 3 NTSC frames ≈ 50 ms, i.e. **20 passes/second**.

Measure it on your cart before trusting the table above — boot it headless and
dump the cell:

```sh
printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\nr 4000000\nm 100 8\nq\n' > ph.scr
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  jzintv -d --script=ph.scr -e rom/exec.bin -g rom/grom.bin "YourGame.bin"
# $0100: .... .... [$0102] [$0103] ....
```

(`b 14D5` + `g 7 14D7` is the EXEC title-skip recipe; it is generic.)

Caveat from the Auto Racing port: the pass can be **4 real frames during some
phases** — if the game runs a VBLANK display state machine that replaces the
EXEC ISR for ~1 frame per tick, `$0102` does not count those frames. Wall
tick rate is then phase-dependent; sim semantics (per-pass) are unaffected.

### 2.2 Tick rate = 20 Hz ÷ timer interval

`tools/recon.py` reads this straight out of the cart header. Baseball's game
entry has interval 2 → **10 Hz, a 100 ms tick**. That single number explains
the "quarter second of input lag" reported from live hardware play: the
default delay `d=3` is 3 × 100 ms = **300 ms**, before a single packet moves.

Confirm it against the built ROM rather than the table, by sampling your tick
counter twice — **jzIntv's debugger prints a cycle count at the end of every
register-dump line**, which is the only wall clock you need:

```
 0004 0342 575D 0000 1842 1448 02FD 145C -Z--I-i-  BNC $1468      41535976
                                                                  ^^^^^^^^
```

Baseball, `baseball_hook.bin`, tick counter at three points:

| cycles | tick | Δcycles/Δtick |
|--------|------|----------------|
| 41,535,976 | 458 | — |
| 82,810,621 | 919 | 89,533 |
| 247,904,395 | 2761 | 89,627 |

89.5k cycles = 6 NTSC frames (frame = 14,934 cycles) = **9.97 Hz**, matching
the header-derived 9.99 Hz. The timer-table notes in `spikes/NOTES.md` had
claimed 30 Hz for years; it was wrong, and it made every latency estimate
3× too optimistic.

(For calibration at the other extreme: Armor Battle, with no ISR dance,
measured consecutive `$17D5` stops exactly 44,802 cycles apart = 3.000
frames = 20.0 Hz — the cleanest cadence of the four ports. Football's wall
tick ran ~4 frames because of its dance overhang.)

### 2.3 The delay budget follows from the tick

`d` buys you jitter tolerance of `d × tick` milliseconds and costs you exactly
that much input lag. At Baseball's 10 Hz, `d=3` = 300 ms of both. At a 20 Hz
tick, `d=3` = 150 ms. Pick `d` from the measured round trip, not by habit, and
tune it live against the HUD's `L` figure (§6).

---

## 3. Recon: generate the port map

```sh
make recon ROM="$HOME/Workspace/PiRTO-II-Flash-Backup/MNO/NFL Football.bin"
```

`tools/recon.py` is a linear scan, not a flow-following disassembler, so it
reports *candidates* — confirm each in `make dis` output before patching. It
is calibrated against Baseball, whose entire hand-derived patch map
(`tools/patches.py`) it reproduces: both `$011F` reads, all five RNG call
sites, the timer-arm site, all seven phase-table installs.

It answers, per cart:

| section | what you do with it |
|---------|--------------------|
| cart header | the two hook points: timer-table pointer (relocate it) and start-of-game vector (insert `NET_START`) |
| timer table | which entry is game logic, its interval → tick rate → delay budget |
| RNG call sites | every one needs a canonical-RNG wrapper (§5.2) |
| timer arm/stop calls | `$181E`/`$1831`/`$1838`/`$1844` sites — these break when you relocate the table |
| controller/phase cells | `$011F`/`$0120` reads to redirect at a shadow pair; `$035D` writes = the game's phase machine |
| display writes | STIC/GRAM writes; **zero means display state is static** and can be repaired from the header (§7.5) |

### What recon says about the ported carts

| | Baseball (done) | NFL Football (done) | Auto Racing (done) | Armor Battle (done) | Utopia (done) | Frog Bog (done) | Boxing (done) | NASL Soccer (done) | PGA Golf (done) |
|---|---|---|---|---|---|---|---|---|---|
| timer table | `$501C` | `$5026` | `$5029` | `$5050` | `$501C` | `$501C` | `$501C` | `$501C` | `$501C` |
| start-of-game | `$5034` | `$5075` | `$5037` | `$505A` | `$504C` | `$5991` | `$5053` | `$506A` | `$5034` |
| game entries / interval | `$5048` / 2 | `$5034` / 1, `$56EF` / 15 | `$511E` / 1, `$51B7` / 15 | `$554E` / 1 | `$51A3` / 1 | **`$5D89`/`$5572` / 1, `$5DE3` / 60, `$5DAA` / 600, `$529A` / 15 (5 entries, most of any port)** | `$51F0`,`$5A0F`,`$57AB` / 1, `$52F2`,`$5297` / 16 | `$5042` / 1, `$5AB8` / 2, `$505F` / 5, `$503A` / 20 | `$54E6` / 1, `$5718` / 3, `$525E` / 1 (3 entries, all virtualized — §7.31's native-dispatch shortcut doesn't fit) |
| **tick rate** | **10 Hz (100 ms)** | **20 Hz (50 ms)** | **20 Hz (50 ms)** | **20 Hz (50 ms)** | **20 Hz (50 ms)** | **20 Hz (50 ms)** | **MEASURED 20.0 Hz (exactly 3.000 frames) — matches the header despite a real cart ISR, §7.28's dance-surprise doesn't apply here** | **MEASURED 14.97 Hz (66.8 ms) — header implies 20 Hz; see §7.28** | **MEASURED 20.0 Hz (exactly 3.000 frames) — matches the header, no ISR-dance surprise** |
| RNG sites to wrap | 5 | 3 | 4 | **9 (+1 stir left volatile)** | 15 (all X_RAND2) | 9 (6× X_RAND1 + 3× X_RAND2 — 2nd port needing both) | 8 | 5 (3× X_RAND1 + 2× X_RAND2 — 3rd port needing both) | 8 (4× X_RAND1 + 4× X_RAND2 — 4th port needing both) |
| `$035D` phase installs | 7 | 1 | 1 | 4 (3 tables, one EXEC-resident: `$1906`) | 2 (`$5125`, `$1906`) + the EXEC number entry's own | 2 (`$55A6` live table, `$1906` EXEC null — both installed once, tail of `.START`) | 3 | **1 (`$5869`, installed once at `$50A1`, NEVER changed — no phase readable off the table at all)** | 2 (`$51D3` live table, `$1906` EXEC null at game-over) + the EXEC number entry's own |
| `$011F`/`$0120` reads found | 2 | 1 | 0 | 1 (both seats via `[$011F+player]`) | **0 (true dispatch-only)** | 1 (both seats via `[$011F+player]`, Armor Battle's hybrid shape) | 0 | **4 (2 walking-pointer setups + 1 direct pair — most of any port)** | 1 (one walking-pointer site — BUT its loop terminator is base-relative and needed patching too, §7.32) |
| timer arm/stop calls | 1 (`$181E`) | 0 | 0 | **3** (`$1838`/`$1844`, stale absolute entry addr → shims) | 0 | **6** (across 3 entries — largest shim surface of any port) | 5 (`$1838`/`$1844`) | **0** | **7** (3 ARM via `$181E`, 4 STOP via `$1838` — one STOP site is a stop-ALL loop across all 3 slots) |
| STIC writes | **0** | 3 (incl. `$0030`) | **7** (incl. `$0030`/`$0031`) | **0** (recon's 1 hit = class-1 false positive) | **0** | **0** (2 recon hits, both class-1 `SDBD`-prefix false positives) | 1 (`$0020`) | 2 (`$0030` scroll + `$0020`) | **0** (recon's 13 hits: one class-1 mid-JSR false positive, the rest graphics data mis-decoded as instructions) |
| display mode (`$500E`) | 0 colour stack | 0 colour stack | **1 fg/bg** | 0 colour stack | 0 colour stack | **1 fg/bg** | 0 colour stack | 0 colour stack | **1 fg/bg** |
| main loop | EXEC | EXEC | EXEC | **cart clone during battle (§7.15)** | EXEC | EXEC | EXEC (verify!) | EXEC — **but entry 1 calls `X_SCAN` itself (§7.26)** | EXEC, dispatch-only — zero `$14F1` references, §7.26 does not apply |

Utopia turned out to be the cleanest of the five: one always-armed timer
entry, no shims, no scan wrapper, no game ISR, dispatch-only input, and
a patch map of 34 words (header + 15 RNG sites and nothing else). Its
one novelty: game-length setup runs through the EXEC's dispatch-driven
number-entry routine (`$1910`, digit-accept table passed in R4), which
installs an EXEC/cart hybrid handler surface recon cannot see — the
adopt-don't-restore rule (§5.3) covers it with no extra work.

Frog Bog is the busiest dispatcher of any port (five game timer entries,
three of them individually stoppable — six arm/stop call sites, the
largest surface yet) but otherwise simple: no cart main loop, no game
ISR, no real STIC writes, a small (37-word) patch map. Its one novelty
turned out to be a non-issue rather than a complication: the game's own
"select a mode" keypad flow (this cart's manual literally instructs the
player to press a specific key before the round starts) is not a
pre-game gate at all — `.START` installs its own live keypad-dispatch
table and falls straight into a playable default, so the "mode select"
keypress is just an ordinary in-game event our engine already covers,
with no Title-vector hook needed (see spikes/NOTES.md in this repo for
the full trace — an early theory that a different, unrelated EXEC
scratch cell was the mode selector was investigated and correctly ruled
out before being acted on, PORTING.md §5.5 in practice).

The real surprise was operational, not architectural, and it was a
two-parter. First `make rig` (not `make det`) caught a real bug — the
polled `$011F` shadow pair wasn't fed from the lockstep rings under
netplay, only under the local spikes — see §7.20. Second, and more
expensive: `make det` had passed clean on an early run, but only because
the two slowest virtualized timer entries (600-tick and 60-tick
countdowns) had never actually reached zero and fired within any test
script's run length — they were seeded from RAM's zero-fill instead of
their real interval, a bug invisible to every gate until a real user
playtest reported the round collapsing to ~30 seconds and always
starting at night. Fixing the seeding bug let those entries fire for the
first time under any test in this repo, which exposed a *second*,
previously-latent leak underneath the first: one of those entries reads
a bitmask another one sets, and branches into a chain of real EXEC sound
effect triggers instead of the wrapped RNG once that bit is live. The
EXEC sound engine churns its real LFSR from ISR context for as many real
frames as each effect plays — this is exactly §5.2's warning about the
sound engine, but manifesting as **sound-engine-state drift**, not an
unwrapped RNG read (there wasn't one; every call site was already
wrapped, confirmed by grepping the whole ROM for unwrapped `$035E`
reads). A synchronous save/restore around the trigger, the fix that
works for RNG, does *not* work here, because the churn continues for
multiple real frames after the trigger returns — see §7.21. Four
investigative sessions and real ROM-patch bisection (force specific
branches, rerun `make det`, observe pass/fail, revert) were needed to
separate "looks like an RNG leak" from "is actually a sound-engine timing
leak wearing an RNG-shaped disguise, only visible once a two-timer-deep
interaction started firing for the first time."

Reading that table, before writing a line of code:

- **All three tick at 20 Hz**, twice Baseball's rate — `d=3` costs 150 ms
  instead of 300 ms, so these should *feel better* than Baseball does.
- **Football is the easiest**: fewest moving parts (three RNG sites, one phase
  install, no timer arm/stop calls), and it has genuine dead-ball moments to
  gate a resync on.
- **Every one of them runs more than one game timer entry** (Baseball ran
  exactly one, which flattered the design): each entry is game logic on its
  own cadence and the master dispatcher must reproduce all of them, in table
  order, at their own intervals — including the slow ones, which are sim state
  too (their countdowns must freeze with everything else during a stall).
- **Boxing needs the most care**: *three* entries at tick rate plus two slow
  ones, five entries in total and no music timer in the table at all. It
  also uses `X_TIMER_START`/`STOP`, which Baseball never did, at five sites —
  all of them relocation-sensitive.
- **Auto Racing breaks the static-display assumption**: seven STIC writes,
  including `$0030`/`$0031` (the scroll delays — it scrolls the track) and it
  runs in foreground/background mode, not colour stack. Do **not** copy
  Baseball's "reassert display state from the header" repair into it; the
  scroll registers are live game state and belong in the resync image instead.
- **Boxing and Auto Racing show no `$011F`/`$0120` reads.** That means they
  read input through a computed pointer the linear scan cannot see (or only
  through the `$035D` dispatch). Chase this in `dis1600` before assuming
  there is nothing to patch — the shadow-input patch is load-bearing.
  (Auto Racing's answer, found at its M2: **dispatch-only** — the port reads
  feed only the EXEC scan's edge cells, and input enters game state
  exclusively through the `$035D` handlers. That finding changed the spike
  design, not the wire format. Run the dis1600 confirmation pass *before*
  committing to a wire format or a spike design.)
- **Armor Battle's answers, for calibration**: the single `$011F` reference
  (`MVII #$011F,R3` + `ADDR player`) serves BOTH seats — one operand patch,
  shadow pair consecutive; the three timer-API calls all pass the ABSOLUTE
  address of the original table's game entry (`$5054`), stale after
  relocation → each `JSR` retargeted to a shim that flips a virtualized
  armed flag (`AB_TICK_EN`, sim state in the CRC and image tails). Decode
  WHICH entry each timer-API site targets before deciding: a music-entry
  (slot 0) call survives relocation untouched; a game-entry call must be
  shimmed, because pointing it at the new table would let the game stop
  MASTER_TICK itself. Its per-battle dead moments (boot screen, battle-end
  explosion) gate the resync; mid-battle falls to the cap, AR-style.

### Known recon false-positive classes (seen across three carts)

Recon is a linear word scan; these three patterns have each produced a bogus
candidate that hand-decoding the raw words exposed:

1. **Misaligned instruction decode** — a "STIC write" that is really the
   middle of two consecutive 3-word `JSR R5` instructions (Football `$5041`),
   or an `SDBD`-prefixed `MVII` pair (Armor Battle `$508E`: "MVO R1,$0001"
   was `SDBD / MVII #$5114,R1`). Decode the surrounding words as
   instructions from a known-good boundary.
2. **`CMPI` against a constant that happens to be a hot cell address** — a
   loop-bound compare of a pointer against `#$035D`/`#$035F`, not a read of
   the cell (Auto Racing `$520F`, Football `$5A12`).
3. **The operand you patch is the `MVI`, not the `MVO`** — at a raw-port
   latch site the *read* operand (`$01FE`/`$01FF`) is the patch target; the
   `MVO` destinations (`$0123`/`$0124`) stay (AR, Football, and Armor
   Battle — three carts in a row).

---

## 4. What you copy, and what you re-derive

**Copy unchanged** (nothing in these is Baseball-specific):

- `src/netcode/mailbox.asm` — FujiNet mailbox driver (`N:TCP://`)
- `src/netcode/session.asm` — login, lobby, matchmaking, framing + the
  per-type length table that keeps a lost byte from misframing the stream
- `src/netcode/lockstep.asm` — delay lockstep, gate, stall, virtual dispatch
- `src/netcode/resync.asm` — CRC exchange, state image, recovery. **Caveat
  confirmed again by the ninth port**: "unchanged" has never been fully
  literal here — `RS_CLAMP_ISR`'s body is itself Soccer-specific content
  (a code-pointer clamp) under a generic-sounding name, and a cart whose
  own hazard doesn't fit inside an existing hook gets one explicit added
  line calling a new cart-defined routine (`SB_REBASE_HOOK` on Sea
  Battle) rather than a rename. Every port still defines the same
  canonical `SC_*` symbol names (`SC_CNT2/3/4`, `SC_PASSLEN`,
  `SC_ISR_SAVE`, `GAME_TBL_LO/HI`) in its own `ram.asm`/`exec_equ.asm` —
  that symbol-name contract, not byte-identical file contents, is what
  actually stays constant across the family.
- `src/netcode/hud.asm` — the live diagnostic row (§6)
- `src/vdispatch.asm` — the shared virtual-dispatch engine (factored out of
  lockstep.asm by the Auto Racing port so the local lag/det/replay spikes and
  the netcode replay events through one code path; includes the disc-settle
  `R0 = -1` event the scan's held path emits)
- `src/ui/text.asm` — BACKTAB text. **Two variants exist**, keyed to header
  `$500E`: the Baseball original for colour-stack carts, the Auto Racing
  rewrite for foreground/background carts. Copy the one matching your cart.
- `server/intv_relay_server.py` — relay + matchmaking; game-agnostic. (Older
  trees call this `bbnet_server.py`; `session.asm`'s bounds comment still does.)
  Copy `server/c/` too if you want the C relay — it is parameterised by
  `--max-seats`, so it is genuinely one binary for every v2 port rather than a
  ninth copy. `tools/server_diff.py` is what keeps the two honest.
- `tools/dump_rom.py`, `tools/check_patch.py`, `tools/recon.py`
- `test/` — the whole rig (two fujinet-pc instances + server + two jzIntv)

**Re-derive per game:**

| thing | where it lives for Baseball | how to get it |
|-------|------------------------------|----------------|
| patch map | `tools/patches.py` | `recon.py`, confirmed in `dis1600` |
| game symbols (`BB_*`) | `src/exec_equ.asm` | disassembly |
| master dispatcher body | `src/hook.asm` `MASTER_TICK` | one call per game timer entry, at its interval, **in the original table's order** (the EXEC walks entries in order; a slow entry listed before the fast one must fire first on the passes where both fire) |
| CRC range (non-volatile game scratch) | `LS_CKSUM`, `$015D-$01EF` | §5.4 |
| resync image layout | `resync.asm` `IMG_*` | §5.4 |
| quiescent point for resync | `BB_TBL_PREPITCH` (`$5335`) | §7.6 |
| controller→role mapping | `NET_ROLE` handling | the game's manual, then verify on screen |
| timer arm/stop shims | Armor Battle's `AB_STOP/START_SHIM` | decode each site's target entry first (§3); music-entry calls need nothing |
| replay order (events vs tick) | `MASTER_TICK`/`LS_PASS` call order | the cart's own scan-vs-dispatch order (§5.7) |
| scan-call wrapper | Armor Battle's `NET_SCAN_WRAP` | only if the cart runs its own main loop (§7.15) |

---

## 5. The seven things that make it deterministic

Get these wrong and the two consoles drift; everything else is plumbing.

### 5.1 Stall by spinning, never by skipping

Freeze `$0102` (save, force 0, restore, interrupts disabled around the
save/restore) and busy-spin inside the dispatch. Skipping the dispatch lets
the ISR's object motion run on while game logic is paused — instant desync.

### 5.2 Quarantine the RNG per call site

The EXEC's LFSR at `$035E` is stirred by the main loop every pass, by the
title-wait loop, and by the **sound engine from `$1CCE` whenever noise SFX
play — including mid-tick, from the ISR**. It can therefore never be sim
state. Patch each game RAND call site to a wrapper that swaps a canonical
sim-space RNG in and out of `$035E` with interrupts off. Wrapping the whole
tick is not airtight; the sound engine churns inside it.

### 5.3 Handle all three input surfaces

1. **Polled cells** `$011F`/`$0120` — repoint the game's reads at a shadow
   pair you control.
2. **Event dispatch** — the EXEC scan *jumps into game code* through the
   handler table pointed to by `$035D`. Point `$035D` at a table of zeros
   during the real scan so real local input can never reach game code, then
   replay both players' events in sim space through the game's live handlers.
   Adopt-don't-restore: handlers install new tables *from inside a dispatch*,
   so re-read `$035D` before the tick and again after the virtual dispatch.
3. **Action/keypad state cells** `$0121`/`$0122` — carry them on the wire too.

### 5.4 Checksum only what is really sim state

Excluded as volatile: `$0100-$015C` (EXEC scratch, music, ISR masks, timer
countdowns), `$01F0-$01FF` (PSG), `$0200-$02EF` (BACKTAB), `$02F0-$031C`
(stack — dead-slot noise varies with interrupt timing), `$035E`, `$035F`.
The object table `$031D-$035C` is deterministic per tick but **ISR-written**,
so a mainline capture races it: checksum it only at quiescent points, or
require two consecutive mismatches. The resync image must include the live
handler-table pointer.

### 5.5 Prove it before networking

`make det` is the gate: two builds, identical scripted inputs, one of them
stall-injected, per-tick state checksums must match exactly. Do this before
any transport work. Note the coverage hole this leaves — scripted fuzz never
reaches deep game states (in Baseball it never triggers a pitch), so a
record-and-replay pass over real gameplay is what actually exercises the
game's phase machine.

A third refinement from the Utopia port, the sharpest form of the hole:
**a det PASS can be two runs identically stuck in the same wrong place.**
Utopia's script encoded key '0' as `$8A` (extrapolated); the real decode
is `$80`, the game-length entry silently rejected and looped, and det
"passed" with both runs parked in the setup prompt — checksums identical,
zero gameplay covered. The checksum compare cannot see this. After the
script's last consequential row, **assert the destination phase** (dump
the adopted handler table / a phase cell at park and require the in-game
value); and measure every scripted event code at the live scan (`$011F`
dump while the key is forced) instead of extrapolating from a sibling
port's table.

Two refinements from the Auto Racing port:

- **Write a deterministic demo script** (`SCRIPT_TBL` in `vdispatch.asm`)
  that drives the game from boot into real play — menus, confirms, the first
  seconds of the game proper — and run it before handing over to fuzz. It
  closes most of the coverage hole cheaply, and both rig consoles can share
  it (host plays the left columns, guest the right).
- **Mask automated fuzz to `$3F`** (disc space only). Unmasked keypad fuzz
  can trigger game-restart/menu paths whose determinism you have not proven
  yet (that is how AR found its sound-state leak); keypad coverage belongs to
  the script, where it is reproducible.

### 5.6 Audit helper registers against everything live in the caller

A helper that clobbers a register the caller still needs can corrupt state
**symmetrically on both consoles**, so CRCs agree and nothing looks wrong for
hundreds of ticks (AR: `SCR_STEP` clobbered R2 = the tick tag inside
`LS_PASS`; every post-script input went out tagged "tick 0" and was silently
dropped as stale). When inserting any call into `LS_PASS`/`MASTER_TICK`,
enumerate what is live in R0-R5 at that point and check the callee against
the list.

### 5.7 Replay events in the cart's own scan-vs-dispatch order

The virtual dispatch must land events on the same side of the game tick as
the real scan does. In the EXEC main loop the scan runs AFTER the timer
dispatch, so replay-after-the-tick (Baseball/AR/Football's order) is
correct there. Armor Battle's battle loop runs its scan BEFORE the
dispatch, so stock handlers fire before the same pass's game tick —
replay-after applied every event one tick late and broke virt==hook on
tank rotation. Replay-BEFORE-the-tick is timeline-correct for both loop
shapes given capture-at-dispatch ring indexing (on the EXEC loop, the
value captured at dispatch N is scan N-1's output, whose stock events also
landed in the no-mutator window between tick N-1 and tick N) — but derive
this from YOUR cart's loop, don't assume. The check is the virt==hook
bit-compare with a script that drives real play.

The Utopia port ran that check on a pure EXEC-loop cart and
replay-BEFORE won there too: replay-after shifted its weather-RNG
schedule by a tick and diverged the canonical RNG mirrors, replay-before
was bit-identical. So the working default for a NEW cart is
replay-before-the-tick, with the virt==hook gate as the confirmation —
the earlier ports' replay-after passing their gates says their handlers'
effects only materialized at the next tick, not that the order was
timeline-equivalent.

---

## 6. Instrument it, or you will be guessing

Netplay on real hardware leaves no log, and every failure looks identical from
the couch: "players stopped moving, sound kept playing." Two facilities exist
for this and both transfer as-is.

**Field counters** at `$8180-$8183` — `DIAG_SLIP` (stream re-framings),
`DIAG_REJ` (refused state chunks), `DIAG_TMO` (mailbox timeouts), `DIAG_ERR`
(error replies). They are printed on the peer-left screen, which is the only
way to read them on hardware without a debugger. The rig asserts all four are
zero.

**The live HUD** (`NET_HUD`, `src/netcode/hud.asm`) paints one BACKTAB row
every 16 ticks, all hex:

```
L 02   S 00   T 21   R 00   H 00
```

- `L` slack = min(remote watermark − tick). Healthy is `d-1`. `00` = the sim
  is running at the network's pace and any jitter becomes a visible stall.
- `S` gate stall rounds, `T` mailbox poll iterations ÷ 256 (transport cost),
  `R` resyncs completed, `H` resync-hold rounds.

Diagnosis: `S` high with `L 00` → network-bound, raise `d` or shorten the
round trip. `S 00` with `T` high → transport-bound, cut transactions per tick;
a bigger `d` would only add lag. `R` climbing → it is a desync, not pacing,
and no amount of tuning will fix it.

This row is what turned "pauses of a second at definite spots" from a guess
into two measured causes in one session.

---

## 7. The expensive lessons

Each of these cost real debugging time on Baseball. They are all generic.

### 7.1 Never put cart RAM in `$8000-$807F`

The STIC only partially decodes its address, so its control registers also
respond at `$4000`, `$8000` and `$C000`. A netcode variable at `$8032` is a
write to the **top-border-extension register**: it painted border over BACKTAB
row 0 and hid the scoreboard whenever network traffic flowed. Reads mostly
"work" (AND-ed bus), so sync and logic look fine and only the display betrays
it. Start netcode RAM at `$8080`.

### 7.2 A wire value must never index a memory writer

The resync applier took its image position straight off the packet. Past the
end of the position→address table it reads **ROM code words as destination
pointers**, and CP-1610 `CMPI`/`BGE` range tests are **signed**, so any
position ≥ `$8000` sails through them and splatters a contiguous run over
`$0000+` — the STIC register file. Validate a minimum length per frame type,
gate data chunks on an actually-open hold, and bounds-check both `pos` and
`pos+count`. Do this on the console even though the relay validates framing:
one lost byte on the read path misframes the stream, and the wire is full of
bytes that read as a valid frame type.

### 7.3 A length-prefixed stream needs a re-sync path

Same root cause, other half: the reassembler had no sync marker, so a single
dropped byte (a `NET_READ` the peripheral completes *after* the transaction
times out) misframed everything after it, forever. Validate `(type, len)` at
peek time against a per-type length table mirroring the server's, and on a
mismatch discard one byte and rescan.

### 7.4 An "empty" record is a valid record

`RS_ON_CRC` matched the peer's CRC against a ring slot by comparing the stored
tick — and a **zeroed** ring reads as a perfectly good record for tick 0 with
a checksum of 0. The peer's tick-0 CRC routinely arrives before this console
has ticked 0 at all, so it compared against nothing, declared a desync, and
every single match paid for a full state resync (a ~1 s freeze) while the
server's CRC log said the two consoles had agreed the whole time. Fill
invalidated records with an impossible value (`$FF`), and clear the ring at
session start — it lives outside the block `NET_START` zeroes, so on hardware
it otherwise carries the *previous* match's records across a reset.

Generalise: any cache keyed by a value whose zero is legal needs an explicit
validity marker.

### 7.5 Display state comes from the header — unless the game scrolls

1978-era carts often never write the STIC or GRAM at all (Baseball: zero
sites). The EXEC programs border extension, mode, colour stack and border
once from header words `$500D-$5013`, and GRAM from the `$5008` init sequence.
Two consequences: there is nothing to transport (both consoles are identical
by construction), and nothing refreshes it, so one stray write stays on screen
for the rest of the game. The repair is to reassert those header words
periodically — a no-op when healthy.

**Check `recon.py`'s STIC-write count first.** Auto Racing writes `$0030`/
`$0031` (scroll) and Football writes `$0030`: for those games the reassert
would fight the game every frame, and the scroll registers are sim state that
belongs in the resync image.

### 7.6 Gate the resync on a quiescent point

Pushing a state image the instant a CRC disagrees teleports everything
mid-play. Baseball's phase is readable off the handler table it installs in
`$035D` (`$5335` = pre-pitch = ball dead), so the host defers the push until
then, with a cap (120 ticks) after which a visible jump beats staying
desynced. Crucially the *guest* must keep playing while it waits — freezing it
starves the host of the inputs it needs to reach ball-dead, and the whole
thing deadlocks.

Per game, the quiescent point differs and the `$035D` installs are where to
look: Football has between-plays, Boxing has between-rounds, **Auto Racing has
none** — a continuous race, where the honest options are to push at a
lap/crash boundary or accept the jump.

### 7.7 Transport cost is per transaction, so count them

Every pump is a mailbox `STATUS` (plus a `READ` when bytes are waiting) and
every transaction is a bus round trip the console spins through. Pumping once
per *pass* rather than once per *tick* doubled that cost for nothing: the pump
on the odd pass only ever mattered when the console had slack in hand, which
is exactly when nothing is waiting. Moving it cut measured transport cost 33%
(HUD `T` 0x32 → 0x21). The gate loop and the resync hold still pump every
round, which is when it genuinely matters.

`STATUS` before `READ` is not optional: FujiNet's TCP read returns
`SOCKET_TIMEOUT` and an error if you ask for more bytes than are available.

### 7.8 The EXEC sound gate can leak real-frame state into the sim

The one determinism leak Auto Racing shipped with: game phase transitions
that call EXEC sound entries behind the SFX-busy gate (`$0149`, checked by
the X_SFX_OK idiom — return via R4 = skip vs R5 = play) can consume
**real-frame-timed** sound state at a decision point. Stall-shift the sound
state and the two consoles take different branches with identical sim state
and inputs. Audit every game call into `$1A61`-class sound entries at recon
time: if any *logic* depends on the outcome, wrap the site so the gate is
deterministic. The CRC + resync net catches what slips through, at the cost
of a sub-second freeze.

### 7.9 Terminal screens must park forever

Baseball's peer-left path returned to the EXEC pass; on Auto Racing the scan
rewrote `$0102` and the pass machinery repainted status rows over the
peer-left screen every frame. Park the mainline in a tight loop
(`B @@self`) once a terminal screen is up — nothing after it needs the pass.

### 7.10 A game ISR dance can outlive your moment

Games that install their own ISR bodies (`$0100/$0101`) for multi-frame STIC
updates can be mid-dance when you take over the display (peer-left, session
screens). Wait out the dance bounded, then force-restore the EXEC default
ISR (`$1126`) — otherwise a stranded game ISR repaints over your screen
forever (AR's `DANCE_SETTLE`). Check at recon whether the cart writes
`$0100/$0101` at all; if it never does, none of this applies.

### 7.11 The debugger's `r N` counts instructions, not cycles

jzIntv's scripted `r N` runs N *instructions* (~4.6 cycles each on
average). Every cycles-derived count in a test script is therefore ~4.6×
too long: harmless where the verdict reads whatever state the run reached,
fatal where a poke must land at a specific moment or dumps must run before
a `timeout` kill (this is how Football's m4 console 2 died and its fault
poke landed pre-session). Budget ~200,000 instructions per emulated
second, and verify any timing-sensitive constant against the cycle counter
the debugger prints on every register line.

### 7.12 Inject input at the scan's port reads, keyed by PC

Forcing values at a shared decode address and counting on stop *order* is
fragile (the order proved phase-dependent on Football and burned hours).
The EXEC scan reads the left port at `$1525` and the right port at `$152C`
— break after each `MVI` (`b 1527` / `b 152E`) and force R2 with the raw
**active-low** byte. Distinct PCs per side, unconditional every pass. Keep
the game's own latch cells consistent by poking the shadow cells at the
tick stop, and align the script to the actual stop cycle first (the first
stop after arming the breakpoints is the scan's, not the tick's).

Armor Battle added two hard caveats. First, forcing at the shared decode
entry (`$1532`) instead of the port reads leaves the raw latch holding the
real (idle) port value; the scan's unchanged-raw path then re-marks the
stale decode as held **forever** ("$44 stuck" — the decoded cells are
sticky latches by design, §15AC re-marks the old value as held on every
no-event pass). Second — see §7.17 — even the correct port-read recipe is
not run-to-run deterministic, so use it for exploration only, never for a
gate that does exact tick arithmetic.

### 7.13 Kill stale rig processes first

A stale fujinet-pc instance silently holds its BOIP port and every later
emulator launch against it becomes a no-op that *looks* like a netcode hang.
Every rig script `pkill`s its own instances before starting. Keep it that
way in new test scripts.

### 7.15 A cart may abandon the EXEC main loop entirely

Armor Battle's battle-start handler generates the map, **resets SP to
`$02F1`, and enters a cart-resident clone of the EXEC main loop**
(`L_52B5`): phase-wait on `$0102`/`$0103` → raw-port latch → `$11FA`
object/collision walk → `$14F1` scan → `$17D5` timer dispatch → `$1AAD`
sound → `X_RAND1` stir → loop. The EXEC loop at `$108F` never runs again
after the first battle. Consequences, all of which generalize:

- The hook survives **because it lives in the timer table**: any loop that
  dispatches `$17D5` with the standard `$0102` pacing runs MASTER_TICK.
  Hooking anything loop-specific would not have survived.
- **The clone's pass order can differ** (scan before dispatch here) —
  that is what forces the §5.7 replay-order derivation.
- **A cart-side per-pass RNG stir** appears as a patchable "RNG site" but
  is the clone's copy of the EXEC loop's stir: leave it on the volatile
  LFSR, wrap only consumers (recon found 10 "sites"; 9 were consumers).
- **An abandoning handler kills the netcode pass that dispatched it**: the
  vdispatch-called handler never returns, so that MASTER_TICK's tail (the
  `$035D` re-null, the tick++) is skipped once. The re-null hole is closed
  structurally by patching the clone's own scan `JSR` to a wrapper
  (`NET_SCAN_WRAP`: adopt + null + tail-call the scan; stock-behaving
  builds compile it to a plain jump). The skipped tick++ is a benign,
  symmetric one-tick counter skid per battle entry — document it and make
  the virt==hook verdict accept state-identical + skid.
- **A cart that resets its own SP may keep globals above the stack base**:
  Armor Battle stores real state at `$0315-$031B`, inside the range the
  model previously excluded as "stack". Census the `$02F0-$031C` range per
  cart; anything game-written belongs in the CRC and the image (and mind
  the shrunken stack headroom under the netcode + ISR frames — the CRC
  coverage is what catches an overflow).

### 7.16 An image layout change must sweep every bounds constant

Growing the resync image from 761 to 777 bytes tripped a quick-guard that
hardcoded `pos_hi < 3` ("nothing valid at `$300+`") in the STATE-chunk
applier: the image's final chunk — the tail with the RNG, the virtualized
timer flag and GAME_TBL — was silently refused, and recovery still LOOKED
successful because those cells happened to match. Only the m4 verdict's
`DIAG == 0` requirement exposed it. When any `IMG_*` constant changes,
grep the applier and the pusher for every numeric comparison in the same
units, and keep only symbolic bounds tight; hardcoded quick-guards get the
loosest correct value (wrap prevention), with the exact bound in one place.

### 7.17 Breakpoint-force injection is not run-to-run deterministic

Two byte-identical jzIntv scripts (title-skip + pass-counted settle +
per-pass `g 2` forces at the port-read stops) produced a battle start one
pass apart on different runs — a forced stop near the ISR boundary can
slip a pass, and the drift compounds. The emulated machine itself is
deterministic; the debugger's stop/resume interleaving is not. Any gate
that needs exact tick arithmetic (the interception proof, determinism,
anything CRC-compared) must generate its inputs **in-ROM** (`SCRIPT_TBL` +
the masked fuzz) and use the debugger only to park (`b 17D5` × N stops)
and dump. Alignment is by stop count, never by instruction count —
different builds execute different instruction streams.

### 7.22 The EXEC boot EXECUTES the word at $7000 — never map code there

Bowling's netcode outgrew the $6000-$6FFF page and as1600's auto-cfg
dutifully mapped the overflow at $7000.  Within ~650 cycles of RESET the
EXEC's expansion hook (what the ECS uses) jumped into it: whether the
build booted or died depended purely on WHICH instruction happened to
land at $7000 (`bowling_net.bin` booted; `_net1.bin` had `SUBR R4,R7`
there, which subtracted $01FE from the PC and wandered to a HLT inside
the cart header).  The failure is silent, build-layout-dependent, and
looks like anything but what it is — it cost a full session of
session/transport forensics before a from-RESET single-step trace showed
the PC at $7000 at cycle ~650.  Fixes that transfer: (a) put segment
overflow at $D000 (the standard Mattel 16K window — the original
Bowling collection cfg's own second segment); (b) a build gate that
fails any cfg mapping $7000 (`make check-7000`).

### 7.23 N players = seats + a turn arbiter (the Bowling generalization)

The whole 2-player engine generalized cleanly to 2-4 with one wire and
one engine change, and N=2 runs the identical path afterwards:

- **Protocol v2**: the SENDER seat-tags INPUT/CRC (relay fanout stays
  verbatim), START carries seat + count + a 4-name roster, ROOM/GO
  frames implement host-starts-when-ready rooms, PEER_LEFT names the
  leaver, LOBBY's status byte becomes occupancy (low 3 bits count,
  bit7 unjoinable).  The server's `partner` scalar becomes a Room with
  members-in-join-order = seats; CRC comparison goes N-way server-side.
- **Engine**: one ring page per seat + per-seat watermarks; the gate is
  min over remote seats; the resync push broadcasts and the WHOLE room
  rebases together (a targeted push is semantically wrong — RS_REBASE
  resets tick/rings/watermarks globally).
- **Turn arbiter**: for a turn-based cart whose handlers are
  controller-blind (Bowling reads NO input cells at all — every handler
  ignores the dispatch's controller index), all consoles must compute
  the ONE controlling seat from sim state each tick and replay only
  that seat's events.  This is a correctness requirement, not UX: any
  seat's disc press would otherwise set the active bowler's curve.
  Registration prompts hand off by the game's own registrant-index
  cell; fixed prompts belong to seat 0; count-type prompts get answered
  by a deterministic injector driven off the roster size (the injector
  counter is sim state: CRC + resync tail).
- **Rig scale-out**: the `main_net%.asm` pattern rule gives consoles
  3/4 for free; stagger-compensate the run lengths (a console outliving
  its peers past the gate timeout records a bogus drop) and let the
  server's `--auto-go N` start rig rooms so all console builds stay
  uniform.

### 7.24 Virtualized countdowns: use the EXACT EXEC reload semantics

The real dispatcher fires an entry when its decremented countdown hits
ZERO and reloads the full interval — period == interval.  The
fire-on-negative form (period == interval+1) was invisible on Frog
Bog's 60/600-tick timers but would be a 50/33/20% slowdown on Bowling's
interval-2/3/5 entries, which pace the BALL and PIN motion.  Also new
here: a cart may call the $1831 set-countdown API on a GAME entry
(Bowling's slow-motion re-arm passes R0=5 for its ball entry) — that
site needs its own shim writing the virtualized countdown, and every
shim must preserve R1/R2 (Bowling's stop-all LOOP walks R1 across all
five slots through one call site).

### 7.25 §5.5's sharpest form yet: keypad-free fuzz + a prompt gate

Bowling's masked ($3F) fuzz can NEVER answer a keypad prompt, so a
4-player room whose demo script only registered two bowlers parked in
registration forever — and every CRC gate still "passed" (both/all
consoles parked identically).  It surfaced only because the m4 gate
REPORTS the adopted handler table and a human read `GAME_TBL=$505B` in
the output.  Beyond det's destination-phase assertion (§5.5), put the
same assertion in the RIG and M4 verdicts — any multi-console gate can
park in a prompt exactly as identically as a det pair can.

### 7.26 A cart may call `X_SCAN` from inside its own timer entry

Every port before Soccer assumed the EXEC main loop is the only thing
that runs the controller scan, so nulling `$035D` *after* the game tick
was enough: between our null and the next dispatch, the only scan was
the EXEC's, and it dispatched into the null table.

NASL Soccer's 20 Hz entry ends with `JSR R5,$14F1` at `$5058` — it calls
`X_SCAN` itself. The scan therefore runs **twice per pass**, and one of
those runs is *inside our tick*, after we installed the real handler
table for replay. Real local input would have been dispatched straight
into game code from within the tick, desyncing on the very first press,
while every single-console gate stayed green.

The fix is one extra adopt-and-null immediately before the game tick:

```
        ... LS_VDISPATCH seat 0, seat 1 ...
        JSR     R5,     LS_TBL_ADOPT
        MVII    #NET_NULL_TBL+4, R0
        MVO     R0,     $35D
        JSR     R5,     SC_GAME_TICK        ; cart's own X_SCAN is now inert
```

This is only safe when the cart's own `$035D` installs are known — here
there is exactly one, at `$50A1`, before any dispatch runs, so `GAME_TBL`
is a constant and nulling early cannot lose a table the cart wanted. If a
cart installs tables from inside tick code, use Armor Battle's
`NET_SCAN_WRAP` instead and patch the `JSR` operand.

**Add to recon**: grep the disassembly for `$14F1` before writing the
dispatcher. It costs one command and it is invisible in every other way.

### 7.27 A transported cell can be a CODE POINTER — clamp it

§7.2 says a wire value must never index a memory writer. Soccer produced
the nastier form: a wire value that *becomes a code pointer*, at a
perfectly legal image position.

The cart's scroll routine saves the live interrupt vector to `$0160/$0161`
before installing its own ISR body, and the body copies that pair back
into `$0100/$0101` unconditionally. `$0160` sits inside `$015D-$01EF`,
which is image section 1 — so it is serialized, transported and applied
like any other game byte. Every bounds check in the applier passes,
because the position *is* legal. One corrupted byte and the next tick
installs an arbitrary address as the frame interrupt handler.

Excluding it would have forced an `IMG_*` layout change and the §7.16
bounds sweep for no benefit, since the value is `$1126` in every healthy
state. So: keep it in the image and the CRC, and clamp it on both sides
in `RS_REBASE` (symmetric, so still CRC-neutral):

```
RS_CLAMP_ISR:
        DIS
        MVII    #EXEC_ISR_DEF AND $FF, R0
        MVO     R0,     SC_ISR_SAVE
        MVO     R0,     $100
        MVII    #EXEC_ISR_DEF SHR 8, R0
        MVO     R0,     SC_ISR_SAVE+1
        MVO     R0,     $101
        EIS
        MOVR    R5,     R7
```

**Generalize the audit**: after fixing the image layout, walk section 1
and ask of each cell not "is this sim state?" but "what does the cart DO
with this value?" Anything the cart loads into `$0100/$0101`, `$035D`, a
`JSR` target or an index register needs a clamp, not just a bound.

### 7.28 Measure the WALL tick rate — an ISR dance can steal a frame

§2.1 says the pass is 3 frames, not 1, and §2.2 gives tick rate =
20 Hz ÷ interval. Soccer's header says interval 1, `$0103` reads 3, and
both are true — yet the measured tick is **59,736 cycles = exactly 4.000
NTSC frames = 66.8 ms = 14.97 Hz**, a third slower than the arithmetic.

The cause is the cart's scroll dance: it installs its own ISR body every
tick and spins waiting for it, and *that body does not decrement `$0102`*.
One whole frame per pass is therefore invisible to the EXEC's own pass
accounting. `$0103` is not lying; it is measuring something narrower than
wall time.

Consequences: the delay budget is 33% more expensive than the header
implies (`d=3` costs ~200 ms here, not 150 ms), and every "ticks per
second" figure in a test script is wrong by the same factor.

**Rule**: on any cart that writes `$0100`/`$0101`, take the two-point
cycle sample at `MASTER_TICK` in the built ROM and derive `d` from that,
never from the header. The measurement is four lines of debugger script:

```
b <MASTER_TICK>
r 10000000     (x8, reading the cycle count at each breakpoint hit)
```

A useful side effect: the measurement also settles questions about the
dance's *length* without decoding flag semantics. Soccer's spin waits on
a cell that could have been a 3-frame counter or a 2-bit field; a counter
would have made the pass 6 frames. It measured 4, so it is a field.

### 7.29 If the quiescent point is unreachable under fuzz, test it on purpose

§7.6 gates the resync push on a dead-ball moment, and §8's step-8 gate
says the m4 report should show the push firing there rather than at the
cap. On Soccer the first m4 run reported the **cap** — and that was
correct behaviour, not a bug: under masked fuzz nobody ever scores, so
the phase cell sits at "live play" for the entire run and no dead-ball
bit is ever set.

The trap is accepting that as a pass. It leaves the entire quiescent
branch of `RS_PENDING` unexecuted by any automated test, forever, on a
cart where real play would take that branch constantly.

The fix is a deliberate mode, not a longer run: `QUIESCE=1` in
`run_m4.sh` forces the host's phase cell to a dead-ball value two seconds
after the fault, and the verdict then *requires* `RS_GATE == 1`. Both
branches get proven, and the ordinary run still reports honestly which
one it took.

**Generalize**: any gate whose interesting branch depends on game state
that fuzz cannot produce needs a forced variant. Ask, for each branch you
added: what would make this execute, and can fuzz ever do it? If not,
write the forcing mode at the same time as the branch.

### 7.18 Known, not yet acted on

- **Nagle is on for `N:TCP` sockets.** `NetworkProtocolTCP::open_client_connection`
  never calls `setNoDelay(true)` (only the modem devices do), so a
  6-byte-per-tick lockstep stream can eat tens of ms of jitter. One-line
  firmware change, but it means reflashing both consoles.
- **PAL.** Frames are 20 ms, so a PAL console's tick is 20% slower than an
  NTSC one's. The sim stays in sync (it is tick-based, not time-based) but the
  pair runs at the slower console's rate. Detect and either refuse the match
  or say so on screen.

### 7.19 Object-record field +5 is real-frame animation — exclude it in checkers

Field +5 of each 8-word object record (`$031D + 8n + 5`) is an
ISR-advanced animation counter: stalls and code-path length shift its
phase, so it differs at matched sim ticks BY DESIGN. The trace ring
always excluded it (Baseball-era finding, `debug.asm` TRACE_RANGES
comment), but the settled-state park compares in the tooling did not —
the earlier ports parked in animation-quiet states and never noticed.
Utopia parks mid-game with weather sprites animating, and both its
virt==hook compare and its det A/B flagged ONLY field-+5 cells. Put the
exclusion in every state-compare tool (`crc_trace_diff.py` has it now);
transporting the field in the resync image stays fine (cosmetic,
converges).

### 7.20 A hybrid poll+dispatch cart's shadow pair needs SHADOW_FROM_RINGS under lockstep too, not just under the local spikes

Armor Battle's `UPDATE_SHADOW` feeds the polled `$011F`/`$0120` shadow
pair from live local cells, then the local `SPIKE_VIRT` path in
`MASTER_TICK` calls `SHADOW_FROM_RINGS` right after to overwrite it from
the delay rings — documented at the time as part of the hybrid model.
What wasn't obvious until the sixth port: **`LS_PASS` (the actual
netplay path) needs the identical `SHADOW_FROM_RINGS` call**, and it is
easy to omit, because `UPDATE_SHADOW` alone compiles, assembles, and
even passes `make det` cleanly — a single-process determinism test sees
the same (locally-live) cells on both "sides" either way, so nothing
looks wrong. Only a real two-console run exposes it: the remote player's
physical controller isn't attached to this console, so without the
rings-overwrite, this console's poll of `[$011F + remote-seat]` reads
whatever this console's OWN (idle) second controller happens to show,
not the exchanged, delay-adjusted value. Frog Bog's first `make rig` run
failed with exactly this signature: CRC mismatches confined to the
window where scripted (not fuzzed) input was exercising the polled
check, self-resolving once only masked disc-only fuzz remained, all
`DIAG` counters clean (a transport-layer red herring to rule out first).
Generalise: **any test that runs the whole engine in one process — `det`,
`lag`, `virt` — cannot catch a bug that is specifically about what a
*second, separate* console sees.** That is exactly why the procedure
below gates on the real two-process rig and does not stop at `det`.

### 7.21 A sound-effect trigger can be a determinism leak even after every RNG site is wrapped

§5.2 already flags that the EXEC sound engine stirs `$035E` from ISR
context whenever a noise SFX plays, and that this is why RNG wrapping has
to be per-call-site, not a whole-tick save/restore. Frog Bog surfaced a
second, distinct failure mode of the *same* mechanism: a code path that
triggers a sound effect can desync **even when it never touches
`$035E` itself, and even when every real RNG call site is already
correctly wrapped.** The sound engine's own internal state (which frame
of an SFX envelope it is playing) advances asynchronously in real frames
for as long as the effect plays, independent of sim ticks. If a stall (or
a second console's independent real-time execution) changes how many real
frames elapse relative to game ticks, and that per-frame sound-engine
state happens to fall inside whatever memory range your determinism
checker compares, you get a leak that *looks* exactly like an unwrapped
RNG read (state diverges downstream of a random-feeling branch) but is
not — grep the whole ROM for unwrapped `$035E` reads outside your known
RNG sites before spending a session chasing an RNG explanation that isn't
there.

**A synchronous save/restore around the trigger call does not fix this**
— confirmed by building and testing it. It can only protect the instant
of the call; the churn that causes the actual divergence happens on every
real frame *after* the trigger returns, for as long as the SFX plays,
long past where any synchronous wrapper still has control.

**What worked**: identify exactly which trigger call site is reached on a
provably frequent, fixed cadence (bisect with ROM-patch flag-forcing +
rerun `make det`, the same technique as isolating an RNG site — force a
branch, does the leak reproduce, revert) and skip the call entirely,
unconditionally in every patched build (not gated on your netplay-armed
flag if your timer-virtualization engine itself runs unconditionally —
gating it that way can leave local single-process determinism spikes
completely unprotected, since they never arm netplay but still run the
virtualized engine that reaches the leaking code). Read the target
routine's *actual* control flow before deciding what a skip costs: a
straight-line disassembly listing does not prove fall-through — computed
returns (`ADD@/ADDR Rx,R7`-style dispatches, common in this EXEC's SFX and
decompression conventions) can make code that reads as one giant routine
actually be several independently-invoked ones sharing an address range
by coincidence. Cross-check the branch-target cross-reference dis1600
emits at the end of its listing before assuming a skip silently disables
some *other* caller's use of the same code.

**What this does not fully close**: every call site that can trigger this
class of leak needs the same audit; skipping the highest-frequency one
can take a `make rig` gate from reproducing on nearly every run to a small
residual (Frog Bog: from constant failure to 3/32 CRC-mismatched pairs on
a real fuzzed run) without reaching zero, if the ROM has other
lower-frequency trigger sites left unaudited. Whether to keep chasing the
residual depends on whether any triggering logic actually depends on the
SFX's outcome (§7.8's own test) — if not, this matches Auto Racing's own
shipped precedent of leaving this class of leak to the CRC+resync net
rather than patching every last call site.

### 7.30 A timer entry can be armed/stopped by a hardcoded literal RAM
address, invisible to recon.py's JSR-only scan

Every timer-arm hazard before this one (§3, §7.24, Armor Battle's shims)
came through the timer API — a `JSR R5,X_TIMER_START`-shaped call site,
passing the ORIGINAL absolute ROM address of a table entry, which
`recon.py` finds because it scans for exactly that JSR pattern. Sea Battle
has one of those (shimmed the ordinary way) and, hidden inside the same
game's ship-destroyed handler, TWO MORE sites that manipulate a timer
entry's countdown by writing the literal RAM address directly:
`MVII #$0127,R4` / `MVO@ R0,R4` and `MVO R0,$0127` — no JSR, no API, just
ordinary-looking game bookkeeping that happens to target the exact RAM
cell the EXEC's timer dispatcher uses for one specific table slot's
countdown ($0125 + 2×slot).

This is invisible to `recon.py` (which only pattern-matches JSR call
sites) and easy to miss in a manual dis1600 read too, because nothing
marks it as timer-related — it reads as "clamp some counter to at most
20, or reset it to 100" until you recognize the address. On the original
cart these writes correctly targeted the entry they always meant to
(the timer table's second slot, whatever RAM offset that happened to be),
because the cart's own code was authored against ITS OWN table layout.
Relocate the table without preserving that entry's RELATIVE POSITION and
these writes silently start targeting WHATEVER is now at that RAM offset
— on this port, that would have been `MASTER_TICK`'s own countdown,
stalling the entire dispatcher for the duration written (up to 100
passes / 5 seconds) every time a ship was destroyed, completely
unannounced, with no CRC mismatch and no crash.

**The fix**: keep every timer entry with a known literal-address writer
at the SAME relative table position it always had (not necessarily
position 0 — just the same position relative to whichever slots
surround it), and if that's not possible, patch the literal operand
words to the entry's new absolute countdown address, exactly as you
would patch a stale JSR target.

**Generalize the audit**: after writing the new table layout, `grep` the
disassembly for the LITERAL countdown addresses your relocation touches
($0125, $0127, $0129, … depending on final slot order) in addition to
grepping for `$181E`/`$1831`/`$1838`/`$1844` call sites. A cart that
manipulates its own timer state directly, without going through the API
it itself defines, is not a contradiction — it is the same shortcut a
human programmer takes any time the "proper" API is more code than a
known-safe direct poke, and EXEC carts from this era were written under
real size constraints.

### 7.31 Letting an entry dispatch natively instead of virtualizing it is a
real simplification — verify the removal, not just the gate

Sea Battle's second and third timer entries turned out not to need
virtualizing at all: because the EXEC's own dispatcher ($17D5) walks the
table in one pass and cannot reach a later slot until an earlier slot's
subroutine call fully returns, putting `MASTER_TICK` first in the table
means $17D5 physically cannot dispatch the entries after it any earlier
than `MASTER_TICK` itself allows — including through a stall, since the
stall spins *inside* `MASTER_TICK`, before it returns. Two entries can
therefore be left at their original ROM targets, fired natively, with
zero hand-rolled countdown code, and stay exactly as stall-safe as a
virtualized entry.

This is a genuine simplification worth generalizing to other carts with
multiple game-logic timer entries — but the removal itself is easy to
get subtly wrong in a way that LOOKS like it works. A first draft of the
simplified dispatcher, reasoning "$17D5 calls table slot 1 by jumping
into MASTER_TICK, so nothing else needs to call the ORIGINAL slot-0
entry", quietly dropped the call to the cart's own primary game-logic
routine entirely — because that routine was never IN the relocated table
at all (its slot was replaced with MASTER_TICK's address, not kept
alongside it). The build assembled clean, booted without crashing, and
`make det` passed 256/256 ticks identical — a stalled/unstalled pair of
runs that both never advance past tick 0 of real game state are, by
definition, identical to each other. The bug was found only by comparing
a live boot-dump against the RECON-PREDICTED state (a phase cell that
should have advanced past its boot value, and didn't) — not by any
automated gate.

**Generalize**: whenever a table-relocation removes a JSR that used to
reach a specific piece of cart logic — even one being "replaced" by
your own dispatcher — audit explicitly whether anything ELSE still
calls it. `make det` proves two builds agree with each other; it does
not prove either one is doing anything. Confirm any timer-table
restructuring against a LIVE BOOT DUMP compared to the recon-predicted
state (a phase cell that should move, a counter that should increment),
not against a passing gate alone — especially right after removing a
JSR you've convinced yourself is now redundant.

### 7.32 A recon false positive can be correctly CLASSIFIED and still need patching

§3's false-positive classes (misaligned decode, hot-cell `CMPI`, wrong
operand) are all framed as "this candidate isn't real, ignore it." Golf's
polled-input site produced a class-2 false positive (a `CMPI` against a
constant shaped like a hot cell — `$0121`) that was, correctly, NOT a
read of `$0121` — it was a loop terminator for a walking-pointer poll
that starts at `$011F` and reads exactly two cells. Classifying it
correctly and therefore skipping its patch would have been a real bug:
the terminator's value (`$0121`) is `$011F`-RELATIVE (base + 2), so
patching only the poll's starting address to the shadow pair leaves the
terminator comparing the NEW base against the OLD absolute sentinel —
the loop then walks the pointer through unrelated RAM until it happens
to collide with `$0121` by chance, reading garbage into the game's disc
decode for an unbounded number of iterations.

**Generalize**: "is this candidate a real read" and "does this address
need patching" are two DIFFERENT questions. A loop bound, an index
limit, or any other value computed as an offset from a base address you
ARE relocating needs to move with that base, even when it is correctly
classified as not itself being a read of live hardware state. When
recon flags a `CMPI`/`CMPR` near a poll or walking-pointer loop, check
whether its constant is arithmetically derived from a nearby `MVII`
you're about to patch, not just whether it "reads" anything.

### 7.33 When the exact input-consuming field is unknown, cross-correlate the determinism ring for `lagcheck`, not a guessed game cell

Every `lagcheck` before this one watches one or two hand-identified game
cells (a MOB velocity field, a fleet position) and cross-correlates
THOSE between a d=0 and a d=20 build. That requires knowing, in advance,
which cell captured input actually lands in — Golf's exact swing/aim
field was not reverse-engineered this session (the `$525E` poll's
internal decode didn't yield to a quick read), so picking a field by
analogy to a sibling cart would have been a guess wearing measurement's
clothes.

Instead, both `main_lag.asm` and `main_lag0.asm` were built with
`SPIKE_TRACE` on (previously exclusive to the `det` builds) and
`TRACE_STOP` kept under 256 so the ring never wraps (ring index *i* is
tick *i*, directly — no lap ambiguity to reason about). `run_lagcheck.sh`
then cross-correlates the FULL per-tick state checksum sequence between
the two builds. This needs no cart-specific knowledge at all: it proves
the whole state timeline in the d=20 build is a d-tick-later copy of the
d=0 build's timeline, which is exactly what the delay ring claims to do,
without requiring you to know WHAT changed — only that everything
downstream of captured input did, together, on a fixed schedule.

**A real trap on the first attempt**: `TRACE_STOP` was initially left
above 256 (matching the `det` builds' convention), which meant the ring's
FINAL dump only reflected its last, unwrapped 256-tick lap — silently
discarding the early ticks (including the whole "settle" row) that had
already been overwritten by the time the run parked. The correlation
scored a false peak at shift=0 (both builds' RECENT, mostly-idle
histories agreeing trivially) until `TRACE_STOP` was dropped under 256,
which fixed it immediately and produced a sharp, isolated peak at the
true shift.

**Generalize**: this is likely the better DEFAULT `lagcheck` design for
future ports, not just a fallback for when the input field is unknown —
it reuses machinery `make det` already proves correct, and it can never
silently key on the wrong cell.

### 7.34 A "copy unchanged" file can still carry the donor cart's own UI strings

PORTING §4 lists `src/netcode/session.asm` as copy-unchanged. Its CODE
is — but a handful of its literal `STRING` constants are cart identity,
not engine plumbing: the title screen, the matched-screen seat-identity
line, and the start-hint line are all donor-cart text (`SOCCER NETPLAY`,
`YOU ARE TEAM n`, `KICK OFF` on this port's Sea Battle-derived copy), and
they compile and run just fine unedited — nothing fails, no gate catches
it, the screen just says the wrong game's name and terminology to a real
player. A subtler fourth case: `STR_ROOM`'s `"WAITING ROOM   OF n"` is a
compile-time-constant TEMPLATE (only the live count gets overwritten at
runtime; the max never does), so it must match the cart's OWN
`MAX_SEATS`, not the donor's — confirmed by checking Bowling's own
`session.asm`, which literally reads `OF 4` for exactly this reason.

Caught this port only by actually READING `make lobby`'s decoded screen
output, not by trusting its PASS lines — the test's assertions were
written against the SAME donor strings the code still had, so a
copy-paste-and-never-touch session.asm would have passed `make lobby`
while showing the wrong game's name on every screen a real player sees.

**Generalize**: after copying any "unchanged" file, `grep` it for
`STRING` and read every literal against the donor cart's own name,
terminology, and any numeric constant that should track a `MAX_SEATS`-
shaped value — this is invisible to every automated gate, because the
gates check BEHAVIOR, and displaying the wrong text is not a behavioral
failure by any measure a checksum or a CRC comparison can see.

### 7.35 The defensive `X_MUSIC_TICK` slot-0 placeholder can be provably
load-bearing, not just precautionary

Every port's `hook.asm` since Baseball carries a stopped `X_MUSIC_TICK`
entry at table slot 0, with a comment explaining WHY: the EXEC's own
note-duration engine (traced in full on Boxing: `$1A61` "sfx entry" →
`.EXEC.831`/`$1831`, the "set countdown := R0" entry) computes its
target countdown address as `$0125 + (table_base - table_base)/2 =
$0125` — i.e. table slot 0, ALWAYS, regardless of what the cart's own
table puts there, whenever a note is actively playing. Every port before
Boxing carried this as a defensive measure whose actual necessity was
never confirmed live — either the cart never called into the note engine
at all, or the call was traced and found unreachable (Sea Battle: "traced
the ROM's only entry-0-rearm routine and found ZERO callers reaching it
... but the placeholder costs one dummy table row, so keep it anyway").

Boxing's own custom ISR genuinely calls `X_PLAY_NOTE` — a real, reachable
call, confirmed in `dis1600` output, not dead code. This makes Boxing the
first port where the placeholder is PROVABLY load-bearing: without it,
the natural choice for table slot 0 (`MASTER_TICK`, since Boxing's
original table — like most ports' — has no music entry of its own)
would have its own dispatcher countdown silently stomped by the EXEC
every time a punch or bell sound plays, invisible to every CRC gate
(both consoles reprogram it identically, so nothing looks wrong) but a
real, periodic stall of the entire netcode engine.

**Generalize**: don't treat "does the cart's own table have a music
entry" as the question that decides whether the placeholder matters —
the real question is "does the cart call into the EXEC's note engine at
all" (grep for `X_PLAY_NOTE`/`X_PLAY_MUS`/`X_PLAY_SFX` targets, from a
cart ISR as well as from mainline code). Keep the placeholder regardless
— it costs one dummy row — but know which ports actually need it before
assuming the pattern is cosmetic.

### 7.36 Game logic can busy-wait on the ISR phase counter directly,
outside the documented timer API

Every prior real-frame-timing hazard in this family (§5.2's RNG stir,
§7.8/§7.21's SFX-engine churn) is mediated by the EXEC's OWN sound
engine — the cart never touches the real-time-dependent state itself, it
just happens to be affected by something else that does. Boxing's
punch-connect timing check (reached from real gameplay, gated behind a
proximity test) is a different shape entirely: `MVI $0102,R1 / EIS /
CMPI #$0001,R1 / BGT <self>` — game logic reading the EXEC's own ISR
phase counter DIRECTLY, with its OWN `EIS` to let the ISR keep advancing
it while it polls. There is no JSR anywhere near this — it is a plain
memory read — so it is invisible to `recon.py`'s JSR-based scan and to
any audit that only greps for calls into known EXEC sound/RNG entry
points.

This watches real, SUB-TICK frame timing that the whole netcode model
has no representation for (the model treats one `MASTER_TICK` call as one
discrete, atomic sim tick; nothing else is supposed to observe time
passing WITHIN one). A netcode stall — the test injector and the real
lockstep freeze both use the identical save/`DIS`/force-`$0102`-to-0/
restore/`EIS` pattern — does not preserve the real-time relationship this
specific poll depends on: freezing `$0102` at 0 satisfies the loop's
"`<=1`" exit condition immediately regardless of how many real ISR
frames the stall actually consumed, producing a real, reproducible
`make det` divergence isolated (by temporarily narrowing `debug.asm`'s
checksummed ranges as a diagnostic) to exactly the sub-range the
affected logic feeds.

**The fix, once found**: canonicalize the read the same way §5.2
canonicalizes RNG — redirect the operand to an always-zero (or otherwise
run-independent) netcode-RAM cell, so the check is satisfied
deterministically on every console regardless of real stall timing. The
sim-logic OUTCOME the check gates is unaffected; only the sub-frame
real-time delay before that outcome is decided is removed. This is a
cheap, low-risk fix once the site is found — the hard part is finding
it.

**Generalize**: after the standard RNG/timer-API/`$011F`/STIC audits, do
a dedicated sweep for direct reads OF `$0102` (and `$0103`) by ANY
non-EXEC code (the cart's own ISR excepted, which legitimately owns
`$0102`) — `MVI $0102,Rx` or `MVI@` through a register holding that
literal address, not just JSR targets. A loop that also does its OWN
`EIS` right after the read is close to a certain sign: it exists
specifically to let real time pass while it polls, which is exactly the
shape that breaks under a stall.

**How this was actually found**: not by static disassembly alone —
by narrowing `debug.asm`'s `TRACE_RANGES` to isolate which sub-range of
checksummed state disagreed, then LIVE SINGLE-INSTRUCTION STEPPING
(jzIntv's `s` command — **not** `n`, which unsets a breakpoint, a real
trap the first time through this session) through the surrounding code
with a breakpoint at every conditional branch, comparing register/flag
state between the two builds at the exact point they diverge. Chasing
this purely through reading a disassembly listing did not converge; the
live trace found it in a handful of targeted breakpoint sessions. The
same technique (not the same bug) also fully resolved this port's M3
two-seat keypad-handshake mystery — it is the generically useful
technique for "the checksum disagrees somewhere in this range and I
don't know why" once static reasoning has run out of leads.

**A real operational trap, worth generalizing regardless of any specific
bug**: every build variant tested by invoking `as1600` directly instead
of `make <target>` produces a `.cfg` missing the `[memattr] $8000-$9BFF
= RAM 8` line — `make`'s own recipes append it as a separate step after
assembly (`echo "$$CART_RAM_CFG" >> $(basename $@).cfg`). Without it,
cart RAM reads as unmapped/floating in jzIntv, and the symptom is a
CONTENT-INDEPENDENT crash (`CPU off in the weeds`, PC lands on a low
address) at a FIXED cycle count regardless of what the ROM logically
does — deterministic and reproducible across reruns, which makes it
look exactly like a real, content-dependent code bug. This cost a real
side-investigation this session (chasing a "crash" through several
script-content variations that all "fixed" it, because the underlying
cause was the missing RAM declaration, not the script) before the
pattern — `b`/`r` work fine, then garbage, always at the same cycle
count no matter what the build actually contains — gave it away.
**Always use `make <target>`, never a bare `as1600` invocation, when
testing a freshly written or edited build variant.**

### 7.37 A cart whose own image fills the family's usual netcode page
needs the hook segment relocated to its own unused tail

Every port before Shark Shark was a 4K-word cart (`$5000-$5FFF`), so
`src/hook.asm`'s `ORG $6000` was always a genuinely empty page. Shark
Shark is the family's first 8K-word cart: its own image runs through
`$67F9`, exactly the page every prior port's netcode occupied. The fix
generalizes cleanly: relocate the hook/vdispatch/mailbox segment to the
cart's own unused tail (`$67FA-$6FFF` here, zero-filled in the original
ROM) rather than to the collection cfg's other declared windows — this
adds NO new hardware ROM window beyond the standard Mattel `$D000`
`NET_SESSION` block every port already uses (proven on real hardware by
Sea Battle), where using `$F000` or similar instead would have.

Two small, generalizable tooling consequences: `tools/dump_rom.py`
needs a `--stop HEX` option so the patched dump doesn't emit DECLE words
into the region the relocated hook segment now owns (the ORG would
otherwise collide with already-emitted bytes); `tools/check_patch.py`
needs a matching word-count limit so `verify-patch` doesn't compare the
hook segment's own code against the original ROM's zero-fill and report
it as thousands of undeclared diffs. `verify-org`'s UNPATCHED dump is
unaffected either way — it must always reproduce the FULL original image.

Also worth checking on any future oversized cart: how close the
relocated segment now sits to `$7000`. Half the margin of every prior
port (2048 words instead of 4096) is still comfortable in practice
(Shark Shark's actual hook segment used only 1019 words), but `make
check-7000`'s ORIGINAL grep-for-a-literal-`$7000`-mapping form only
catches a segment that STARTS there — extending it to a genuine SPAN
check (parse every `.cfg` mapping line, fail if the destination range
overlaps `$7000` at all, not just begins there) is one-time, cheap
insurance worth carrying forward as the family's new default, not just
this port's workaround.

### 7.38 The family's whole-checksum `lagcheck` design (§7.33) can FAIL
even when the delay mechanism is CORRECT

§7.33 documented the whole-`TRACE_RING`-checksum cross-correlation as
the more robust default for `lagcheck` going forward, reusing the same
machinery `make det` already proves. Shark Shark is the first cart where
that design itself failed — not the delay ring it was testing.

Root cause: this cart has FOUR always-armed, real-time-scheduled timer
entries (spawn roll, AI steering, bite resolution, recovery — none
gated on player input, all firing unconditionally on their own fixed
interval) alongside the one input-driven MOB-position write. The
checksummed range is DOMINATED by that ambient component, which is
delay-INVARIANT by construction: at real tick T, both a d=0 and a d=20
build have run identical ambient logic for the identical T ticks,
regardless of what input either has seen. A genuine cross-correlation
(`d0[T] == d20[T+d]`) is asking the d=20 build's ambient state, having
progressed T+d real ticks, to match the d=0 build's, having progressed
only T — the dominant signal can never align at ANY shift, precisely
BECAUSE it correctly does not depend on delay. Confirmed live: the two
builds' checksums matched EXACTLY, bit-for-bit, for the first 20 ticks
(pure ambient, no input divergence had reached either build yet), then
diverged with no shift ever re-aligning them — the textbook signature of
this failure mode, not of a broken delay ring.

**Diagnostic**: before concluding a `lagcheck` FAIL means the delay
mechanism itself is broken, dump the raw ring values (not just the
correlation score) and check whether early, pre-divergence ticks match
exactly between the d=0 and d=20 builds. They should. If they do, and no
shift ever produces a clean peak afterward, suspect the checksum's own
composition (does it include always-armed, input-independent state?)
before suspecting `DELAY_EN`, `VIRT_CAPTURE`, or the ring read/write
logic.

**The fix, when it applies**: if the exact input-consuming cell IS known
(unlike Golf's own case, which is why §7.33 chose the whole-checksum
fallback in the first place), go back to the family's ORIGINAL
hand-picked-cell approach instead — but track a DIRECT, un-smoothed
input echo (a cell written only by the actual input-dispatch path, nothing
else), not a cell the ambient logic also touches, which would reintroduce
the same problem at smaller scale. Shark Shark added a small, dedicated
`LAG_RING` (two extra `MVI`/`MVO@` pairs in `TRACE_TICK`, a separate ring
address) rather than repurposing `TRACE_RING` itself, so `make det`'s own
proof stays completely unaffected by a change made only to fix
`lagcheck`.

**Generalize**: §7.33's whole-checksum design is the right default only
when the checksummed timeline is genuinely PRIMARILY input-driven, or
the exact input-consuming field is truly unknown. A cart with multiple
always-armed ambient timer entries — increasingly likely as this family
tackles busier carts — needs the hand-picked-cell approach instead, and
needs it BECAUSE of the same busyness that makes full virtualization
necessary in `hook.asm`, not despite it.

### 7.39 Forcing a DERIVED flag for a `QUIESCE`-style test doesn't work
if the deriving computation runs between every poke and its consumer

§7.29 established that a gate whose interesting branch depends on game
state fuzz cannot reach needs a forcing mode. Every port through Golf
forced the flag `RS_PENDING` reads (`SC_PHASE`/`SC_PHASE_DEAD`) directly,
repeatedly, across a window — and it worked, because in each of those
carts nothing else on the per-tick path recomputed that exact cell.

Shark Shark's `SS_QUIESCENT` (aliased to `SC_PHASE`) is COMPUTED fresh
every tick, by `SS_GAME_TICK`, from the underlying MOB "alive" bits —
and `SS_GAME_TICK` runs, unconditionally, BEFORE `RS_PENDING` checks the
flag in that same tick's `LS_PASS`. An external debugger poke to the
flag lands between ticks (at whatever arbitrary instruction count the
test script happens to be at); the very next tick's `SS_GAME_TICK` call
overwrites it with the real, non-quiescent computation before
`RS_PENDING` ever observes the forced value. No amount of widening the
forcing window fixes this — the poke and the overwrite race on every
single tick, and the deriving computation runs first every time, by
construction. (Confirmed by elimination: a 15s window failed, a 50s
window also failed with the SAME symptom, and only forcing the
UNDERLYING cells the computation reads — not the flag it produces —
made the quiescent branch fire, immediately, on the very next tick.)

**Generalize**: before choosing what to force for a `QUIESCE`-style
test, check whether the target flag is a RAW state cell the cart's own
code and the netcode both leave alone outside of arm/stop calls (Golf's
`GF_ARM*`, Bowling's — these are safe to force directly), or a DERIVED
value some per-tick routine recomputes from OTHER cells (this cart's
`SS_QUIESCENT`, and plausibly any future port's own quiescence flag if
it's built the same way, from live game state rather than from a timer-
API-gated flag). For a derived value, force the inputs the computation
reads, not the output it produces — and if the derivation involves a
hypothesis not yet independently confirmed (as `SS_QUIESCENT`'s MOB-bit
derivation was here), a successful forced run doubles as the first live
confirmation of that hypothesis, not just a workaround for the test.

Also worth carrying forward: the SPECIFIC fault chosen for a plain
(non-`QUIESCE`) `m4` run and the fault chosen for a `QUIESCE=1` run can
have genuinely OPPOSITE requirements. Shark Shark's first attempt used
one fault (`SS_PCOUNT`, a loop bound `SS_TICK4` reads every tick) for
both, and it was wrong for BOTH, in different ways: for the plain test,
its every-tick effect made the divergence ONGOING rather than one-shot,
eventually timing out the gate loop into a real `NET_DROPPED`; for the
`QUIESCE` test, a DIFFERENT fault (a write-only input-echo cell) turned
out to be unreliable because whether it ever gets read back at all
depends on random fuzz timing, producing zero mismatches some runs. The
fix was two DIFFERENT faults, matched to what each test specifically
needs (a clean one-shot corruption for proving ordinary detect-and-repair;
an immediate, guaranteed-every-tick-checksummed one for proving a
specific gate branch fires inside a bounded forcing window) — don't
assume one fault has to serve both purposes.

---

## 8. Procedure

Each step has a gate that must pass before the next one is worth starting.

1. **Byte-identical rebuild.** `tools/dump_rom.py` with no patch file, then
   `make verify-org` — the source must reassemble to the original ROM exactly.
   This guards every later step against dump/toolchain drift.
2. **Recon.** `make recon ROM=…`, confirm every candidate in `make dis`
   output, write `tools/patches.py`. Gate: `make verify-patch` reports exactly
   the sites you declared.
3. **Hook.** Relocate the timer table, insert `NET_START`, reproduce every
   game timer entry in the master dispatcher. Gate: `make run-hook` must feel
   identical to stock.
4. **Interception proof.** Route input through the shadow pair with a delay
   ring. Gate: `make run-lag` — a 1-second input delay is unmistakable.
5. **Determinism.** RNG wrappers, volatile-cell map, stall injection. Gate:
   `make det` PASS. Then extend with recorded real gameplay (`make run-rec`).
6. **Transport.** Gate: `make echo-test` — 100 clean echo rounds through
   `jzintv --fujinet` → fujinet-pc.
7. **Lockstep + matchmaking.** Gate: `make rig` — two consoles, auto-matched,
   CRC pairs compared, `DIAG` counters all zero.
8. **Desync recovery.** Gate: `make m4` — fault injected, detected, repaired,
   and the report says the push fired at the quiescent point rather than the
   cap.
9. **Drop handling.** Gate: `make peerleft`, both branches.
10. **Hardware.** `make rom SRV_HOST=…`, two PiRTO IIs, HUD on. Read `L`, `S`,
    `T`, `R` during real play and tune `d` from what they say.

## 9. Checklist

```
[ ] $0103 measured (pass length in frames)
[ ] tick rate measured in the built ROM, two-point cycle sample
[ ] delay d chosen from measured RTT, not habit
[ ] every timer entry the game uses reproduced in the dispatcher
[ ] every RNG call site wrapped
[ ] every $011F/$0120 read repointed (chase indexed reads in dis1600)
[ ] $035D nulled during the real scan; virtual dispatch replays both sides
[ ] $0121/$0122 carried on the wire
[ ] volatile-cell map built; CRC covers only real sim state
[ ] resync image includes the live handler-table pointer
[ ] quiescent point identified (or its absence accepted deliberately)
[ ] display: STIC-write count checked; header reassert only if it is zero
[ ] netcode RAM starts at $8080
[ ] all wire-driven writes bounds-checked, signed compares audited
[ ] CRC ring invalidated with a non-zero marker and cleared at session start
[ ] DIAG counters wired to the peer-left screen
[ ] HUD enabled for bring-up, disabled for release
[ ] timer arm/stop sites decoded: which entry does each target? shims where needed
[ ] cart-side main loop? scan-vs-dispatch order derived; replay order matches (5.7)
[ ] $02F0-$031C censused for cart globals above the stack base (7.15)
[ ] image bounds constants swept after any IMG_* change (7.16)
[ ] exact-tick gates driven by in-ROM script, parked by stop count (7.17)
[ ] every scripted event code measured at the live scan, not extrapolated (5.5)
[ ] det verdict asserts the destination phase, not just checksums (5.5)
[ ] state-compare tools exclude object-record field +5 (7.19)
[ ] every SFX-trigger call site audited for real-frame state leakage,
    distinct from RNG wrapping (7.21)
[ ] no cfg maps $7000 -- the EXEC boot executes it (7.22; make check-7000)
[ ] countdown reload semantics exact (fire on ==0, reload full) when the
    entries pace visible motion; $1831 set-countdown sites shimmed (7.24)
[ ] shims preserve R1/R2 (stop-all loops walk R1 through one site) (7.24)
[ ] multi-console gate verdicts assert the destination phase too (7.25)
[ ] N-player: seat-tagged frames, per-seat rings/watermarks, broadcast
    resync with all-rebase, turn arbiter for turn-based carts (7.23)
[ ] grep the cart for $14F1: a timer entry that calls X_SCAN itself needs
    $035D nulled BEFORE the tick as well as after (7.26)
[ ] every transported cell audited for what the cart DOES with it, not
    just bounded -- code pointers need a clamp (7.27)
[ ] wall tick rate MEASURED at MASTER_TICK on any cart that writes
    $0100/$0101; d derived from that, never from the header (7.28)
[ ] every gate branch that fuzz cannot reach has a forcing mode, written
    at the same time as the branch (7.29)
[ ] grepped the disassembly for every timer entry's LITERAL countdown
    address ($0125 + 2*slot), not just JSR-based timer-API sites (7.30)
[ ] any table-relocation that removes a JSR to let an entry dispatch
    natively is verified against a live boot dump against the
    recon-predicted state, not just a green `make det` (7.31)
[ ] a loop terminator or index bound expressed relative to a patched
    base address is patched too, even when correctly classified as
    "not a read" (7.32)
[ ] if the input-consuming field is unknown, lagcheck cross-correlates
    the determinism ring instead of a guessed cell (7.33)
[ ] every literal STRING in a "copy unchanged" file checked against the
    donor cart's own name/terminology, including MAX_SEATS-shaped
    numeric templates (7.34)
[ ] if the cart's ISR (or any mainline code) calls into the EXEC note
    engine, the X_MUSIC_TICK slot-0 placeholder is confirmed
    load-bearing, not just kept as a precaution (7.35)
[ ] swept for direct, non-JSR reads of $0102/$0103 by non-EXEC code
    (especially any read paired with its own EIS) -- a real-frame
    busy-wait outside the timer API, invisible to a JSR-based recon
    (7.36)
[ ] every fresh build variant tested via `make <target>`, never a bare
    as1600 invocation -- a hand-built .cfg is missing the [memattr] RAM
    declaration and produces a content-independent, misleading crash
    (7.36)
[ ] if the cart's own image already occupies $6000-$6FFF (an 8K+-word
    cart), the hook segment is relocated to the cart's own unused tail,
    not a fresh collection-cfg window -- dump_rom.py --stop / check_
    patch.py's compare-length keep verify-patch honest about it (7.37)
[ ] before trusting a lagcheck FAIL as a broken delay ring, dumped the
    raw ring and confirmed early ticks do NOT match exactly between the
    d=0/d=20 builds -- if they DO match early then diverge with no shift
    ever re-aligning them, suspect always-armed ambient timer entries
    dominating the checksum, not the delay mechanism (7.38)
[ ] for a QUIESCE-style forcing test, confirmed whether the target flag
    is a raw arm/stop-gated cell (safe to force directly) or a value some
    per-tick routine recomputes from other state (force THOSE cells
    instead, not the derived flag, or the poke races the recomputation
    and loses on every tick regardless of window width) (7.39)
[ ] chose separate faults for the plain and QUIESCE=1 m4 runs if a single
    fault's properties are wrong for one of them (immediate-and-reliable
    vs. one-shot-and-contained are often incompatible requirements) (7.39)
```

## 10. Where the detail lives

- `~/Workspace/fujinet-intv-shark-shark/spikes/NOTES.md` — twelfth-port
  deltas: the first 8K-word cart in the family (hook segment relocated
  to the cart's own unused tail, not a fresh collection-cfg window), a
  mid-session seat-model correction (scaffolded from a wrong 1-4-player-
  turn-based premise, corrected live to 1-2-player-simultaneous once the
  cart's own boot prompt and controller-routing mechanism were read), the
  busiest fully-virtualized timer surface yet (five entries, none with
  interval 1), an ISR dance firing unconditionally every tick (not a rare
  event) with its own §7.27/§7.35 consequences, the whole-checksum
  `lagcheck` design's first real failure (dominated by always-armed
  ambient logic, §7.38) and its fix (a dedicated input-echo `LAG_RING`),
  and a three-iteration `QUIESCE=1` investigation that root-caused WHY
  forcing a derived flag can never work regardless of window width
  (§7.39), ending in the first live confirmation of this cart's own
  `SS_QUIESCENT` derivation hypothesis.
- `~/Workspace/fujinet-intv-boxing/spikes/NOTES.md` — eleventh-port
  deltas: the fifth 2-player port, native dispatch applied to four of
  five timer entries (the widest yet), the X_MUSIC_TICK placeholder
  proven load-bearing rather than precautionary, the CHOOSE MEN
  two-seat keypad handshake fully root-caused by live single-
  instruction stepping (picking the same digit as the other seat is a
  silent, undocumented reject), the $0102 direct-read busy-wait
  determinism leak (one class found and fixed, a second narrowed but
  not yet reconciled), and the as1600-vs-make memattr testing trap.
- `~/Workspace/fujinet-intv-golf/spikes/NOTES.md` — tenth-port deltas:
  the second 2-4 player port, the first combining the 4-seat engine with
  the C-relay-diff tooling (and the `server_diff.py` fix that surfaced),
  the recon false positive that was correctly classified and still
  needed patching, the TRACE_RING-based `lagcheck` redesign, and the
  copy-unchanged-file-with-donor-strings bug caught by reading decoded
  screen output rather than trusting PASS lines.
- `~/Workspace/fujinet-intv-sea-battle/spikes/NOTES.md` — ninth-port
  deltas: the first cart needing zero RNG wrappers, the hardcoded-literal
  timer-countdown-write hazard found by a second, deeper disassembly pass
  after the first hook build already boot-tested clean (§7.30), the
  native-dispatch simplification for two of three timer entries and the
  self-inflicted regression (a dropped JSR to the cart's own primary
  logic) that a passing `make det` did not catch, found instead by a live
  boot-dump comparison (§7.31), and the dead-end of guessing action-button
  raw codes by analogy to a sibling port when the EXEC's dispatch-vs-poll
  distinction means the codes were never going to respond in the phase
  being tested.
- `~/Workspace/fujinet-intv-frog-bog/spikes/NOTES.md` — sixth-port
  deltas: the five-entry timer dispatcher, the timer-shim design
  generalized to three stoppable entries, the mode-select investigation
  (a wrong lead chased and ruled out before acting on it, then the real
  mechanism found and confirmed harmless), the `SHADOW_FROM_RINGS`-
  under-lockstep bug (§7.20) that a real `make rig` run caught after
  `make det` passed clean, and — the most expensive investigation of any
  port so far — five sessions tracing a `make det`/`make rig` regression
  that only appeared after fixing a real user-reported round-length bug,
  down to a sound-effect-trigger determinism leak distinct from RNG
  wrapping (§7.21), fixed for the dominant call site with a documented,
  accepted residual.
- `~/Workspace/fujinet-intv-utopia/spikes/NOTES.md` — Utopia-specific
  recon, decodes and the milestone log (the dispatch-only confirmation,
  the '0'-key decode catch, the EXEC-loop replay-before derivation, the
  number-entry setup flow).
- `~/Workspace/fujinet-intv-armor-battle/spikes/NOTES.md` — fourth-port
  deltas: the battle main-loop clone, the timer shims, the replay-order
  fix, the injection-nondeterminism forensics.
- `~/Workspace/intv-baseball-experiment/spikes/NOTES.md` — the EXEC
  reverse-engineering notes: main loop, timer table internals, controller
  decode, raw port encoding, decoded input byte format, jzIntv debugger
  facts. Read this before touching timing or input code.
- `~/Workspace/fujinet-intv-auto-racing/spikes/NOTES.md` — second-port
  deltas: the headless input-injection recipe (force all four read sites per
  pass in stop order; never add extra breakpoints to an injection run),
  event-semantics corrections (keypad digits 1-based into handlers, ENTER =
  raw `$28` → event `$B`), the VBLANK-dance analysis, the leak forensics.
- `~/Workspace/fujinet-intv-football/spikes/NOTES.md` — third-port deltas:
  the ISRVEC-labelled dance discovery, `r N` instruction units, PC-keyed
  injection, the play-system map.
- `src/netcode/hud.asm` — how to read the HUD.
- `README.md` — build targets, interactive runs, current status.
