# Tang Nano 20K + RP2350 VDP 開発用 Makefile
# ツールはすべて Docker コンテナ内で実行する (make images で事前にビルド)

FPGA_IMAGE ?= tang-fpga:latest
PICO_IMAGE ?= tang-pico:latest

DOCKER_RUN := docker run --rm -v "$(CURDIR)":/work -w /work --user $(shell id -u):$(shell id -g)
FPGA       := $(DOCKER_RUN) $(FPGA_IMAGE)
PICO       := $(DOCKER_RUN) $(PICO_IMAGE)

# --- FPGA ---
# ビットストリームは 4 つ (成果物は build/<名前>/)。フラッシュには vdp と gpu3d の組を置き、RECONFIG で入れ替える:
#   vdp    VDP (top.sv、HDMI)。フラッシュの 0x000000 (電源を入れるとこれ)。次は 0x100000
#   gpu3d  3D GPU (top.sv の GPU3D = 1、docs/GPU3D_PLAN.md)。フラッシュの 0x100000。次は 0x000000
#   lcd    40 ピン RGB LCD (800x480) にテストパターン (top_lcd.sv。HDMI とピンを共用しているので別)
#   probe  ハーネスの配線テスト (top_harness_probe.sv)
# 再コンフィグ (multiboot): それぞれ相手の番地を「次のビットストリーム」にし (gowin_pack --multiboot_address)、設計が RECONFIG_N (ピン 9) を
# Low にして切り替える (vdp_regs の RECONFIG、harness.py reconfig)。gowin_pack の --reconfign_as_gpio は付けない:
# 付けるとピンが GPIO になって、Low にしても再コンフィグしない (実機で確かめた)。付けなくても設計の出力はピンを駆動でき、再コンフィグの入力として効く
DESIGNS := vdp gpu3d lcd probe
vdp_TOP     := top
vdp_CST     := constraints/tangnano20k.cst
vdp_PARAMS  :=
vdp_PACK    := --multiboot_address 0x100000
vdp_FLASH   := 0x000000
gpu3d_TOP    := top
gpu3d_CST    := constraints/tangnano20k.cst
gpu3d_PARAMS := -G GPU3D=1 $(if $(filter 1,$(MUL_PROBE)),-G MUL_PROBE=1)
gpu3d_PACK   := --multiboot_address 0x000000
gpu3d_FLASH  := 0x100000
gpu3d_STRICT := 1                # 真のデュアルポートの BSRAM の番地が FF から直接でなければ止める (scripts/bsram_check.py)
lcd_TOP     := top_lcd
lcd_CST     := constraints/tangnano20k_lcd.cst
probe_TOP   := top_harness_probe
probe_CST   := constraints/tangnano20k_harness_probe.cst

ifneq ($(origin TARGET),undefined)
$(error TARGET はなくなりました: make bitstream (vdp と gpu3d)、make bitstream-<vdp|gpu3d|lcd|probe>、make prog / prog-3d / prog-lcd / prog-probe、make flash)
endif

DEVICE   := GW2AR-LV18QN88C8/I7
FAMILY   := GW2A-18C
BOARD    := tangnano20k

VDP_SRC   := $(wildcard rtl/vdp/*.sv)
GPU3D_SRC := $(wildcard rtl/gpu3d/*.sv)
RTL_SRC   := $(VDP_SRC) $(GPU3D_SRC)            # ベンダ非依存の RTL (シミュレーションと lint)
GOWIN_SRC := $(wildcard rtl/gowin/*.sv)
GOWIN_BB  := $(wildcard rtl/gowin/blackbox/*.sv)   # 合成専用のプリミティブ定義
SYN_SRC   := $(RTL_SRC) $(GOWIN_SRC)

TBS      := $(basename $(notdir $(wildcard sim/tb_*.sv)))
SIM_LIB  := $(filter-out sim/tb_%.sv,$(wildcard sim/*.sv))   # テストベンチが使うモデル (sdram_model など)
SIM      ?= iverilog            # iverilog | verilator
FRAMES   ?= 3
FREEZE   ?= 0                   # 1: アニメーションを止めて描く (実機の FRAME_CRC と比べる参照用)

BUILD    := build

# --- ハーネス (docs/HARNESS.md) ---
HARNESS_PINS     := harness/pins.json
HARNESS_BOARD    ?= waveshare_rp2040_zero
HARNESS_PLATFORM ?= rp2040
HARNESS_FW_BUILD := harness/firmware/build
HARNESS_UF2      := $(HARNESS_FW_BUILD)/harness_bridge.uf2
RP2_MOUNT         = $(firstword $(wildcard /Volumes/RPI-RP2 /Volumes/RP2350 /media/*/RPI-RP2 /media/*/RP2350))

# --- RP2350 ---
PICO_BOARD    ?= pico2
PICO_PLATFORM ?= rp2350-arm-s   # rp2350-riscv にすると Hazard3 コア用

.PHONY: timing-repro help images image-fpga image-pico all lint sim scenario $(addprefix sim-,$(TBS)) render render-lcd \
	bitstream $(addprefix bitstream-,$(DESIGNS)) $(addprefix pincheck-,$(DESIGNS)) prog prog-3d prog-gpu3d prog-lcd prog-probe flash \
	demo fw harness-fw harness-deploy shell shell-pico zip clean

help:
	@echo "make images      Docker イメージをビルド (image-fpga / image-pico で個別に)"
	@echo "make lint        Verilator で RTL を lint"
	@echo "make sim         テストベンチを全部実行 (SIM=iverilog|verilator, VCD は build/sim/)"
	@echo "make sim-<tb>    個別テストベンチ実行 (例: make sim-tb_tmds_encoder)"
	@echo "make scenario    シナリオ (SCENARIO=scenarios/*.json) をシステム全体の RTL で走らせ、参照モデルの CRC と比べる"
	@echo "                 scenarios/gpu3d/ のシナリオは 3D GPU の構成で走る"
	@echo "make render      Verilator で映像出力を PNG 化 (build/render/, FRAMES=$(FRAMES))。make render-lcd で 800x480"
	@echo "                 FREEZE=1 でアニメーションを止めた参照画像と CRC (frames.json) を build/render_frozen/ に"
	@echo "make bitstream   VDP と 3D GPU のビットストリーム (build/vdp/top.fs、build/gpu3d/top.fs)。1 つだけなら make bitstream-<vdp|gpu3d|lcd|probe>"
	@echo "make prog        VDP を SRAM に書き込み (make prog-3d / prog-lcd / prog-probe。ホストの openFPGALoader が必要。pincheck 込み)"
	@echo "make flash       VDP (0x000000) と 3D GPU (0x100000) をフラッシュに。電源を入れると VDP、harness.py reconfig で入れ替わる"
	@echo "make demo        デモをハーネス経由で流す (既定は Ctrl-C まで、FRAMES=N で N フレーム。ホストの python3)"
	@echo "                 SCENE=logo|tunnel|room|city で 3D の場面、SCENE=all で 4 つを 10 秒ずつくり返す。なければ M9 のデモ (VDP)。"
	@echo "                 動いているビットストリームが違えば RECONFIG で切り替える (make flash で両方を書いておく)"
	@echo "make harness-fw  ハーネスの RP2 ブリッジファームウェア (HARNESS_BOARD=$(HARNESS_BOARD))"
	@echo "make harness-deploy  BOOTSEL の RP2 に書き込む (ホストで実行)"
	@echo "make fw          RP2350 ファームウェアをビルド (firmware/build/*.uf2)"
	@echo "make shell       FPGA ツールコンテナのシェル"
	@echo "make shell-pico  RP2350 ツールコンテナのシェル"
	@echo "make zip         別環境へ持っていくためのソース一式を $(ZIP) に作成"

all: lint sim render bitstream fw

# 社内プロキシの CA。無ければ空ファイルを作る (Dockerfile 側で空ならスキップ)
CA_CERT ?= $(HOME)/.zscaler/certs.pem

certs.pem:
	@if [ -f "$(CA_CERT)" ]; then \
		cp "$(CA_CERT)" certs.pem; \
		echo "Copied certs.pem from $(CA_CERT)"; \
	else \
		touch certs.pem; \
		echo "No CA cert found, created empty certs.pem"; \
	fi

# メモリを食うので 2 つのイメージは順番にビルドする
images: image-fpga image-pico

image-fpga: certs.pem
	docker build --secret id=ca_cert,src=certs.pem -t $(FPGA_IMAGE) docker/fpga

image-pico: certs.pem
	docker build --secret id=ca_cert,src=certs.pem -t $(PICO_IMAGE) docker/pico

$(BUILD)/sim:
	@mkdir -p $@

# ---------------------------------------------------------------- 検証
lint:
	$(FPGA) verilator --lint-only -Wall --top-module vdp_video -GMODE=0 $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module vdp_video -GMODE=1 $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module spi_slave $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module vdp_regs $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module sdram_ctrl $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module mem_test $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module sdram_arb $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module line_compositor $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module tile_layer $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module sprite_layer $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module audio_out $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module mode7_layer $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module gpu $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module fb_line $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module mul_probe $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module smul36x18 $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module tri_setup $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module tri_engine $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module tile_engine $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module raster3d $(RTL_SRC)
	$(FPGA) verilator --lint-only -Wall --top-module gpu -GGPU3D=1 $(RTL_SRC)

sim: $(addprefix sim-,$(TBS))

$(addprefix sim-,$(TBS)): sim-%: sim/%.sv $(RTL_SRC) $(SIM_LIB) | $(BUILD)/sim
ifeq ($(strip $(SIM)),verilator)
	$(FPGA) verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style \
		--top-module $* -Mdir $(BUILD)/sim/obj_$* -o $* $< $(RTL_SRC) $(SIM_LIB)
	$(FPGA) $(BUILD)/sim/obj_$*/$*
else
	$(FPGA) iverilog -g2012 -Wall -Wno-timescale -o $(BUILD)/sim/$*.vvp -s $* $< $(RTL_SRC) $(SIM_LIB)
	$(FPGA) vvp -n $(BUILD)/sim/$*.vvp
endif

# 映像を PNG に (VIDEO_MODE は vdp_video の MODE: 0 は 640x480、1 は 800x480 の LCD)
render:     RENDER_DIR := build/render$(if $(filter 1,$(strip $(FREEZE))),_frozen)
render:     VIDEO_MODE := 0
render-lcd: RENDER_DIR := build/render_lcd$(if $(filter 1,$(strip $(FREEZE))),_frozen)
render-lcd: VIDEO_MODE := 1
render render-lcd:
	@mkdir -p $(RENDER_DIR)
	$(FPGA) verilator --cc --exe --build -j 0 -O2 -Wno-fatal \
		--top-module vdp_video -GMODE=$(VIDEO_MODE) -Mdir $(RENDER_DIR)/obj -o render \
		$(VDP_SRC) sim/verilator/render_main.cpp
	$(FPGA) $(RENDER_DIR)/obj/render $(RENDER_DIR) $(FRAMES) $(strip $(FREEZE))
	$(FPGA) python3 scripts/ppm2png.py $(RENDER_DIR)/*.ppm
	@rm -f $(RENDER_DIR)/*.ppm

# シナリオをシステム全体の RTL (Verilator) で走らせ、参照モデル (tools/harness/gpu_model.py) と比べる
# scenarios/gpu3d/ のシナリオは 3D GPU の構成 (GPU3D = 1) で走らせる
SCENARIO ?= scenarios/m5_basic.json
SCN_3D    = $(findstring scenarios/gpu3d/,$(SCENARIO))
SCN_SUFFIX = $(if $(SCN_3D),_gpu3d)
SCN_PARAMS = $(if $(SCN_3D),-GGPU3D=1)
SCN_DIR   = $(BUILD)/scenario$(SCN_SUFFIX)/$(basename $(notdir $(SCENARIO)))

scenario:
	@mkdir -p $(SCN_DIR)
	$(FPGA) python3 tools/harness/gpu_model.py export $(SCENARIO) $(SCN_DIR)
	$(FPGA) verilator --binary --timing -O2 -Wno-fatal -Wno-lint -Wno-style \
		--top-module gpu_scenario_tb $(SCN_PARAMS) -Mdir $(BUILD)/scenario$(SCN_SUFFIX)/obj -o gpu_scenario \
		sim/scenario/gpu_scenario_tb.sv $(RTL_SRC) $(SIM_LIB)
	$(FPGA) $(BUILD)/scenario$(SCN_SUFFIX)/obj/gpu_scenario +cmds=$(SCN_DIR)/cmds.hex +checks=$(SCN_DIR)/checks.txt +out=$(SCN_DIR)
	$(FPGA) python3 tools/harness/gpu_model.py compare $(SCENARIO) $(SCN_DIR)

# ---------------------------------------------------------------- 実装
bitstream: build/vdp/top.fs build/gpu3d/top.fs
bitstream-vdp:   build/vdp/top.fs
bitstream-gpu3d: build/gpu3d/top.fs
bitstream-lcd:   build/lcd/top_lcd.fs
bitstream-probe: build/probe/top_harness_probe.fs

# 設計ごとの規則 (合成 → 配置配線 → ビットストリーム → pincheck)。$(1) は設計の名前
# SystemVerilog は yosys-slang プラグイン (read_slang) で読む。
# -nolutram: LUT の RAM (RAM16SDP4) は実機で値が化ける (docs/GPU3D_PLAN.md の G1)。小さい配列はフリップフロップか BSRAM に置く
define design_rules
build/$(1)/$$($(1)_TOP).json: $$(SYN_SRC) $$(GOWIN_BB)
	@mkdir -p build/$(1)
	$$(FPGA) yosys -m slang -q -l build/$(1)/$$($(1)_TOP)_yosys.log \
		-p "read_slang --top $$($(1)_TOP) $$($(1)_PARAMS) $$(SYN_SRC) $$(GOWIN_BB); synth_gowin -family gw2a -nolutram -top $$($(1)_TOP) -json $$@"
	$$(FPGA) python3 scripts/fix_netlist.py $$@ $$($(1)_TOP)
	@# 真のデュアルポートの BSRAM の番地に論理が挟まっていないか (nextpnr はそのタイミングを見ない)。3D は止める、ほかは報告だけ
	$$(FPGA) python3 scripts/bsram_check.py $$@ $$(if $$($(1)_STRICT),,|| true)

build/$(1)/$$($(1)_TOP)_pnr.json: build/$(1)/$$($(1)_TOP).json $$($(1)_CST)
	$$(FPGA) nextpnr-himbaechel -q -l build/$(1)/$$($(1)_TOP)_nextpnr.log \
		--json $$< --write $$@ --device $$(DEVICE) \
		--vopt family=$$(FAMILY) --vopt cst=$$($(1)_CST) --vopt sspi_as_gpio

build/$(1)/$$($(1)_TOP).fs: build/$(1)/$$($(1)_TOP)_pnr.json
	$$(FPGA) gowin_pack -d $$(FAMILY) --sspi_as_gpio $$($(1)_PACK) -o $$@ $$<
	@grep -A30 'Device utilisation' build/$(1)/$$($(1)_TOP)_nextpnr.log | grep -E 'LUT|DFF|BSRAM|PLL|OSER|IOB' || true
	@grep -E 'Max frequency' build/$(1)/$$($(1)_TOP)_nextpnr.log | tail -n 4 || true

# ハーネスが駆動するピン (harness/pins.json) を FPGA も駆動しようとしていないか検査する。
# ハーネスがつながっている前提なので、prog / flash は必ずこれを通してから書き込む
pincheck-$(1): build/$(1)/$$($(1)_TOP).fs
	$$(FPGA) python3 scripts/pincheck.py $$(HARNESS_PINS) $$($(1)_CST) build/$(1)/$$($(1)_TOP).json $$<
endef
$(foreach d,$(DESIGNS),$(eval $(call design_rules,$(d))))

# Docker Desktop (macOS) のコンテナからは USB が見えないので書き込みだけはホストで行う
prog: pincheck-vdp
	openFPGALoader -b $(BOARD) build/vdp/top.fs
prog-3d prog-gpu3d: pincheck-gpu3d
	openFPGALoader -b $(BOARD) build/gpu3d/top.fs
prog-lcd: pincheck-lcd
	openFPGALoader -b $(BOARD) build/lcd/top_lcd.fs
prog-probe: pincheck-probe
	openFPGALoader -b $(BOARD) build/probe/top_harness_probe.fs

# フラッシュ: VDP を 0x000000、3D GPU を 0x100000 に (電源を入れると VDP。RECONFIG で入れ替わる)
flash: pincheck-vdp pincheck-gpu3d
	openFPGALoader -b $(BOARD) -f --offset $(vdp_FLASH) build/vdp/top.fs
	openFPGALoader -b $(BOARD) -f --offset $(gpu3d_FLASH) build/gpu3d/top.fs

# デモ: ハーネス (USB) を使うのでホストで動かす。SCENE なしは M9 のデモ (VDP)、SCENE=logo/tunnel/room/city/all は G5 の 3D の場面 (3D GPU)。
# 動いているビットストリームが違えば harness.py が RECONFIG で切り替える
# FRAMES は make render の既定 (3) と共用なので、コマンドラインで指定したときだけ使う (既定は 0 = Ctrl-C まで)
DEMO_FRAMES = $(if $(filter command line,$(origin FRAMES)),$(FRAMES),0)
demo:
	python3 tools/harness/harness.py demo $(SCENE) --frames $(DEMO_FRAMES)

# ---------------------------------------------------------------- RP2350
fw:
	$(PICO) sh -c 'cmake -S firmware -B firmware/build -G Ninja \
		-DPICO_BOARD=$(strip $(PICO_BOARD)) -DPICO_PLATFORM=$(strip $(PICO_PLATFORM)) \
		&& cmake --build firmware/build'
	@ls firmware/build/*.uf2

# ---------------------------------------------------------------- ハーネス
# ピン定義は harness/pins.json から生成する (ファームウェア側で手書きしない)
harness-fw:
	@mkdir -p $(HARNESS_FW_BUILD)
	$(PICO) python3 scripts/gen_pins_h.py $(HARNESS_PINS) $(HARNESS_FW_BUILD)/pins.h
	$(PICO) sh -c 'cmake -S harness/firmware -B $(HARNESS_FW_BUILD) -G Ninja \
		-DPICO_BOARD=$(strip $(HARNESS_BOARD)) -DPICO_PLATFORM=$(strip $(HARNESS_PLATFORM)) \
		&& cmake --build $(HARNESS_FW_BUILD)'
	@ls $(HARNESS_UF2)

# BOOTSEL で出てくるドライブに UF2 をコピーする (コンテナから USB は見えないのでホストで実行)
harness-deploy: harness-fw
	@if [ -z "$(RP2_MOUNT)" ]; then echo "RP2 の BOOTSEL ドライブが見つかりません (BOOT を押しながら USB をつなぐ)"; exit 1; fi
	cp $(HARNESS_UF2) $(RP2_MOUNT)/
	@echo "-> $(RP2_MOUNT)"

# nextpnr の Gowin のタイミング解析の確かめ (docs/NEXTPNR_GOWIN_TIMING.md)。配置のあとと配線のあとの Max frequency を並べる
TIMING_REPRO := tools/repro/nextpnr_gowin_timing
timing-repro:
	@for v in "16 0" "16 1" "32 0" "32 1" "32 2"; do \
		set -- $$v; \
		docker run --rm -v "$(CURDIR)":/work -w /work/$(TIMING_REPRO) --user $$(id -u):$$(id -g) $(FPGA_IMAGE) bash run.sh $$1 $$2 >/dev/null 2>&1; \
		printf "W=%-2s WCHAIN=%s  %s\n" $$1 $$2 "$$(grep -o "Max frequency[^(]*" $(TIMING_REPRO)/c_$$1_$$2.log | sed 's/.*: //' | paste -sd' ' - | sed 's/ MHz /  ->  /')"; \
	done

# ---------------------------------------------------------------- その他
shell:
	docker run --rm -it -v "$(CURDIR)":/work -w /work $(FPGA_IMAGE) bash

shell-pico:
	docker run --rm -it -v "$(CURDIR)":/work -w /work $(PICO_IMAGE) bash

# git 管理下のファイルと、未追跡でも .gitignore されていないファイルをまとめる
# (ビルド成果物や certs.pem は含まない)。展開すると $(NAME)/ 以下に出てくる。
# git と zip だけ使うのでホストで実行する。
NAME := $(notdir $(CURDIR))
ZIP  := dist/$(NAME).zip

zip:
	@mkdir -p dist
	@rm -f $(ZIP)
	cd .. && git -C $(NAME) ls-files -co --exclude-standard \
		| while read -r f; do [ -e "$(NAME)/$$f" ] && echo "$(NAME)/$$f"; done \
		| zip -q $(CURDIR)/$(ZIP) -@
	@unzip -l $(ZIP) | tail -n 1
	@echo "-> $(ZIP)"

clean:
	rm -rf $(BUILD) firmware/build $(HARNESS_FW_BUILD) certs.pem dist
