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
      {"op": "point", "x": 10, "y": 20, "color": "#rrggbb"},                 # 座標は符号付き 16bit
      {"op": "line", "x0": 0, "y0": 0, "x1": 319, "y1": 239, "color": "#rrggbb"},
      {"op": "clip", "x0": 0, "y0": 0, "x1": 319, "y1": 239},               # 両端を含む。FILL_RECT / POINT / LINE / BLIT に効く
      {"op": "upload_sprite", "kind": "arrow", "addr": 196608, "w": 16, "h": 16, "stride": 8},   # 下の sprite_pixels
      {"op": "blit", "src": 196608, "stride": 8, "w": 16, "h": 16, "x": 10, "y": 20,
       "transparent": true, "hflip": false, "vflip": false, "key": "#ff00ff"},
      {"op": "check"}                            # ここで表示されている画面を比べる
  ]}
色は "#rrggbb" (RGB565 に丸める) か、RGB565 の整数。
"""
import json

import fbmodel

SRC_W, SRC_H = fbmodel.SRC_W, fbmodel.SRC_H
OP_NOP, OP_CLEAR, OP_FILL_RECT, OP_SWAP, OP_UPLOAD = 0x00, 0x01, 0x02, 0x03, 0x04
OP_POINT, OP_DRAW_LINE, OP_CLIP, OP_BLIT = 0x05, 0x06, 0x07, 0x08
BLIT_MAX_W = 512
SPRITE_KEY = 0xF81F      # sprite_pixels が透過色に使う色 (#ff00ff)
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
    if op == "point":
        return [OP_POINT << 24 | color565(step["color"]), xy(step["x"], step["y"])]
    if op == "line":
        return [OP_DRAW_LINE << 24 | color565(step["color"]), xy(step["x0"], step["y0"]), xy(step["x1"], step["y1"])]
    if op == "clip":
        return [OP_CLIP << 24, xy(step["x0"], step["y0"]), xy(step["x1"], step["y1"])]
    if op == "blit":
        flags = (1 if step.get("transparent") else 0) | (2 if step.get("hflip") else 0) | (4 if step.get("vflip") else 0)
        return [OP_BLIT << 24 | flags << 16 | color565(step.get("key", SPRITE_KEY)), step["src"],
                (step["h"] & 0xFFFF) << 16 | (step["w"] & 0xFFFF), xy(step["x"], step["y"]), step["stride"] & 0xFFFF]
    if op == "upload_sprite":
        px = sprite_pixels(step["kind"], step["w"], step["h"])
        return image_words(px, step["w"], step["h"], step["stride"], step["addr"])
    if op == "check":
        return []
    raise ValueError(f"unknown op {op!r}")


def xy(x, y):
    return (y & 0xFFFF) << 16 | (x & 0xFFFF)


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def bresenham(x0, y0, x1, y1):
    """rtl/vdp/gpu.sv と同じ: err = dx + dy (dy は負)、e2 = 2 err。両端を含む"""
    dx, dy = abs(x1 - x0), -abs(y1 - y0)
    sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
    err = dx + dy
    while True:
        yield x0, y0
        if x0 == x1 and y0 == y1:
            return
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x0 += sx
        if e2 <= dx:
            err += dx
            y0 += sy


def sprite_pixels(kind, w, h):
    """シナリオ用の決まったスプライト (RGB565 のリスト、行優先)。透過したいところは SPRITE_KEY
      arrow:   右向きの矢印 (左右・上下で形が変わるので反転がわかる)。背景は透過色
      ball:    円。背景は透過色
      stripes: 透過色なしの斜めの縞 (幅の広いソース用)"""
    out = []
    for y in range(h):
        for x in range(w):
            if kind == "arrow":
                body = h // 3 <= y < h - h // 3 and x < w * 2 // 3
                head = x >= w // 2 and abs(y - (h - 1) / 2) <= (w - 1 - x)
                c = fbmodel.to565(255, 200 - 8 * y, 40 + 10 * x) if (body or head) else SPRITE_KEY
            elif kind == "ball":
                r = min(w, h) / 2
                inside = (x + 0.5 - w / 2) ** 2 + (y + 0.5 - h / 2) ** 2 <= r * r
                c = fbmodel.to565(60 + 10 * x, 120 + 7 * y, 255) if inside else SPRITE_KEY
            elif kind == "stripes":
                c = fbmodel.to565(255, 255, 0) if (x + y) % 6 < 3 else fbmodel.to565(0, 128, 0)
            else:
                raise ValueError(f"unknown sprite {kind!r}")
            out.append(c)
    return out


def image_words(px, w, h, stride, addr):
    """w x h のピクセルを、各行 stride ワードで addr から置く UPLOAD (行ごとに 1 コマンド)"""
    out = []
    for y in range(h):
        row = px[y * w:(y + 1) * w] + [0] * (2 * stride - w)
        words = [row[2 * k] | row[2 * k + 1] << 16 for k in range(stride)]
        out += [OP_UPLOAD << 24 | stride, addr + y * stride] + words
    return out


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
        self.clip = (0, 0, SRC_W - 1, SRC_H - 1)     # (x0, y0, x1, y1) 両端を含む

    def put_pixel(self, base, x, y, c):
        a = (base + y) * 256 + x // 2
        w = self.mem.get(a, 0)
        w = (w & 0x0000FFFF) | c << 16 if x % 2 else (w & 0xFFFF0000) | c
        self.mem[a] = w

    def fill(self, x, y, w, h, c, clip=None):
        """矩形と範囲 (clip、None なら画面全体) の重なりを塗る"""
        bx0, by0, bx1, by1 = clip or (0, 0, SRC_W - 1, SRC_H - 1)
        if w == 0 or h == 0:
            return
        for yy in range(max(y, by0), min(y + h - 1, by1) + 1):
            for xx in range(max(x, bx0), min(x + w - 1, bx1) + 1):
                self.put_pixel(self.draw_base, xx, yy, c)

    def plot(self, x, y, c):
        cx0, cy0, cx1, cy1 = self.clip
        if cx0 <= x <= cx1 and cy0 <= y <= cy1:
            self.put_pixel(self.draw_base, x, y, c)

    def blit(self, src, stride, w, h, x, y, flags, key):
        """gpu.sv の BLIT と同じ: ソースの各行はワードの先頭から。透過・左右反転・上下反転、クリップ"""
        if w == 0 or h == 0 or w > BLIT_MAX_W:
            return
        for j in range(h):
            sj = h - 1 - j if flags & 4 else j
            for i in range(w):
                si = w - 1 - i if flags & 2 else i
                word = self.mem.get(src + sj * stride + si // 2)
                if word is None:
                    raise ValueError(f"BLIT reads unwritten word {src + sj * stride + si // 2:#x}")
                p = word >> 16 if si % 2 else word & 0xFFFF
                if flags & 1 and p == key:
                    continue
                self.plot(x + i, y + j, p)

    def set_clip(self, x0, y0, x1, y1):
        """画面の外は画面の端に丸める。x0 / y0 が画面の外なら空 (gpu.sv と同じ)"""
        if x0 > SRC_W - 1 or y0 > SRC_H - 1:
            self.clip = (1, 1, 0, 0)
        else:
            self.clip = (x0, y0, min(x1, SRC_W - 1), min(y1, SRC_H - 1))

    def run(self, words):
        i = 0
        while i < len(words):
            w = words[i]
            op = w >> 24
            if op == OP_CLEAR:
                self.fill(0, 0, SRC_W, SRC_H, w & 0xFFFF)
                i += 1
            elif op == OP_FILL_RECT:
                a0, a1 = words[i + 1], words[i + 2]
                self.fill(a0 & 0xFFFF, a0 >> 16, a1 & 0xFFFF, a1 >> 16, w & 0xFFFF, self.clip)
                i += 3
            elif op == OP_POINT:
                a0 = words[i + 1]
                self.plot(s16(a0), s16(a0 >> 16), w & 0xFFFF)
                i += 2
            elif op == OP_DRAW_LINE:
                a0, a1 = words[i + 1], words[i + 2]
                for px, py in bresenham(s16(a0), s16(a0 >> 16), s16(a1), s16(a1 >> 16)):
                    self.plot(px, py, w & 0xFFFF)
                i += 3
            elif op == OP_BLIT:
                src, hw, a2, stride = words[i + 1:i + 5]
                self.blit(src & 0x1FFFFF, stride & 0xFFFF, hw & 0xFFFF, hw >> 16, s16(a2), s16(a2 >> 16),
                          (w >> 16) & 7, w & 0xFFFF)
                i += 5
            elif op == OP_CLIP:
                a0, a1 = words[i + 1], words[i + 2]
                self.set_clip(a0 & 0xFFFF, a0 >> 16, a1 & 0xFFFF, a1 >> 16)
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
