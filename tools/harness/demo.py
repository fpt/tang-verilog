"""M9 のデモ (docs/GPU_PLAN.md の M9)。タイル レイヤの背景スクロール + スプライト + 図形を、ホストのコマンドだけで毎フレーム作る

フレーム k のコマンドは k だけで決まる (前のフレームの状態を使わない) ので、同じ関数を
  - 実機で流し続ける (harness.py demo)
  - 参照モデルと Verilator・実機で比べる (シナリオ m9_demo の demo_setup / demo_frame)
の両方に使う。

画面:
  - タイル レイヤ: 64x32 のマップ (scene)。空・丘・地面を帯ごとに違う速さで横スクロール (多重スクロール)。
    空は背景色のグラデーション (8 ラインごと)。下の水面は 4 ラインごとにスクロールを揺らす
  - スプライト 42 個: リサジューで動く玉 24 個 (16x16、半分は高優先)、左右に流れて画面の端から出入りする矢印 12 個 (16x16、
    向きで左右反転)、上下に揺れる輪 6 個 (32x32、低優先なので高優先のタイルの下)
  - 図形 (ビットマップ レイヤ、透過色あり、順位 4): 回る星と六角形 (DRAW_LINE)、伸び縮みする棒 (FILL_RECT)。
    2 枚の面に交互に描き、SWAP で切り替える

1 フレームのコマンドの順番 (どれもフレームの中で間に合うように):
  WAIT_VBLANK → ライン 0 のレジスタ → OAM_WRITE → SWAP (ライン 0 の合成で切り替わる)
  → 空のグラデーションと帯のスクロール (WAIT_LINE + REG_WRITE、ライン 128 まで)
  → 次のフレームの図形を裏の面に描く (CLEAR 約 0.7ms)
  → 水面の揺れ (ライン 208〜236)
"""
import math

import fbmodel
import gpu_model as g

MAP_ADDR = 0x3000            # 64x32 のマップ (1024 ワード)
BG_TILES = 0x0000            # 背景のタイル (demo、16 個)
OBJ_TILES = 0x0400           # スプライトのタイル (objects、24 個)
KEY = 0xF81F                 # ビットマップの透過色 (#ff00ff)
SPR_BANK = 1


def rgb(r, g_, b):
    return fbmodel.to565(r, g_, b)


def isin(deg, amp):
    """整数の度で sin。結果は丸めた整数 (同じ k から同じコマンドになる)"""
    return int(round(amp * math.sin(math.radians(deg))))


def icos(deg, amp):
    return int(round(amp * math.cos(math.radians(deg))))


# ---------------------------------------------------------------- 絵
def object_image(kind):
    """スプライトの絵 (4bpp の値の 2 次元リスト、0 = 透明)"""
    if kind == "ball":
        n = 16
        out = []
        for y in range(n):
            row = []
            for x in range(n):
                dx, dy = x + 0.5 - 8, y + 0.5 - 8
                d = dx * dx + dy * dy
                if d > 56:
                    row.append(0)
                elif d > 42:
                    row.append(1)                                   # 縁
                else:
                    hl = (dx + 3) ** 2 + (dy + 3) ** 2              # 左上が明るい
                    row.append(7 if hl < 6 else 6 if hl < 18 else 5 if hl < 34 else 4)
            out.append(row)
        return out
    if kind == "arrow":
        out = []
        for y in range(16):
            row = []
            for x in range(16):
                body = 5 <= y <= 10 and x < 10
                head = x >= 8 and abs(y - 7.5) <= 15 - x
                row.append(0 if not (body or head) else 9 if y < 8 else 10 if not (x + y) % 5 == 0 else 8)
            out.append(row)
        return out
    if kind == "ring":
        out = []
        for y in range(32):
            row = []
            for x in range(32):
                d = math.hypot(x + 0.5 - 16, y + 0.5 - 16)
                a = math.degrees(math.atan2(y + 0.5 - 16, x + 0.5 - 16)) % 360
                row.append(0 if not 9 <= d <= 15 else 11 + int(a // 72))   # 5 色の扇
            out.append(row)
        return out
    raise ValueError(kind)


def object_tiles():
    """玉 (タイル 0..3)・矢印 (4..7)・輪 (8..23)。どれも列優先 (セルの並び順 0) で並べる"""
    out = []
    for kind in ("ball", "arrow", "ring"):
        img = object_image(kind)
        h, w = len(img) // 8, len(img[0]) // 8
        for c in range(w):
            for r in range(h):
                for y in range(8):
                    out.append(g.tile_row_word(img[r * 8 + y][c * 8:c * 8 + 8]))
    return out


def sprite_palettes():
    """バンク 1 のパレット 4 つ (16 色ずつ)。値 1 = 縁 (暗い)、4..7 = 玉の明るさ、8..10 = 矢印、11..15 = 輪"""
    hues = [(255, 80, 60), (60, 200, 255), (120, 255, 90), (255, 210, 60)]
    out = []
    for p, (r, gg, b) in enumerate(hues):
        pal = [0] * 16
        pal[1] = rgb(r // 4, gg // 4, b // 4)
        for i, s in enumerate((0.45, 0.65, 0.85, 1.0)):
            pal[4 + i] = rgb(int(r * s), int(gg * s), int(b * s))
        pal[7] = rgb(255, 255, 255)
        pal[8], pal[9], pal[10] = rgb(255, 255, 255), rgb(r, gg, b), rgb(r // 2, gg // 2, b // 2)
        for i in range(5):
            q = (p + i) % 4
            pal[11 + i] = rgb(*hues[q])
        out += pal
    return out


# ---------------------------------------------------------------- 1 フレーム
def sprites(k):
    sp = []
    for i in range(24):            # 玉: リサジュー
        a = k * 2 + i * 15
        sp.append({"x": 152 + isin(2 * a, 140), "y": 112 + isin(3 * a + 40, 96), "w": 2, "h": 2, "tile": 0,
                   "pal": i % 4, "pri": i % 2})
    for i in range(12):            # 矢印: 左右に流れ、画面の端から出入りする
        t = (k * (2 + i % 3) + i * 37) % 400 - 40
        right = i % 2 == 0
        sp.append({"x": t if right else 320 - 16 - t, "y": 136 + i * 8, "w": 2, "h": 2, "tile": 4,
                   "hflip": not right, "pal": (i + 1) % 4, "pri": 1})
    for i in range(6):             # 輪: 上下に揺れる。低優先 (高優先のタイルの下)
        sp.append({"x": 12 + i * 52, "y": 40 + isin(k * 3 + i * 60, 24), "w": 4, "h": 4, "tile": 8,
                   "vflip": (k // 60 + i) % 2 == 1, "pal": i % 4, "pri": 0})
    return sp


def shapes_words(j):
    """図形 j を裏の面に描く: 透過色で全体を消し、星・六角形・棒"""
    out = [g.OP_CLEAR << 24 | KEY]
    cx, cy = 160, 120
    star = [(cx + icos(j * 2 + 144 * n - 90, 70), cy + isin(j * 2 + 144 * n - 90, 70)) for n in range(6)]
    for (x0, y0), (x1, y1) in zip(star, star[1:]):
        out += [g.OP_DRAW_LINE << 24 | rgb(255, 255, 0), g.xy(x0, y0), g.xy(x1, y1)]
    hexa = [(cx + icos(-j * 3 + 60 * n, 40), cy + isin(-j * 3 + 60 * n, 40)) for n in range(7)]
    for (x0, y0), (x1, y1) in zip(hexa, hexa[1:]):
        out += [g.OP_DRAW_LINE << 24 | rgb(0, 255, 255), g.xy(x0, y0), g.xy(x1, y1)]
    w = 120 + isin(j * 4, 100)
    out += [g.OP_FILL_RECT << 24 | rgb(255, 255, 255), g.xy(8, 90), (8 << 16) | 224 + 4]
    out += [g.OP_FILL_RECT << 24 | rgb(40, 40, 40), g.xy(10, 92), (4 << 16) | 224]
    out += [g.OP_FILL_RECT << 24 | rgb(255, 64, 64), g.xy(10, 92), (4 << 16) | w]
    return out


def reg(name, v):
    return g.OP_REG_WRITE << 24 | g.LAYER_REGS[name] << 16 | (v & g.LAYER_MASK[name])


def sky(line):
    t = line / 104
    return rgb(int(20 + 100 * t), int(40 + 140 * t), int(120 + 120 * t))


def frame_words(k, mark=False):
    out = [g.OP_WAIT_VBLANK << 24 | (1 if mark else 0)]
    # ライン 0 のレジスタ (空)
    out += [reg("tile_scroll_x", k // 2), reg("tile_scroll_y", 0), reg("bg_color", sky(0))]
    out += g.oam_write_words(0, g.oam_words(sprites(k)))
    out += [g.OP_SWAP << 24]
    # 空のグラデーション、丘、地面
    for line in range(8, 104, 8):
        out += [g.OP_WAIT_LINE << 24 | line, reg("bg_color", sky(line))]
    out += [g.OP_WAIT_LINE << 24 | 104, reg("tile_scroll_x", k)]
    out += [g.OP_WAIT_LINE << 24 | 128, reg("tile_scroll_x", 2 * k)]
    # 次のフレームの図形 (ライン 128 から 208 のあいだに終わる)
    out += shapes_words(k + 1)
    # 水面
    for line in range(208, 240, 4):
        out += [g.OP_WAIT_LINE << 24 | line, reg("tile_scroll_x", 3 * k + isin(line * 12 + k * 6, 6))]
    return out


def setup_words():
    out = []
    out += g.vram_write_words(BG_TILES, g.tile_words("demo"))
    out += g.vram_write_words(OBJ_TILES, object_tiles())
    out += g.vram_write_words(MAP_ADDR, g.map_words(g.map_entries("scene", 64, 32)))
    out += g.pal_write_words(0, g.palette_colors("demo", 64))
    out += g.pal_write_words(SPR_BANK * 64, sprite_palettes())
    # ビットマップの 2 枚の面: 表は透過色だけ、裏に図形 0
    out += [g.OP_CLEAR << 24 | KEY, g.OP_SWAP << 24]
    out += shapes_words(0)
    out += [reg("tile_map_base", MAP_ADDR), reg("tile_pat_base", BG_TILES), reg("tile_ctrl", 0b0001),   # 64 x 32
            reg("spr_pat_base", OBJ_TILES), reg("spr_bank", SPR_BANK), reg("spr_line_px", 320),
            reg("bitmap_key", KEY), reg("bitmap_rank", 4), reg("layer_ctrl", 0b1111)]
    return out
