#!/bin/bash
# usage: run.sh W WCHAIN   (tang-fpga コンテナの中で、このディレクトリから。リポジトリは /work)
# 配置のあとと配線のあとの Max frequency を c_<W>_<WCHAIN>.log に出す
set -e
W=$1; C=$2
yosys -m slang -q -p "read_slang --top repro -G W=$W -G WCHAIN=$C repro.sv; synth_gowin -family gw2a -nolutram -top repro -json c_${W}_${C}.json"
python3 /work/scripts/fix_netlist.py c_${W}_${C}.json repro
nextpnr-himbaechel -q -l c_${W}_${C}.log --json c_${W}_${C}.json --write /tmp/c.json --device GW2AR-LV18QN88C8/I7 \
  --vopt family=GW2A-18C --vopt cst=repro.cst --freq 50 --report c_${W}_${C}_rep.json || true
