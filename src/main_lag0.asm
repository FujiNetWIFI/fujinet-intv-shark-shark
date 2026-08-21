; Interception-proof BASELINE: identical to main_lag.asm but with zero
; delay -- the same in-ROM script through the same virtualized dispatch.
; run_lagcheck.sh cross-correlates the two builds' TRACE_RING checksum
; sequences; the difference must be the delay depth.
SPIKE_DELAY     EQU     0
SPIKE_SCRIPT    EQU     1
SPIKE_TRACE     EQU     1
TRACE_STOP      EQU     250     ; < 256: ring never wraps, index i == tick i
STALL_N         EQU     0
SPIKE_ECHO      EQU     0
SPIKE_RECORD    EQU     0
SPIKE_REPLAY    EQU     0
NET_SESSION     EQU     0
AUTO_JOIN       EQU     0
NET_FUZZ        EQU     0
NET_HUD         EQU     0
SPIKE_VIRT      EQU     1
        INCLUDE "src/core.asm"
