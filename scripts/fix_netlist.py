"""yosys の JSON のネットリストから、トップに残った $buf のセルを取り除く (接続に置き換える)

yosys 0.69 の synth_gowin (abc9 の bufnorm) は、レジスタの Q と名前の付いたワイヤのあいだに $buf を残すことがある
(E4 の tpass、K3 の STRETCH_BLIT の累算器)。nextpnr-himbaechel は $buf を置けないので、書き出したあとに外す。
$buf の出力 Y のビットを、入力 A のビットに付け替える。Y がトップのポートにつながっているものは扱わない (エラーにする)。

使い方: python3 scripts/fix_netlist.py <netlist.json> <top>
"""
import json
import sys


def main(path, top):
    with open(path) as f:
        d = json.load(f)
    m = d["modules"][top]
    port_bits = {b for p in m["ports"].values() for b in p["bits"]}
    remap = {}
    for name, c in list(m["cells"].items()):
        if c["type"] not in ("$buf", "$_BUF_"):
            continue
        a, y = c["connections"]["A"], c["connections"]["Y"]
        for ab, yb in zip(a, y):
            if yb in port_bits:
                sys.exit(f"fix_netlist: {name} drives a top-level port; not removed")
            remap[yb] = ab
        del m["cells"][name]
    if not remap:
        return

    def resolve(b):
        while b in remap:            # $buf が連なっていても最後の入力まで
            b = remap[b]
        return b

    for c in m["cells"].values():
        for p, bits in c["connections"].items():
            c["connections"][p] = [resolve(b) for b in bits]
    for n in m["netnames"].values():
        n["bits"] = [resolve(b) for b in n["bits"]]
    with open(path, "w") as f:
        json.dump(d, f)
    print(f"fix_netlist: removed $buf cells ({len(remap)} bits) from {top}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
