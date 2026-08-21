; Netcode RAM layout -- PiRTO II cart RAM, 8-bit cells.
; Declare only $8000-$9BFF in the cfg: $9C00-$9FFF is the FujiNet mailbox,
; and claiming it breaks jzIntv's --fujinet peripheral (AND-ed bus reads).
;
; IMPORTANT -- $8000-$807F is a STIC decode alias and must stay UNUSED:
; the STIC only partially decodes its address, so its control registers
; also respond at $4000, $8000 and $C000.  Nothing may live below $8080.
;
; Base layout below is Sea Battle's/Golf's, kept identical where nothing
; cart-specific is involved -- the resync image layout (IMG_S1/S2/S3/TOTAL
; in resync.asm) and every bounds constant it implies were proven across
; eleven ports, and PORTING.md §7.16 says any layout change forces a full
; sweep. This port DOES grow the tail (15 words of real virtualized-timer
; state vs. Golf's 14 -- five timer entries here, not three, and every one
; needs its own countdown, M1a), so IMG_TOTAL moves 769 -> 770 and the
; sweep has been done (resync.asm, this file, debug.asm TRACE_RANGES,
; lockstep.asm LS_CKSUM all agree -- see spikes/NOTES.md M2/M3).
;
; SHARK SHARK IS 1-2 PLAYERS, SIMULTANEOUS (M1b/M1c) -- Boxing's shape,
; not Golf's turn-arbiter shape: dispatch-only for input (zero $011F-
; $0124 reads anywhere in the cart, confirmed at the EXEC-mechanism level
; not just by absence of references), so there is NO shadow-input pair
; and NO UPDATE_SHADOW/SHADOW_FROM_RINGS call anywhere in this port.
; There is also no turn arbiter and no ARB_SEAT: both seats' events
; replay every tick via VD_SIDE/VD_CTRL set to 0 then 1, exactly
; reproducing the EXEC's own R1 controller-index handoff the cart's
; shared per-seat handler body already relies on (M1c).

NET_RAM         EQU     $8080   ; base of netcode state (zeroed by NET_START)
NET_RAM_SIZE    EQU     $0180   ; $8080-$81FF zeroed at start

; --- Virtualized game timer state ------------------------------------------
; This cart's timer table has FIVE game entries, all fully virtualized
; (Bowling/Golf's model -- with 5 real entries and only 2 slots free after
; the music placeholder + MASTER_TICK, native dispatch doesn't fit, and
; full virtualization is the family's proven-safe default, PORTING.md §4).
; EVERY entry needs its own countdown (none has interval 1, M1a) -- the
; busiest countdown surface of any port to date, tied with Frog Bog's
; entry count but this cart needs MORE countdowns than Frog Bog's five
; entries did (three of Frog Bog's were individually stoppable but shared
; simpler cadences).  Arm/stop: $51A7/$51B8 are one-time stop-ALL/start-
; ALL loops across all five slots; $628D stops SLOT 3 ONLY at game over
; (M1a).  ALL of it is sim state: LS_CKSUM (lockstep.asm) + debug.asm
; TRACE_RANGES + resync.asm RS_TAILTBL must stay in agreement.
SS_ARM1         EQU     $8102   ; entry 1 ($5B1A, spawn roll) armed
SS_ARM2         EQU     $8103   ; entry 2 ($5B75, shark AI) armed
SS_ARM3         EQU     $8104   ; entry 3 ($5C7F, bite/collision) armed
SS_ARM4         EQU     $810F   ; entry 4 ($5CEA, PRIMARY) armed
SS_ARM5         EQU     $8196   ; entry 5 ($5D5B, recovery) armed
SS_CNT1         EQU     $8197   ; entry 1 countdown (interval $10)
SS_CNT2         EQU     $8198   ; entry 2 countdown (interval $2D)
SS_CNT3         EQU     $8199   ; entry 3 countdown (interval $0A)
SS_CNT4         EQU     $819A   ; entry 4 countdown (interval $02)
SS_CNT5         EQU     $819B   ; entry 5 countdown (interval $50)

DELAY_EN        EQU     $8105   ; virt-dispatch delay depth in game ticks
                                ;  (0 = same-tick dispatch, stock feel)
RNG_LO          EQU     $8106   ; canonical game RNG (mirrors $035E across
RNG_HI          EQU     $8107   ;  sim ticks) -- serves all 14 X_RAND2
                                ;  wrapper call sites (M1a)
TICK_LO         EQU     $8108   ; 16-bit sim (game) tick counter
TICK_HI         EQU     $8109
SLF_LO          EQU     $810A   ; scripted-input PRNG state (spike c)
SLF_HI          EQU     $810B
FRM_CTR         EQU     $810C   ; frame counter for the stall injector
SCR_IDX         EQU     $810D   ; demo-script row offset ($FF = done -> fuzz)
SCR_CNT         EQU     $810E   ; ticks consumed in the current script row
MB_DEV          EQU     $8114   ; mailbox transaction arguments
MB_CMD          EQU     $8115
MB_NPARAM       EQU     $8116
MB_TXLEN_LO     EQU     $8117
MB_TXLEN_HI     EQU     $8118
MB_OK           EQU     $8119   ; 1 = last transaction ACKed
MB_ERR          EQU     $811A   ; FN_ERR / status code (0 = timeout)
MB_PMAX_LO      EQU     $811B   ; worst-case ACKSEQ poll iterations seen
MB_PMAX_HI      EQU     $811C
NAVAIL_LO       EQU     $811D   ; NET_STATUS bytes-available
NAVAIL_HI       EQU     $811E
NREQ_LO         EQU     $8130   ; NET_READ/WRITE length argument
NREQ_HI         EQU     $8131
NGOT_LO         EQU     $8132   ; NET_READ actual byte count
NGOT_HI         EQU     $8133

FIRSTC_LO       EQU     $8110   ; (spike c) tick+1 of first game RNG use
FIRSTC_HI       EQU     $8111
RNGP_LO         EQU     $8112   ; (spike c) previous canonical RNG
RNGP_HI         EQU     $8113

RX_WR           EQU     $8134   ; net stream accumulator write index (mod 256)
RX_RD           EQU     $8135   ; read index
NAME_BUF        EQU     $8150   ; own player name, 8 cells + NUL
NAME_LEN        EQU     $8159
MENU_SEL        EQU     $815A   ; lobby cursor index
MENU_PREV       EQU     $815B   ; previous raw controller value (edge detect)
LOBBY_CNT       EQU     $815C   ; entries in LOBBY_CACHE
SES_TMR_LO      EQU     $815D   ; lobby refresh pacing counter
SES_TMR_HI      EQU     $815E
NET_SEAT        EQU     $8160   ; this console's seat, 0-1 (0 = host)
NET_DELAY       EQU     $8161   ; lockstep input delay d (game ticks)
NET_ACTIVE      EQU     $8162   ; 1 = lockstep netplay engaged
NET_DROPPED     EQU     $8163   ; 1 = peer gone / timeout
SES_STAT        EQU     $8166   ; session progress/error marker (UI/debug)
CRC_PH          EQU     $8167   ; crc send phase counter
LS_TMPB         EQU     $8168   ; lockstep scratch
LS_TMPB2        EQU     $8169
LS_FROZE        EQU     $816A   ; 1 = ISR phase counter currently frozen
LS_SAVE102      EQU     $816B   ; saved $0102 during a stall
LS_WAITC_LO     EQU     $816C   ; gate pump-round counter
LS_WAITC_HI     EQU     $816D
PP_TMP          EQU     $816E   ; pump scratch
SES_SAVE102     EQU     $816F   ; ISR phase counter saved across the session
RESYNC_HOLD     EQU     $8090   ; 1 = sim held for a state resync
RS_R_LO         EQU     $8091   ; agreed resume tick R
RS_R_HI         EQU     $8092
RS_TO_LO        EQU     $8093   ; hold timeout pump counter
RS_TO_HI        EQU     $8094
RS_TMP          EQU     $8095
RS_POS_LO       EQU     $8096   ; serializer/applier image position
RS_POS_HI       EQU     $8097
RS_TMP2         EQU     $8098
GAME_TBL_LO     EQU     $80C0   ; game's live input-handler table ($035D),
GAME_TBL_HI     EQU     $80C1   ;  captured around each game tick.  THREE
                                ;  static cart-side installs ($5193 live
                                ;  table, $1906 EXEC null at game-over,
                                ;  $629C post-game "play again"), PLUS one
                                ;  install done INTERNALLY by the shared
                                ;  EXEC $1910 routine for the boot prompt
                                ;  (SS_HTBL_PROMPT, M1c) -- adopt-don't-
                                ;  restore still applies (§5.3).
VD_TMP          EQU     $80C2   ; virtual dispatcher scratch
VD_SIDE         EQU     $80C3   ; SEAT whose ring the dispatcher reads (0-1)
VD_CUR          EQU     $80C4
VD_PREV         EQU     $80C5
VD_KP           EQU     $80C6
VD_KPPRE        EQU     $80C7

; --- 2-seat state ----------------------------------------------------------
NET_COUNT       EQU     $819D   ; players this match, 1-2 (the cart's own
                                ;  boot prompt hard-caps it at 2, M1b);
                                ;  local spikes: 2
SS_INJ          EQU     $819F   ; boot-prompt ("SELECT 1 OR 2 PLAYERS")
                                ;  auto-inject sequencer counter -- SIM
                                ;  STATE (in the CRC tail and the resync
                                ;  image tail, PORTING.md §7.16).  No
                                ;  arbiter gates this (there isn't one,
                                ;  M1b): it runs unconditionally on both
                                ;  the local and netplay dispatch paths
                                ;  until GAME_TBL moves off
                                ;  SS_HTBL_PROMPT, answering from
                                ;  NET_COUNT so both consoles agree
                                ;  without a human race (Golf's
                                ;  ARB_INJECT rationale, minus the
                                ;  arbiter gate).
SEAT_WM         EQU     $81A0   ; 2 x [wm_lo, wm_hi] per-seat remote input
                                ;  watermarks ($81A0-$81A3); own seat
                                ;  unused; $81A4-$81A7 unused (family
                                ;  layout supports up to 4 seats, this
                                ;  cart only ever uses 2)
VD_CTRL         EQU     $81A8   ; controller index passed to handlers in R1
                                ;  -- LOAD-BEARING on this cart (M1c):
                                ;  the shared per-seat handler body
                                ;  branches on it directly (TSTR R1) to
                                ;  pick MOB0 ($031D) vs MOB1 ($0325,
                                ;  stride 8).  Set to match VD_SIDE (0
                                ;  then 1) on every dispatch call, both
                                ;  seats every tick -- Boxing's shape.
ROOM_CNT        EQU     $81AA   ; pre-match waiting-room member count
                                ;  (0/1 = browsing the lobby, 2 = in a
                                ;  forming room)
ROOM_HOST       EQU     $81AB   ; 1 = we are roster slot 0 (ENTER sends GO)
LEFT_SEAT       EQU     $81AC   ; seat of whoever ended the match (PEER_LEFT)
LEFT_NAME       EQU     $81B0   ; leaver's name for the terminal screen (8+NUL)
NAME_TBL        EQU     $81C0   ; 4 x 9 (name8 + NUL), seat-ordered roster
                                ;  from the START payload ($81C0-$81E3) --
                                ;  ROSTER_SLOTS stays 4, a wire-protocol
                                ;  constant shared with every port, not a
                                ;  capacity (only slots 0-1 are ever live
                                ;  here)

; Field diagnostics.  A live session over real hardware leaves no log, so
; these saturating counters are the only evidence an incident produces --
; dump them with `m 8180 4` after a bad game.
DIAG_SLIP       EQU     $8180   ; parser resyncs (byte stream had slipped)
DIAG_REJ        EQU     $8181   ; STATE chunks refused by the resync guards
DIAG_TMO        EQU     $8182   ; mailbox transactions that timed out
DIAG_ERR        EQU     $8183   ; mailbox transactions that replied an error

UI_COLOR        EQU     $818B   ; current text colour, palette index 0-15
                                ;  (UI_CLS resets it to white)

; Live performance HUD (NET_HUD builds only -- see src/netcode/hud.asm).
HUD_PLL         EQU     $8190   ; mailbox poll iterations this window, 16-bit
HUD_PLH         EQU     $8191   ;  (the high cell is what gets displayed)
HUD_STL         EQU     $8192   ; gate stall rounds this window (saturating)
HUD_HLD         EQU     $8193   ; resync-hold pump rounds this window
HUD_LEAD        EQU     $8194   ; smallest (remote watermark - tick) seen, 0-15
HUD_RSY         EQU     $8195   ; resyncs completed since the session started

RS_PEND         EQU     $8187   ; 1 = resync wanted, waiting for quiescent point
RS_PTMO         EQU     $8188   ; game ticks waited so far
RS_WAITED       EQU     $8189   ; ticks the last resync waited (diagnostic)
RS_GATE         EQU     $818A   ; why the last push fired: 1 = quiescent, 2 = cap

PEER_SCR        EQU     $8185   ; 1 = peer-left screen up, sim stopped for good
PEER_WHY        EQU     $8186   ; 1 = server said PEER_LEFT, 0 = we timed out

RXACC           EQU     $8200   ; 256-byte circular net stream accumulator
FRMBUF          EQU     $8300   ; current frame, linear (len,type,payload)
LOBBY_CACHE     EQU     $8380   ; last LOBBY payload (count + 9/entry)

; --- Per-seat input rings (one 256-cell page per seat) ---------------------
; Decoded-input rings: SEAT_RING + seat*$100, $8400-$87FF.
; Keypad-cell rings:   SEAT_KP   + seat*$100, $8800-$8BFF.
; LS_RING_INIT idle-fills all pages (decoded $40, keypad 0).  Only seats
; 0-1 are ever live on this cart, but the family-standard 4-page layout
; is kept for consistency (harmless, matches every sibling port).
SEAT_RING       EQU     $8400
SEAT_KP         EQU     $8800

OWN_CRC         EQU     $8C00   ; 8 x [tick_lo, tick_hi, crc_lo, crc_hi]

TRACE_RING      EQU     $9000   ; 256 x 2-byte per-tick state checksums

; LAG_RING: 256 x 2-word per-tick raw capture of $0168/$0169 (P1/P2's
; disc-heading echo cells, exec_equ.asm) -- lagcheck-only (SPIKE_TRACE
; builds), written by debug.asm's TRACE_TICK alongside the checksum ring.
; NOT used by `make det`'s determinism proof (that uses TRACE_RING's
; whole-state checksum, unaffected).  Needed because this cart's
; checksummed state is DOMINATED by four ambient, real-time-scheduled
; timer entries (spawn/AI, unconditional regardless of input) that swamp
; the much smaller input-driven signal in a whole-state cross-correlation
; -- unlike Golf, where the family's TRACE_RING-correlation lagcheck
; design (PORTING.md §7.33) works directly. $0168/$0169 are a DIRECT,
; un-smoothed echo of the most recent disc value dispatched to each seat
; (L_63D3's caller, $63B4/$6418 -- confirmed in dis1600), inside the
; already-checksummed $015D-$01EF range, so they need no new CRC/image
; coverage of their own.
LAG_RING        EQU     $9200   ; $9200-$93FF (256 x 2 words)

; This cart is DISPATCH-ONLY for input (M1a/M1c: zero $011F-$0124 reads
; anywhere, confirmed at the EXEC-mechanism level -- the scan's own
; SUBI #$011F,R1 hands the shared per-seat handler body R1=0/1 directly,
; and VD_CTRL above reproduces exactly that).  Unlike every polling cart
; in this family, there is NO shadow $011F/$0120 pair here at all -- no
; SHADOW_CTRL/SHADOW_CTRL_R, no UPDATE_SHADOW, no SHADOW_FROM_RINGS call
; anywhere in hook.asm or lockstep.asm's LS_PASS.

; SS_QUIESCENT: the resync-gate predicate resync.asm's generic RS_PENDING
; expects at SC_PHASE/SC_PHASE_DEAD (`MVI SC_PHASE,R0 / ANDI
; #SC_PHASE_DEAD,R0 / BNEQ ...dead...`).  Computed into this derived flag
; every tick in SS_GAME_TICK (not MASTER_TICK's local-only section --
; must run on both the local AND netplay paths, PORTING.md's hard-won Sea
; Battle rule).  PURELY DERIVED from cells already inside the standard
; CRC range ($015D-$01EF) -- needs no independent CRC or image coverage.
;
; Working hypothesis (NOT yet live-confirmed with a forced QUIESCE=1
; test, M1b/M1c open item): the SAME joint-AND condition the cart's own
; game-over gate uses ($6228-$6242) -- both MOB0 ($031D) and MOB1
; ($0325) bit $0800 clear AND $0323==0 AND $032B==0.  Because play is
; simultaneous, there may be NO safe mid-round quiescent moment (Auto
; Racing's shape, not Bowling's between-turns shape) -- this flag may
; only ever go true once the round is actually over, in which case the
; resync push defers to RS_PEND_MAX's cap during live play, which is
; still correct behaviour, just untested until a forced QUIESCE run
; proves the branch (§7.29).
SS_QUIESCENT    EQU     $81AF
SC_PHASE        EQU     SS_QUIESCENT
SC_PHASE_DEAD   EQU     $01
