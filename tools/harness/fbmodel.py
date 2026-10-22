"""フレームバッファの参照モデル (docs/GPU_PLAN.md の M4)。Python 標準ライブラリだけで動く

rtl/vdp/fb_scanout.sv と同じ規則で、SDRAM に置く RGB565 の画像から実機の出力 (縦横 2 倍、8bit に広げた RGB) を作る。
"""
import zlib

SRC_W, SRC_H = 320, 240
WORDS_PER_LINE = 256    # 1 ライン = SDRAM の 1 行 (1KiB)


def to565(r, g, b):
    return (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)


def expand565(p):
    """fb_scanout.sv と同じ: 上位ビットを下位に繰り返して 8bit にする"""
    r5, g6, b5 = p >> 11, (p >> 5) & 0x3F, p & 0x1F
    return (r5 << 3 | r5 >> 2, g6 << 2 | g6 >> 4, b5 << 3 | b5 >> 2)


def rgb_to_565(rgb, w, h):
    return [to565(*rgb[3 * i:3 * i + 3]) for i in range(w * h)]


def line_bytes(img565, y, w=SRC_W):
    """ライン y を SDRAM に書くバイト列 (1 ワード = 偶数 x が下位 16bit、リトルエンディアン)"""
    out = bytearray()
    for x in range(w):
        out += img565[y * w + x].to_bytes(2, "little")
    return bytes(out)


def expected_output(img565, w=SRC_W, h=SRC_H):
    """実機が出す 2w x 2h の RGB (8bit) バイト列"""
    rows = []
    for y in range(h):
        row = bytearray()
        for x in range(w):
            px = bytes(expand565(img565[y * w + x]))
            row += px + px
        rows += [bytes(row), bytes(row)]
    return b"".join(rows)


def expected_crc(img565, w=SRC_W, h=SRC_H):
    return zlib.crc32(expected_output(img565, w, h))


def test_image(w=SRC_W, h=SRC_H):
    """決まった内容のテスト画像 (RGB 8bit)。なだらかな変化と、はっきりした境目の両方を入れる
      0..59:    赤 -> 緑 -> 青 の横方向グラデーション (上から下に明るさも変える)
      60..119:  8 色のバー (40 ピクセル幅)
      120..179: 左半分は灰色の縦グラデーション、右半分は 8 ピクセルの市松
      180..239: 濃い青の地に、白い対角線と黄色い円
    """
    rgb = bytearray(w * h * 3)

    def put(x, y, c):
        rgb[3 * (y * w + x):3 * (y * w + x) + 3] = bytes(c)

    bars = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
            (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]
    for y in range(h):
        for x in range(w):
            if y < 60:
                t = x / (w - 1)
                k = 0.4 + 0.6 * y / 59
                if t < 0.5:
                    c = (255 * (1 - 2 * t), 255 * 2 * t, 0)
                else:
                    c = (0, 255 * (2 - 2 * t), 255 * (2 * t - 1))
                c = tuple(int(v * k) for v in c)
            elif y < 120:
                c = bars[x * 8 // w]
            elif y < 180:
                if x < w // 2:
                    v = int(255 * (y - 120) / 59)
                    c = (v, v, v)
                else:
                    c = (200, 200, 200) if ((x // 8) + (y // 8)) % 2 else (40, 40, 60)
            else:
                c = (0, 0, 96)
                if abs((x - 20) - 2 * (y - 180)) <= 1:
                    c = (255, 255, 255)
                if (x - 240) ** 2 + (y - 210) ** 2 <= 22 ** 2:
                    c = (255, 220, 0)
            put(x, y, c)
    return bytes(rgb)
