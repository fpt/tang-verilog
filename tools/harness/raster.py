"""三角形のラスタライザの参照 (docs/GPU3D_PLAN.md の 3.4 節、G1)。rtl/gpu3d/tri_setup.sv・tri_engine.sv と同じ整数の計算

即時モード (G1) と TBDR (G2) は、この同じセットアップの結果と走査の規則を使う。ここが「同じ絵を出す規則」の正。

  頂点: x, y は符号付き 12.4 (1/16 ピクセル)。ホストは -512..+831 ピクセル (ガードバンド) の中に収める
  ピクセル (px, py) の中心は (px * 16 + 8, py * 16 + 8)
  面積: area2 = (x1-x0)(y2-y0) - (y1-y0)(x2-x0) (1/256 ピクセル²)。0 なら描かない。負なら v1 と v2 を入れ替える (どちらの向きも描く)
  辺 i は頂点 i の向かい (e0: v1→v2、e1: v2→v0、e2: v0→v1)。辺 a→b の関数 E(p) = (xb-xa)(py-ya) - (yb-ya)(px-xa)。中は E > 0
  上左の規則: 辺が上か左 (dy < 0、または dy == 0 かつ dx > 0) なら E == 0 も中。そうでなければ E に -1 を足して E >= 0 で判定
  外接矩形 (ピクセル): px は (min x + 7) >> 4 .. (max x - 8) >> 4、py も同じ。クリップ矩形 (両端を含む) と重ねる
  属性 (Gouraud の r, g, b と z): 固定小数点 F = 12 bit
    d1 = a1 - a0, d2 = a2 - a0
    Nx = d1 (y2 - y0) + d2 (y0 - y1)、Ny = d1 (x0 - x2) + d2 (x1 - x0)        (1/16 ピクセルあたり、面積倍)
    n = area2 のビット長、m = ((1 << (n + 16)) - 1) // area2                (17bit の仮数、2^16 <= m < 2^17)
    gx = sat32((Nx * m) >> n)、gy = sat32((Ny * m) >> n)                    (1 ピクセルあたり x 2^12)
    s = sat32((a0 << 12) + ((gx (sx - x0) + gy (sy - y0)) >> 4))           (sx, sy は外接矩形の左上のピクセルの中心)
  走査: 行ごとに左から。E はピクセルごとに -dy*16、行ごとに dx*16。属性は 32bit で回る加算 (gx、gy)
  ピクセルの値: clamp(acc >> 12, 0, 最大値) (色は 255、z は 65535)。色は RGB565 に切り捨て
  Z (flags bit3): z < Z バッファ なら通る (同じ値は先に描いたものが勝つ)。通ったら z と色を書く
  テクスチャ (flags bit1、G3): 頂点ごとの {v, u} (10.6 = テクセル x 64、0..1023.98) も属性 (u, v) として同じ式で補間する。テクセルの座標は
    tu = (acc_u >>> 18) & (幅 - 1)、tv = (acc_v >>> 18) & (高さ - 1) (はみ出した分は折り返す)
    テクスチャ (SET_TEX): 形式 0 = 16bpp (RGB565、1 ワードに 2 つ、下位が偶数の u)、1 = 8bpp (1 ワードに 4 つ、u % 4 番目のバイト)、
    2 = 4bpp (1 ワードに 8 つ、u % 8 番目は [31 - 4k -: 4] = タイルの行と同じ並び)。8bpp / 4bpp は CLUT[(値 + clut) & 255] の色
    テクセル (tu, tv) のワードアドレスは base | (tv << (幅の log2 - s)) | (tu >> s) (s は 16bpp 1、8bpp 2、4bpp 3)。
    base はテクスチャのワード数 (2 ^ (幅の log2 + 高さの log2 - s)) の倍数にする (足し算でなく OR で作るため)
    色 0 (RGB565 の 0x0000) のテクセルは透明 (色も Z も書かない)。Gouraud なら頂点の色で変調する (PS1 と同じく 128 = 1 倍):
    R = min(31, (texR * r) >> 7)、G = min(63, (texG * g) >> 7)、B = min(31, (texB * b) >> 7)。Gouraud でなければテクセルの色そのまま
  半透明 (flags bit2、G4): 描く色 F (テクスチャ・変調のあと) を描く面の色 B と RGB565 の成分ごとに混ぜる。式は flags [5:4] (PS1 と同じ 4 つ):
    0 平均 (B + F) >> 1、1 加算 min(最大, B + F)、2 減算 max(0, B - F)、3 1/4 加算 min(最大, B + (F >> 2))
    Z (bit3) があれば Z テストはするが、Z は書かない。透明のテクセル (色 0) は半透明でも描かない
"""

F = 12
FLAG_GOURAUD, FLAG_TEX, FLAG_SEMI, FLAG_Z = 1, 2, 4, 8


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def wrap32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v >> 31 else v


def sat32(v):
    return max(-(1 << 31), min((1 << 31) - 1, v))


def words_per_tri(flags):
    return 1 + 3 * (1 + (flags & FLAG_GOURAUD and 1) + (flags & FLAG_Z and 1) + (flags & FLAG_TEX and 1))


def parse(words):
    """TRI のワード列 → (flags, 単色, 頂点 [(x, y, (r, g, b), z, (u, v))] x 3)。頂点ごとに {y, x}、[色]、[z]、[{v, u}]"""
    w0 = words[0]
    flags, color = (w0 >> 16) & 0xFF, w0 & 0xFFFF
    vs, i = [], 1
    for _ in range(3):
        x, y = s16(words[i]), s16(words[i] >> 16)
        i += 1
        rgb = (0, 0, 0)
        if flags & FLAG_GOURAUD:
            c = words[i]
            rgb = ((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF)
            i += 1
        z = 0
        if flags & FLAG_Z:
            z = words[i] & 0xFFFF
            i += 1
        uv = (0, 0)
        if flags & FLAG_TEX:
            uv = (words[i] & 0xFFFF, (words[i] >> 16) & 0xFFFF)
            i += 1
        vs.append((x, y, rgb, z, uv))
    return flags, color, vs


def setup(vs, clip):
    """セットアップ。描くものがなければ None。clip = (x0, y0, x1, y1) ピクセル、両端を含む"""
    (x0, y0, *_), (x1, y1, *_), (x2, y2, *_) = vs
    area2 = (x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0)
    if area2 == 0:
        return None
    if area2 < 0:
        vs = [vs[0], vs[2], vs[1]]
        area2 = -area2
    (x0, y0, c0, z0, t0), (x1, y1, c1, z1, t1), (x2, y2, c2, z2, t2) = vs
    cx0, cy0, cx1, cy1 = clip
    bx0 = max(cx0, (min(x0, x1, x2) + 7) >> 4)
    bx1 = min(cx1, (max(x0, x1, x2) - 8) >> 4)
    by0 = max(cy0, (min(y0, y1, y2) + 7) >> 4)
    by1 = min(cy1, (max(y0, y1, y2) - 8) >> 4)
    if bx0 > bx1 or by0 > by1:
        return None
    sx, sy = bx0 * 16 + 8, by0 * 16 + 8
    edges = []
    for (xa, ya), (xb, yb) in (((x1, y1), (x2, y2)), ((x2, y2), (x0, y0)), ((x0, y0), (x1, y1))):
        dx, dy = xb - xa, yb - ya
        tl = dy < 0 or (dy == 0 and dx > 0)
        e = dx * (sy - ya) - dy * (sx - xa) + (0 if tl else -1)
        edges.append((e, -dy * 16, dx * 16))
    n = area2.bit_length()
    m = ((1 << (n + 16)) - 1) // area2
    attrs = []
    for a in ([c[0] for c in (c0, c1, c2)], [c[1] for c in (c0, c1, c2)], [c[2] for c in (c0, c1, c2)], [z0, z1, z2],
              [t[0] for t in (t0, t1, t2)], [t[1] for t in (t0, t1, t2)]):
        d1, d2 = a[1] - a[0], a[2] - a[0]
        nx = d1 * (y2 - y0) + d2 * (y0 - y1)
        ny = d1 * (x0 - x2) + d2 * (x1 - x0)
        gx, gy = sat32((nx * m) >> n), sat32((ny * m) >> n)
        s = sat32((a[0] << F) + ((gx * (sx - x0) + gy * (sy - y0)) >> 4))
        attrs.append((s, gx, gy))
    return {"bbox": (bx0, by0, bx1, by1), "edges": edges, "attrs": attrs, "area2": area2, "n": n, "m": m}


def pixels(rec):
    """外接矩形を行ごとに左から: (x, y, 中か, (r, g, b), z, (u の累算, v の累算))"""
    bx0, by0, bx1, by1 = rec["bbox"]
    er = [e for e, _, _ in rec["edges"]]
    ar = [s for s, _, _ in rec["attrs"]]
    for y in range(by0, by1 + 1):
        e = list(er)
        a = list(ar)
        for x in range(bx0, bx1 + 1):
            inside = all(v >= 0 for v in e)
            vals = [max(0, min(mx, wrap32(v) >> F)) for v, mx in zip(a, (255, 255, 255, 65535))]
            yield x, y, inside, tuple(vals[:3]), vals[3], (wrap32(a[4]), wrap32(a[5]))
            e = [v + sx for v, (_, sx, _) in zip(e, rec["edges"])]
            a = [wrap32(v + gx) for v, (_, gx, _) in zip(a, rec["attrs"])]
        er = [v + sy for v, (_, _, sy) in zip(er, rec["edges"])]
        ar = [wrap32(v + gy) for v, (_, _, gy) in zip(ar, rec["attrs"])]


def blend(mode, b, f):
    """半透明: 描く面の色 b と描く色 f (どちらも RGB565) を成分ごとに混ぜる。mode は flags [5:4]"""
    out = 0
    for sh, mx in ((11, 31), (5, 63), (0, 31)):
        bc, fc = (b >> sh) & mx, (f >> sh) & mx
        if mode == 0:
            c = (bc + fc) >> 1
        elif mode == 1:
            c = min(mx, bc + fc)
        elif mode == 2:
            c = max(0, bc - fc)
        else:
            c = min(mx, bc + (fc >> 2))
        out |= c << sh
    return out


def to565(rgb):
    r, g, b = rgb
    return (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)


TEX_SHIFT = {0: 1, 1: 2, 2: 3}        # 形式 (16 / 8 / 4bpp) → 1 ワードのテクセル数の log2


def texel(read, tex, clut, uv):
    """テクセルの色 (RGB565)。read(ワードアドレス) は SDRAM、tex = (形式, 幅の log2, 高さの log2, CLUT のずらし, base)、uv は累算の値"""
    fmt, wl, hl, coff, base = tex
    tu = (uv[0] >> 18) & ((1 << wl) - 1)
    tv = (uv[1] >> 18) & ((1 << hl) - 1)
    sh = TEX_SHIFT[fmt]
    w = read((base | (tv << (wl - sh)) | (tu >> sh)) & 0x1FFFFF)
    if fmt == 0:
        return (w >> (16 * (tu & 1))) & 0xFFFF
    v = (w >> (8 * (tu & 3))) & 0xFF if fmt == 1 else (w >> (28 - 4 * (tu & 7))) & 0xF
    return clut[(v + coff) & 0xFF]


def modulate(t, rgb):
    """テクセル (RGB565) を頂点の色 (8bit、128 = 1 倍) で変調する"""
    r, g, b = rgb
    return (min(31, (t >> 11) * r >> 7) << 11 | min(63, ((t >> 5) & 63) * g >> 7) << 5 | min(31, (t & 31) * b >> 7))

