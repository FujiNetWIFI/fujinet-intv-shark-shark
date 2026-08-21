; EXEC ROM entry points and RAM locations used by the netcode patch.
; Addresses are the shared EXEC's (identical across every port so far --
; confirmed for this cart in build/sharkshark.dis, spikes/NOTES.md M1a/M1c).

X_MUSIC_TICK    EQU     $1A71   ; music note-timer routine; this cart's own
                                ;  timer table slot 0 target, interval
                                ;  $8001 (stopped/one-shot) -- kept as the
                                ;  family's defensive placeholder
                                ;  (PORTING.md §4) -- PROVABLY load-bearing
                                ;  here (§7.35): the cart's own ISR dance
                                ;  (SS_DANCE below) genuinely calls
                                ;  X_PLAY_NOTE, same finding as Boxing.
X_RAND2         EQU     $169E   ; LFSR random entry -- the ONLY flavour
                                ;  this cart uses (14 sites, all X_RAND2;
                                ;  zero X_RAND1 sites, M1a)
X_SCAN          EQU     $14F1   ; controller scan (EXEC main loop only --
                                ;  this cart never calls it itself: zero
                                ;  $14F1 references anywhere in the ROM,
                                ;  M1a, so $035D only needs nulling AFTER
                                ;  the tick, not before too -- §7.26 does
                                ;  not apply)
X_TIMER_STOP    EQU     $1838   ; disarm a timer-table entry, R1 = slot addr
                                ;  (2 call sites: $51A7 stop-ALL loop,
                                ;  $628D single-slot-3 stop -- M1a)
X_TIMER_START   EQU     $1844   ; arm a timer-table entry, R1 = slot addr
                                ;  (1 call site: $51B8 start-ALL loop --
                                ;  M1a; this cart calls the higher-level
                                ;  $1844 entry, NOT the $181E ARM entry
                                ;  some sibling ports use)
X_PLAY_NOTE     EQU     $1118   ; EXEC note-play entry -- called from this
                                ;  cart's own ISR dance body ($5E3A, M1a),
                                ;  confirmed reachable, not dead code --
                                ;  this is WHY X_MUSIC_TICK must stay at
                                ;  table slot 0 (§7.35)

EXEC_RNG        EQU     $035E   ; 16-bit LFSR state (System RAM)
EXEC_ISR_DEF    EQU     $1126   ; the EXEC's default game-time ISR

; EXEC decoded per-controller input cells, rewritten by the scan each pass.
EXEC_IN_L       EQU     $011F   ; left controller decoded input
EXEC_IN_R       EQU     $0120   ; right controller decoded input
EXEC_KP_L       EQU     $0121   ; left keypad event/state cell (vdispatch.asm
EXEC_KP_R       EQU     $0122   ;  references these unconditionally --
                                ;  engine-shaped only; this cart never
                                ;  reads $011F-$0124 itself, M1a/M1c, so
                                ;  these are never a cart patch target)
EXEC_HTBL       EQU     $035D   ; input-handler table pointer (game-managed
                                ;  -- and, on THIS cart, also written
                                ;  internally by the shared EXEC $1910
                                ;  number-entry routine for the boot
                                ;  prompt, M1b/M1c: not visible to a
                                ;  cart-only disassembly scan, confirmed
                                ;  only by a live $035D dump)
EXEC_RAW_L      EQU     $0123   ; left controller raw (inverted port) value
EXEC_RAW_R      EQU     $0124

; SC_ISR_SAVE: RS_CLAMP_ISR (src/netcode/resync.asm, copied unchanged) runs
; unconditionally from RS_REBASE.  UNLIKE most prior ports (which alias
; this to a harmless spare because they have no cart ISR at all), THIS
; cart has a REAL ISR-vector save/restore of its own -- M1a's big finding:
; L_5DF4 (called unconditionally by the primary $5CEA entry, EVERY 9.99Hz
; tick) saves the live $0100/$0101 vector into consecutive cells
; G_015F/G_0160 before installing its own $5E14 body, and restores them
; before returning.  $015F/$0160 sit inside the CRC'd $015D-$01EF range,
; so they transport in the resync image like ordinary game bytes --
; aliasing SC_ISR_SAVE directly onto the cart's OWN save cell (Soccer's
; exact §7.27 shape, one cell earlier) is what lets the family's
; unchanged generic RS_CLAMP_ISR clamp it correctly on both sides.
SC_ISR_SAVE     EQU     $015F   ; = G_015F; SC_ISR_SAVE+1 ($0160) = G_0160,
                                ;  confirmed low/high byte order matches
                                ;  RS_CLAMP_ISR's expected layout (M1a)

; DANCE_SETTLE (src/vdispatch.asm, copied unchanged) unconditionally checks
; $0101 against SC_ISR_BODY's page before repainting a terminal screen --
; PORTING.md §7.10.  This cart's dance installs $5E14 as the temp vector
; (M1a), so $0101 reads $5E while it's live.  The window is narrow (the
; dance always completes synchronously within one MASTER_TICK call, restore
; happens before L_5DF4 returns), but the family convention is cheap
; defensive insurance for the terminal-screen edge case regardless.
SC_ISR_BODY     EQU     $5E00

; Original game timer entries, re-dispatched from the master tick in
; original table order.  Original table at $501C, FOUR words per entry
; (addr lo/hi, interval lo/hi), slots at $501C+4k.  All FIVE are fully
; virtualized (Bowling/Golf's model, not Sea Battle/Boxing's native-
; dispatch shortcut -- with 5 real entries and only 2 slots free after the
; music placeholder + MASTER_TICK, native dispatch doesn't fit, and full
; virtualization is the family's proven-safe default when it doesn't).
; Every entry's role confirmed by READING the code (M1a), not guessed
; from address/interval alone.
SS_TICK1        EQU     $5B1A   ; slot 1, interval $10 (1.25 Hz): low-prob
                                ;  spawn/event roll (X_RAND2 0-5) + a HUD
                                ;  digit redraw (score/air gauge)
SS_TICK2        EQU     $5B75   ; slot 2, interval $2D (0.44 Hz): shark-vs-
                                ;  diver proximity/steering AI
SS_TICK3        EQU     $5C7F   ; slot 3, interval $0A (2.00 Hz): bite/
                                ;  collision resolution between two MOB
                                ;  records -- the entry $628D explicitly
                                ;  stops (alone) at game over
SS_TICK4        EQU     $5CEA   ; slot 4, interval $02 (~9.99 Hz):
                                ;  PRIMARY -- tick counter, object
                                ;  spawn/init every 8th call, flicker/
                                ;  invulnerability decay, and calls the
                                ;  ISR dance (L_5DF4) UNCONDITIONALLY
                                ;  every single call (M1a)
SS_TICK5        EQU     $5D5B   ; slot 5, interval $50 (0.25 Hz): post-
                                ;  catch recovery/knockback, gated by the
                                ;  same collision flag slot 3 tests
SS_START        EQU     $506B   ; original start-of-game vector target

; Original header-table slot addresses -- what all THREE timer-API call
; sites pass in R1 (stale absolute addresses after relocation).  The
; shims dispatch on these to flip the matching virtualized SS_ARMn flag.
; $51A7/$51B8 are one-time STOP-ALL/START-ALL loops walking R1 across all
; five in sequence (R1 += 4 each iteration); $628D is a single stop of
; SS_SLOT3 only, at game over (M1a).
SS_SLOT1        EQU     $5020
SS_SLOT2        EQU     $5024
SS_SLOT3        EQU     $5028
SS_SLOT4        EQU     $502C
SS_SLOT5        EQU     $5030

; Original entry intervals in passes (seed the virtualized countdown to
; the FULL interval at NET_START and on every ARM -- the Frog Bog lesson:
; seeding from RAM's zero-fill instead silently breaks the slow entries).
; ALL FIVE need a countdown -- none has interval 1 (every entry here fires
; slower than every pass, unlike Golf's two interval-1 entries).
SS_INT1         EQU     $10     ; 16 passes  (1.25 Hz)
SS_INT2         EQU     $2D     ; 45 passes  (0.44 Hz)
SS_INT3         EQU     $0A     ; 10 passes  (2.00 Hz)
SS_INT4         EQU     $02     ; 2 passes   (~9.99 Hz, the primary entry)
SS_INT5         EQU     $50     ; 80 passes  (0.25 Hz)

; The $035D handler-table values (M1b/M1c-traced).  Exactly 3 explicit
; cart-side MVO-to-$035D sites, PLUS one install done INTERNALLY by the
; shared EXEC $1910 routine (SS_HTBL_PROMPT, from the R4 argument the
; cart passes at $50BE) -- invisible to a cart-only scan, confirmed only
; by a live $035D dump while parked at the boot prompt.
SS_HTBL_PROMPT  EQU     $5185   ; "SELECT 1 OR 2 PLAYERS" boot prompt --
                                ;  a genuine 5-slot low/high-byte address
                                ;  table (EXEC $1910's digit-accept
                                ;  table, R4 argument at $50BE), NOT
                                ;  installed by any cart-side MVO
SS_HTBL_LIVE    EQU     $5193   ; live-play table, installed once by the
                                ;  cart at $5114 right after the prompt
                                ;  is accepted (settle delay ~0 ticks,
                                ;  M1c) -- 5-slot low/high-byte address
                                ;  table, boundary confirmed via a real
                                ;  dis1600 xref at $519D
SS_HTBL_NULL    EQU     $1906   ; EXEC null table, installed at game over
                                ;  ($6273, right before "GAME OVER" prints)
SS_HTBL_PLAYAGAIN EQU   $629C   ; post-game "play again" table, installed
                                ;  ~20 frames after game-over ($6299, via
                                ;  a real wait call unlike the boot
                                ;  prompt's instant transition)

; Game-state cells (all inside $015D-$01EF, the block .START zero-fills =
; the engine CRC range).
SS_PCOUNT       EQU     $0172   ; player count, 1-2 (accepted at $50CB;
                                ;  the cart's OWN code rejects anything
                                ;  outside 1-2, so this hard-caps the
                                ;  port at 2 seats -- M1b)

; Controller-to-object routing: CONFIRMED (M1c, live + static xref) to be
; the EXEC's own R1 controller-index handoff, exactly Boxing's shape --
; R1=0 (left) selects MOB0 ($031D-base), R1=1 (right) selects MOB1
; ($0325-base, stride 8), inside the cart's OWN shared per-seat handler
; body (L_63D3 and a second inlined site at $63EF).  NO shadow-pair
; patch is needed and no cart-side symbol is required for this -- the
; family's generic VD_CTRL/VD_SIDE convention in vdispatch.asm/hook.asm
; already reproduces exactly this R1 semantics without any per-cart code.
