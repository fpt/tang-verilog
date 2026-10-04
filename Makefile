# Tang Nano 20K + RP2350 VDP 開発用 Makefile
# ツールはすべて Docker コンテナ内で実行する (make images で事前にビルド)

FPGA_IMAGE ?= tang-fpga:latest
PICO_IMAGE ?= tang-pico:latest

DOCKER_RUN := docker run --rm -v "$(CURDIR)":/work -w /work --user $(shell id -u):$(shell id -g)
FPGA       := $(DOCKER_RUN) $(FPGA_IMAGE)
PICO       := $(DOCKER_RUN) $(PICO_IMAGE)

# --- FPGA ---
TOP      := top
DEVICE   := GW2AR-LV18QN88C8/I7
FAMILY   := GW2A-18C
BOARD    := tangnano20k
CST      := constraints/tangnano20k.cst

VDP_SRC   := $(wildcard rtl/vdp/*.sv)
GOWIN_SRC := $(wildcard rtl/gowin/*.sv)
GOWIN_BB  := $(wildcard rtl/gowin/blackbox/*.sv)   # 合成専用のプリミティブ定義
SYN_SRC   := $(VDP_SRC) $(GOWIN_SRC)

TBS      := $(basename $(notdir $(wildcard sim/tb_*.sv)))
SIM      ?= iverilog            # iverilog | verilator
FRAMES   ?= 3

BUILD    := build

# --- RP2350 ---
PICO_BOARD    ?= pico2
PICO_PLATFORM ?= rp2350-arm-s   # rp2350-riscv にすると Hazard3 コア用

.PHONY: help images image-fpga image-pico all lint sim $(addprefix sim-,$(TBS)) render synth pnr bitstream prog flash fw shell shell-pico zip clean

help:
	@echo "make images      Docker イメージをビルド (image-fpga / image-pico で個別に)"
	@echo "make lint        Verilator で RTL を lint"
	@echo "make sim         テストベンチを全部実行 (SIM=iverilog|verilator, VCD は build/sim/)"
	@echo "make sim-<tb>    個別テストベンチ実行 (例: make sim-tb_tmds_encoder)"
	@echo "make render      Verilator で映像出力を PNG 化 (build/render/, FRAMES=$(FRAMES))"
	@echo "make bitstream   合成 -> 配置配線 -> $(BUILD)/$(TOP).fs"
	@echo "make prog        SRAM に書き込み (ホストの openFPGALoader が必要)"
	@echo "make flash       Flash に書き込み (同上)"
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

$(BUILD)/sim $(BUILD)/render:
	@mkdir -p $@

# ---------------------------------------------------------------- 検証
lint:
	$(FPGA) verilator --lint-only -Wall --top-module vdp_video $(VDP_SRC)

sim: $(addprefix sim-,$(TBS))

$(addprefix sim-,$(TBS)): sim-%: sim/%.sv $(VDP_SRC) | $(BUILD)/sim
ifeq ($(strip $(SIM)),verilator)
	$(FPGA) verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style \
		--top-module $* -Mdir $(BUILD)/sim/obj_$* -o $* $< $(VDP_SRC)
	$(FPGA) $(BUILD)/sim/obj_$*/$*
else
	$(FPGA) iverilog -g2012 -Wall -Wno-timescale -o $(BUILD)/sim/$*.vvp -s $* $< $(VDP_SRC)
	$(FPGA) vvp -n $(BUILD)/sim/$*.vvp
endif

render: | $(BUILD)/render
	$(FPGA) verilator --cc --exe --build -j 0 -O2 -Wno-fatal \
		--top-module vdp_video -Mdir $(BUILD)/render/obj -o render \
		$(VDP_SRC) sim/verilator/render_main.cpp
	$(FPGA) $(BUILD)/render/obj/render $(BUILD)/render $(FRAMES)
	$(FPGA) python3 scripts/ppm2png.py $(BUILD)/render/*.ppm
	@rm -f $(BUILD)/render/*.ppm

# ---------------------------------------------------------------- 実装
synth: $(BUILD)/$(TOP).json
pnr: $(BUILD)/$(TOP)_pnr.json
bitstream: $(BUILD)/$(TOP).fs

# SystemVerilog は yosys-slang プラグイン (read_slang) で読む
$(BUILD)/$(TOP).json: $(SYN_SRC) $(GOWIN_BB)
	@mkdir -p $(BUILD)
	$(FPGA) yosys -m slang -q -l $(BUILD)/yosys.log \
		-p "read_slang --top $(TOP) $(SYN_SRC) $(GOWIN_BB); synth_gowin -family gw2a -top $(TOP) -json $@"

$(BUILD)/$(TOP)_pnr.json: $(BUILD)/$(TOP).json $(CST)
	$(FPGA) nextpnr-himbaechel -q -l $(BUILD)/nextpnr.log \
		--json $< --write $@ --device $(DEVICE) \
		--vopt family=$(FAMILY) --vopt cst=$(CST)

$(BUILD)/$(TOP).fs: $(BUILD)/$(TOP)_pnr.json
	$(FPGA) gowin_pack -d $(FAMILY) -o $@ $<
	@grep -A30 'Device utilisation' $(BUILD)/nextpnr.log | grep -E 'LUT|DFF|BSRAM|PLL|OSER|IOB' || true
	@grep -E 'Max frequency' $(BUILD)/nextpnr.log | tail -n 4 || true

# Docker Desktop (macOS) のコンテナからは USB が見えないので書き込みだけはホストで行う
prog: $(BUILD)/$(TOP).fs
	openFPGALoader -b $(BOARD) $<

flash: $(BUILD)/$(TOP).fs
	openFPGALoader -b $(BOARD) -f $<

# ---------------------------------------------------------------- RP2350
fw:
	$(PICO) sh -c 'cmake -S firmware -B firmware/build -G Ninja \
		-DPICO_BOARD=$(strip $(PICO_BOARD)) -DPICO_PLATFORM=$(strip $(PICO_PLATFORM)) \
		&& cmake --build firmware/build'
	@ls firmware/build/*.uf2

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
	rm -rf $(BUILD) firmware/build certs.pem dist
