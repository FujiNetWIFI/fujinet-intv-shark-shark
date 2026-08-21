; Record build: pass-through inputs, captures decoded disc + keypad state
; per game tick into $9000-$9BFF (768 ticks, ~38s, REC_CAPTURE's own cap --
; src/vdispatch.asm). Play in windowed jzintv, hit F4 for the debugger,
; then: m 8100 20  /  m 9000 C00  -> save log for mk_replay.py
SPIKE_DELAY     EQU     0
SPIKE_SCRIPT    EQU     0
SPIKE_TRACE     EQU     0
STALL_N         EQU     0
SPIKE_ECHO      EQU     0
SPIKE_RECORD    EQU     1
SPIKE_REPLAY    EQU     0
NET_SESSION     EQU     0
AUTO_JOIN       EQU     0
NET_FUZZ        EQU     0
NET_HUD         EQU     0
SPIKE_VIRT      EQU     0
        INCLUDE "src/core.asm"
