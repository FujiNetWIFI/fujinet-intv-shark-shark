; Virtualized-dispatch build, zero delay: the real scan's $035D table is
; nulled and both pads' events replay through the live handlers in sim
; space, same tick they were captured.  Must feel identical to run-hook --
; this gates the dispatch replication before any delay/netplay sits on it.
SPIKE_VIRT      EQU     1
SPIKE_DELAY     EQU     0
SPIKE_SCRIPT    EQU     0
SPIKE_TRACE     EQU     0
STALL_N         EQU     0
SPIKE_ECHO      EQU     0
SPIKE_RECORD    EQU     0
SPIKE_REPLAY    EQU     0
NET_SESSION     EQU     0
AUTO_JOIN       EQU     0
NET_FUZZ        EQU     0
NET_HUD         EQU     0
        INCLUDE "src/core.asm"
