"""コマンド GPU の参照モデルとシナリオ (docs/GPU_PLAN.md の M5)。Python 標準ライブラリだけで動く

rtl/vdp/gpu.sv と同じ規則でコマンドを解釈し、表示される面の画像と CRC を作る。
同じシナリオから、実機 (harness.py scenario) と Verilator (make scenario) に送る 32bit ワードの列も作る。

シナリオ (JSON):
  {"name": "...", "steps": [
      {"op": "clear", "color": "#rrggbb"},
      {"op": "fill_rect", "x": 0, "y": 0, "w": 10, "h": 10, "color": "#rrggbb"},
      {"op": "swap"},
      {"op": "upload", "addr": 1234, "words": ["deadbeef", ...]},
      {"op": "upload_image", "slot": 256},      # fbmodel.test_image() を slot の面へ
      {"op": "check"}                            # ここで表示されている画面を比べる
  ]}
色は "#rrggbb" (RGB565 に丸める) か、RGB565 の整数。
"""
import json

import fbmodel

SRC_W, SRC_H = fbmodel.SRC_W, fbmodel.SRC_H
OP_NOP, OP_CLEAR, OP_FILL_RECT, OP_SWAP, OP_UPLOAD = 0x00, 0x01, 0x02, 0x03, 0x04
FB_BASE_RESET, DRAW_BASE_RESET = 0, 256


def color565(c):
    if isinstance(c, int):
        return c & 0xFFFF
    c = c.lstrip("#")
    return fbmodel.to565(int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16))


def encode(step):
    """1 つのステップを GPU に送るワードの列にする (check は送らない)"""
    op = step["op"]
    if op == "clear":
        return [OP_CLEAR << 24 | color565(step["color"])]
    if op == "fill_rect":
        return [OP_FILL_RECT << 24 | color565(step["color"]),
                (step["y"] & 0xFFFF) << 16 | (step["x"] & 0xFFFF),
                (step["h"] & 0xFFFF) << 16 | (step["w"] & 0xFFFF)]
    if op == "swap":
        return [OP_SWAP << 24]
    if op == "upload":
        words = [int(w, 16) if isinstance(w, str) else w for w in step["words"]]
        return [OP_UPLOAD << 24 | len(words), step["addr"]] + words
    if op == "upload_image":
        img = fbmodel.rgb_to_565(fbmodel.test_image(), SRC_W, SRC_H)
        return upload_image_words(img, step["slot"])
    if op == "check":
        return []
    raise ValueError(f"unknown op {op!r}")


def upload_image_words(img565, slot):
    """320x240 の RGB565 を slot の面へ送る UPLOAD (1 ライン 1 コマンド)"""
    out = []
    for y in range(SRC_H):
        line = fbmodel.line_bytes(img565, y)
        words = [int.from_bytes(line[4 * i:4 * i + 4], "little") for i in range(SRC_W // 2)]
        out += [OP_UPLOAD << 24 | len(words), (slot + y) * fbmodel.WORDS_PER_LINE] + words
    return out


class Model:
    """SDRAM はワードアドレス -> 32bit の辞書。書いていないワードは None (画面に出たらエラー)"""

    def __init__(self):
        self.mem = {}
        self.fb_base = FB_BASE_RESET
        self.draw_base = DRAW_BASE_RESET

    def put_pixel(self, base, x, y, c):
        a = (base + y) * 256 + x // 2
        w = self.mem.get(a, 0)
        w = (w & 0x0000FFFF) | c << 16 if x % 2 else (w & 0xFFFF0000) | c
        self.mem[a] = w

    def fill(self, x, y, w, h, c):
        if w == 0 or h == 0 or x >= SRC_W or y >= SRC_H:
            return
        for yy in range(y, min(y + h, SRC_H)):
            for xx in range(x, min(x + w, SRC_W)):
                self.put_pixel(self.draw_base, xx, yy, c)

    def run(self, words):
        i = 0
        while i < len(words):
            w = words[i]
            op = w >> 24
            if op == OP_CLEAR:
                self.fill(0, 0, SRC_W, SRC_H, w & 0xFFFF)
                i += 1
            elif op == OP_FILL_RECT:
                xy, hw = words[i + 1], words[i + 2]
                self.fill(xy & 0xFFFF, xy >> 16, hw & 0xFFFF, hw >> 16, w & 0xFFFF)
                i += 3
            elif op == OP_SWAP:
                self.fb_base, self.draw_base = self.draw_base, self.fb_base
                i += 1
            elif op == OP_UPLOAD:
                n, addr = w & 0xFFFFFF, words[i + 1]
                for k in range(n):
                    self.mem[addr + k] = words[i + 2 + k]
                i += 2 + n
            else:          # NOP と知らないコマンドは 1 ワード
                i += 1

    def displayed565(self):
        """表示されている面 (fb_base) の 320x240 RGB565"""
        img = []
        for y in range(SRC_H):
            for x in range(SRC_W // 2):
                w = self.mem.get((self.fb_base + y) * 256 + x)
                if w is None:
                    raise ValueError(f"displayed plane {self.fb_base} has unwritten pixels at ({2 * x},{y})")
                img += [w & 0xFFFF, w >> 16]
        return img


def load(path):
    with open(path) as f:
        return json.load(f)


def expected(scenario):
    """シナリオを最初から走らせ、check ごとに (そこまでのワード数, 画像 565, CRC) を返す"""
    m = Model()
    words, checks = [], []
    for step in scenario["steps"]:
        if step["op"] == "check":
            img = m.displayed565()
            checks.append((len(words), img, fbmodel.expected_crc(img)))
        else:
            w = encode(step)
            m.run(w)
            words += w
    return words, checks


def export(path, out_dir):
    """Verilator のシナリオ実行 (sim/scenario/gpu_scenario_tb.sv) の入力を書く"""
    import os
    sc = load(path)
    words, checks = expected(sc)
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "cmds.hex"), "w") as f:
        f.write(f"{len(words)}\n" + "".join(f"{w:08x}\n" for w in words))
    with open(os.path.join(out_dir, "checks.txt"), "w") as f:
        f.write(f"{len(checks)}\n" + "".join(f"{n}\n" for n, _, _ in checks))
    with open(os.path.join(out_dir, "expected.json"), "w") as f:
        json.dump([{"words": n, "crc": f"0x{c:08x}"} for n, _, c in checks], f, indent=1)
    print(f"{sc['name']}: {len(words)} words, {len(checks)} checks -> {out_dir}")


def compare(path, out_dir):
    """Verilator の結果を参照モデルと比べる。CRC は 3 つ: モデル、RTL の frame_crc、PPM から Python で計算したもの"""
    import os
    import zlib
    sc = load(path)
    _, checks = expected(sc)
    results, ok = [], True
    for i, (_, _, crc) in enumerate(checks):
        with open(os.path.join(out_dir, f"crc_{i}.txt")) as f:
            rtl_crc, frame, under, max_fetch = f.read().split()
        with open(os.path.join(out_dir, f"frame_{i}.ppm"), "rb") as f:
            ppm = f.read()
        ppm_crc = zlib.crc32(ppm[ppm.index(b"255\n") + 4:])
        r = {"check": i, "model": f"0x{crc:08x}", "rtl_frame_crc": f"0x{int(rtl_crc, 16):08x}",
             "ppm": f"0x{ppm_crc:08x}", "frame": int(frame), "underflow": int(under),
             "max_fetch_cycles": int(max_fetch)}
        # 表示のライン読み出しは出力 2 ライン (63.5us = clk_sys 4000 クロック) までに終われば間に合う
        r["ok"] = int(rtl_crc, 16) == crc == ppm_crc and int(under) == 0 and int(max_fetch) < 4000
        ok &= r["ok"]
        results.append(r)
    print(json.dumps({"scenario": sc["name"], "ok": ok, "checks": results}, indent=1))
    print(("PASS: " if ok else "FAIL: ") + f"scenario {sc['name']}")
    return ok


if __name__ == "__main__":
    import sys
    if len(sys.argv) == 4 and sys.argv[1] == "export":
        export(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == "compare":
        sys.exit(0 if compare(sys.argv[2], sys.argv[3]) else 1)
    else:
        sys.exit("usage: gpu_model.py export|compare <scenario.json> <dir>")
