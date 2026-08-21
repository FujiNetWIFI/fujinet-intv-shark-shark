# Networked Intellivision Shark! Shark! (Mattel 1982) over FujiNet.
# 1-2 player lockstep netplay, simultaneous (no turn arbiter -- the cart's
# own boot prompt hard-caps player count at 2).

AS1600   ?= as1600
DIS1600  ?= dis1600
BIN2ROM  ?= bin2rom
JZINTV   ?= $(HOME)/Workspace/jzintv-20200712-src/bin/jzintv
PYTHON   ?= python3

GAME     := sharkshark
ROM_ORG  := rom/SharkShark.bin
EXEC     := rom/exec.bin
GROM     := rom/grom.bin
BUILD    := build

# Dummy SDL drivers for headless/automated runs; `make run*` targets use real video.
HEADLESS := SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy

JZFLAGS  := -e $(EXEC) -g $(GROM) -z 6

# Where the ORIGINAL cart image ends: this is the first 8K-word cart in the
# family (every prior port was 4K), and it already owns $6000-$6FFF -- the
# page every prior port's hook.asm ORG'd at.  Real code runs through $67F9;
# $67FA-$6FFF is zero fill.  The patched dump therefore stops at $67F9 (6138
# words from $5000) and hook.asm takes over from $6800, leaving a clean
# 2048-word margin above the fatal $7000 boundary (PORTING.md §7.22).
# verify-org's UNPATCHED dump always covers the full original image and does
# not use this.
CART_STOP    := 67FA
CART_STOP_LEN := 6138

.PHONY: all verify-org run-org clean lobby rig peerleft m4 recon \
        relay-c server-diff hook virt lag lag0 net dis rom rom-hud \
        lagcheck verify-patch echo-test check-7000 run-hook run-virt \
        run-lag run-rec run-net1 run-net2

all: verify-org

$(BUILD):
	mkdir -p $(BUILD)

# ---------------------------------------------------------------------------
# verify-org: regenerate an unpatched dump, assemble, require byte-identity
# with the original ROM.  Guards against dump/toolchain drift forever.
# ---------------------------------------------------------------------------
$(BUILD)/org_plain.asm: $(ROM_ORG) tools/dump_rom.py | $(BUILD)
	$(PYTHON) tools/dump_rom.py $(ROM_ORG) 5000 $@

$(BUILD)/org.bin: $(BUILD)/org_plain.asm
	$(AS1600) -o $@ -l $(BUILD)/org.lst $<

verify-org: $(BUILD)/org.bin
	cmp $(ROM_ORG) $(BUILD)/org.bin
	@echo "verify-org: byte-identical"

run-org: $(BUILD)/org.bin
	$(JZINTV) $(JZFLAGS) $(BUILD)/org.bin

# ---------------------------------------------------------------------------
# Hooked builds: patched original + netcode segment at $6800 (the cart's own
# unused tail past $67F9 -- see CART_STOP above; every prior port used $6000
# because its cart image ended at $5FFF).
#   hook = pass-through shadow inputs (must feel stock)
#   lag  = 1-second input delay ring (interception proof)
# ---------------------------------------------------------------------------
$(BUILD)/$(GAME)_patched.asm: $(ROM_ORG) tools/dump_rom.py tools/patches.py | $(BUILD)
	$(PYTHON) tools/dump_rom.py $(ROM_ORG) 5000 $@ tools/patches.py --stop $(CART_STOP)

# PiRTO II cart RAM.  Only up to $9BFF: the FujiNet mailbox owns $9C00-$9FFF
# and declaring it breaks jzIntv's --fujinet peripheral (AND-ed bus reads).
define CART_RAM_CFG
[memattr]
$$8000 - $$9BFF = RAM 8
endef
export CART_RAM_CFG

HOOK_SRCS := src/core.asm src/hook.asm src/vdispatch.asm src/ram.asm src/exec_equ.asm

$(BUILD)/$(GAME)_hook.bin: $(BUILD)/$(GAME)_patched.asm src/main_hook.asm $(HOOK_SRCS)
	$(AS1600) -o $@ -l $(BUILD)/$(GAME)_hook.lst -s $(BUILD)/$(GAME)_hook.sym src/main_hook.asm
	echo "$$CART_RAM_CFG" >> $(BUILD)/$(GAME)_hook.cfg

$(BUILD)/$(GAME)_virt.bin: $(BUILD)/$(GAME)_patched.asm src/main_virt.asm $(HOOK_SRCS)
	$(AS1600) -o $@ -l $(BUILD)/$(GAME)_virt.lst -s $(BUILD)/$(GAME)_virt.sym src/main_virt.asm
	echo "$$CART_RAM_CFG" >> $(BUILD)/$(GAME)_virt.cfg

$(BUILD)/$(GAME)_lag.bin: $(BUILD)/$(GAME)_patched.asm src/main_lag.asm $(HOOK_SRCS) src/debug.asm
	$(AS1600) -o $@ -l $(BUILD)/$(GAME)_lag.lst -s $(BUILD)/$(GAME)_lag.sym src/main_lag.asm
	echo "$$CART_RAM_CFG" >> $(BUILD)/$(GAME)_lag.cfg

$(BUILD)/$(GAME)_lag0.bin: $(BUILD)/$(GAME)_patched.asm src/main_lag0.asm $(HOOK_SRCS) src/debug.asm
	$(AS1600) -o $@ -l $(BUILD)/$(GAME)_lag0.lst -s $(BUILD)/$(GAME)_lag0.sym src/main_lag0.asm
	echo "$$CART_RAM_CFG" >> $(BUILD)/$(GAME)_lag0.cfg

# M4 gate: the same in-ROM script at d=0 vs d=20 -- the first key must
# land in game state exactly the delay depth later.
lagcheck: $(BUILD)/$(GAME)_lag.bin $(BUILD)/$(GAME)_lag0.bin
	test/run_lagcheck.sh

# Only the declared patch sites may differ from the original in $5000-$67F9
# (the patched dump's own extent -- $67FA-$6FFF is hook.asm's, not a patch
# site, and must not be compared word-for-word against the original zero fill).
verify-patch: $(BUILD)/$(GAME)_hook.bin $(BUILD)/org.bin
	$(PYTHON) tools/check_patch.py $(BUILD)/org.bin $(BUILD)/$(GAME)_hook.bin tools/patches.py $(CART_STOP_LEN)

hook: $(BUILD)/$(GAME)_hook.bin verify-patch
virt: $(BUILD)/$(GAME)_virt.bin
lag: $(BUILD)/$(GAME)_lag.bin

run-hook: hook
	$(JZINTV) $(JZFLAGS) $(BUILD)/$(GAME)_hook.bin

run-virt: virt
	$(JZINTV) $(JZFLAGS) $(BUILD)/$(GAME)_virt.bin

run-lag: lag
	$(JZINTV) $(JZFLAGS) $(BUILD)/$(GAME)_lag.bin

# ---------------------------------------------------------------------------
# Determinism spike: two builds, identical scripted inputs, run B stalls the
# sim 3/64 frames.  Per-sim-tick state checksums must match exactly.
# ---------------------------------------------------------------------------
$(BUILD)/$(GAME)_det_%.bin: $(BUILD)/$(GAME)_patched.asm src/main_det_%.asm $(HOOK_SRCS) src/debug.asm
	$(AS1600) -o $@ -l $(basename $@).lst -s $(basename $@).sym src/main_det_$*.asm
	echo "$$CART_RAM_CFG" >> $(basename $@).cfg

det: $(BUILD)/$(GAME)_det_a.bin $(BUILD)/$(GAME)_det_b.bin
	tools/run_det.sh a
	tools/run_det.sh b
	$(PYTHON) tools/crc_trace_diff.py $(BUILD)/det_a.out $(BUILD)/det_b.out
	$(PYTHON) tools/check_dest_phase.py $(BUILD)/det_a.out

# ---------------------------------------------------------------------------
# Transport spike: TCP echo through jzintv --fujinet -> fujinet-pc (BOIP).
# Needs a running fujinet-pc rs232 build; port via FN_BOIP (default 9995,
# the workspace instance).
# ---------------------------------------------------------------------------
$(BUILD)/$(GAME)_echo.bin: $(BUILD)/$(GAME)_patched.asm src/main_echo.asm $(HOOK_SRCS) src/echo.asm src/netcode/mailbox.asm
	$(AS1600) -o $@ -l $(BUILD)/$(GAME)_echo.lst -s $(BUILD)/$(GAME)_echo.sym src/main_echo.asm
	echo "$$CART_RAM_CFG" >> $(BUILD)/$(GAME)_echo.cfg

echo-test: $(BUILD)/$(GAME)_echo.bin
	tools/run_echo.sh

# Record build: play interactively, F4 -> debugger, `m 8100 20` + `m 9000 800`,
# save the session log, then tools/mk_replay.py log > src/replay_data.asm
$(BUILD)/$(GAME)_rec.bin: $(BUILD)/$(GAME)_patched.asm src/main_rec.asm $(HOOK_SRCS) src/netcode/mailbox.asm
	$(AS1600) -o $@ -l $(BUILD)/$(GAME)_rec.lst -s $(BUILD)/$(GAME)_rec.sym src/main_rec.asm
	echo "$$CART_RAM_CFG" >> $(BUILD)/$(GAME)_rec.cfg

run-rec: $(BUILD)/$(GAME)_rec.bin
	$(JZINTV) -d $(JZFLAGS) $(BUILD)/$(GAME)_rec.bin

# ---------------------------------------------------------------------------
# Netplay build (login/lobby + lockstep).  run-net1/run-net2 attach to the
# two BOIP instances of the local rig (see test/run_rig.sh).
# ---------------------------------------------------------------------------
# Netplay server endpoint compiled into the client.
SRV_HOST ?= fujinet.online
SRV_PORT ?= 9113

$(BUILD)/srv_endpoint.asm: FORCE | $(BUILD)
	@printf 'SRV_SPEC:\n        STRING  "N:TCP://%s:%s/"\nSRV_SPEC_LEN    EQU     %d\n' \
	    "$(SRV_HOST)" "$(SRV_PORT)" \
	    $$(printf 'N:TCP://%s:%s/' "$(SRV_HOST)" "$(SRV_PORT)" | wc -c) \
	    > $@.tmp
	@cmp -s $@.tmp $@ || mv $@.tmp $@
	@rm -f $@.tmp

FORCE:

NET_SRCS := src/main_net.asm $(HOOK_SRCS) src/netcode/mailbox.asm \
            src/netcode/server_cfg.asm src/netcode/session.asm \
            src/netcode/lockstep.asm src/netcode/resync.asm \
            src/netcode/hud.asm \
            src/ui/text.asm src/ram.asm src/exec_equ.asm \
            $(BUILD)/srv_endpoint.asm

$(BUILD)/$(GAME)_net.bin: $(BUILD)/$(GAME)_patched.asm $(NET_SRCS)
	$(AS1600) -o $@ -l $(BUILD)/$(GAME)_net.lst -s $(BUILD)/$(GAME)_net.sym src/main_net.asm
	echo "$$CART_RAM_CFG" >> $(BUILD)/$(GAME)_net.cfg

$(BUILD)/$(GAME)_net%.bin: $(BUILD)/$(GAME)_patched.asm src/main_net%.asm $(NET_SRCS)
	$(AS1600) -o $@ -l $(basename $@).lst -s $(basename $@).sym src/main_net$*.asm
	echo "$$CART_RAM_CFG" >> $(basename $@).cfg

# No build's segment may map, or overflow into, $7000: the EXEC boot
# EXECUTES whatever is there (the ECS expansion hook).  Caught live on an
# earlier port: net builds booted or crashed purely on which instruction
# their $7000 word happened to encode.  This cart's hook.asm segment starts
# at $6800, only 2048 words below the boundary (every prior port started at
# $6000, twice the margin), so a span check -- not just a start-address
# grep -- is real insurance here.
check-7000:
	@$(PYTHON) tools/check_7000.py $(BUILD)/*.cfg

net: $(BUILD)/$(GAME)_net.bin check-7000

# .rom for real hardware (PiRTO II); build with SRV_HOST=<your server>
rom: $(BUILD)/$(GAME)_net.bin
	$(BIN2ROM) $(BUILD)/$(GAME)_net.bin
	@echo "hardware image: $(BUILD)/$(GAME)_net.rom"

# Bring-up variant with the live HUD row (L/S/T/R/H) for delay tuning.
$(BUILD)/$(GAME)_nethud.bin: $(BUILD)/$(GAME)_patched.asm src/main_nethud.asm $(NET_SRCS)
	$(AS1600) -o $@ -l $(BUILD)/$(GAME)_nethud.lst -s $(BUILD)/$(GAME)_nethud.sym src/main_nethud.asm
	echo "$$CART_RAM_CFG" >> $(BUILD)/$(GAME)_nethud.cfg

rom-hud: $(BUILD)/$(GAME)_nethud.bin
	$(BIN2ROM) $(BUILD)/$(GAME)_nethud.bin
	@echo "bring-up image (HUD on): $(BUILD)/$(GAME)_nethud.rom"

# The rig always builds/runs against the local server -- never the SRV_HOST
# default (a stale production endpoint here once sent fuzz inputs to the
# live server).  run_rig.sh independently refuses non-127.0.0.1 endpoints.
# This cart hard-caps at 2 players (its own boot prompt rejects >2), so
# PLAYERS is really just a fixed 2 here -- the $(GAME)_net%.bin pattern
# rule still scales generically, kept for consistency with the rest of
# the family rather than because a 3rd/4th seat is meaningful.
PLAYERS  ?= 2
RIG_BINS := $(foreach n,$(shell seq 1 $(PLAYERS)),$(BUILD)/$(GAME)_net$(n).bin)

# Which relay the gates run against.  py (default) is server/intv_relay_server.py,
# the canonical reference; c is the port in server/c/, which tools/server_diff.py
# holds to byte-for-byte equality with it.  `make rig SERVER=c` builds it first.
SERVER   ?= py
RELAY_C  := server/c/intv-relay
RELAY_DEP = $(if $(filter c,$(SERVER)),relay-c,)

$(RELAY_C): server/c/src/intv-relay.c server/c/src/lobby.c server/c/src/lobby.h \
            server/c/Makefile
	$(MAKE) -C server/c

relay-c: $(RELAY_C)

# The differential gate: both servers driven through identical scripted
# scenarios, every received frame and log line compared byte for byte.
server-diff: $(RELAY_C)
	$(PYTHON) tools/server_diff.py

rig: $(RELAY_DEP)
	$(MAKE) SRV_HOST=127.0.0.1 SRV_PORT=9113 $(RIG_BINS)
	$(MAKE) check-7000
	PLAYERS=$(PLAYERS) SERVER=$(SERVER) test/run_rig.sh

# Peer-left screen: the rig, with console 2 walking out mid-game.  The verdict
# decodes console 1's BACKTAB back into text.  LEAVE_MODE=timeout kills only
# the emulator (fujinet-pc holds the socket open) to exercise the
# "CONNECTION LOST" path instead of the server's PEER_LEFT.
# LEAVER=n, LEAVE_MODE=clean|timeout
peerleft: $(RELAY_DEP)
	$(MAKE) SRV_HOST=127.0.0.1 SRV_PORT=9113 $(RIG_BINS)
	$(MAKE) check-7000
	PLAYERS=$(PLAYERS) SERVER=$(SERVER) test/run_peerleft.sh

# Lobby/matchmaking UI: one interactive console against parked players, two of
# them already in a match.  Drives the menu from the debugger and
# decodes the BACKTAB (text + colour) after each keypress.
lobby: $(RELAY_DEP)
	$(MAKE) SRV_HOST=127.0.0.1 SRV_PORT=9113 $(BUILD)/$(GAME)_net.bin
	SERVER=$(SERVER) test/run_lobby.sh

# Desync recovery: fault-inject console 2, watch the whole room
# re-baseline together (the host's STATE push is a broadcast).  Reports
# whether the deferred push fired at the quiescent point or hit RS_PEND_MAX.
m4: $(RELAY_DEP)
	$(MAKE) SRV_HOST=127.0.0.1 SRV_PORT=9113 $(RIG_BINS)
	$(MAKE) check-7000
	PLAYERS=$(PLAYERS) SERVER=$(SERVER) test/run_m4.sh

run-net1: net
	$(JZINTV) $(JZFLAGS) --fujinet=localhost:9995 $(BUILD)/$(GAME)_net.bin

run-net2: net
	$(JZINTV) $(JZFLAGS) --fujinet=localhost:19852 $(BUILD)/$(GAME)_net.bin

# ---------------------------------------------------------------------------
# Disassembly references (regenerable analysis artifacts)
# ---------------------------------------------------------------------------
$(BUILD)/$(GAME).dis: $(ROM_ORG) | $(BUILD)
	$(DIS1600) $(ROM_ORG) $@ -f

$(BUILD)/exec.dis: $(EXEC) | $(BUILD)
	cp $(EXEC) $(BUILD)/exec_copy.bin
	printf '[mapping]\n$$0000 - $$0FFF = $$1000\n' > $(BUILD)/exec_copy.cfg
	$(DIS1600) -0 -e '$$1000' -e '$$1004' $(BUILD)/exec_copy.bin $@ -f

dis: $(BUILD)/$(GAME).dis $(BUILD)/exec.dis

# ---------------------------------------------------------------------------
# recon: port map for any EXEC cart -- hook points, tick rate, sites to patch.
# See PORTING.md.   make recon ROM="~/roms/Utopia.bin"
# ---------------------------------------------------------------------------
ROM ?= $(ROM_ORG)

recon:
	$(PYTHON) tools/recon.py "$(ROM)"

clean:
	rm -rf $(BUILD)
