#!/usr/bin/env python3
"""ハーネスのピン方向の検査 (docs/HARNESS.md「ピン方向の検査」)

usage: pincheck.py <pins.json> <cst> <synth.json> <bitstream.fs>

cst の IO_LOC (ポート名 -> ピン) と Yosys の JSON (ポート名 -> 向き) を突き合わせ、
ハーネス側 (RP2) が駆動するピンを FPGA も駆動しようとしていたら失敗する。
結果を JSON で標準出力に出し、失敗したら終了コード 1。
"""
import json
import os
import re
import sys


def main() -> int:
    pins_path, cst_path, synth_path, fs_path = sys.argv[1:5]

    with open(pins_path) as f:
        pins = json.load(f)["pins"]

    # IO_LOC "name" 73;  (行頭の // はコメント)
    loc = {}
    with open(cst_path) as f:
        for line in f:
            line = line.split("//", 1)[0]
            m = re.match(r'\s*IO_LOC\s+"([^"]+)"\s+(\d+)\s*;', line)
            if m:
                loc[m.group(1)] = int(m.group(2))

    with open(synth_path) as f:
        synth = json.load(f)
    tops = [m for m in synth["modules"].values() if m.get("attributes", {}).get("top")]
    if len(tops) != 1:
        print(json.dumps({"ok": False, "error": "top module not found in synth JSON"}))
        return 1
    ports = tops[0]["ports"]

    errors, warnings, checked = [], [], []
    for p in pins:
        # このピンに割り当てられ、かつ合成結果に存在するポート ("led[0]" -> "led")
        names = [n for n, pin in loc.items() if pin == p["fpga_pin"]]
        dirs = sorted({ports[n.split("[")[0]]["direction"] for n in names if n.split("[")[0] in ports})
        entry = {"signal": p["signal"], "fpga_pin": p["fpga_pin"], "expected": p["fpga_dir"], "actual": dirs or ["unused"]}
        checked.append(entry)
        if p["fpga_dir"] == "input" and any(d in ("output", "inout") for d in dirs):
            errors.append(f'{p["signal"]} (pin {p["fpga_pin"]}): RP2 drives this pin but FPGA port is {dirs}')
        if p["fpga_dir"] == "output" and "input" in dirs:
            warnings.append(f'{p["signal"]} (pin {p["fpga_pin"]}): observation pin is an FPGA input')

    # ビットストリームが検査した JSON より古ければ、別の JSON から作られた可能性がある
    if os.path.getmtime(fs_path) < os.path.getmtime(synth_path):
        errors.append(f"{fs_path} is older than {synth_path}; rebuild the bitstream")

    ok = not errors
    print(json.dumps({"ok": ok, "errors": errors, "warnings": warnings, "pins": checked}, indent=1))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
