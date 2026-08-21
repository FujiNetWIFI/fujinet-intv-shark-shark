; Interception proof build: the deterministic demo script (SCRIPT_TBL)
; drives both pads, with every input delayed by 20 game ticks (1 second).
; SPIKE_TRACE is on so run_lagcheck.sh can correlate the WHOLE per-tick
; state checksum ring against the d=0 build (sharkshark_lag0) rather than
; a hand-picked game cell -- the family's proven-robust default (§7.33):
; it does not require knowing WHAT changed, only THAT the whole state
; timeline is a d-tick-shifted copy of the zero-delay timeline.
; TRACE_STOP is short (250 ticks, under the 256-wrap boundary) so the
; scripted portion is still inside the ring's last lap when it parks.
SPIKE_DELAY     EQU     20
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
