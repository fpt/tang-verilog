#!/usr/bin/env python3
"""harness/pins.json から RP2 ファームウェア用の pins.h を生成する

usage: gen_pins_h.py <pins.json> <pins.h>
"""
import json
import sys

pins_path, out_path = sys.argv[1:3]
with open(pins_path) as f:
    pins = json.load(f)["pins"]

lines = [
    "// 自動生成 (scripts/gen_pins_h.py harness/pins.json)。直接編集しない",
    "#pragma once",
    "#include <stdbool.h>",
    "",
]
for p in pins:
    lines.append(f'#define PIN_{p["signal"]:<10} {p["pico_gpio"]}')
lines += [
    "",
    "typedef struct {",
    "    const char *name;",
    "    unsigned    gpio;",
    "    bool        fpga_output;   // true: FPGA が駆動し RP2 は読むだけ",
    "} harness_pin_t;",
    "",
    "static const harness_pin_t HARNESS_PINS[] = {",
]
for p in pins:
    out = "true" if p["fpga_dir"] == "output" else "false"
    lines.append(f'    {{"{p["signal"]}", {p["pico_gpio"]}, {out}}},')
lines += [
    "};",
    f"#define HARNESS_PIN_COUNT {len(pins)}",
    "",
]
with open(out_path, "w") as f:
    f.write("\n".join(lines))
