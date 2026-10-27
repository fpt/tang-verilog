#!/usr/bin/env python3
"""真のデュアルポートの BSRAM の番地が FF から直接来ているかを、合成したネットリスト (yosys の JSON) で確かめる

nextpnr の Gowin のタイミングのモデルは、真のデュアルポートの BSRAM (DPX9B / DPB) の B ポートの番地 (ADB) を見ない
(gowin_arch_gen.py が ADB を別の種類のセルに登録している。docs/GPU3D_PLAN.md の G3・G5)。番地に論理を挟むと、
報告では間に合っていても配置によって実機で値が化ける。yosys は「組み合わせで読む RAM の番地が FF」のとき、
その FF を RAM に取り込んで、FF の D 入力 (論理) を番地にすることがあるので、RTL を見るだけでは分からない。

どちらのポートが B になるかは決まらないので、ADA と ADB の全ビットを見る。許すのは FF の Q と定数 (GND / VCC) だけ。
SDP (SDPX9B / SDPB) は nextpnr が番地もデータも見るので対象にしない。

usage: bsram_check.py <netlist.json>     違反があれば一覧を出して終了コード 1
"""
import json
import sys

DP_TYPES = {"DPX9B", "DPB", "DPX9", "DP"}


def main(path):
    with open(path) as f:
        top = json.load(f)
    mods = top["modules"]
    m = mods.get("top") or next(iter(mods.values()))
    driver = {}                                        # ネットのビット → (セルの種類, セルの名前, ポート)
    for name, c in m["cells"].items():
        dirs = c.get("port_directions", {})
        for port, bits in c["connections"].items():
            if dirs.get(port) == "output":
                for b in bits:
                    if isinstance(b, int):
                        driver[b] = (c["type"], name, port)
    bad, checked = [], 0
    for name, c in m["cells"].items():
        if c["type"] not in DP_TYPES:
            continue
        checked += 1
        for port in ("ADA", "ADB"):
            for i, b in enumerate(c["connections"].get(port, [])):
                if not isinstance(b, int):
                    continue                           # 定数 ("0" / "1")
                t, dn, dp = driver.get(b, ("?", "?", "?"))
                if not ((t.startswith("DFF") and dp == "Q") or t in ("GND", "VCC")):
                    bad.append(f"{name} {port}[{i}] <- {t} {dn}.{dp}")
    print(json.dumps({"ok": not bad, "dp_bsram": checked, "violations": len(bad)}))
    for line in bad[:50]:
        print("  " + line)
    if len(bad) > 50:
        print(f"  ... and {len(bad) - 50} more")
    return 0 if not bad else 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1]))
