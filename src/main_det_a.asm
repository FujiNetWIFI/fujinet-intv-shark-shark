; Determinism spike, run A: scripted fuzz inputs + checksum trace, no stalls.
SPIKE_DELAY     EQU     0
SPIKE_SCRIPT    EQU     1
SPIKE_TRACE     EQU     1
STALL_N         EQU     0
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
