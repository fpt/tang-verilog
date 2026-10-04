#!/usr/bin/env python3
"""P6 PPM を PNG に変換する (標準ライブラリのみ)。 usage: ppm2png.py in.ppm [...]"""
import struct
import sys
import zlib


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    tokens, pos = [], 0
    while len(tokens) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        tokens.append(data[pos:end])
        pos = end
    assert tokens[0] == b"P6", "only binary PPM (P6) is supported"
    w, h = int(tokens[1]), int(tokens[2])
    return w, h, data[pos + 1:pos + 1 + w * h * 3]


def write_png(path, w, h, rgb):
    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))
    raw = b"".join(b"\x00" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


for src in sys.argv[1:]:
    dst = src.rsplit(".", 1)[0] + ".png"
    write_png(dst, *read_ppm(src))
    print(f"{src} -> {dst}")
