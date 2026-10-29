"""G5 の 3D の場面 (docs/GPU3D_PLAN.md の G5)。Final Reality 風に、ロゴ・トンネル・映り込む玉のある部屋・夜の街

ホストの仕事 (PS1 の CPU + GTE がやっていたこと) を Python で: 頂点の変換、視錐台とガードバンドで切る (クリップ)、裏面を捨てる、
頂点の明るさ (平行光 + 環境光、霧)、環境マップ (視点から見た法線で uv を作る)、奥から手前への並べ替え。
GPU (make TARGET=gpu3d) には画面の座標の TRI (raster.py の規則) を送るだけ。

フレーム k のコマンドは k だけで決まる (前のフレームの状態を使わない) ので、同じ関数を
  - 実機で流し続ける (harness.py demo <場面>)
  - 参照モデルと Verilator・実機で比べる (シナリオ g5_scenes の demo3d_setup / demo3d_frame)
の両方に使う (demo.py と同じ)。

ハーネス v1 の SPI は 1 秒に約 45,000 ワードなので、TRI (テクスチャ + Gouraud で 10 ワード、Z 込みで 13) を 1 フレーム 150〜250 個にしてある。
Z は要るところだけ (ロゴ)。ほかは奥から手前に並べて描く (PS1 と同じ)。

場面:
  logo    TANG の文字を押し出した立体 (金色の環境マップ) が奥から飛んできて揺れる。背景はグラデーション、下に光の帯 (加算の半透明)
  tunnel  曲がるトンネルの中を進む。石のテクスチャ、奥ほど暗く (霧)、ところどころ光の輪 (加算の半透明)
  room    市松の床と壁の部屋で、映り込む玉 (環境マップ) が弾む。床への映り込み (玉を床の下に写して描き、床を平均の半透明で重ねる) と影 (減算)
  city    夜の街の上を飛ぶ。窓のテクスチャのビル、奥ほど暗く、街灯 (加算の半透明)
"""
import math

import gpu_model as g

W, H = 320, 240
CX, CY = 160.0, 120.0
NEAR, FAR = 0.1, 64.0
TEX_BASE = 0xA0000                      # テクスチャ VRAM (SDRAM のバイト 0x280000)。64 x 64 の 16bpp は 2,048 ワード

# テクスチャ: 名前 → (番号, 幅, 高さ)。どれも 16bpp。先頭は 2,048 ワードの倍数 (= テクスチャのワード数の倍数)
TEX = {"stone": 0, "env": 1, "floor": 2, "wall": 3, "window": 4, "ground": 5, "gold": 6}


def tex_base(name):
    return TEX_BASE + 2048 * TEX[name]


# ---- ベクトル ----

def add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def mul(a, s):
    return (a[0] * s, a[1] * s, a[2] * s)


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def norm(a):
    n = math.sqrt(dot(a, a)) or 1.0
    return (a[0] / n, a[1] / n, a[2] / n)


def rot_y(a):
    c, s = math.cos(a), math.sin(a)
    return ((c, 0, s), (0, 1, 0), (-s, 0, c))


def rot_x(a):
    c, s = math.cos(a), math.sin(a)
    return ((1, 0, 0), (0, c, -s), (0, s, c))


def rot_z(a):
    c, s = math.cos(a), math.sin(a)
    return ((c, -s, 0), (s, c, 0), (0, 0, 1))


def mmul(a, b):
    return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))


def mvec(m, v):
    return (dot(m[0], v), dot(m[1], v), dot(m[2], v))


IDENT = ((1, 0, 0), (0, 1, 0), (0, 0, 1))


# ---- カメラと描画 ----

class Camera:
    """y が上の世界。視点の座標は x 右、y 上、z 前。画面は sx = CX + f x / z、sy = CY - f y / z"""

    def __init__(self, eye, target, fov=70.0, roll=0.0):
        self.eye = eye
        fwd = norm(sub(target, eye))
        right = norm(cross((0, 1, 0), fwd))
        up = cross(fwd, right)
        if roll:
            c, s = math.cos(roll), math.sin(roll)
            right, up = add(mul(right, c), mul(up, s)), add(mul(up, c), mul(right, -s))
        self.rot = (right, up, fwd)
        self.f = CX / math.tan(math.radians(fov) / 2)

    def view(self, p):
        return mvec(self.rot, sub(p, self.eye))

    def view_dir(self, d):
        return mvec(self.rot, d)


# ガードバンド (raster.py: 頂点は -512..+831 ピクセル) の少し内側で切る
GB_LO, GB_HI = -480.0, 800.0


def _planes(f):
    """視点の座標で「中」が 0 以上になる平面 (a, b, c) (a x + b y + c z): 近い面、ガードバンドの左右上下"""
    return [(0.0, 0.0, 1.0, -NEAR),
            (f, 0.0, CX - GB_LO, 0.0), (-f, 0.0, GB_HI - CX, 0.0),
            (0.0, -f, CY - GB_LO, 0.0), (0.0, f, GB_HI - CY, 0.0)]


def _clip(poly, planes):
    """Sutherland-Hodgman。頂点は (視点の座標, 属性のタプル)"""
    for a, b, c, d in planes:
        out = []
        n = len(poly)
        for i in range(n):
            p, q = poly[i], poly[(i + 1) % n]
            dp = a * p[0][0] + b * p[0][1] + c * p[0][2] + d
            dq = a * q[0][0] + b * q[0][1] + c * q[0][2] + d
            if dp >= 0:
                out.append(p)
            if (dp >= 0) != (dq >= 0):
                t = dp / (dp - dq)
                out.append((tuple(pv + (qv - pv) * t for pv, qv in zip(p[0], q[0])),
                            tuple(pv + (qv - pv) * t for pv, qv in zip(p[1], q[1]))))
        poly = out
        if len(poly) < 3:
            return []
    return poly


def zval(z):
    """視点の z → Z バッファの値 (1/z に比例するので画面で線形に補間してよい)"""
    v = (1.0 - NEAR / z) * FAR / (FAR - NEAR)
    return max(0, min(65534, int(v * 65535)))


class Frame:
    """1 フレームの三角形を集める。draw() で多角形を足し、words() で TRI のワード列にする"""

    def __init__(self, cam):
        self.cam = cam
        self.planes = _planes(cam.f)
        self.items = []                  # (並べ替えのキー, 投入順, set_tex のワード, TRI のワード)
        self.n = 0

    def poly(self, pts, cols, uvs=None, tex=None, zbuf=False, blend=None, cull=1, key=None, flat=None):
        """世界の座標の多角形 (凸、反時計回りが表 = cull 1、-1 なら逆、0 なら両面)。cols は頂点の色 (r, g, b、テクスチャなら 128 = 1 倍)。
        uvs はテクセル。key は並べ替えのキー (大きいほど先に描く。省略すると視点からの平均の距離)"""
        cam = self.cam
        vs = [cam.view(p) for p in pts]
        attrs = [tuple(c) + (tuple(uvs[i]) if uvs else ()) for i, c in enumerate(cols)]
        clipped = _clip(list(zip(vs, attrs)), self.planes)
        if not clipped:
            return
        scr = [(CX + cam.f * v[0] / v[2], CY - cam.f * v[1] / v[2]) for v, _ in clipped]
        area = 0.0
        for i in range(len(scr)):
            x0, y0 = scr[i]
            x1, y1 = scr[(i + 1) % len(scr)]
            area += x0 * y1 - x1 * y0
        if cull and area * cull > 0:     # 画面は y が下なので、反時計回り (表) は面積が負
            return
        if key is None:
            key = sum(v[2] for v, _ in clipped) / len(clipped)
        set_tex = []
        if tex:
            set_tex = g.encode({"op": "set_tex", "base": tex_base(tex), "fmt": "16", "w": 64, "h": 64})
        for i in range(1, len(clipped) - 1):
            idx = (0, i, i + 1)
            step = {"op": "tri", "v": [[round(scr[j][0], 2), round(scr[j][1], 2)] for j in idx]}
            if flat is not None:
                step["color"] = flat
            else:
                step["rgb"] = ["#%02x%02x%02x" % tuple(max(0, min(255, int(c))) for c in clipped[j][1][:3]) for j in idx]
            if uvs:
                us = [clipped[j][1][3] for j in idx]
                vv = [clipped[j][1][4] for j in idx]
                du, dv = 64 * math.floor(min(us) / 64), 64 * math.floor(min(vv) / 64)
                step["uv"] = [[min(1023.9, max(0.0, us[k] - du)), min(1023.9, max(0.0, vv[k] - dv))] for k in range(3)]
            if zbuf:
                step["z"] = [zval(clipped[j][0][2]) for j in idx]
            if blend:
                step["blend"] = blend
            self.items.append((key, self.n, tuple(set_tex), g.tri_words(step)))
            self.n += 1

    def words(self, sort=True):
        items = sorted(self.items, key=lambda it: (-it[0], it[1])) if sort else self.items
        out, cur = [], None
        for _, _, st, tw in items:
            if st and st != cur:
                out += list(st)
                cur = st
            out += tw
        return out


def shade(n, light, base, amb=0.35, dif=0.75):
    """頂点の色: base x (環境光 + 拡散)。base は (r, g, b)"""
    k = amb + dif * max(0.0, dot(n, light))
    return tuple(c * k for c in base)


def fog(col, dist, near, far):
    k = 1.0 - min(1.0, max(0.0, (dist - near) / (far - near)))
    return tuple(c * k for c in col)


def env_uv(cam, n):
    """環境マップ (球面の写像を簡単にしたもの): 視点から見た法線の x, y → テクセル"""
    v = cam.view_dir(n)
    return (32 + 31 * v[0], 32 - 31 * v[1])


# ---- テクスチャ ----

def _rgb(r, g_, b):
    c = (int(r) >> 3) << 11 | (int(g_) >> 2) << 5 | (int(b) >> 3)
    return c or 0x0021                  # 色 0 は透明なので避ける


def _hash(x, y, s=0):
    h = (x * 374761393 + y * 668265263 + s * 2246822519) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return (h ^ (h >> 16)) & 0xFFFF


def tex_pixel(name, u, v):
    if name == "stone":                 # 石のブロック (目地は暗く、ブロックごとに色を少し変える)
        row = v // 16
        off = 8 if row % 2 else 0
        bx = (u + off) // 16
        edge = (u + off) % 16 == 0 or v % 16 == 0
        n = _hash(bx, row) % 40 + _hash(u, v, 1) % 24
        if edge:
            return _rgb(40, 34, 30)
        return _rgb(120 + n, 105 + n, 90 + n // 2)
    if name in ("env", "gold"):         # 環境マップ: 上は空 (青から白)、下は床 (暗い市松)、地平線に明るい帯と窓の光
        dx, dy = u - 31.5, v - 31.5
        r2 = (dx * dx + dy * dy) / (32 * 32)
        if v < 30:
            t = v / 30
            r, g_, b = 60 + 180 * t, 90 + 150 * t, 200 + 55 * t
            if (u // 8 + v // 10) % 5 == 0 and v > 10:
                r, g_, b = 255, 250, 220
        elif v < 34:
            r, g_, b = 255, 255, 255
        else:
            c = 90 if ((u // 8) + (v // 8)) % 2 else 40
            r, g_, b = c, c, c + 10
        k = 1.0 - 0.35 * r2
        if name == "gold":
            return _rgb(min(255, r * k * 1.0), min(255, g_ * k * 0.8), min(255, b * k * 0.35))
        return _rgb(min(255, r * k), min(255, g_ * k), min(255, b * k))
    if name == "floor":                 # 大理石の市松
        a = ((u // 32) + (v // 32)) % 2
        n = _hash(u // 2, v // 2, 3) % 20
        vein = 30 if (u + 2 * v + _hash(u // 8, v // 8, 4) % 6) % 23 == 0 else 0
        if a:
            return _rgb(220 - n - vein, 215 - n - vein, 205 - n - vein)
        return _rgb(50 + n + vein, 55 + n + vein, 70 + n + vein)
    if name == "wall":                  # 縦のパネル
        x = u % 32
        if x < 2 or v % 64 < 2:
            return _rgb(60, 40, 30)
        n = _hash(u // 4, v, 5) % 16
        return _rgb(150 + n, 110 + n, 80 + n // 2) if x < 30 else _rgb(90, 64, 45)
    if name == "window":                # ビルの窓 (16 x 16 に 1 つ、点いているものと消えているもの)
        wx, wy = u // 16, v // 16
        x, y = u % 16, v % 16
        if 3 <= x < 13 and 4 <= y < 13:
            if _hash(wx, wy, 7) % 3:
                k = 200 + _hash(wx, wy, 8) % 55
                return _rgb(k, k * 0.85, k * 0.45)
            return _rgb(20, 25, 40)
        return _rgb(70, 75, 90)
    if name == "ground":                # 道路: アスファルトと白線
        if u % 64 < 2:
            return _rgb(200, 200, 160)
        n = _hash(u, v, 9) % 24
        return _rgb(40 + n, 40 + n, 46 + n)
    raise ValueError(name)


def tex_upload(name):
    """64 x 64 の 16bpp を raster.py の並び (4 x 4 テクセルのかたまり) で"""
    import raster
    words = [0] * 2048
    for v in range(64):
        for u in range(0, 64, 2):
            words[raster.tex_index(0, 6, u, v)] = tex_pixel(name, u, v) | tex_pixel(name, u + 1, v) << 16
    return [g.OP_UPLOAD << 24 | len(words), tex_base(name)] + words


# ---- 形 ----

FONT = {                                 # 5 x 7
    "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "N": ["#...#", "##..#", "#.#.#", "#.#.#", "#..##", "#...#", "#...#"],
    "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###."],
}


def logo_quads(text):
    """文字のマスを押し出した立体の四角形 (中心が原点、1 マス 1、奥行き 1.2)。返すのは (4 隅, 法線)"""
    cells = set()
    for i, ch in enumerate(text):
        for y, row in enumerate(FONT[ch]):
            for x, c in enumerate(row):
                if c == "#":
                    cells.add((i * 6 + x, y))
    w = len(text) * 6 - 1
    ox, oy, d = w / 2, 3.5, 0.6
    quads = []

    def P(x, y, z):
        return (x - ox, oy - y, z)
    # 前と後ろの面は行ごとのつながりで 1 枚に
    for y in range(7):
        x = 0
        while x < w:
            if (x, y) in cells:
                x1 = x
                while (x1 + 1, y) in cells:
                    x1 += 1
                quads.append(([P(x, y + 1, -d), P(x1 + 1, y + 1, -d), P(x1 + 1, y, -d), P(x, y, -d)], (0, 0, -1)))
                quads.append(([P(x, y, d), P(x1 + 1, y, d), P(x1 + 1, y + 1, d), P(x, y + 1, d)], (0, 0, 1)))
                x = x1 + 1
            else:
                x += 1
    for (x, y) in cells:
        if (x - 1, y) not in cells:
            quads.append(([P(x, y + 1, d), P(x, y + 1, -d), P(x, y, -d), P(x, y, d)], (-1, 0, 0)))
        if (x + 1, y) not in cells:
            quads.append(([P(x + 1, y + 1, -d), P(x + 1, y + 1, d), P(x + 1, y, d), P(x + 1, y, -d)], (1, 0, 0)))
        if (x, y - 1) not in cells:
            quads.append(([P(x, y, -d), P(x + 1, y, -d), P(x + 1, y, d), P(x, y, d)], (0, 1, 0)))
        if (x, y + 1) not in cells:
            quads.append(([P(x, y + 1, d), P(x + 1, y + 1, d), P(x + 1, y + 1, -d), P(x, y + 1, -d)], (0, -1, 0)))
    # 向きをそろえる: 表から見て反時計回り (cross(p1 - p0, p2 - p0) が法線と逆向き。Frame.poly の cull 1 で表が残る)
    out = []
    for pts, n in quads:
        if dot(cross(sub(pts[1], pts[0]), sub(pts[2], pts[0])), n) > 0:
            pts = pts[::-1]
        out.append((pts, n))
    return out


LOGO = logo_quads("TANG")


def sphere(cx, cy, cz, r, nlat=6, nlon=10):
    """緯度経度の球の四角形 (三角形も 4 隅の形で、極は 3 点)。返すのは (点, 法線) の列"""
    out = []
    for i in range(nlat):
        a0, a1 = math.pi * i / nlat - math.pi / 2, math.pi * (i + 1) / nlat - math.pi / 2
        for j in range(nlon):
            b0, b1 = 2 * math.pi * j / nlon, 2 * math.pi * (j + 1) / nlon
            ns = []
            for a, b in ((a0, b0), (a0, b1), (a1, b1), (a1, b0)):
                ns.append((math.cos(a) * math.cos(b), math.sin(a), math.cos(a) * math.sin(b)))
            if i == 0:
                ns = [ns[0], ns[2], ns[3]]
            elif i == nlat - 1:
                ns = [ns[0], ns[1], ns[2]]
            out.append([((cx + r * n[0], cy + r * n[1], cz + r * n[2]), n) for n in ns])
    return out


# ---- 場面 ----

def sky(fr, top, bottom, key=1e9):
    """画面全体のグラデーション (視点の前に置いた大きな四角形)。いちばん先に描く"""
    cam = fr.cam
    fwd, up, right = cam.rot[2], cam.rot[1], cam.rot[0]
    c = add(cam.eye, mul(fwd, 50))
    hw, hh = 50 * CX / cam.f * 1.1, 50 * CY / cam.f * 1.1
    pts = [add(add(c, mul(right, -hw)), mul(up, hh)), add(add(c, mul(right, hw)), mul(up, hh)),
           add(add(c, mul(right, hw)), mul(up, -hh)), add(add(c, mul(right, -hw)), mul(up, -hh))]
    fr.poly(pts, [top, top, bottom, bottom], cull=0, key=key)


def scene_logo(k):
    t = k / 60.0
    cam = Camera((0, 1.5, -26), (0, 0, 0), fov=60)
    fr = Frame(cam)
    sky(fr, (10, 10, 40), (120, 40, 90))
    fly = max(0.0, 1.0 - t / 2.0)                      # 最初の 2 秒で奥から飛んでくる
    pos = (0, 0.6 * math.sin(t * 1.3), 60 * fly * fly)
    m = mmul(rot_y(0.5 * math.sin(t * 0.9) + 6 * fly), rot_x(0.15 * math.sin(t * 0.7)))
    light = norm((0.4, 0.8, -0.6))
    for pts, n in LOGO:
        wn = mvec(m, n)
        wp = [add(mvec(m, p), pos) for p in pts]
        col = shade(wn, light, (150, 140, 120), amb=0.55, dif=0.6)
        uv = env_uv(cam, wn)
        # 面ごとに環境マップの位置を少しずらす (平らな面でも映り込みが流れて見えるように)
        uvs = []
        for p in wp:
            vp = cam.view(p)
            uvs.append((min(63.5, max(0.0, uv[0] + 0.6 * vp[0])), min(63.5, max(0.0, uv[1] - 0.6 * vp[1]))))
        fr.poly(wp, [col] * len(wp), uvs, tex="gold", zbuf=True, key=0)
    # 下の光の帯 (加算の半透明)。ロゴの後ろの床に流れる
    for i in range(6):
        z = ((i * 6 - t * 12) % 36) - 6
        a = 1.0 - abs(z - 12) / 24
        c = (40 * a, 90 * a, 160 * a)
        fr.poly([(-14, -6, z), (14, -6, z), (14, -6, z + 1.5), (-14, -6, z + 1.5)], [c] * 4, cull=0, blend="add", key=-1)
    return fr.words()


def tunnel_center(s):
    return (3.0 * math.sin(s * 0.11) + 1.5 * math.sin(s * 0.23), 2.0 * math.sin(s * 0.07), s)


def scene_tunnel(k):
    s0 = k * 0.12
    eye = tunnel_center(s0)
    cam = Camera(eye, tunnel_center(s0 + 3), fov=75, roll=0.3 * math.sin(s0 * 0.1))
    fr = Frame(cam)
    sides, rings, r = 10, 11, 2.2
    first = math.floor(s0) - 1
    light = (0.0, 0.0, 1.0)
    flick = 0.85 + 0.15 * math.sin(k * 0.3)
    pts = {}
    for i in range(rings + 1):
        s = first + i
        c = tunnel_center(s)
        for j in range(sides + 1):
            a = 2 * math.pi * j / sides + s * 0.05
            n = (-math.cos(a), -math.sin(a), 0.0)
            p = (c[0] + r * math.cos(a), c[1] + r * math.sin(a), c[2])
            dist = s - s0
            col = fog(shade(n, light, (200 * flick, 190 * flick, 170 * flick), amb=0.9, dif=0.2), dist, 1.0, rings - 1)
            pts[i, j] = (p, col, (j * 16.0, (s % 4) * 16.0))
    for i in range(rings):
        for j in range(sides):
            q = [pts[i, j], pts[i, j + 1], pts[i + 1, j + 1], pts[i + 1, j]]
            uvs = [x[2] for x in q]
            if uvs[2][1] < uvs[0][1]:                    # v は 4 段で回るので、つなぎ目は 64 にする
                uvs = [uvs[0], uvs[1], (uvs[2][0], 64.0), (uvs[3][0], 64.0)]
            fr.poly([x[0] for x in q], [x[1] for x in q], uvs, tex="stone", key=i)
    # 光の輪 (加算の半透明): 6 つおき
    for i in range(rings):
        s = first + i
        if s % 6 != 0:
            continue
        c = tunnel_center(s + 0.5)
        a_ = max(0.0, 1.0 - (s - s0) / rings)
        col = (30 * a_, 160 * a_, 220 * a_)
        for j in range(sides):
            a0, a1 = 2 * math.pi * j / sides, 2 * math.pi * (j + 1) / sides
            ro, ri = r * 0.97, r * 0.75
            fr.poly([(c[0] + ro * math.cos(a0), c[1] + ro * math.sin(a0), c[2]), (c[0] + ro * math.cos(a1), c[1] + ro * math.sin(a1), c[2]),
                     (c[0] + ri * math.cos(a1), c[1] + ri * math.sin(a1), c[2]), (c[0] + ri * math.cos(a0), c[1] + ri * math.sin(a0), c[2])],
                    [col] * 4, cull=0, blend="add", key=i - 0.5)
    return fr.words()


ROOM = 6.0                                           # 部屋は x, z が -6..6、y が 0..5


def scene_room(k):
    t = k / 60.0
    a = t * 0.35
    cam = Camera((9.5 * math.sin(a), 3.2, -9.5 * math.cos(a)), (0, 1.2, 0), fov=70)
    fr = Frame(cam)
    light = norm((0.3, 1.0, 0.2))
    hy = 5.0
    # 壁と天井 (内側が表、奥から手前)
    walls = [([(-ROOM, 0, ROOM), (ROOM, 0, ROOM), (ROOM, hy, ROOM), (-ROOM, hy, ROOM)], (0, 0, -1)),
             ([(ROOM, 0, -ROOM), (-ROOM, 0, -ROOM), (-ROOM, hy, -ROOM), (ROOM, hy, -ROOM)], (0, 0, 1)),
             ([(-ROOM, 0, -ROOM), (-ROOM, 0, ROOM), (-ROOM, hy, ROOM), (-ROOM, hy, -ROOM)], (1, 0, 0)),
             ([(ROOM, 0, ROOM), (ROOM, 0, -ROOM), (ROOM, hy, -ROOM), (ROOM, hy, ROOM)], (-1, 0, 0))]
    for pts, n in walls:
        (x0, _, z0), (x1, _, z1) = pts[0], pts[1]
        for s in range(2):                          # 横に 2 つに分けて (アフィンの歪みを減らす)
            f0, f1 = s / 2, (s + 1) / 2
            p0 = (x0 + (x1 - x0) * f0, 0, z0 + (z1 - z0) * f0)
            p1 = (x0 + (x1 - x0) * f1, 0, z0 + (z1 - z0) * f1)
            q = [p0, p1, (p1[0], hy, p1[2]), (p0[0], hy, p0[2])]
            cols = [shade(n, light, (150, 150, 150), amb=0.7, dif=0.3) if p[1] > 0 else shade(n, light, (90, 90, 100), amb=0.7, dif=0.3) for p in q]
            fr.poly(q, cols, [(s * 64.0, 64.0), (s * 64.0 + 64, 64.0), (s * 64.0 + 64, 0.0), (s * 64.0, 0.0)], tex="wall", key=1000)
    fr.poly([(-ROOM, hy, ROOM), (ROOM, hy, ROOM), (ROOM, hy, -ROOM), (-ROOM, hy, -ROOM)], [(30, 30, 40)] * 4, key=1000)
    fr.poly([(-1.5, hy - 0.01, 1.5), (1.5, hy - 0.01, 1.5), (1.5, hy - 0.01, -1.5), (-1.5, hy - 0.01, -1.5)], [(255, 250, 220)] * 4, key=999)
    # 玉: 弾む (床に当たるところで少しつぶれる代わりに速さを変えるだけ)
    bounce = abs(math.sin(t * 2.2))
    ball = (2.2 * math.sin(t * 0.8), 1.1 + 2.2 * bounce, 2.2 * math.cos(t * 0.6))
    br = 1.1
    floor_quads = []
    n4 = 4
    for i in range(n4):
        for j in range(n4):
            x0, x1 = -ROOM + 2 * ROOM * i / n4, -ROOM + 2 * ROOM * (i + 1) / n4
            z0, z1 = -ROOM + 2 * ROOM * j / n4, -ROOM + 2 * ROOM * (j + 1) / n4
            q = [(x0, 0, z0), (x0, 0, z1), (x1, 0, z1), (x1, 0, z0)]
            uv = [(i * 48.0, j * 48.0), (i * 48.0, j * 48.0 + 48), (i * 48.0 + 48, j * 48.0 + 48), (i * 48.0 + 48, j * 48.0)]
            floor_quads.append((q, uv))
    # 1. 床 (不透明)
    for q, uv in floor_quads:
        cols = [fog((150, 150, 150), math.dist(p, (0, 0, 0)), 4, 14) for p in q]
        cols = [tuple(c + 60 for c in col) for col in cols]
        fr.poly(q, cols, uv, tex="floor", cull=-1, key=900)
    # 2. 床の下に写した玉 (表と裏が逆になる)
    for quad in sphere(ball[0], -ball[1], ball[2], br):
        pts = [p for p, _ in quad]
        ns = [(n[0], -n[1], n[2]) for _, n in quad]
        fr.poly(pts, [shade(n, light, (110, 110, 120)) for n in ns], [env_uv(cam, n) for n in ns], tex="env", cull=-1, key=800)
    # 3. 床を平均で重ねる (写った玉が半分透ける。玉のないところは床どうしの平均で床のまま)
    for q, uv in floor_quads:
        cols = [fog((150, 150, 150), math.dist(p, (0, 0, 0)), 4, 14) for p in q]
        cols = [tuple(c + 60 for c in col) for col in cols]
        fr.poly(q, cols, uv, tex="floor", blend="avg", cull=-1, key=700)
    # 4. 影 (減算)
    sh = 1.0 - 0.5 * bounce
    rs = br * (1.0 - 0.3 * bounce)
    shp = [(ball[0] + rs * math.cos(2 * math.pi * i / 10), 0.01, ball[2] + rs * math.sin(2 * math.pi * i / 10)) for i in range(10)]
    fr.poly(shp, [(70 * sh, 70 * sh, 60 * sh)] * 10, cull=0, blend="sub", key=600)
    # 5. 玉 (環境マップ。凸なので裏面を捨てれば Z は要らない)
    for quad in sphere(ball[0], ball[1], ball[2], br):
        pts = [p for p, _ in quad]
        ns = [n for _, n in quad]
        fr.poly(pts, [shade(n, light, (150, 150, 160), amb=0.6, dif=0.5) for n in ns], [env_uv(cam, n) for n in ns], tex="env", key=500)
    return fr.words()


def building(i, j):
    """区画 (i, j) のビル: (x0, z0, x1, z1, 高さ)。道路の区画は None"""
    if i % 3 == 0 or j % 4 == 0:
        return None
    h = 2.0 + (_hash(i, j, 11) % 100) / 100 * 7.0
    if _hash(i, j, 12) % 5 == 0:
        h += 6.0
    inset = 0.15 + (_hash(i, j, 13) % 10) / 100
    return (i * 2.0 + inset, j * 2.0 + inset, i * 2.0 + 2 - inset, j * 2.0 + 2 - inset, h)


def scene_city(k):
    t = k / 60.0
    zc = t * 3.0
    eye = (6.0 + 1.5 * math.sin(t * 0.5), 9.5 + 1.5 * math.sin(t * 0.3), zc)
    cam = Camera(eye, (6.0 + 2.0 * math.sin(t * 0.5 + 0.8), 4.0, zc + 16), fov=62, roll=0.05 * math.sin(t * 0.5))
    fr = Frame(cam)
    sky(fr, (5, 5, 25), (40, 30, 70))
    dmax = 19.0
    light = norm((0.5, 0.8, -0.3))
    # 地面 (道路のテクスチャ、近いところだけ細かく)
    j0 = int(math.floor(zc / 2)) - 1
    for j in range(j0, j0 + 11):
        for i in range(0, 7):
            x0, z0 = i * 2.0 - 1, j * 2.0
            if i % 3 != 0 and j % 4 != 0:
                continue                                   # ビルの下は描かない
            q = [(x0, 0, z0), (x0, 0, z0 + 2), (x0 + 2, 0, z0 + 2), (x0 + 2, 0, z0)]
            cols = [fog((230, 230, 230), math.dist(p, eye), 4, dmax) for p in q]
            fr.poly(q, cols, [(0.0, 0.0), (0.0, 32.0), (32.0, 32.0), (32.0, 0.0)], tex="ground", cull=-1, key=900)
    # ビル (区画ごとに奥から)
    for j in range(j0, j0 + 11):
        for i in range(-1, 8):
            b = building(i, j)
            if b is None:
                continue
            x0, z0, x1, z1, h = b
            ctr = ((x0 + x1) / 2, h / 2, (z0 + z1) / 2)
            d = math.dist(ctr, eye)
            if d > dmax + 2:
                continue
            faces = [([(x0, 0, z0), (x1, 0, z0), (x1, h, z0), (x0, h, z0)], (0, 0, -1), x1 - x0),
                     ([(x1, 0, z1), (x0, 0, z1), (x0, h, z1), (x1, h, z1)], (0, 0, 1), x1 - x0),
                     ([(x0, 0, z1), (x0, 0, z0), (x0, h, z0), (x0, h, z1)], (-1, 0, 0), z1 - z0),
                     ([(x1, 0, z0), (x1, 0, z1), (x1, h, z1), (x1, h, z0)], (1, 0, 0), z1 - z0)]
            for pts, n, wdt in faces:
                if dot(n, sub(eye, pts[0])) <= 0:
                    continue
                us = wdt * 24
                segs = 1 if d > 12 else max(1, min(3, int(h / 4)))
                for s in range(segs):
                    y0, y1 = h * s / segs, h * (s + 1) / segs
                    q = [(pts[0][0], y0, pts[0][2]), (pts[1][0], y0, pts[1][2]), (pts[1][0], y1, pts[1][2]), (pts[0][0], y1, pts[0][2])]
                    cols = [fog(shade(n, light, (190, 190, 200), amb=0.75, dif=0.35), math.dist(p, eye), 6, dmax) for p in q]
                    fr.poly(q, cols, [(0.0, y0 * 24), (us, y0 * 24), (us, y1 * 24), (0.0, y1 * 24)], tex="window", key=d)
            # 屋上 (上から見て反時計回りが表。前は向きが逆で、いつも裏として捨てられていた)
            roof = [(x0, h, z0), (x1, h, z0), (x1, h, z1), (x0, h, z1)]
            if eye[1] > h:
                # 単色 (リンクの量を減らす。屋上はどこも同じ明るさなので、霧は真ん中の距離で)
                rc = fog(shade((0, 1, 0), light, (120, 118, 130), amb=0.55, dif=0.4), math.dist((ctr[0], h, ctr[2]), eye), 6, dmax)
                fr.poly(roof, [rc] * 4, key=d - 0.01, flat="#%02x%02x%02x" % tuple(max(0, min(255, int(c))) for c in rc))
    # 街灯 (加算の半透明。道路の両側)
    for j in range(j0, j0 + 9):
        for x in (0.2, 5.8):
            zz = j * 2.0 + 1
            d = math.dist((x, 0.6, zz), eye)
            a = max(0.0, 1.0 - d / dmax)
            c = (220 * a, 160 * a, 60 * a)
            fr.poly([(x - 0.6, 0.02, zz - 0.6), (x - 0.6, 0.02, zz + 0.6), (x + 0.6, 0.02, zz + 0.6), (x + 0.6, 0.02, zz - 0.6)],
                    [c] * 4, cull=0, blend="add", key=850)
    return fr.words()


SCENES = {"logo": scene_logo, "tunnel": scene_tunnel, "room": scene_room, "city": scene_city}
ORDER = ["logo", "tunnel", "room", "city"]          # SCENE=all でこの順に回す (harness.py demo all)
SCENE_TEX = {"logo": ["gold"], "tunnel": ["stone"], "room": ["env", "floor", "wall"], "city": ["window", "ground"]}
CLEAR = {"logo": "#000000", "tunnel": "#000000", "room": "#000000", "city": "#000000"}


def setup_words(scene):
    """場面のテクスチャ。"all" なら全部の場面の分 (テクスチャの置き場所は場面ごとに別)"""
    out = []
    names = [n for sc in ORDER for n in SCENE_TEX[sc]] if scene == "all" else SCENE_TEX[scene]
    for name in names:
        out += tex_upload(name)
    return out


def frame_words(scene, k):
    """フレーム k: シーン (描く面を消して Z を 0xFFFF から) → SWAP"""
    words = g.encode({"op": "begin_scene", "color": CLEAR[scene], "clear_z": True})
    words += SCENES[scene](k)
    words += g.encode({"op": "end_scene"}) + g.encode({"op": "swap"})
    return words
