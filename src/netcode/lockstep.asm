; Lockstep netplay engine.  LS_PASS replaces MASTER_TICK's local body when
; NET_ACTIVE: one transport pump per pass, delay-based input exchange at
; game-tick cadence, sim gate on the remote input watermark, spin-stall with
; the ISR phase counter frozen (see spikes/NOTES.md for why).

LS_TIMEOUT      EQU     900             ; gate pump rounds before giving up

LS_PASS:
        PSHR    R5
        ; peer gone: terminal screen, sim stopped for good
        MVI     PEER_SCR, R0
        TSTR    R0
        BNEQ    @@ls_frz
        MVI     NET_DROPPED, R0
        TSTR    R0
        BNEQ    @@ls_gone
        ; resync hold: sim frozen, keep pumping (STATE frames arrive here)
        MVI     RESYNC_HOLD, R0
        TSTR    R0
        BEQ     @@ls_go0
        MVI     LS_FROZE, R0
        TSTR    R0
        BNEQ    @@ls_hf
        MVII    #1,     R0
        MVO     R0,     LS_FROZE
        DIS
        MVI     $102,   R0
        MVO     R0,     LS_SAVE102
        CLRR    R0
        MVO     R0,     $102
        EIS
@@ls_hf:
    IF NET_HUD <> 0
        MVI     HUD_HLD, R0
        CMPI    #$FF,   R0
        BEQ     @@ls_hh
        INCR    R0
        MVO     R0,     HUD_HLD
@@ls_hh:
    ENDI
        JSR     R5,     SES_PUMP
        MVI     RS_TO_LO, R0
        INCR    R0
        MVO     R0,     RS_TO_LO
        CMPI    #$100,  R0
        BNEQ    @@ls_hd
        MVI     RS_TO_HI, R0
        INCR    R0
        MVO     R0,     RS_TO_HI
        CMPI    #RS_HOLD_TMO SHR 8, R0
        BLT     @@ls_hd
        ; peer vanished mid-resync: give up (LS_PASS paints the screen)
        CLRR    R0
        MVO     R0,     PEER_WHY        ; we timed out, no clean goodbye
        MVII    #1,     R0
        MVO     R0,     NET_DROPPED
        CLRR    R0
        MVO     R0,     RESYNC_HOLD
        JSR     R5,     LS_IDLE_RMT
@@ls_hd:
        PULR    R7
@@ls_go0:
        ; Every EXEC pass is a game tick on this cart -- LS_PASS itself runs
        ; every pass regardless of any individual virtualized entry's own
        ; interval (none of the five has interval 1, see SS_GAME_TICK).
        ; Transport pump, once per game tick.
        ; Every pump is a mailbox STATUS (plus a READ when bytes are waiting),
        ; and each transaction is a bus round trip the console spins through --
        ; the dominant cost in the pass.  The pump on the odd pass only ever
        ; mattered when the console had slack in hand, and slack is exactly
        ; when nothing is waiting on the read: the moment the sim actually
        ; needs a frame it enters the gate below, which pumps every round.
        JSR     R5,     SES_PUMP
        ; ---- game tick T is due ------------------------------------------
        ; capture local input (left controller) for tick T+d, send it
        MVI     TICK_HI, R1
        SWAP    R1,     1
        ADD     TICK_LO, R1             ; R1 = T
        MVI     NET_DELAY, R2
        ADDR    R1,     R2              ; R2 = T+d
    IF NET_FUZZ <> 0
        ; Rig builds: the demo script first (the "SELECT 1 OR 2 PLAYERS"
        ; prompt digit + ENTER is answered by SS_INJECT, not this script --
        ; the script drives the disc: diver movement), then pseudo-random
        ; input seeded per console from boot entropy.  The script has two
        ; columns, one per seat -- both ALWAYS replay every tick (no turn
        ; arbiter to suppress either, M1b).  Masked to $3F below (disc-
        ; space only): keypad coverage belongs to the script, where it is
        ; reproducible (PORTING.md §5.5).
        ; SCR_STEP clobbers R1/R2 -- and R2 here is T+d, the ring slot AND
        ; the tick the INPUT frame carries.  Losing it sent every fuzz-era
        ; input as "tick 0" (dropped as stale by the peer), which is how
        ; frog-bog's first rig desynced at the first post-script CRC.
        PSHR    R2
        JSR     R5,     SCR_STEP        ; R2 = row addr, 0 when done
        MOVR    R2,     R4
        PULR    R2                      ; T+d restored
        TSTR    R4
        BEQ     @@lf_fz
        INCR    R4                      ; -> dec0 column
        MVI     NET_SEAT, R0
        ANDI    #1,     R0
        ADDR    R0,     R4              ; odd seats read dec1 / kp1
        MVI@    R4,     R0
        MVO     R0,     LS_TMPB
        INCR    R4                      ; skip the other column's dec
        MVI@    R4,     R0
        MVO     R0,     LS_TMPB2
        B       @@lf_done
@@lf_fz:
        MVI     TICK_LO, R0
        ANDI    #7,     R0
        BNEQ    @@lf_hold
        MVI     SLF_HI, R0
        SWAP    R0,     1
        ADD     SLF_LO, R0
        SLLC    R0,     1
        ADCR    R0
        ADDI    #$6D2B, R0
        MVO     R0,     SLF_LO
        SWAP    R0,     1
        MVO     R0,     SLF_HI
@@lf_hold:
        MVI     SLF_LO, R0
        ANDI    #$3F,   R0              ; disc-space only (no fuzz restarts)
        MVO     R0,     LS_TMPB
        CLRR    R0
        MVO     R0,     LS_TMPB2        ; fuzz has no keypad stream
@@lf_done:
    ELSE
        MVI     EXEC_IN_L, R0
        MVO     R0,     LS_TMPB
        MVI     EXEC_KP_L, R0           ; decoded keypad cell ($0121)
        MVO     R0,     LS_TMPB2
    ENDI
        ; store into OUR seat's ring pages at slot (T+d) & $FF
        MOVR    R2,     R3
        ANDI    #$FF,   R3
        MVI     NET_SEAT, R0
        SWAP    R0,     1               ; seat * $100
        ADDR    R0,     R3
        ADDI    #SEAT_RING, R3
        MVI     LS_TMPB, R0
        MVO@    R0,     R3              ; (R3 is not an auto-inc register)
        ADDI    #SEAT_KP-SEAT_RING, R3
        MVI     LS_TMPB2, R0
        MVO@    R0,     R3
        ; INPUT frame v2: len=6, type, seat, tick_lo, tick_hi, in11F, inKP
        MVII    #FN_TX, R5
        MVII    #6,     R0
        MVO@    R0,     R5
        MVII    #FT_INPUT, R0
        MVO@    R0,     R5
        MVI     NET_SEAT, R0
        MVO@    R0,     R5
        MVO@    R2,     R5              ; lo (8-bit cell truncates)
        SWAP    R2,     1
        MVO@    R2,     R5              ; hi
        MVI     LS_TMPB, R0
        MVO@    R0,     R5
        MVI     LS_TMPB2, R0
        MVO@    R0,     R5
        MVII    #7,     R0
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_WRITE
        ; ---- gate: wait until EVERY remote seat's watermark reaches T -----
        ; (the sim advances at the slowest console's pace; a stall on any
        ; seat freezes everything coherently, same as the 2-player engine)
@@ls_gate:
        MVI     NET_DROPPED, R0
        TSTR    R0
        BNEQ    @@ls_run                ; match over: play on vs idle inputs
        MVII    #15,    R3              ; min slack across seats (HUD)
        CLRR    R2                      ; seat index
@@ls_gs:
        CMP     NET_SEAT, R2
        BEQ     @@ls_gn                 ; own seat has no watermark
        MOVR    R2,     R1
        SLL     R1,     1
        ADDI    #SEAT_WM, R1
        MOVR    R1,     R4
        MVI@    R4,     R0              ; wm lo
        MVI@    R4,     R1              ; wm hi
        SWAP    R1,     1
        ADDR    R1,     R0              ; 16-bit watermark
        MVI     TICK_HI, R1
        SWAP    R1,     1
        ADD     TICK_LO, R1
        SUBR    R1,     R0              ; WM - T, wrap-safe small delta
        BMI     @@ls_stall
        CMPR    R3,     R0
        BGE     @@ls_gn
        MOVR    R0,     R3              ; new minimum slack
@@ls_gn:
        INCR    R2
        CMP     NET_COUNT, R2
        BLT     @@ls_gs
    IF NET_HUD <> 0
        ; min slack: how many ticks of the scarcest remote input we had in
        ; hand.  0 = the sim is running at the slowest link's pace.
        CMP     HUD_LEAD, R3
        BGE     @@ls_ld
        MVO     R3,     HUD_LEAD
@@ls_ld:
    ENDI
        B       @@ls_run
@@ls_stall:
    IF NET_HUD <> 0
        CLRR    R0
        MVO     R0,     HUD_LEAD        ; starving
        MVI     HUD_STL, R0
        CMPI    #$FF,   R0
        BEQ     @@ls_sh
        INCR    R0
        MVO     R0,     HUD_STL
@@ls_sh:
    ENDI
        ; stall: freeze ISR phases once, pump, bounded retry
        MVI     LS_FROZE, R0
        TSTR    R0
        BNEQ    @@ls_wf
        MVII    #1,     R0
        MVO     R0,     LS_FROZE
        DIS
        MVI     $102,   R0
        MVO     R0,     LS_SAVE102
        CLRR    R0
        MVO     R0,     $102
        EIS
@@ls_wf:
        JSR     R5,     SES_PUMP
        MVI     LS_WAITC_LO, R0
        INCR    R0
        MVO     R0,     LS_WAITC_LO
        CMPI    #$100,  R0
        BNEQ    @@ls_gate
        MVI     LS_WAITC_HI, R0
        INCR    R0
        MVO     R0,     LS_WAITC_HI
        CMPI    #LS_TIMEOUT SHR 8, R0
        BLT     @@ls_gate
        ; timed out: mark dropped, idle-fill the remote ring
        CLRR    R0
        MVO     R0,     PEER_WHY        ; we timed out, no clean goodbye
        MVII    #1,     R0
        MVO     R0,     NET_DROPPED
        JSR     R5,     LS_IDLE_RMT
        B       @@ls_gate
@@ls_run:
        ; unfreeze phases if we stalled
        MVI     LS_FROZE, R0
        TSTR    R0
        BEQ     @@ls_nf
        CLRR    R0
        MVO     R0,     LS_FROZE
        MVO     R0,     LS_WAITC_LO
        MVO     R0,     LS_WAITC_HI
        DIS
        MVI     LS_SAVE102, R0
        MVO     R0,     $102
        EIS
@@ls_nf:
        ; DISPATCH-ONLY (M1a/M1c): zero $011F-$0124 reads anywhere in the
        ; ROM, confirmed at the EXEC dispatch-mechanism level -- no
        ; UPDATE_SHADOW/SHADOW_FROM_RINGS call at all, unlike every polling
        ; cart in this family.  Handler-table swap, non-destructive: the
        ; game (and EXEC $1910) install new tables from tick code AND from
        ; dispatched handlers, so adopt whatever is live before
        ; overwriting, run the tick + virtual dispatch with the REAL table
        ; installed (handlers may re-install mid-dispatch, stock-style),
        ; adopt again, then null it out so the real scan's dispatch stays
        ; inert until the next tick.
        JSR     R5,     LS_TBL_ADOPT
        MVI     GAME_TBL_HI, R1
        SWAP    R1,     1
        ADD     GAME_TBL_LO, R1
        BEQ     @@ls_no_tbl
        MVO     R1,     $35D
@@ls_no_tbl:
        ; Virtual dispatch BEFORE the tick (replay-before, the EXEC-loop
        ; default confirmed by the virt==hook gate at M5).  BOTH seats
        ; replay, every tick: there is no turn arbiter on this cart -- the
        ; shared per-seat handler body (L_63D3) indexes state off R1
        ; (VD_CTRL) directly (M1c), and both divers act simultaneously, so
        ; suppressing either seat would drop half the input.  The ONE
        ; exception: while the boot prompt ("SELECT 1 OR 2 PLAYERS", EXEC
        ; $1910's own table, GAME_TBL == SS_HTBL_PROMPT) is up, SS_INJECT
        ; owns the tick instead, answering deterministically from
        ; NET_COUNT so both consoles agree without a human race.
        MVI     GAME_TBL_LO, R0
        CMPI    #SS_HTBL_PROMPT AND $FF, R0
        BNEQ    @@ls_dispatch
        MVI     GAME_TBL_HI, R0
        CMPI    #SS_HTBL_PROMPT SHR 8, R0
        BNEQ    @@ls_dispatch
        JSR     R5,     SS_INJECT
        B       @@ls_dispdone
@@ls_dispatch:
        CLRR    R0
        MVO     R0,     VD_SIDE         ; seat 0
        MVO     R0,     VD_CTRL
        JSR     R5,     LS_VDISPATCH
        MVII    #1,     R0
        MVO     R0,     VD_SIDE         ; seat 1
        MVO     R0,     VD_CTRL
        JSR     R5,     LS_VDISPATCH
@@ls_dispdone:
        JSR     R5,     SS_GAME_TICK    ; all five entries, arm-gated inside
        JSR     R5,     LS_TBL_ADOPT
        MVII    #NET_NULL_TBL+4, R0
        MVO     R0,     $35D
        ; CRC report every 64 ticks
        MVI     TICK_LO, R0
        ANDI    #$3F,   R0
        BNEQ    @@ls_nocrc
        ; The static display state (colour stack, border, delays) is written
        ; once at start-of-game and never refreshed, so anything that scribbles
        ; on it stays on screen forever.  Reassert it here -- a no-op when
        ; healthy -- to bound that to ~2 seconds.
        JSR     R5,     RS_DISPLAY_RESET
        JSR     R5,     LS_CKSUM        ; R0 = checksum
        MVO     R0,     LS_TMPB
        SWAP    R0,     1
        MVO     R0,     LS_TMPB2
        JSR     R5,     RS_RECORD_CRC   ; keep for peer comparison
        ; CRC frame v2: len=6, type, seat, tick_lo, tick_hi, crc_lo, crc_hi
        MVII    #FN_TX, R5
        MVII    #6,     R0
        MVO@    R0,     R5
        MVII    #FT_CRC, R0
        MVO@    R0,     R5
        MVI     NET_SEAT, R0
        MVO@    R0,     R5
        MVI     TICK_LO, R0
        MVO@    R0,     R5
        MVI     TICK_HI, R0
        MVO@    R0,     R5
        MVI     LS_TMPB, R0
        MVO@    R0,     R5
        MVI     LS_TMPB2, R0
        MVO@    R0,     R5
        MVII    #7,     R0
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_WRITE
@@ls_nocrc:
        ; tick++
        MVI     TICK_LO, R0
        INCR    R0
        MVO     R0,     TICK_LO
        CMPI    #$100,  R0
        BNEQ    @@ls_pend
        MVI     TICK_HI, R0
        INCR    R0
        MVO     R0,     TICK_HI
@@ls_pend:
    IF NET_HUD <> 0
        ; HUD row, repainted every 16 ticks (~2 refreshes/second at full
        ; speed).  No per-player name row on this cart -- both seats are
        ; always live simultaneously, there is no "current player" concept
        ; to display (unlike Golf's turn-based NAME_DRAW).
        MVI     TICK_LO, R0
        ANDI    #$0F,   R0
        BNEQ    @@ls_nohud
        JSR     R5,     HUD_DRAW
@@ls_nohud:
    ENDI
        JSR     R5,     RS_PENDING      ; deferred resync push
        PULR    R7

@@ls_frz:
        PULR    R7                      ; screen already up: do nothing, ever
@@ls_gone:
        ; Freeze the ISR phase counter for good.  $0102 = 0 is the ISR's skip
        ; path -- video enable and sound keep running, so the screen we are
        ; about to paint stays lit, but object motion and the rest of the pass
        ; never resume.  If a stall or a resync hold already froze it, leave
        ; the saved value alone.
        MVI     LS_FROZE, R0
        TSTR    R0
        BNEQ    @@pl_fz
        MVII    #1,     R0
        MVO     R0,     LS_FROZE
        DIS
        MVI     $102,   R0
        MVO     R0,     LS_SAVE102
        CLRR    R0
        MVO     R0,     $102
        EIS
@@pl_fz:
        JSR     R5,     LS_PEER_LEFT
        MVII    #1,     R0
        MVO     R0,     PEER_SCR
        ; Park HERE, forever.  Returning to the EXEC pass does not work on
        ; this cart: the scan writes its progress markers into $0102 right
        ; after our freeze, the passes resume, and the pass machinery
        ; repaints the status rows over this screen every frame.  The ISR
        ; stays live (display + sound); only RESET leaves.
@@pl_park:
        B       @@pl_park

; ---------------------------------------------------------------------------
; LS_PEER_LEFT -- paint the terminal peer-left screen.
;
; With no opponent the sim cannot advance (every tick needs the remote input
; for that tick), so there is nothing to return to: LS_PASS bails out early
; from here on and the console sits on this screen until reset.
;
; The four diagnostic counters go on screen too.  This is the one moment a
; player on real hardware can read them without a debugger attached, and a
; drop is exactly when their values matter.
; ---------------------------------------------------------------------------
LS_PEER_LEFT:
        PSHR    R5
        JSR     R5,     DANCE_SETTLE    ; structural no-op (no cart ISR, M0)
        ; Golf's display is fully static (zero real STIC writes, M0) and
        ; comes entirely from the header, so RS_DISPLAY_RESET -- the
        ; Baseball/Bowling form -- is correct here, unlike the scrolling
        ; carts (Soccer/Sea Battle) that need a separate normalize routine.
        JSR     R5,     RS_DISPLAY_RESET
        JSR     R5,     UI_CLS
        MVI     PEER_WHY, R0
        TSTR    R0
        BEQ     @@pl_lost
        MVII    #20*4+3, R0
        MVII    #STR_GONE, R1
        JSR     R5,     UI_PRINT
        B       @@pl_nm
@@pl_lost:
        MVII    #20*4+2, R0
        MVII    #STR_LOST, R1
        JSR     R5,     UI_PRINT
@@pl_nm:
        MVII    #20*6+6, R0
        MVII    #LEFT_NAME, R1
        JSR     R5,     UI_PRINT
        MVII    #20*9+4, R0
        MVII    #STR_RESET, R1
        JSR     R5,     UI_PRINT
        MVII    #20*10+2, R0
        MVII    #STR_DIAG, R1
        JSR     R5,     UI_PRINT
        MVI     DIAG_SLIP, R0
        MVII    #20*11+2, R1
        JSR     R5,     UI_HEX2
        MVI     DIAG_REJ, R0
        MVII    #20*11+7, R1
        JSR     R5,     UI_HEX2
        MVI     DIAG_TMO, R0
        MVII    #20*11+11, R1
        JSR     R5,     UI_HEX2
        MVI     DIAG_ERR, R0
        MVII    #20*11+15, R1
        JSR     R5,     UI_HEX2
        PULR    R7

; LS_IDLE_RMT -- fill EVERY seat's rings with idle values and pin every
; remote watermark far ahead (match over: any drop ends it for everyone).
; Filling our own seat's pages too is harmless -- the sim stops advancing
; input-wise the moment NET_DROPPED is set.
LS_IDLE_RMT:
        PSHR    R5
        JSR     R5,     LS_RING_INIT    ; all eight pages to idle
        MVII    #SEAT_WM, R3
        MVII    #4,     R2
@@li_w:
        MOVR    R3,     R4
        MVI     TICK_LO, R0
        MVO@    R0,     R4
        MVI     TICK_HI, R0
        ADDI    #$40,   R0              ; T + ~16k ticks ahead
        MVO@    R0,     R4
        ADDI    #2,     R3
        DECR    R2
        BNEQ    @@li_w
        PULR    R7

; LS_CKSUM -- rotate-add checksum over the ISR-clean game state:
; $015D-$01EF game scratch + canonical RNG + the virtualized timer state
; (SS_ARM1-5 + SS_CNT1-5 -- ALL FIVE entries need a countdown, the busiest
; virtualized surface of any port to date, tied with Frog Bog's entry
; count) + SS_INJ, the boot-prompt injector counter.  Must match
; src/debug.asm TRACE_RANGES and resync.asm's RS_TAILTBL exactly.  This
; tail is 15 words (RNG_LO/HI + 5 arm + 5 cnt + SS_INJ + GAME_TBL_LO/HI),
; one word longer than the family's traditional 14-word image tail --
; resync.asm's IMG_TOTAL moved 769 -> 770, PORTING.md §7.16 sweep done --
; see spikes/NOTES.md M3/M4.
LS_CKSUM:
        PSHR    R5
        CLRR    R0
        MVII    #$15D,  R4
@@lk_1: SLLC    R0,     1
        ADCR    R0
        ADD@    R4,     R0
        CMPI    #$1F0,  R4
        BLT     @@lk_1
        SLLC    R0,     1
        ADCR    R0
        ADD     RNG_LO, R0
        SLLC    R0,     1
        ADCR    R0
        ADD     RNG_HI, R0
        SLLC    R0,     1
        ADCR    R0
        ; Virtualized timer tail.  ALL FIVE arm flags and countdowns carry
        ; real state (3 timer-API sites make them hot -- M1a).  SS_ARM1-3
        ; are contiguous ($8102-$8104), SS_ARM4 sits alone ($810F), and
        ; SS_ARM5+SS_CNT1-5 are contiguous ($8196-$819B) -- checksummed as
        ; three groups matching ram.asm's actual layout.
        ADD     SS_ARM1, R0
        SLLC    R0,     1
        ADCR    R0
        ADD     SS_ARM2, R0
        SLLC    R0,     1
        ADCR    R0
        ADD     SS_ARM3, R0
        SLLC    R0,     1
        ADCR    R0
        ADD     SS_ARM4, R0
        MVII    #SS_ARM5, R4            ; $8196-$819B: ARM5, CNT1-5
@@lk_2: SLLC    R0,     1
        ADCR    R0
        ADD@    R4,     R0
        CMPI    #SS_CNT5+1, R4
        BLT     @@lk_2
        SLLC    R0,     1
        ADCR    R0
        ADD     SS_INJ, R0
        PULR    R7
