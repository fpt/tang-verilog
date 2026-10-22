"""HDMI キャプチャと参照画像の比較 (docs/GPU_PLAN.md の M2)。Python 標準ライブラリだけで動く

キャプチャ (MS2109 など) は YUV 4:2:2 のリミテッドレンジを通るので、色が少しずれ、横方向に色がにじむ。
そこで、チャンネルごとに「キャプチャ ≒ 倍率 x 参照 + オフセット」を最小二乗で求めて補正してから、
補正後の差が許容値以内のピクセルの割合を見る。色の境目から横 2 ピクセル・縦 1 ライン以内は必ずにじむので、
割合の計算から外し、別に数える。正しさの判定は FRAME_CRC (完全一致) で行い、
こちらは「実際に画面に出ているか」の確認に使う。
"""
import os
import platform
import struct
import subprocess
import zlib

DEFAULT_DEVICE = "USB3. 0 capture"   # macOS の avfoundation での名前。Linux では /dev/video0 など


def read_png(path):
    """8bit RGB / RGBA の PNG を読み、(幅, 高さ, rgb バイト列) を返す (インターレースなし)"""
    with open(path, "rb") as f:
        data = f.read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat = 8, b""
    while pos < len(data):
        length, tag = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if tag == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and ctype in (2, 6) and interlace == 0, "only 8bit RGB/RGBA, non-interlaced"
        elif tag == b"IDAT":
            idat += body
        pos += 12 + length
    bpp = 3 if ctype == 2 else 4
    raw = zlib.decompress(idat)
    stride = w * bpp
    out = bytearray()
    prev = bytearray(stride)
    for y in range(h):
        ftype = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if ftype == 1:
                line[i] = (line[i] + a) & 0xFF
            elif ftype == 2:
                line[i] = (line[i] + b) & 0xFF
            elif ftype == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif ftype == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        prev = line
        if bpp == 4:
            line = bytearray(v for i, v in enumerate(line) if i % 4 != 3)
        out += line
    return w, h, bytes(out)


def write_png(path, w, h, rgb):
    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))
    raw = b"".join(b"\x00" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


def capture(w, h, device=None, skip=5):
    """HDMI キャプチャから 1 フレームを rgb24 で取り込む。最初の数フレームは古いことがあるので捨てる。
    デバイスは番号ではなく名前で選ぶ (番号は変わることがあり、別のカメラを開いてしまうことがある)"""
    device = device or os.environ.get("HARNESS_CAPTURE") or (
        DEFAULT_DEVICE if platform.system() == "Darwin" else "/dev/video0")
    if platform.system() == "Darwin":
        src = ["-f", "avfoundation", "-framerate", "30", "-video_size", f"{w}x{h}", "-i", f"{device}:none"]
    else:
        src = ["-f", "v4l2", "-video_size", f"{w}x{h}", "-i", device]
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", *src,
           "-vf", f"select=gte(n\\,{skip})", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if r.returncode != 0 or len(r.stdout) != w * h * 3:
        raise RuntimeError(f"capture failed ({len(r.stdout)} bytes): {r.stderr.decode(errors='replace').strip()}")
    return r.stdout


def edge_mask(ref, w, h, radius=2):
    """参照画像で、横 radius ピクセル以内、または縦 1 ライン以内に違う色があるピクセル
    (キャプチャは 4:2:2 で横に、縮小・スケーラの都合で縦にも 1 ラインほどにじむ)"""
    mask = bytearray(w * h)
    for y in range(h):
        row = [ref[3 * (y * w + x):3 * (y * w + x) + 3] for x in range(w)]
        for x in range(w - 1):
            if row[x] != row[x + 1]:
                for k in range(max(0, x - radius + 1), min(w, x + radius + 1)):
                    mask[y * w + k] = 1
        if y + 1 < h:
            for x in range(w):
                i = 3 * (y * w + x)
                if ref[i:i + 3] != ref[i + 3 * w:i + 3 * w + 3]:
                    mask[y * w + x] = mask[(y + 1) * w + x] = 1
    return mask


def compare(ref, cap, w, h, tolerance=40):
    """チャンネルごとに倍率とオフセットを合わせてから比べる。(結果の dict, 差分画像の rgb) を返す。
    match_ratio は色の境目付近を除いたピクセルでの割合"""
    n = w * h
    edges = edge_mask(ref, w, h)
    fit = []
    for ch in range(3):
        xs, ys = ref[ch::3], cap[ch::3]
        sx, sy = sum(xs), sum(ys)
        sxx = sum(x * x for x in xs)
        sxy = sum(x * y for x, y in zip(xs, ys))
        den = n * sxx - sx * sx
        gain = (n * sxy - sx * sy) / den if den else 1.0
        offset = (sy - gain * sx) / n
        fit.append((gain, offset))

    ok_raw = ok = counted = edge_ok = 0
    diff = bytearray(n * 3)
    for i in range(n):
        worst_raw = worst = 0
        for ch in range(3):
            r, c = ref[3 * i + ch], cap[3 * i + ch]
            gain, offset = fit[ch]
            corrected = (c - offset) / gain if gain else c
            worst_raw = max(worst_raw, abs(c - r))
            worst = max(worst, abs(corrected - r))
        good = worst <= tolerance
        if edges[i]:
            edge_ok += good
        else:
            counted += 1
            ok += good
            ok_raw += worst_raw <= tolerance
        if good:
            g = sum(ref[3 * i:3 * i + 3]) // 9      # 合っているところは暗い灰色
            diff[3 * i:3 * i + 3] = bytes((g, g, g))
        elif edges[i]:
            diff[3 * i:3 * i + 3] = b"\xff\xc0\x00"  # 色の境目で合っていないところは黄色 (4:2:2 のにじみ)
        else:
            diff[3 * i:3 * i + 3] = b"\xff\x00\x00"  # それ以外で合っていないところは赤
    edge_count = n - counted
    return {
        "match_ratio": round(ok / counted, 5) if counted else 0.0,
        "match_ratio_uncorrected": round(ok_raw / counted, 5) if counted else 0.0,
        "edge_pixels": edge_count,
        "edge_match_ratio": round(edge_ok / edge_count, 5) if edge_count else 1.0,
        "tolerance": tolerance,
        "fit": [{"gain": round(g, 4), "offset": round(o, 2)} for g, o in fit],
    }, bytes(diff)
