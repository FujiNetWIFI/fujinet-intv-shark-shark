# In-place patch map for SharkShark.bin (word address -> as1600 expression).
# Symbols are defined in src/hook.asm / src/ram.asm / src/exec_equ.asm.
# Building with tools/dump_rom.py and NO patch file must stay byte-identical
# to the original (make verify-org -- verified).
#
# STATUS (see spikes/NOTES.md M1 for the evidence trail): header relocation,
# all 14 RNG call sites (all X_RAND2 -- zero X_RAND1 sites on this cart), and
# all 3 timer-API shim sites are decoded and confirmed in the dis1600
# listing. `make verify-patch` proves exactly the 38 words below differ from
# the original ROM.
#
# NO shadow-pair patch is needed on this cart (M1c): input reaches game code
# entirely through the EXEC's own $035D dispatch + R1 controller-index
# handoff, confirmed live -- zero $011F-$0124 reads anywhere in the cart's
# own code.
{
    # --- Cart header ---
    # $5002/$5003: EXEC timer table pointer -> relocated table at $6800 seg.
    0x5002: "NEW_TIMER_TBL AND $FF",
    0x5003: "NEW_TIMER_TBL SHR 8",
    # $5004/$5005: start-of-game vector -> netcode init shim (falls through
    # to the original .START at $506B).
    0x5004: "NET_START AND $FF",
    0x5005: "NET_START SHR 8",

    # --- RNG call sites -> canonical-RNG wrapper ---
    # X_RAND2 ($169E), 14 sites -- the most of any port in this family to
    # date (previous record: Armor Battle's 9).  Each JSR R5,target is the
    # 3-word form (opcode word unpatched; the following two words encode
    # the target as ((target SHR 10) SHL 2) OR $0100, target AND $3FF).
    0x5B23: "((SS_RAND2 SHR 10) SHL 2) OR $0100",
    0x5B24: "SS_RAND2 AND $3FF",
    0x5E62: "((SS_RAND2 SHR 10) SHL 2) OR $0100",
    0x5E63: "SS_RAND2 AND $3FF",
    0x5E87: "((SS_RAND2 SHR 10) SHL 2) OR $0100",
    0x5E88: "SS_RAND2 AND $3FF",
    0x5E96: "((SS_RAND2 SHR 10) SHL 2) OR $0100",
    0x5E97: "SS_RAND2 AND $3FF",
    0x5EEC: "((SS_RAND2 SHR 10) SHL 2) OR $0100",
    0x5EED: "SS_RAND2 AND $3FF",
    0x5F0F: "((SS_RAND2 SHR 10) SHL 2) OR $0100",
    0x5F10: "SS_RAND2 AND $3FF",
    0x5F22: "((SS_RAND2 SHR 10) SHL 2) OR $0100",
    0x5F23: "SS_RAND2 AND $3FF",
    0x5FB3: "((SS_RAND2 SHR 10) SHL 2) OR $0100",
    0x5FB4: "SS_RAND2 AND $3FF",
    0x5FE0: "((SS_RAND2 SHR 10) SHL 2) OR $0100",
    0x5FE1: "SS_RAND2 AND $3FF",
    0x5FFE: "((SS_RAND2 SHR 10) SHL 2) OR $0100",
    0x5FFF: "SS_RAND2 AND $3FF",
    0x6037: "((SS_RAND2 SHR 10) SHL 2) OR $0100",
    0x6038: "SS_RAND2 AND $3FF",
    0x6079: "((SS_RAND2 SHR 10) SHL 2) OR $0100",
    0x607A: "SS_RAND2 AND $3FF",
    0x6096: "((SS_RAND2 SHR 10) SHL 2) OR $0100",
    0x6097: "SS_RAND2 AND $3FF",
    0x60A8: "((SS_RAND2 SHR 10) SHL 2) OR $0100",
    0x60A9: "SS_RAND2 AND $3FF",

    # --- Timer-arm/stop sites -> virtualized-flag shims ---
    # All three sites call the REAL EXEC entry point (X_TIMER_STOP=$1838 or
    # X_TIMER_START=$1844) with R1 = the ORIGINAL header table's slot
    # address ($5020/$5024/$5028/$502C/$5030 -- stale once the table is
    # relocated, since both entry points resolve R1 against the header
    # pointer, which now points at NEW_TIMER_TBL).  Retargeted to
    # SS_ARM_SHIM/SS_STOP_SHIM, which dispatch on the still-meaningful
    # stale R1 value to flip the matching virtualized SS_ARMn flag.
    #
    # STOP-ALL site ($51A2's loop, $51A7): walks R1 across all FIVE slots
    # in one call site via ADDI #4,R1 each iteration -- the shim must
    # preserve R1/R2, matching the family's stop-all-loop precedent
    # (Golf's $503B, Bowling's $1831-set-countdown loop, PORTING.md §7.24).
    0x51A8: "((SS_STOP_SHIM SHR 10) SHL 2) OR $0100",
    0x51A9: "SS_STOP_SHIM AND $3FF",
    # START-ALL site ($51B3's loop, $51B8): matching shape, all five slots.
    0x51B9: "((SS_ARM_SHIM SHR 10) SHL 2) OR $0100",
    0x51BA: "SS_ARM_SHIM AND $3FF",
    # Single-slot STOP site ($628D): R1 is always $5028 (slot 3, the bite/
    # collision entry) here -- fires once, at game over, disarming ONLY
    # the collision-resolution entry while the others keep running.
    0x628E: "((SS_STOP_SHIM SHR 10) SHL 2) OR $0100",
    0x628F: "SS_STOP_SHIM AND $3FF",
}
