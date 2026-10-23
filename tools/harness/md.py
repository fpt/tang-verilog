"""メガドライブの VDP の状態を、この VDP のコマンドに直す (docs/EMU_GPU_PLAN.md の E4。E5 のホスト翻訳層の下書き)

状態 (辞書):
  vram:  64KiB の bytes (メガドラの VRAM そのまま)
  cram:  64 色 (9bit、0000 BBB0 GGG0 RRR0)
  vsram: 縦スクロール (少なくとも 2 つ: [0] 面 A、[1] 面 B)
  regs:  VDP のレジスタ 24 個

直し方:
  - VRAM はそのまま 16K ワードに (4 バイトをビッグエンディアンの 32bit ワードに)。タイルの形式とマップのエントリの形式はメガドラと
    同じなので、マップはエントリの並びのビット (TILE_CTRL[7]) を立てるだけでよい。タイルの場所は 0
  - CRAM -> パレット 0..63 (バンク 0)。背景色はレジスタ 7
  - 面 A / B / ウィンドウ / 横スクロールの表のアドレスと大きさ、縦スクロール (VSRAM 0 / 1)
  - スプライトの表 (SAT) はリンクの順にたどって OAM に (x - 128、y - 128)。1 ラインの上限は 320 ピクセル
  - メガドラの画面は 320x224。この VDP は 320x240 なので、上下に 8 ラインずつの縁 (背景色だけ) を付け、面とスプライトを 8 ライン下げる。
    縁は WAIT_LINE でレイヤを切って作るので、比べるのは印を付けたフレーム
やっていないこと (warnings に出す): H32、インターレース、2 セル単位の縦スクロール (最初の列の値を画面全体に使う)、
  影/ハイライト、横スクロールのモード 01、1 ライン 20 個のスプライトの上限、x = 0 のスプライトによるマスク
"""
import math

import fbmodel
import gpu_model as g

TOP = 8                     # メガドラのライン 0 を置くライン


def md_color(c):
    r, gg, b = (c >> 1) & 7, (c >> 5) & 7, (c >> 9) & 7
    return fbmodel.to565(r * 255 // 7, gg * 255 // 7, b * 255 // 7)


def w16(vram, a):
    return vram[a & 0xFFFF] << 8 | vram[(a + 1) & 0xFFFF]


def sat_sprites(st):
    """SAT をリンクの順にたどる (最大 80 個)"""
    vram, regs = st["vram"], st["regs"]
    base = (regs[5] & 0x7E) << 9
    out, n, seen = [], 0, set()
    while n not in seen and len(out) < 80:
        seen.add(n)
        a = base + 8 * n
        y, size, attr, x = w16(vram, a) & 0x3FF, vram[a + 2], w16(vram, a + 4), w16(vram, a + 6) & 0x1FF
        out.append({"x": x - 128, "y": y - 128 + TOP, "w": (size >> 2 & 3) + 1, "h": (size & 3) + 1,
                    "tile": attr & 0x7FF, "hflip": bool(attr >> 11 & 1), "vflip": bool(attr >> 12 & 1),
                    "pal": attr >> 13 & 3, "pri": attr >> 15 & 1})
        n = vram[a + 3] & 0x7F
        if n == 0:
            break
    return out


def translate(st, mark=True):
    """状態 -> (コマンドの列, warnings)。最後に WAIT_VBLANK (印) から 1 フレーム分のレイヤの帯まで"""
    vram, regs, cram, vsram = st["vram"], st["regs"], st["cram"], st["vsram"]
    warn = []
    if not (regs[12] & 0x81):
        warn.append("H32 is not supported (drawn as H40)")
    if regs[12] & 0x06:
        warn.append("interlace is not supported")
    if regs[12] & 0x08:
        warn.append("shadow/highlight is not supported")
    if regs[11] & 0x04:
        warn.append("2-cell vertical scroll is not supported (column 0 is used for the whole screen)")
    hs = regs[11] & 3
    if hs == 1:
        warn.append("horizontal scroll mode 01 is not supported (treated as full screen)")

    size = {0: 0, 1: 1, 3: 2}
    wcode, hcode = size.get(regs[16] & 3, 0), size.get(regs[16] >> 4 & 3, 0)
    ctrl = 0x80 | hcode << 2 | wcode
    hs_base = ((regs[13] & 0x3F) << 10) // 4
    hs_mode, hs_off = {0: (1, 0), 1: (1, 0), 2: (2, TOP), 3: (3, TOP)}[hs]
    wv = regs[18]
    wv_pos = min((wv & 31) + TOP // 8, 31)

    out = g.vram_write_words(0, [int.from_bytes(vram[4 * i:4 * i + 4], "big") for i in range(16384)])
    out += g.pal_write_words(0, [md_color(c) for c in cram])
    out += g.oam_write_words(0, g.oam_words(sat_sprites(st)))

    def reg(name, v):
        return g.OP_REG_WRITE << 24 | g.LAYER_REGS[name] << 16 | (v & g.LAYER_MASK[name])

    bg = md_color(cram[(regs[7] >> 4 & 3) * 16 + (regs[7] & 15)])
    out += [reg("bg_color", bg),
            reg("tile_map_base", ((regs[2] & 0x38) << 10) // 4), reg("tile_pat_base", 0), reg("tile_ctrl", ctrl),
            reg("tile_scroll_x", 0), reg("tile_scroll_y", vsram[0] - TOP),
            reg("tileb_map_base", ((regs[4] & 0x07) << 13) // 4), reg("tileb_pat_base", 0), reg("tileb_ctrl", ctrl),
            reg("tileb_scroll_x", 0), reg("tileb_scroll_y", vsram[1] - TOP),
            reg("win_h", regs[17] & 0x9F), reg("win_v", (wv & 0x80) | wv_pos),
            reg("win_map_base", ((regs[3] & 0x3C) << 10) // 4 - 32 * (TOP // 8)),     # 64 列のマップの 1 行 = 32 ワード
            reg("hscroll_mode", hs_mode), reg("hscroll_base", hs_base - hs_off),
            reg("spr_pat_base", 0), reg("spr_bank", 0), reg("spr_line_px", 320), reg("bitmap_rank", 1)]
    on = 0b11100 if regs[1] & 0x40 else 0
    out += [g.OP_WAIT_VBLANK << 24 | (1 if mark else 0), reg("layer_ctrl", 0),
            g.OP_WAIT_LINE << 24 | TOP, reg("layer_ctrl", on),
            g.OP_WAIT_LINE << 24 | (TOP + 224), reg("layer_ctrl", 0)]
    return out, warn


# ---------------------------------------------------------------- 決まったテスト用の状態
def synthetic(variant=0):
    """メガドラの形式で作った、ゲームらしい 1 フレーム (実機のゲームのフレームが手に入るまでの代わり)
      0: 横スクロールはラインごと (面 A は波、面 B は斜め)、ウィンドウは上 2 セル + 右 (x >= 272)、面は 64x32
      1: 横スクロールは 8 ラインごと、ウィンドウは下 (ライン 192 から) + 左 (x < 64)、面 A は 128x32 (B も同じ大きさ)
      2: 横スクロールは画面全体、ウィンドウなし、面は 32x32、縦スクロールが大きい"""
    import demo
    vram = bytearray(65536)

    def put32(a, w):
        vram[a:a + 4] = (w & 0xFFFFFFFF).to_bytes(4, "big")

    def put16(a, v):
        vram[a:a + 2] = (v & 0xFFFF).to_bytes(2, "big")

    # タイル: 0..63 = 表 (sheet)、64..87 = スプライト (玉・矢印・輪)
    for i, w in enumerate(g.tile_words("sheet") + demo.object_tiles()):
        put32(4 * i, w)
    plane_a, plane_b, window, sat, hscroll = 0xC000, 0xE000, 0xB000, 0xF800, 0xFC00
    mw = {0: 64, 1: 128, 2: 32}[variant]
    if variant == 1:
        plane_a, plane_b = 0x8000, 0xC000           # 128x32 は 8KiB
    for r in range(32):
        for c in range(mw):
            k = (c * 7 + r * 3) % 29
            # 面 A: 地面と、空のところどころに置いたもの (半分くらいは透明)。高優先は奇数の行
            if r >= 20:
                e = 1 + (c + r) % 40 | (r % 4) << 13 | (r % 2) << 15
            else:
                e = (k + 5 | (c % 4) << 13 | (k % 5 == 0) << 15) if k < 6 else 0
            e |= (c % 3 == 0) << 11 | (r % 5 == 0) << 12
            put16(plane_a + 2 * (r * mw + c), e)
            # 面 B: 全面の模様 (ほとんど低優先)
            e = 16 + (c * 3 + r) % 32 | ((c // 8 + r // 4) % 4) << 13 | (c % 11 == 0 and r % 3 == 0) << 15
            put16(plane_b + 2 * (r * mw + c), e)
    for r in range(32):                             # ウィンドウ: 縁取りした HUD (64 列)
        for c in range(64):
            e = (2 if r in (0, 27) or c in (0, 39) else 9 + (c + r) % 3) | 1 << 13 | (r % 2) << 15
            put16(window + 2 * (r * 64 + c), e)
    for m in range(224):                            # 横スクロールの表 (面 A, 面 B)
        a_v = int(round(10 * math.sin(math.radians(m * 6 + variant * 40))))
        b_v = -(m // 2) - variant * 17
        put16(hscroll + 4 * m, a_v)
        put16(hscroll + 4 * m + 2, b_v)
    # スプライト 40 個。リンクは 0 から始まり、決まった順列でたどる
    order = [0] + [(i * 17) % 39 + 1 for i in range(39)]
    for j, n in enumerate(order):
        a = sat + 8 * n
        kind = j % 3
        tile, w, h = [(64, 2, 2), (68, 2, 2), (72, 4, 4)][kind]
        x = 128 - 20 + (j * 47 + variant * 31) % 360
        y = 128 - 12 + (j * 29 + variant * 13) % 240
        put16(a, y)
        vram[a + 2] = (w - 1) << 2 | (h - 1)
        vram[a + 3] = order[j + 1] if j + 1 < len(order) else 0
        put16(a + 4, tile | (j % 2) << 11 | (j % 7 == 0) << 12 | (j % 4) << 13 | (j % 3 == 1) << 15)
        put16(a + 6, x)
    cram = []
    for line in range(4):
        for i in range(16):
            r, gg, b = (i * 3 + line * 2) % 8, (i * 5 + line) % 8, (7 - i + line * 3) % 8
            cram.append(b << 9 | gg << 5 | r << 1)
    regs = [0] * 24
    regs[1] = 0x44
    regs[2] = plane_a >> 10
    regs[3] = window >> 10
    regs[4] = plane_b >> 13
    regs[5] = sat >> 9
    regs[7] = 0x2A                                  # 背景色: パレット 2 の 10
    regs[11] = [0x03, 0x02, 0x00][variant]
    regs[12] = 0x81                                 # H40
    regs[13] = hscroll >> 10
    regs[16] = [0x01, 0x03, 0x00][variant]          # 64x32 / 128x32 / 32x32
    regs[17] = [0x80 | 17, 4, 0][variant]           # 右 x >= 272 / 左 x < 64 / なし
    regs[18] = [0x02, 0x80 | 24, 0][variant]        # 上 16 ライン / 下 192 から / なし
    vsram = [[4, 20], [0, 300], [100, 200]][variant] + [0] * 38
    return {"vram": bytes(vram), "cram": cram, "vsram": vsram, "regs": regs}
