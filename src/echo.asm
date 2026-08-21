; Transport spike (d): TCP echo loop over the FujiNet mailbox.
; Runs from NET_START before the game would launch; never returns -- parks
; at ECHO_PARK with results in RAM for the debugger to dump:
;   $8120 E_STAGE   $AA = success, $Fx = failed at stage x
;   $8121 E_ECODE   copy of MB_ERR at failure
;   $8122 E_ROUNDS  completed echo rounds (target 100)
;   $8123 E_BAD     payload mismatches
;   $8124/25 E_SMAX max NET_STATUS calls needed for one round's reply
;   $811B/1C MB_PMAX worst ACKSEQ poll spin (~10 CPU cycles per count)

E_STAGE         EQU     $8120
E_ECODE         EQU     $8121
E_ROUNDS        EQU     $8122
E_BAD           EQU     $8123
E_SMAX_LO       EQU     $8124
E_SMAX_HI       EQU     $8125
E_SPOLL_LO      EQU     $8126
E_SPOLL_HI      EQU     $8127

ECHO_ROUNDS     EQU     100

ECHO_TEST:
        ; ---- stage 1: mailbox present?
        MVII    #1,     R0
        MVO     R0,     E_STAGE
        JSR     R5,     MB_WAIT_MAGIC
        MVI     MB_OK,  R0
        TSTR    R0
        BEQ     @@efail

        ; ---- stage 2: open the echo endpoint
        MVII    #2,     R0
        MVO     R0,     E_STAGE
        MVII    #ECHO_SPEC, R4
        MVII    #FN_TX, R5
        MVII    #ECHO_SPEC_LEN, R1
@@cp:   MVI@    R4,     R0
        MVO@    R0,     R5
        DECR    R1
        BNEQ    @@cp
        MVII    #ECHO_SPEC_LEN, R0
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_OPEN
        MVI     MB_OK,  R0
        TSTR    R0
        BEQ     @@efail

        ; ---- stage 3: echo rounds
@@round:
        MVII    #3,     R0
        MVO     R0,     E_STAGE
        ; payload: round#, $A5, 2, 3, 4, 5, 6, 7
        MVII    #FN_TX, R5
        MVI     E_ROUNDS, R0
        MVO@    R0,     R5
        MVII    #$A5,   R0
        MVO@    R0,     R5
        MVII    #2,     R0
@@pl:   MVO@    R0,     R5
        INCR    R0
        CMPI    #8,     R0
        BNEQ    @@pl
        MVII    #8,     R0
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_WRITE
        MVI     MB_OK,  R0
        TSTR    R0
        BEQ     @@efail

        ; wait for the 8 bytes to come back
        MVII    #4,     R0
        MVO     R0,     E_STAGE
        CLRR    R0
        MVO     R0,     E_SPOLL_LO
        MVO     R0,     E_SPOLL_HI
@@st:   JSR     R5,     NET_STATUS
        MVI     MB_OK,  R0
        TSTR    R0
        BEQ     @@efail
        MVI     NAVAIL_HI, R0
        TSTR    R0
        BNEQ    @@have
        MVI     NAVAIL_LO, R0
        CMPI    #8,     R0
        BGE     @@have
        ; count the status poll, bound at $4000
        MVI     E_SPOLL_LO, R0
        INCR    R0
        MVO     R0,     E_SPOLL_LO
        CMPI    #$100,  R0
        BNEQ    @@st
        MVI     E_SPOLL_HI, R0
        INCR    R0
        MVO     R0,     E_SPOLL_HI
        CMPI    #$40,   R0
        BNEQ    @@st
        MVII    #6,     R0              ; stage 6 = reply never arrived
        MVO     R0,     E_STAGE
        B       @@efail
@@have:
        ; track worst-case status polls
        MVI     E_SMAX_HI, R0
        SWAP    R0,     1
        ADD     E_SMAX_LO, R0
        MOVR    R0,     R2
        MVI     E_SPOLL_HI, R0
        SWAP    R0,     1
        ADD     E_SPOLL_LO, R0
        CMPR    R2,     R0
        BLT     @@no_smax
        MVO     R0,     E_SMAX_LO
        SWAP    R0,     1
        MVO     R0,     E_SMAX_HI
@@no_smax:
        ; read it back and verify
        MVII    #5,     R0
        MVO     R0,     E_STAGE
        MVII    #8,     R0
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_READ
        MVI     MB_OK,  R0
        TSTR    R0
        BEQ     @@efail
        MVI     NGOT_LO, R0
        CMPI    #8,     R0
        BNEQ    @@bad
        MVI     FN_RX,  R0
        CMP     E_ROUNDS, R0
        BNEQ    @@bad
        MVI     FN_RX+1, R0
        CMPI    #$A5,   R0
        BEQ     @@good
@@bad:  MVI     E_BAD,  R0
        INCR    R0
        MVO     R0,     E_BAD
@@good: MVI     E_ROUNDS, R0
        INCR    R0
        MVO     R0,     E_ROUNDS
        CMPI    #ECHO_ROUNDS, R0
        BNEQ    @@round

        ; ---- done
        JSR     R5,     NET_CLOSE
        MVII    #$AA,   R0
        MVO     R0,     E_STAGE
        B       ECHO_PARK

@@efail: MVI     MB_ERR, R0
        MVO     R0,     E_ECODE
        MVI     E_STAGE, R0
        XORI    #$F0,   R0
        MVO     R0,     E_STAGE
ECHO_PARK:
        B       ECHO_PARK

ECHO_SPEC:
        STRING  "N:TCP://localhost:9105/"
ECHO_SPEC_LEN   EQU     23
