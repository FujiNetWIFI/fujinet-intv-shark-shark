; FujiNet mailbox driver (PiRTO II / jzIntv --fujinet), CP-1610 port of the
; proven IntyBASIC primitives (netcat fujinet.bas / fujirealm rt.bas).
; Mailbox registers are byte-wide cells at $9C00; Inty writes are truncated
; to 8 bits by the hardware, reads return $00xx.

FN_MAGIC0       EQU     $9C00           ; 'F'
FN_MAGIC1       EQU     $9C01           ; 'N'
FN_SEQ          EQU     $9C03
FN_ACKSEQ       EQU     $9C04
FN_DEVICE       EQU     $9C05
FN_CMD          EQU     $9C06
FN_NPARAM       EQU     $9C07
FN_TXLEN_LO     EQU     $9C08
FN_TXLEN_HI     EQU     $9C09
FN_ERR          EQU     $9C0B
FN_RXLEN_LO     EQU     $9C0C
FN_RXLEN_HI     EQU     $9C0D
FN_REPLY_CMD    EQU     $9C0E
FN_PARAM_SIZE   EQU     $9C10           ; [8]
FN_PARAM_VAL    EQU     $9C20           ; [8][4], LE, one byte per cell
FN_TX           EQU     $9C40           ; 256 bytes
FN_RX           EQU     $9D40           ; 512 bytes

FUJICMD_ACK     EQU     $06

NET_DEVICEID    EQU     $71
NETCMD_OPEN     EQU     $4F
NETCMD_CLOSE    EQU     $43
NETCMD_READ     EQU     $52
NETCMD_WRITE    EQU     $57
NETCMD_STATUS   EQU     $53

OPEN_MODE_RW    EQU     12              ; read-write (TCP client)
OPEN_TRANS_NONE EQU     0

; ---------------------------------------------------------------------------
; DIAG_BUMP -- saturating increment of the 8-bit counter addressed by R4.
; Clobbers R0 and leaves R4 one past the counter.
; ---------------------------------------------------------------------------
DIAG_BUMP:
        MVI@    R4,     R0
        CMPI    #$FF,   R0
        BEQ     @@db_out
        INCR    R0
        DECR    R4
        MVO@    R0,     R4
@@db_out:
        MOVR    R5,     R7

; ---------------------------------------------------------------------------
; MB_WAIT_MAGIC -- bounded wait for the mailbox magic bytes.
; Returns: MB_OK = 1 if 'F','N' seen, else 0.
; ---------------------------------------------------------------------------
MB_WAIT_MAGIC:
        PSHR    R5
        MVII    #120,   R2              ; outer bound
@@o:    MVII    #$2000, R1              ; inner spin
@@i:    MVI     FN_MAGIC0, R0
        CMPI    #'F',   R0
        BNEQ    @@n
        MVI     FN_MAGIC1, R0
        CMPI    #'N',   R0
        BEQ     @@ok
@@n:    DECR    R1
        BNEQ    @@i
        DECR    R2
        BNEQ    @@o
        CLRR    R0
        MVO     R0,     MB_OK
        PULR    R7
@@ok:   MVII    #1,     R0
        MVO     R0,     MB_OK
        PULR    R7

; ---------------------------------------------------------------------------
; MB_TRANSACT -- run the transaction staged in MB_DEV/MB_CMD/MB_NPARAM/
; MB_TXLEN_LO/HI (params + TX payload already poked by the caller).
; seq derives from the peripheral's own ACKSEQ (console reset zeroes our RAM
; but not the peripheral, so a local counter would deadlock -- see the
; fujirealm fujinet.bas commentary).
; Returns: MB_OK = 1 on ACK, else 0 with MB_ERR (0 = timeout).
; Clobbers R0-R2 (and R4/R5 on the failure paths, which bump a diagnostic
; counter).  MB_PMAX_LO/HI tracks the worst ACKSEQ poll count seen.
; ---------------------------------------------------------------------------
MB_TRANSACT:
        PSHR    R5
        MVI     MB_DEV, R0
        MVO     R0,     FN_DEVICE
        MVI     MB_CMD, R0
        MVO     R0,     FN_CMD
        MVI     MB_NPARAM, R0
        MVO     R0,     FN_NPARAM
        MVI     MB_TXLEN_LO, R0
        MVO     R0,     FN_TXLEN_LO
        MVI     MB_TXLEN_HI, R0
        MVO     R0,     FN_TXLEN_HI

        MVI     FN_ACKSEQ, R0
        INCR    R0
        ANDI    #$FF,   R0
        BNEQ    @@seq_ok
        INCR    R0                      ; seq skips 0
@@seq_ok:
        MOVR    R0,     R2              ; R2 = expected ackseq
        MVO     R0,     FN_SEQ

        CLRR    R1                      ; poll counter (16-bit, few seconds)
@@poll: MVI     FN_ACKSEQ, R0
        CMPR    R2,     R0
        BEQ     @@acked
        INCR    R1
        BNEQ    @@poll
        ; Timeout.  The peripheral may still complete the transaction after
        ; we walk away, so a timed-out NET_READ can silently swallow bytes --
        ; which misframes the stream from here on.  Count them.
        CLRR    R0
        MVO     R0,     MB_OK
        MVO     R0,     MB_ERR
        MVII    #DIAG_TMO, R4
        JSR     R5,     DIAG_BUMP
        PULR    R7
@@acked:
        ; track worst-case poll count
        MVI     MB_PMAX_HI, R0
        SWAP    R0,     1
        ADD     MB_PMAX_LO, R0
        CMPR    R0,     R1
        BLT     @@no_max
        MVO     R1,     MB_PMAX_LO
        SWAP    R1,     1
        MVO     R1,     MB_PMAX_HI
@@no_max:
    IF NET_HUD <> 0
        ; Accumulate the poll count for the HUD's transport figure.  One poll
        ; iteration is ~40 cycles, so a whole NTSC frame is ~370 of them --
        ; this is how much of the sim's time budget the mailbox is eating.
        MOVR    R1,     R2
        ANDI    #$FF,   R2
        MVI     HUD_PLL, R0
        ADDR    R2,     R0
        MVO     R0,     HUD_PLL         ; 8-bit cell truncates
        MOVR    R1,     R2
        SWAP    R2,     1
        ANDI    #$FF,   R2
        CMPI    #$100,  R0
        BLT     @@hp_nc
        INCR    R2                      ; carry out of the low cell
@@hp_nc:
        MVI     HUD_PLH, R0
        ADDR    R2,     R0
        CMPI    #$FF,   R0
        BLT     @@hp_st
        MVII    #$FF,   R0              ; saturate rather than wrap
@@hp_st:
        MVO     R0,     HUD_PLH
    ENDI
        MVI     FN_REPLY_CMD, R0
        CMPI    #FUJICMD_ACK, R0
        BEQ     @@tok
        MVI     FN_ERR, R0
        MVO     R0,     MB_ERR
        CLRR    R0
        MVO     R0,     MB_OK
        MVII    #DIAG_ERR, R4
        JSR     R5,     DIAG_BUMP
        PULR    R7
@@tok:  MVII    #1,     R0
        MVO     R0,     MB_OK
        PULR    R7

; ---------------------------------------------------------------------------
; NET_STATUS -- bytes available on the open channel.
; Returns: MB_OK; NAVAIL_LO/HI; MB_ERR gets the nDevStatus code when the
; reply's status byte is not 1 (SUCCESS -- an HTTP error page would still
; show readable bytes, see fujirealm notes).
; ---------------------------------------------------------------------------
NET_STATUS:
        PSHR    R5
        MVII    #NET_DEVICEID, R0
        MVO     R0,     MB_DEV
        MVII    #NETCMD_STATUS, R0
        MVO     R0,     MB_CMD
        MVII    #2,     R0
        MVO     R0,     MB_NPARAM
        MVII    #1,     R0
        MVO     R0,     FN_PARAM_SIZE
        MVO     R0,     FN_PARAM_SIZE+1
        CLRR    R0
        MVO     R0,     FN_PARAM_VAL
        MVO     R0,     FN_PARAM_VAL+4
        MVO     R0,     MB_TXLEN_LO
        MVO     R0,     MB_TXLEN_HI
        JSR     R5,     MB_TRANSACT
        MVI     MB_OK,  R0
        TSTR    R0
        BEQ     @@fail
        MVI     FN_RX,  R0
        MVO     R0,     NAVAIL_LO
        MVI     FN_RX+1, R0
        MVO     R0,     NAVAIL_HI
        MVI     FN_RX+3, R0
        CMPI    #1,     R0
        BEQ     @@done
        MVO     R0,     MB_ERR
        CLRR    R0
        MVO     R0,     MB_OK
        PULR    R7
@@fail: CLRR    R0
        MVO     R0,     NAVAIL_LO
        MVO     R0,     NAVAIL_HI
@@done: PULR    R7

; ---------------------------------------------------------------------------
; NET_READ -- read up to NREQ_LO/HI bytes into FN_RX (caller consumes them
; from there before the next transaction clobbers the buffer).
; Returns: MB_OK; NGOT_LO/HI = actual byte count.
; ---------------------------------------------------------------------------
NET_READ:
        PSHR    R5
        MVII    #NET_DEVICEID, R0
        MVO     R0,     MB_DEV
        MVII    #NETCMD_READ, R0
        MVO     R0,     MB_CMD
        MVII    #1,     R0
        MVO     R0,     MB_NPARAM
        MVII    #2,     R0
        MVO     R0,     FN_PARAM_SIZE
        MVI     NREQ_LO, R0
        MVO     R0,     FN_PARAM_VAL
        MVI     NREQ_HI, R0
        MVO     R0,     FN_PARAM_VAL+1
        CLRR    R0
        MVO     R0,     MB_TXLEN_LO
        MVO     R0,     MB_TXLEN_HI
        JSR     R5,     MB_TRANSACT
        MVI     MB_OK,  R0
        TSTR    R0
        BEQ     @@rfail
        MVI     FN_RXLEN_LO, R0
        MVO     R0,     NGOT_LO
        MVI     FN_RXLEN_HI, R0
        MVO     R0,     NGOT_HI
        PULR    R7
@@rfail:
        CLRR    R0
        MVO     R0,     NGOT_LO
        MVO     R0,     NGOT_HI
        PULR    R7

; ---------------------------------------------------------------------------
; NET_WRITE -- send NREQ_LO/HI bytes already staged at FN_TX.
; ---------------------------------------------------------------------------
NET_WRITE:
        PSHR    R5
        MVII    #NET_DEVICEID, R0
        MVO     R0,     MB_DEV
        MVII    #NETCMD_WRITE, R0
        MVO     R0,     MB_CMD
        MVII    #1,     R0
        MVO     R0,     MB_NPARAM
        MVII    #2,     R0
        MVO     R0,     FN_PARAM_SIZE
        MVI     NREQ_LO, R0
        MVO     R0,     FN_PARAM_VAL
        MVO     R0,     MB_TXLEN_LO
        MVI     NREQ_HI, R0
        MVO     R0,     FN_PARAM_VAL+1
        MVO     R0,     MB_TXLEN_HI
        JSR     R5,     MB_TRANSACT
        PULR    R7

; ---------------------------------------------------------------------------
; NET_OPEN -- open the devicespec staged at FN_TX (length NREQ_LO) in
; read-write mode (TCP client), translation none.
; ---------------------------------------------------------------------------
NET_OPEN:
        PSHR    R5
        MVII    #NET_DEVICEID, R0
        MVO     R0,     MB_DEV
        MVII    #NETCMD_OPEN, R0
        MVO     R0,     MB_CMD
        MVII    #2,     R0
        MVO     R0,     MB_NPARAM
        MVII    #1,     R0
        MVO     R0,     FN_PARAM_SIZE
        MVO     R0,     FN_PARAM_SIZE+1
        MVII    #OPEN_MODE_RW, R0
        MVO     R0,     FN_PARAM_VAL
        MVII    #OPEN_TRANS_NONE, R0
        MVO     R0,     FN_PARAM_VAL+4
        MVI     NREQ_LO, R0
        MVO     R0,     MB_TXLEN_LO
        CLRR    R0
        MVO     R0,     MB_TXLEN_HI
        JSR     R5,     MB_TRANSACT
        PULR    R7

; ---------------------------------------------------------------------------
; NET_CLOSE
; ---------------------------------------------------------------------------
NET_CLOSE:
        PSHR    R5
        MVII    #NET_DEVICEID, R0
        MVO     R0,     MB_DEV
        MVII    #NETCMD_CLOSE, R0
        MVO     R0,     MB_CMD
        CLRR    R0
        MVO     R0,     MB_NPARAM
        MVO     R0,     MB_TXLEN_LO
        MVO     R0,     MB_TXLEN_HI
        JSR     R5,     MB_TRANSACT
        PULR    R7
