# Tang Nano 20K + RP2350 VDP 開発用 Makefile
# ツールはすべて Docker コンテナ内で実行する (make images で事前にビルド)

FPGA_IMAGE ?= tang-fpga:latest
PICO_IMAGE ?= tang-pico:latest

DOCKER_RUN := docker run --rm -v "$(CURDIR)":/work -w /work --user $(shell id -u):$(shell id -g)
FPGA       := $(DOCKER_RUN) $(FPGA_IMAGE)
PICO       := $(DOCKER_RUN) $(PICO_IMAGE)

# --- FPGA ---
# TARGET でビルドするトップを選ぶ (HDMI と 40 ピン LCD はピンを共用しているので別のビットストリームにする)
# VIDEO_MODE は make render で使う vdp_video の MODE (0: 640x480, 1: 800x480)
# gpu3d は HDMI と同じトップ (top.sv) の GPU3D = 1 (VDP を外した 3D GPU のビットストリーム、docs/GPU3D_PLAN.md)。成果物は build/gpu3d/
TARGET   ?= hdmi                # hdmi | lcd | harness_probe | gpu3d
TOP_PARAMS :=
OUT_DIR    := build
# 再コンフィグ (multiboot): VDP をフラッシュの 0x000000、3D GPU を 0x100000 に置き、それぞれ相手の番地を「次のビットストリーム」にする。
# どちらも RECONFIG_N (ピン 9) を設計が Low にして切り替える (vdp_regs の RECONFIG、harness.py reconfig)。
# gowin_pack の --reconfign_as_gpio は付けない: 付けるとピンが GPIO になって、Low にしても再コンフィグしない (実機で確かめた)。
# 付けなくても設計の出力はピンを駆動でき、再コンフィグの入力として効く
PACK_FLAGS   :=
FLASH_OFFSET := 0
ifeq ($(strip $(TARGET)),hdmi)
TOP        := top
CST        := constraints/tangnano20k.cst
VIDEO_MODE := 0
RENDER_DIR := build/render
PACK_FLAGS := --multiboot_address 0x100000
else ifeq ($(strip $(TARGET)),gpu3d)
TOP        := top
CST        := constraints/tangnano20k.cst
VIDEO_MODE := 0
RENDER_DIR := build/render
TOP_PARAMS := -G GPU3D=1 $(if $(filter 1,$(MUL_PROBE)),-G MUL_PROBE=1)
OUT_DIR    := build/gpu3d
PACK_FLAGS   := --multiboot_address 0x000000
FLASH_OFFSET := 0x100000
# 真のデュアルポートの BSRAM の番地が FF から直接でなければ止める (scripts/bsram_check.py)
BSRAM_STRICT := 1
else ifeq ($(strip $(TARGET)),lcd)
TOP        := top_lcd
CST        := constraints/tangnano20k_lcd.cst
VIDEO_MODE := 1
RENDER_DIR := build/render_lcd
else ifeq ($(strip $(TARGET)),harness_probe)
TOP        := top_harness_probe
CST        := constraints/tangnano20k_harness_probe.cst
VIDEO_MODE := 0
RENDER_DIR := build/render
else
$(error TARGET=$(strip $(TARGET)) は未対応です (hdmi | lcd | harness_probe | gpu3d))
endif
ifeq ($(strip $(FREEZE)),1)
RENDER_DIR := $(RENDER_DIR)_frozen
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

.PHONY: timing-repro help images image-fpga image-pico all lint sim scenario $(addprefix sim-,$(TBS)) render synth pnr bitstream pincheck prog flash demo fw harness-fw harness-deploy shell shell-pico zip clean

help:
	@echo "make images      Docker イメージをビルド (image-fpga / image-pico で個別に)"
	@echo "make lint        Verilator で RTL を lint"
	@echo "make sim         テストベンチを全部実行 (SIM=iverilog|verilator, VCD は build/sim/)"
	@echo "make sim-<tb>    個別テストベンチ実行 (例: make sim-tb_tmds_encoder)"
	@echo "make scenario    シナリオ (SCENARIO=scenarios/*.json) をシステム全体の RTL で走らせ、参照モデルの CRC と比べる"
	@echo "make render      Verilator で映像出力を PNG 化 ($(RENDER_DIR)/, FRAMES=$(FRAMES), TARGET=lcd で 800x480)"
	@echo "                 FREEZE=1 でアニメーションを止めた参照画像と CRC (frames.json) を build/render_frozen/ に"
	@echo "make bitstream   合成 -> 配置配線 -> $(BUILD)/$(TOP).fs (TARGET=hdmi|lcd|harness_probe)"
	@echo "make pincheck    ハーネスが駆動するピンを FPGA が駆動しないか検査 (prog / flash の前に自動で実行)"
	@echo "make prog        SRAM に書き込み (ホストの openFPGALoader が必要)"
	@echo "make flash       Flash に書き込み (同上。TARGET=hdmi は 0x000000、TARGET=gpu3d は 0x100000。両方書けば harness.py reconfig で切り替わる)"
	@echo "make demo        デモをハーネス経由で流す (既定は Ctrl-C まで、FRAMES=N で N フレーム。ホストの python3)"
	@echo "                 SCENE=logo|tunnel|room|city で 3D の場面、SCENE=all で 4 つを 10 秒ずつくり返す (先に make prog TARGET=gpu3d)。なければ M9 のデモ (VDP)"
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

$(BUILD)/sim $(RENDER_DIR):
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

render: | $(RENDER_DIR)
	$(FPGA) verilator --cc --exe --build -j 0 -O2 -Wno-fatal \
		--top-module vdp_video -GMODE=$(VIDEO_MODE) -Mdir $(RENDER_DIR)/obj -o render \
		$(VDP_SRC) sim/verilator/render_main.cpp
	$(FPGA) $(RENDER_DIR)/obj/render $(RENDER_DIR) $(FRAMES) $(strip $(FREEZE))
	$(FPGA) python3 scripts/ppm2png.py $(RENDER_DIR)/*.ppm
	@rm -f $(RENDER_DIR)/*.ppm

# シナリオをシステム全体の RTL (Verilator) で走らせ、参照モデル (tools/harness/gpu_model.py) と比べる
SCENARIO ?= scenarios/m5_basic.json
SCN_DIR   = $(BUILD)/scenario$(SCN_SUFFIX)/$(basename $(notdir $(SCENARIO)))
ifeq ($(strip $(TARGET)),gpu3d)
SCN_SUFFIX := _gpu3d
SCN_PARAMS := -GGPU3D=1
endif

scenario:
	@mkdir -p $(SCN_DIR)
	$(FPGA) python3 tools/harness/gpu_model.py export $(SCENARIO) $(SCN_DIR)
	$(FPGA) verilator --binary --timing -O2 -Wno-fatal -Wno-lint -Wno-style \
		--top-module gpu_scenario_tb $(SCN_PARAMS) -Mdir $(BUILD)/scenario$(SCN_SUFFIX)/obj -o gpu_scenario \
		sim/scenario/gpu_scenario_tb.sv $(RTL_SRC) $(SIM_LIB)
	$(FPGA) $(BUILD)/scenario$(SCN_SUFFIX)/obj/gpu_scenario +cmds=$(SCN_DIR)/cmds.hex +checks=$(SCN_DIR)/checks.txt +out=$(SCN_DIR)
	$(FPGA) python3 tools/harness/gpu_model.py compare $(SCENARIO) $(SCN_DIR)

# ---------------------------------------------------------------- 実装
synth: $(OUT_DIR)/$(TOP).json
pnr: $(OUT_DIR)/$(TOP)_pnr.json
bitstream: $(OUT_DIR)/$(TOP).fs

# SystemVerilog は yosys-slang プラグイン (read_slang) で読む。
# -nolutram: LUT の RAM (RAM16SDP4) は実機で値が化ける (docs/GPU3D_PLAN.md の G1)。小さい配列はフリップフロップか BSRAM に置く
$(OUT_DIR)/$(TOP).json: $(SYN_SRC) $(GOWIN_BB)
	@mkdir -p $(OUT_DIR)
	$(FPGA) yosys -m slang -q -l $(OUT_DIR)/$(TOP)_yosys.log \
		-p "read_slang --top $(TOP) $(TOP_PARAMS) $(SYN_SRC) $(GOWIN_BB); synth_gowin -family gw2a -nolutram -top $(TOP) -json $@"
	$(FPGA) python3 scripts/fix_netlist.py $@ $(TOP)
	@# 真のデュアルポートの BSRAM の番地に論理が挟まっていないか (nextpnr はそのタイミングを見ない)。3D は止める、ほかは報告だけ
	$(FPGA) python3 scripts/bsram_check.py $@ $(if $(BSRAM_STRICT),,|| true)

$(OUT_DIR)/$(TOP)_pnr.json: $(OUT_DIR)/$(TOP).json $(CST)
	$(FPGA) nextpnr-himbaechel -q -l $(OUT_DIR)/$(TOP)_nextpnr.log \
		--json $< --write $@ --device $(DEVICE) \
		--vopt family=$(FAMILY) --vopt cst=$(CST) --vopt sspi_as_gpio

$(OUT_DIR)/$(TOP).fs: $(OUT_DIR)/$(TOP)_pnr.json
	$(FPGA) gowin_pack -d $(FAMILY) --sspi_as_gpio $(PACK_FLAGS) -o $@ $<
	@grep -A30 'Device utilisation' $(OUT_DIR)/$(TOP)_nextpnr.log | grep -E 'LUT|DFF|BSRAM|PLL|OSER|IOB' || true
	@grep -E 'Max frequency' $(OUT_DIR)/$(TOP)_nextpnr.log | tail -n 4 || true

# ハーネスが駆動するピン (harness/pins.json) を FPGA も駆動しようとしていないか検査する。
# ハーネスがつながっている前提なので、prog / flash は必ずこれを通してから書き込む
pincheck: $(OUT_DIR)/$(TOP).fs
	$(FPGA) python3 scripts/pincheck.py $(HARNESS_PINS) $(CST) $(OUT_DIR)/$(TOP).json $<

# Docker Desktop (macOS) のコンテナからは USB が見えないので書き込みだけはホストで行う
prog: pincheck
	openFPGALoader -b $(BOARD) $(OUT_DIR)/$(TOP).fs

# フラッシュ: VDP (TARGET=hdmi) は 0x000000、3D GPU (TARGET=gpu3d) は 0x100000 (FLASH_OFFSET)。電源を入れると 0x000000 から立ち上がる
flash: pincheck
	openFPGALoader -b $(BOARD) -f --offset $(FLASH_OFFSET) $(OUT_DIR)/$(TOP).fs

# デモ: ハーネス (USB) を使うのでホストで動かす。SCENE なしは M9 のデモ (VDP のビットストリーム)、SCENE=logo/tunnel/room/city は G5 の 3D の場面 (TARGET=gpu3d)
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
