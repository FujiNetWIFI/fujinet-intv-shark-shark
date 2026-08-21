; Determinism-spike instrumentation (assembled only when SPIKE_TRACE <> 0).
;
; TRACE_TICK runs after every game tick: rotate-add checksum over the game
; state, stored into a 256-entry ring keyed by sim-tick low byte, then the
; sim tick counter advances.  When the tick counter reaches TRACE_STOP the
; CPU parks in a self-loop at TRACE_DONE so a debugger breakpoint can dump
; the ring at an exact, build-independent sim tick.
;
; Checksummed ranges (see spikes/NOTES.md):
;   $015D-$01EF  game scratch vars (EXEC-reserved cells below $15D excluded:
;                timer countdown slots and music state are real-frame timed)
;   $02F0-$035F  EXEC/system vars incl. object table and RNG state
; BACKTAB ($0200-$02EF) intentionally excluded for now.

; TRACE_STOP (park tick) is defined by the including main_det_*.asm.

TRACE_TICK:
        PSHR    R5
        DIS                             ; atomic capture: the ISR mutates
        CLRR    R0                      ; checksummed cells (object motion)
        MVII    #TRACE_RANGES, R3
@@range:
        MOVR    R3,     R5
        MVI@    R5,     R1              ; range start (0 terminates)
        MVI@    R5,     R2              ; range end, exclusive
        MOVR    R5,     R3
        TSTR    R1
        BEQ     @@store
        MOVR    R1,     R4
@@cell: SLLC    R0,     1
        ADCR    R0                      ; 16-bit rotate left
        ADD@    R4,     R0
        CMPR    R2,     R4
        BLT     @@cell
        B       @@range
@@store:
        EIS
        ; breadcrumb: record tick+1 of the first game RNG consumption
        MVI     RNG_LO, R1
        CMP     RNGP_LO, R1
        BNEQ    @@rng_chg
        MVI     RNG_HI, R1
        CMP     RNGP_HI, R1
        BEQ     @@rng_same
@@rng_chg:
        MVI     RNG_LO, R1
        MVO     R1,     RNGP_LO
        MVI     RNG_HI, R1
        MVO     R1,     RNGP_HI
        MVI     FIRSTC_LO, R1
        TSTR    R1
        BNEQ    @@rng_same
        MVI     FIRSTC_HI, R1
        TSTR    R1
        BNEQ    @@rng_same
        MVI     TICK_LO, R1
        INCR    R1
        MVO     R1,     FIRSTC_LO      ; tick+1, low byte (spike ticks < 256)
        MVI     TICK_HI, R1
        MVO     R1,     FIRSTC_HI
@@rng_same:
        ; ring[tick & $FF] = checksum
        MVI     TICK_LO, R1
        SLL     R1,     1
        ADDI    #TRACE_RING, R1
        MOVR    R1,     R4
        MVO@    R0,     R4
        SWAP    R0,     1
        MVO@    R0,     R4
        ; LAG_RING[tick & $FF] = [P1 heading ($0168), P2 heading ($0169)] --
        ; lagcheck-only capture, ram.asm.  Cheap (2 extra MVI/MVO@ pairs)
        ; and harmless to `make det` (a separate ring, not part of
        ; TRACE_RANGES/LS_CKSUM/RS_TAILTBL's determinism-proof coverage).
        MVI     TICK_LO, R1
        SLL     R1,     1
        ADDI    #LAG_RING, R1
        MOVR    R1,     R4
        MVI     $168,   R0
        MVO@    R0,     R4
        MVI     $169,   R0
        MVO@    R0,     R4
        ; tick++
        MVI     TICK_LO, R0
        INCR    R0
        MVO     R0,     TICK_LO
        CMPI    #$100,  R0
        BNEQ    @@chk
        MVI     TICK_HI, R0
        INCR    R0
        MVO     R0,     TICK_HI
@@chk:  ; park at TRACE_STOP
        MVI     TICK_HI, R1
        SWAP    R1,     1
        MVI     TICK_LO, R0
        ADDR    R1,     R0
        CMPI    #TRACE_STOP, R0
        BNEQ    @@out
TRACE_DONE:
        B       TRACE_DONE              ; parked; debugger breaks here
@@out:  PULR    R7

; Checksummed state: (start, end-exclusive) pairs, zero-terminated.
; Exclusions so far (see spikes/NOTES.md "Volatile cells"):
;   $01F0-$02EF  PSG + BACKTAB (hardware / display)
;   $02F0-$031C  CPU stack + EXEC header-ptr copy (interrupt-timing noise)
;   field +5 of each 8-word object record ($031D + 8n + 5): real-frame
;                animation counters (differed at matched sim ticks)
; The object table ($031D-$035C) is ISR-written (motion integration), so a
; mainline capture races with it by a few cycles no matter what -- it is
; validated separately at the settled park state instead (cell diff in
; crc_trace_diff.py).  The ring checksums only ISR-clean state.
TRACE_RANGES:
        DECLE   $015D,  $01F0           ; game scratch vars
        DECLE   RNG_LO, RNG_HI+1        ; canonical game RNG (sim space)
        ; Virtualized timer state.  ALL FIVE entries' arm flags and
        ; countdowns carry real state (3 cart timer-API sites) -- these
        ; ranges must match LS_CKSUM's and RS_TAILTBL's exactly (§7.16).
        DECLE   SS_ARM1, SS_ARM3+1      ; $8102-$8104 (ARM1/2/3, contiguous)
        DECLE   SS_ARM4, SS_ARM4+1      ; $810F
        DECLE   SS_ARM5, SS_CNT5+1      ; $8196-$819B (ARM5, CNT1-5)
        DECLE   SS_INJ, SS_INJ+1        ; $819F -- the boot-prompt
                                        ;  injector counter, real sim state
        DECLE   0, 0
