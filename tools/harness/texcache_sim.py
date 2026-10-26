"""テクスチャのキャッシュの見積もり (G5)。demo3d.py の場面のテクセルの取り出しを、tile_engine.sv と同じ順
(タイル順、タイルの中は投入順、外接矩形とタイルの重なりを行ごと、辺の中のピクセルだけ) に並べ、直接写像のキャッシュの当たりの割合を数える

  今のハード: 16 行 x 8 ワード、1 行は横 16 テクセル (16bpp)。Verilator の tex_miss と同じ数になる
  比べるもの: 行の数 (32 / 64 / 128)、1 行を 4 x 4 テクセルのかたまりにする並び

usage: python3 tools/harness/texcache_sim.py [scene:frame ...]   (既定は 4 つの場面)
"""
import sys

import demo3d
import gpu_model
import raster


def lookups(scene, k):
    """フレーム k のテクセルの取り出し: (先頭, 幅の log2, tu, tv) の列 (ハードの順)"""
    grabbed = {}
    orig = gpu_model.Model.end_scene

    def grab(self):
        grabbed["sc"] = self.scene
        return orig(self)
    gpu_model.Model.end_scene = grab
    try:
        m = gpu_model.Model()
        m.run(gpu_model.layer_reset_words() + demo3d.setup_words(scene) + demo3d.frame_words(scene, k))
    finally:
        gpu_model.Model.end_scene = orig
    recs = []
    for words, clip, tex in grabbed["sc"]["tris"]:
        fl, _, vs = raster.parse(words)
        if fl & raster.FLAG_TEX:
            r = raster.setup(vs, clip)
            if r:
                recs.append((r, tex))
    out = []
    for ty in range(8):
        for tx in range(10):
            for r, tex in recs:
                bx0, by0, bx1, by1 = r["bbox"]
                if bx1 < tx * 32 or bx0 > tx * 32 + 31 or by1 < ty * 32 or by0 > ty * 32 + 31:
                    continue
                _, wl, hl, _, base = tex
                for x, y, inside, _, _, uv in raster.pixels(r):
                    if inside and x >> 5 == tx and y >> 5 == ty:
                        out.append((base, wl, (uv[0] >> 18) & ((1 << wl) - 1), (uv[1] >> 18) & ((1 << hl) - 1)))
    return out


def misses(seq, lines, block):
    """直接写像、1 行 8 ワード (16bpp で 16 テクセル)。block なら 1 行が 4 x 4 テクセル、でなければ横 16 テクセル"""
    tags = [None] * lines
    n = 0
    for base, wl, tu, tv in seq:
        ln = (tv >> 2) * ((1 << wl) >> 2) + (tu >> 2) if block else (tv << (wl - 4)) | (tu >> 4)
        a = (base >> 3) + ln
        if tags[a % lines] != a:
            tags[a % lines] = a
            n += 1
    return n


if __name__ == "__main__":
    args = sys.argv[1:] or ["tunnel:300", "room:120", "city:200", "logo:150"]
    print("場面 取り出し " + " ".join(f"{n}{'b' if b else ''}" for n in (16, 32, 64, 128) for b in (0, 1)) + "  (b = 4 x 4 のかたまり、値は当たりの割合 %)")
    for a in args:
        scene, k = a.split(":")
        seq = lookups(scene, int(k))
        rates = [100 - 100 * misses(seq, n, b) / max(1, len(seq)) for n in (16, 32, 64, 128) for b in (0, 1)]
        print(f"{scene}:{k} {len(seq)} " + " ".join(f"{r:.1f}" for r in rates))
