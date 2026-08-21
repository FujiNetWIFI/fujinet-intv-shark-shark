; Live netplay performance HUD (NET_HUD builds).
;
; Netplay on real hardware leaves no log and the symptoms all look alike from
; the couch: whether the sim is waiting on the peer, waiting on the mailbox,
; or being frozen by a state resync, what a player sees is the same "players
; stopped moving, sound kept playing".  This row separates them live, so the
; counter that jumps during a pause names its cause.
;
; Bottom BACKTAB row, refreshed every 16 game ticks (~0.8 s at the measured
; 20 Hz tick rate).  Every figure is HEX:
;
;   L nn  slack -- min(remote watermark - tick) this window, 0-15.  Healthy
;         is d-1 (02 at the stock delay of 3).  00 means the remote input
;         arrived exactly when it was needed, or later: the sim is running at
;         the network's pace, not the console's, and every scrap of jitter
;         becomes a visible stall.
;   S nn  gate stall rounds this window: pump rounds spent waiting for the
;         peer's input.  Normal play needs none; each round is one mailbox
;         STATUS transaction of pure waiting.
;   T nn  mailbox poll iterations / 256 this window.  One iteration is ~40
;         cycles; a game tick measures ~60k cycles (nominally 3 NTSC frames
;         plus ISR-dance overhang, 20 Hz -- see spikes/NOTES.md), so a
;         16-tick window is ~0.96M cycles and saturation is T = ~5D.  The
;         Football rig read 21 (~35% of budget), down from 32 before the
;         pump moved to one per tick.
;   R nn  state resyncs completed since the session started.  Any increment
;         is a desync that got repaired; if R ticks up on every pause, the
;         pauses ARE the resyncs and the determinism bug is the real target.
;   H nn  resync-hold pump rounds this window (how long the sim sat frozen
;         waiting for the image to arrive).
;
; Reading it: S high with L 00 = network-bound (raise the delay, or shorten
; the round trip).  S 00 with T high = transport-bound (cut transactions per
; tick; a bigger delay would only add lag).  R climbing = desync, not pacing.
;
; The row costs one UI_PRINT + five UI_HEX2 every 16 ticks and writes only
; BACKTAB, which is display state -- it cannot affect the CRC or the sim.

HUD_ROW         EQU     20*11           ; bottom row, clear of the scoreboard

HUD_DRAW:
        PSHR    R5
        MVII    #C_WHITE, R0
        MVO     R0,     UI_COLOR
        MVII    #HUD_ROW, R0
        MVII    #STR_HUD, R1
        JSR     R5,     UI_PRINT
        MVI     HUD_LEAD, R0
        MVII    #HUD_ROW+1, R1
        JSR     R5,     UI_HEX2
        MVI     HUD_STL, R0
        MVII    #HUD_ROW+5, R1
        JSR     R5,     UI_HEX2
        MVI     HUD_PLH, R0
        MVII    #HUD_ROW+9, R1
        JSR     R5,     UI_HEX2
        MVI     HUD_RSY, R0
        MVII    #HUD_ROW+13, R1
        JSR     R5,     UI_HEX2
        MVI     HUD_HLD, R0
        MVII    #HUD_ROW+17, R1
        JSR     R5,     UI_HEX2
        ; new window
        CLRR    R0
        MVO     R0,     HUD_PLL
        MVO     R0,     HUD_PLH
        MVO     R0,     HUD_STL
        MVO     R0,     HUD_HLD
        MVII    #15,    R0
        MVO     R0,     HUD_LEAD        ; min-tracker starts at the ceiling
        PULR    R7

STR_HUD:        STRING  "L   S   T   R   H   "
                DECLE   0
