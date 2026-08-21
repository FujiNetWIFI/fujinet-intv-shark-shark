; Netcode hook segment for Shark! Shark! (Mattel 1982).
;
; STATUS: M1 recon complete (spikes/NOTES.md).  Header relocation, the
; single RNG wrapper flavour (14 sites, all X_RAND2 -- the most of any port
; to date), and all three timer-API shim sites are the declared patch map
; (tools/patches.py).
;
; The cart header's timer-table pointer ($5002) is patched to
; NEW_TIMER_TBL.  This cart's ORIGINAL table has a music entry (slot 0,
; stopped one-shot) exactly like every sibling port -- kept as the family's
; defensive placeholder (PORTING.md §4).  PROVABLY LOAD-BEARING here
; (§7.35, same finding as Boxing): this cart's own ISR-vector-swap dance
; (SS_TICK4's unconditional per-tick call into L_5DF4, see exec_equ.asm)
; genuinely calls X_PLAY_NOTE.
;
; The original FIVE game entries (table $501C, slots 4 words apart):
;   slot 1  $5B1A  int $10 (1.25 Hz)  spawn/event roll + HUD digit
;   slot 2  $5B75  int $2D (0.44 Hz)  shark-vs-diver steering AI
;   slot 3  $5C7F  int $0A (2.00 Hz)  bite/collision resolution
;   slot 4  $5CEA  int $02 (~9.99 Hz) PRIMARY: tick/spawn/flicker + the
;                                     ISR dance, unconditionally every call
;   slot 5  $5D5B  int $50 (0.25 Hz)  post-catch recovery/knockback
; ALL FIVE are FULLY VIRTUALIZED (Bowling/Golf's model, not Sea Battle/
; Boxing's native-dispatch shortcut) -- five real entries and only two
; slots free after the music placeholder + MASTER_TICK, and none of the
; five has interval 1, so every one needs its own countdown (busier than
; any prior port's virtualized surface).  SS_GAME_TICK reproduces all
; five, in table order, exact EXEC reload semantics (fire on 0, reload
; full interval -- PORTING.md §7.24).
;
; No X_SCAN self-call hazard: zero references to $14F1 anywhere in the ROM
; (M1a), so $035D only needs nulling AFTER the tick, not before as well.
;
; ISR dance: SS_TICK4 calls L_5DF4 (exec_equ.asm) unconditionally every
; tick, which saves/restores $0100/$0101 via G_015F/G_0160 -- aliased
; directly to SC_ISR_SAVE, so the family's unchanged RS_CLAMP_ISR
; (resync.asm) clamps it correctly with zero code here.  The wall tick
; rate MUST be measured live at MASTER_TICK (§7.28), never taken from the
; header -- this dance almost certainly steals a frame every tick.
;
; SHARK SHARK IS 1-2 SEATS, SIMULTANEOUS, DISPATCH-ONLY input (M1a/M1c:
; zero $011F-$0124 reads anywhere in the ROM, confirmed at the EXEC
; dispatch-mechanism level, not just by absence of references) -- Boxing's
; shape exactly, NOT a turn-arbiter shape.  The EXEC scan hands each
; handler R1 = the seat index via `SUBI #$011F,R1` before the dispatch
; jump, and this cart's shared per-seat handler body (L_63D3) indexes MOB0
; ($031D) vs MOB1 ($0325, stride 8) directly off R1 -- so VD_CTRL must
; track VD_SIDE.  Both seats replay every tick; there is no
; SHADOW_CTRL/UPDATE_SHADOW surface at all, because there is nothing to
; poll.
;
; The ONE genuinely special case: the "SELECT 1 OR 2 PLAYERS" boot prompt
; (M1b/M1c).  It dispatches through the SAME $035D + R1 mechanism as
; ordinary gameplay -- the shared EXEC routine $1910 installs its OWN
; cart-supplied digit-accept table (SS_HTBL_PROMPT = $5185, passed in R4
; at $50BE) into $035D internally, invisible to a cart-only disassembly
; scan but confirmed live (`m 35D 2` while parked at the prompt).  Live-
; confirmed separately that the EXEC's own per-pass timer dispatch ($17D5)
; keeps firing normally the whole time the prompt is up, so MASTER_TICK
; gets real per-pass ticks during the prompt exactly as it does during
; play.  While GAME_TBL sits on SS_HTBL_PROMPT, SS_INJECT answers it
; deterministically from NET_COUNT (1 or 2) instead of routing real
; controller events through -- avoiding any possibility of the two
; consoles racing to answer differently.  Golf's ARB_INJECT shape, minus
; the arbiter gate (there isn't one): mutual exclusion with normal
; dispatch is done with a direct GAME_TBL comparison.

        ORG     $6800

NEW_TIMER_TBL:
        DECLE   X_MUSIC_TICK AND $FF, X_MUSIC_TICK SHR 8
        DECLE   $01, $80                ; interval $8001: stopped, one-shot
        DECLE   MASTER_TICK AND $FF, MASTER_TICK SHR 8
        DECLE   $01, $00                ; every pass, always armed
        DECLE   $00, $00                ; terminator

; ---------------------------------------------------------------------------
; NET_START -- patched start-of-game vector ($5004, original target
; SS_START = $506B).  Runs after the title screen, before the EXEC main
; loop starts (the EXEC jumps here with R5 = $108F), so netcode RAM is
; initialized before the first MASTER_TICK.  Falls through to the original
; .START, which immediately STOP-alls all five slots (via SS_STOP_SHIM,
; the $51A2 loop) before running the boot prompt -- so the arm flags here
; just need to be sane, and every countdown must hold its FULL interval
; (the Frog Bog seeding lesson) so a later arm fires on the real cadence.
; ---------------------------------------------------------------------------
NET_START:
        PSHR    R5                      ; EXEC main-loop return
        MVII    #NET_RAM, R4
        MVII    #NET_RAM_SIZE, R1
        CLRR    R0
@@zero: MVO@    R0,     R4
        DECR    R1
        BNEQ    @@zero
        MVII    #SS_INT1, R0            ; every countdown starts full
        MVO     R0,     SS_CNT1
        MVII    #SS_INT2, R0
        MVO     R0,     SS_CNT2
        MVII    #SS_INT3, R0
        MVO     R0,     SS_CNT3
        MVII    #SS_INT4, R0
        MVO     R0,     SS_CNT4
        MVII    #SS_INT5, R0
        MVO     R0,     SS_CNT5
        MVII    #SPIKE_DELAY, R0        ; virt-dispatch delay depth (spike knob)
        MVO     R0,     DELAY_EN
        ; Seat defaults for local builds: seat 0 of a 2-player game.  The
        ; netplay path overwrites both from the START payload.
        MVII    #2,     R0
        MVO     R0,     NET_COUNT
    IF SPIKE_VIRT <> 0
        JSR     R5,     LS_RING_INIT    ; idle-fill the dispatch rings
    ENDI
    IF SPIKE_ECHO <> 0
        JSR     R5,     ECHO_TEST       ; parks with results; never returns
    ENDI
    IF NET_SESSION <> 0
        JSR     R5,     SES_MAIN        ; login/lobby; arms NET_ACTIVE or not
    ENDI
        PULR    R5
        J       SS_START

; NET_NULL_TBL: handed to the EXEC scan (via $035D) while dispatch is
; virtualized so its event dispatch resolves null pointers and never calls
; game code from real local input.  Zeros on both sides of the base cover
; negative slot indexes.
NET_NULL_TBL:
        DECLE   0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        DECLE   0, 0, 0, 0, 0, 0, 0, 0, 0, 0

; ---------------------------------------------------------------------------
; MASTER_TICK -- timer entry 1 of NEW_TIMER_TBL, dispatched by the EXEC
; every main-loop pass.  May clobber R0-R3.  Returns via the dispatcher's
; R5.
; ---------------------------------------------------------------------------
MASTER_TICK:
        PSHR    R5
    IF STALL_N <> 0
        ; Stall injector (spike c): every 64th pass, busy-spin ~STALL_N
        ; frames INSIDE the dispatch.  The ISR keeps firing but $0102 sits
        ; at 0 mid-pass, so it takes its skip path: display continues,
        ; game logic freezes.
        MVI     FRM_CTR, R0
        INCR    R0
        ANDI    #$3F,   R0
        MVO     R0,     FRM_CTR
        BNEQ    @@no_stall
        DIS
        MVI     $102,   R2
        CLRR    R0
        MVO     R0,     $102
        EIS
        MVII    #STALL_N * 3000, R1     ; ~15 cycles/iter, ~1 frame per 1000
@@spin: DECR    R1
        BNEQ    @@spin
        DIS
        MVO     R2,     $102
        EIS
@@no_stall:
    ENDI
    IF NET_SESSION <> 0
        MVI     NET_ACTIVE, R0
        TSTR    R0
        BEQ     @@mt_local
        JSR     R5,     LS_PASS         ; lockstep netplay path
        PULR    R7
@@mt_local:
    ENDI
    IF SPIKE_RECORD <> 0
        JSR     R5,     REC_CAPTURE     ; log the live cells for this tick
    ENDI
    IF SPIKE_VIRT <> 0
        ; Virtualized local dispatch.  BOTH seats replay, every tick: there
        ; is no turn arbiter on this cart -- both divers act simultaneously
        ; (M1b).
        JSR     R5,     VIRT_CAPTURE
        JSR     R5,     LS_TBL_ADOPT
        MVI     GAME_TBL_HI, R1
        SWAP    R1,     1
        ADD     GAME_TBL_LO, R1
        BEQ     @@mt_no_tbl
        MVO     R1,     $35D
@@mt_no_tbl:
        ; Boot-prompt exclusion: while GAME_TBL is the EXEC's own SS_HTBL_
        ; PROMPT table (installed internally by $1910, M1c), the injector
        ; owns this tick instead of real dispatch -- deterministic, from
        ; NET_COUNT, so both consoles agree without a human race.
        MVI     GAME_TBL_LO, R0
        CMPI    #SS_HTBL_PROMPT AND $FF, R0
        BNEQ    @@mt_dispatch
        MVI     GAME_TBL_HI, R0
        CMPI    #SS_HTBL_PROMPT SHR 8, R0
        BNEQ    @@mt_dispatch
        JSR     R5,     SS_INJECT
        B       @@mt_dispdone
@@mt_dispatch:
        CLRR    R0
        MVO     R0,     VD_SIDE         ; seat 0
        MVO     R0,     VD_CTRL
        JSR     R5,     LS_VDISPATCH
        MVII    #1,     R0
        MVO     R0,     VD_SIDE         ; seat 1
        MVO     R0,     VD_CTRL
        JSR     R5,     LS_VDISPATCH
@@mt_dispdone:
    ENDI
        JSR     R5,     SS_GAME_TICK
    IF SPIKE_VIRT <> 0
        JSR     R5,     LS_TBL_ADOPT
        MVII    #NET_NULL_TBL+4, R0
        MVO     R0,     $35D
    ENDI
    IF SPIKE_TRACE <> 0
        JSR     R5,     TRACE_TICK
    ELSE
        ; sim tick counter (16-bit across two 8-bit cells)
        MVI     TICK_LO, R0
        INCR    R0
        MVO     R0,     TICK_LO
        CMPI    #$100,  R0
        BNEQ    @@mt_out
        MVI     TICK_HI, R0
        INCR    R0
        MVO     R0,     TICK_HI
    ENDI
@@mt_out:
        PULR    R7

; ---------------------------------------------------------------------------
; SS_GAME_TICK -- reproduces all five original timer entries at their own
; cadence, in the original table's order, with exact EXEC reload semantics
; (fire on countdown == 0, reload to full interval).  Shared by
; MASTER_TICK's local path and lockstep.asm's LS_PASS.  Also computes
; SS_QUIESCENT every tick (must run on BOTH paths -- Sea Battle's hard-won
; rule: NET_ACTIVE returns via LS_PASS before MASTER_TICK's local-only
; section is ever reached).
; Clobbers R0/R1.  Returns via the caller's R5.
; ---------------------------------------------------------------------------
SS_GAME_TICK:
        PSHR    R5
        ; Entry 1 ($5B1A, interval $10) -- spawn/event roll + HUD digit
        MVI     SS_ARM1, R0
        TSTR    R0
        BEQ     @@gt_e1_off
        MVI     SS_CNT1, R0
        DECR    R0
        BNEQ    @@gt_e1_hold
        JSR     R5,     SS_TICK1
        MVII    #SS_INT1, R0
@@gt_e1_hold:
        MVO     R0,     SS_CNT1
@@gt_e1_off:
        ; Entry 2 ($5B75, interval $2D) -- shark-vs-diver steering AI
        MVI     SS_ARM2, R0
        TSTR    R0
        BEQ     @@gt_e2_off
        MVI     SS_CNT2, R0
        DECR    R0
        BNEQ    @@gt_e2_hold
        JSR     R5,     SS_TICK2
        MVII    #SS_INT2, R0
@@gt_e2_hold:
        MVO     R0,     SS_CNT2
@@gt_e2_off:
        ; Entry 3 ($5C7F, interval $0A) -- bite/collision resolution
        MVI     SS_ARM3, R0
        TSTR    R0
        BEQ     @@gt_e3_off
        MVI     SS_CNT3, R0
        DECR    R0
        BNEQ    @@gt_e3_hold
        JSR     R5,     SS_TICK3
        MVII    #SS_INT3, R0
@@gt_e3_hold:
        MVO     R0,     SS_CNT3
@@gt_e3_off:
        ; Entry 4 ($5CEA, interval $02) -- PRIMARY: tick/spawn/flicker,
        ; and unconditionally the ISR dance (exec_equ.asm SC_ISR_SAVE)
        MVI     SS_ARM4, R0
        TSTR    R0
        BEQ     @@gt_e4_off
        MVI     SS_CNT4, R0
        DECR    R0
        BNEQ    @@gt_e4_hold
        JSR     R5,     SS_TICK4
        MVII    #SS_INT4, R0
@@gt_e4_hold:
        MVO     R0,     SS_CNT4
@@gt_e4_off:
        ; Entry 5 ($5D5B, interval $50) -- post-catch recovery/knockback
        MVI     SS_ARM5, R0
        TSTR    R0
        BEQ     @@gt_e5_off
        MVI     SS_CNT5, R0
        DECR    R0
        BNEQ    @@gt_e5_hold
        JSR     R5,     SS_TICK5
        MVII    #SS_INT5, R0
@@gt_e5_hold:
        MVO     R0,     SS_CNT5
@@gt_e5_off:
        ; SS_QUIESCENT: working hypothesis (M1b/M1c, not yet live-
        ; confirmed with a forced QUIESCE=1 test) -- the SAME joint-AND
        ; condition the cart's own game-over gate uses ($6228-$6242):
        ; both MOB0 ($031D) and MOB1 ($0325) bit $0800 clear AND
        ; $0323==0 AND $032B==0.  Purely derived from cells already
        ; inside the standard CRC range -- needs no independent coverage.
        MVI     $031D,  R0
        SDBD
        ANDI    #$0800, R0
        BNEQ    @@gt_not_q
        MVI     $0325,  R0
        SDBD
        ANDI    #$0800, R0
        BNEQ    @@gt_not_q
        MVI     $0323,  R0
        TSTR    R0
        BNEQ    @@gt_not_q
        MVI     $032B,  R0
        TSTR    R0
        BNEQ    @@gt_not_q
        MVII    #1,     R0
        MVO     R0,     SS_QUIESCENT
        B       @@gt_qout
@@gt_not_q:
        CLRR    R0
        MVO     R0,     SS_QUIESCENT
@@gt_qout:
        PULR    R7

; ---------------------------------------------------------------------------
; SS_INJECT -- deterministic answer for the "SELECT 1 OR 2 PLAYERS" boot
; prompt.  While GAME_TBL sits on SS_HTBL_PROMPT, a tick counter (SS_INJ,
; sim state) paces two synthetic keypad events through the live handler,
; exactly as LS_VDISPATCH would deliver them.  Both digit entry and ENTER
; are keypad-CLASS events in the EXEC's universal scan convention (slot 2,
; word offset into whatever table is live -- vdispatch.asm's own disc-vs-
; keypad routing, M1c) regardless of which specific table $035D points at:
;   tick 2: digit NET_COUNT (1 or 2) -- the plain digit value, bit 7
;           already stripped, matching LS_VCALL's convention
;   tick 6: ENTER ($0B, the family-universal decoded ENTER value)
; Self-terminates once GAME_TBL changes (MASTER_TICK stops calling this
; once GAME_TBL != SS_HTBL_PROMPT).  SS_INJ is CRC'd and in the resync
; image tail.  VD_CTRL is set to 0 for determinism (the prompt is global,
; not per-seat, so which value doesn't matter -- just that both consoles
; agree).  Clobbers R0/R1.
; ---------------------------------------------------------------------------
SS_INJECT:
        PSHR    R5
        CLRR    R0
        MVO     R0,     VD_CTRL
        MVI     SS_INJ, R0
        INCR    R0
        MVO     R0,     SS_INJ
        CMPI    #2,     R0
        BEQ     @@si_digit
        CMPI    #6,     R0
        BEQ     @@si_enter
        PULR    R7
@@si_digit:
        MVII    #2,     R0              ; keypad-class events land on slot 2
        MVO     R0,     VD_TMP
        MVI     NET_COUNT, R0           ; digit N = R0 value N (1 or 2)
        JSR     R5,     LS_VCALL
        PULR    R7
@@si_enter:
        MVII    #2,     R0
        MVO     R0,     VD_TMP
        MVII    #$0B,   R0              ; ENTER, clean value ($8B AND $7F)
        JSR     R5,     LS_VCALL
        PULR    R7

; ---------------------------------------------------------------------------
; SS_RAND2 -- canonical-RNG wrapper for the game's fourteen RAND call sites
; (all X_RAND2 -- zero X_RAND1 sites on this cart, M1a; the largest RNG
; surface of any port to date).  The EXEC sound engine advances the shared
; LFSR at $035E from ISR context whenever noise SFX play (§5.2), so game
; logic must not read $035E directly: swap the canonical (sim-space) value
; in, call the EXEC routine with interrupts off, swap the advanced value
; back out.
; Preserves R1/R2 like the underlying EXEC routine; result in R0.
; ---------------------------------------------------------------------------
SS_RAND2:
        PSHR    R5
        DIS
        JSR     R5,     @@swap_in
        JSR     R5,     X_RAND2
        PSHR    R1
        MVI     EXEC_RNG, R1
        MVO     R1,     RNG_LO
        SWAP    R1,     1
        MVO     R1,     RNG_HI
        PULR    R1
        EIS
        PULR    R7

@@swap_in:
        PSHR    R1
        PSHR    R2
        MVI     RNG_HI, R1
        SWAP    R1,     1
        MVI     RNG_LO, R2
        ADDR    R2,     R1
        MVO     R1,     EXEC_RNG
        PULR    R2
        PULR    R1
        MOVR    R5,     R7

; ---------------------------------------------------------------------------
; SS_ARM_SHIM / SS_STOP_SHIM -- wired into tools/patches.py at all three
; original timer-API call sites.  $51A7/$51B8 are one-time STOP-ALL/
; START-ALL loops walking R1 across all FIVE original slot addresses in
; sequence (R1 += 4 each iteration, no R2 counter -- unlike some sibling
; ports' loops, this cart's bound is a direct CMPI against $5036, so only
; R1 needs preserving, and neither shim touches it).  $628D is a single
; stop of SS_SLOT3 only, at game over.  Each site passes R1 = the
; ORIGINAL header table's slot address ($5020/$5024/$5028/$502C/$5030 --
; stale once the table is relocated, since both real entry points resolve
; R1 against the header pointer, which now points at NEW_TIMER_TBL).
; ARM seeds the entry's countdown to the full interval (real ARM
; semantics: first fire happens INT passes after arming).
; ---------------------------------------------------------------------------
SS_STOP_SHIM:
        CLRR    R0
        CMPI    #SS_SLOT1, R1
        BNEQ    @@st_2
        MVO     R0,     SS_ARM1
        MOVR    R5,     R7
@@st_2: CMPI    #SS_SLOT2, R1
        BNEQ    @@st_3
        MVO     R0,     SS_ARM2
        MOVR    R5,     R7
@@st_3: CMPI    #SS_SLOT3, R1
        BNEQ    @@st_4
        MVO     R0,     SS_ARM3
        MOVR    R5,     R7
@@st_4: CMPI    #SS_SLOT4, R1
        BNEQ    @@st_5
        MVO     R0,     SS_ARM4
        MOVR    R5,     R7
@@st_5: MVO     R0,     SS_ARM5         ; SS_SLOT5 (only remaining case)
        MOVR    R5,     R7

SS_ARM_SHIM:
        MVII    #1,     R0
        CMPI    #SS_SLOT1, R1
        BNEQ    @@sa_2
        MVO     R0,     SS_ARM1
        MVII    #SS_INT1, R0
        MVO     R0,     SS_CNT1
        MOVR    R5,     R7
@@sa_2: CMPI    #SS_SLOT2, R1
        BNEQ    @@sa_3
        MVO     R0,     SS_ARM2
        MVII    #SS_INT2, R0
        MVO     R0,     SS_CNT2
        MOVR    R5,     R7
@@sa_3: CMPI    #SS_SLOT3, R1
        BNEQ    @@sa_4
        MVO     R0,     SS_ARM3
        MVII    #SS_INT3, R0
        MVO     R0,     SS_CNT3
        MOVR    R5,     R7
@@sa_4: CMPI    #SS_SLOT4, R1
        BNEQ    @@sa_5
        MVO     R0,     SS_ARM4
        MVII    #SS_INT4, R0
        MVO     R0,     SS_CNT4
        MOVR    R5,     R7
@@sa_5: MVO     R0,     SS_ARM5         ; SS_SLOT5 (only remaining case)
        MVII    #SS_INT5, R0
        MVO     R0,     SS_CNT5
        MOVR    R5,     R7

; ---------------------------------------------------------------------------
; SS_REBASE_HOOK -- called from resync.asm's RS_REBASE (one line, retargeted
; from GF_REBASE_HOOK; resync.asm is otherwise unchanged) after a state
; image has been applied.  The one transported cell this cart's own code
; actually DOES something dangerous with (a code pointer, §7.27) is the
; ISR-save pair $015F/$0160 -- already handled with zero code here, since
; SC_ISR_SAVE (exec_equ.asm) is aliased directly onto it and the family's
; UNCHANGED generic RS_CLAMP_ISR (resync.asm) runs unconditionally from
; this same RS_REBASE, just before this hook is called.  SS_PCOUNT ($0172,
; player count) isn't used as an index or pointer anywhere found in M1,
; but is clamped anyway as cheap, standard insurance (every prior port
; clamps its own small enumerated transported cells the same way).
; Clobbers R0.
; ---------------------------------------------------------------------------
SS_REBASE_HOOK:
        MVI     SS_PCOUNT, R0
        CMPI    #2,     R0
        BLE     @@rh_pc_ok
        MVII    #2,     R0
@@rh_pc_ok:
        TSTR    R0
        BGT     @@rh_pc_ok2
        MVII    #1,     R0
@@rh_pc_ok2:
        MVO     R0,     SS_PCOUNT
        MOVR    R5,     R7
