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
    return 1 + 3 * (1 + (flags & FLAG_GOURAUD and 1) + (flags & FLAG_Z and 1))


def parse(words):
    """TRI のワード列 → (flags, 単色, 頂点 [(x, y, (r, g, b), z)] x 3)"""
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
        vs.append((x, y, rgb, z))
    return flags, color, vs


def setup(vs, clip):
    """セットアップ。描くものがなければ None。clip = (x0, y0, x1, y1) ピクセル、両端を含む"""
    (x0, y0, _, _), (x1, y1, _, _), (x2, y2, _, _) = vs
    area2 = (x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0)
    if area2 == 0:
        return None
    if area2 < 0:
        vs = [vs[0], vs[2], vs[1]]
        area2 = -area2
    (x0, y0, c0, z0), (x1, y1, c1, z1), (x2, y2, c2, z2) = vs
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
    for a in ([c[0] for c in (c0, c1, c2)], [c[1] for c in (c0, c1, c2)], [c[2] for c in (c0, c1, c2)], [z0, z1, z2]):
        d1, d2 = a[1] - a[0], a[2] - a[0]
        nx = d1 * (y2 - y0) + d2 * (y0 - y1)
        ny = d1 * (x0 - x2) + d2 * (x1 - x0)
        gx, gy = sat32((nx * m) >> n), sat32((ny * m) >> n)
        s = sat32((a[0] << F) + ((gx * (sx - x0) + gy * (sy - y0)) >> 4))
        attrs.append((s, gx, gy))
    return {"bbox": (bx0, by0, bx1, by1), "edges": edges, "attrs": attrs, "area2": area2, "n": n, "m": m}


def pixels(rec):
    """外接矩形を行ごとに左から: (x, y, 中か, (r, g, b), z)"""
    bx0, by0, bx1, by1 = rec["bbox"]
    er = [e for e, _, _ in rec["edges"]]
    ar = [s for s, _, _ in rec["attrs"]]
    for y in range(by0, by1 + 1):
        e = list(er)
        a = list(ar)
        for x in range(bx0, bx1 + 1):
            inside = all(v >= 0 for v in e)
            vals = [max(0, min(mx, wrap32(v) >> F)) for v, mx in zip(a, (255, 255, 255, 65535))]
            yield x, y, inside, tuple(vals[:3]), vals[3]
            e = [v + sx for v, (_, sx, _) in zip(e, rec["edges"])]
            a = [wrap32(v + gx) for v, (_, gx, _) in zip(a, rec["attrs"])]
        er = [v + sy for v, (_, _, sy) in zip(er, rec["edges"])]
        ar = [wrap32(v + gy) for v, (_, _, gy) in zip(ar, rec["attrs"])]


def to565(rgb):
    r, g, b = rgb
    return (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)
