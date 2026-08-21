; Netplay build with the live diagnostic HUD row -- the bring-up image for
; real hardware (PORTING.md section 6: read L/S/T/R/H during real play and
; tune the delay).  Ship main_net.asm (HUD off) once the numbers look right.
SPIKE_VIRT      EQU     0
SPIKE_DELAY     EQU     0
SPIKE_SCRIPT    EQU     0
SPIKE_TRACE     EQU     0
STALL_N         EQU     0
SPIKE_ECHO      EQU     0
SPIKE_RECORD    EQU     0
SPIKE_REPLAY    EQU     0
NET_SESSION     EQU     1
AUTO_JOIN       EQU     0
NET_FUZZ        EQU     0
NET_HUD         EQU     1
        INCLUDE "src/core.asm"
