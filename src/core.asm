; Common assembly core: EXEC equates, RAM map, patched original ROM, hook.
; Build flags each top-level main_*.asm must define:
;   SPIKE_VIRT    1 = virtualize the $035D dispatch locally (null the real
;                 scan's table, replay ring events through live handlers)
;   SPIKE_DELAY   virt-dispatch delay depth in game ticks (0 = same tick)
;   SPIKE_SCRIPT  1 = feed deterministic fuzz inputs instead of controllers
;   SPIKE_TRACE   1 = per-tick state checksum ring + park at TRACE_STOP
;   STALL_N       freeze the sim for N frames out of every 64 (0 = never)
        INCLUDE "src/exec_equ.asm"
        INCLUDE "src/ram.asm"
        INCLUDE "build/sharkshark_patched.asm"
        INCLUDE "src/hook.asm"
        INCLUDE "src/vdispatch.asm"
        INCLUDE "src/netcode/mailbox.asm"
    IF SPIKE_TRACE <> 0
        INCLUDE "src/debug.asm"
    ENDI
    IF SPIKE_ECHO <> 0
        INCLUDE "src/echo.asm"
    ENDI
    IF NET_SESSION <> 0
        ; The session/lockstep block lives at $D000 (the standard Mattel
        ; 16K cart window).  It must NOT continue at $7000: the EXEC boot
        ; EXECUTES whatever sits at $7000 (the expansion hook the ECS
        ; uses) -- PORTING.md §7.22, `make check-7000` guards it.  The
        ; $6800 page (not the family's usual $6000 -- this cart's own
        ; image already fills $5000-$67F9, the first 8K-word cart in the
        ; family) holds hook + vdispatch + mailbox and must stay under
        ; $7000.
        ORG     $D000
        INCLUDE "src/netcode/server_cfg.asm"
        INCLUDE "build/srv_endpoint.asm"
        INCLUDE "src/ui/text.asm"
        INCLUDE "src/netcode/session.asm"
        INCLUDE "src/netcode/lockstep.asm"
        INCLUDE "src/netcode/resync.asm"
      IF NET_HUD <> 0
        INCLUDE "src/netcode/hud.asm"
      ENDI
    ENDI
