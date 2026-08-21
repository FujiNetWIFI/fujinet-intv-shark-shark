; Determinism spike, run B: identical to run A but the sim freezes for 3
; frames out of every 64 (simulated network stall).  The per-sim-tick state
; checksums must match run A exactly.
SPIKE_DELAY     EQU     0
SPIKE_SCRIPT    EQU     1
SPIKE_TRACE     EQU     1
STALL_N         EQU     9
SPIKE_ECHO      EQU     0
SPIKE_RECORD    EQU     0
SPIKE_REPLAY    EQU     0
NET_SESSION     EQU     0
AUTO_JOIN       EQU     0
NET_FUZZ        EQU     0
TRACE_STOP      EQU     $0400
NET_HUD         EQU     0
SPIKE_VIRT      EQU     1
        INCLUDE "src/core.asm"
