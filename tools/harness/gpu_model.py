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
                                                 # 8bpp (bitmap_fmt = 1) のとき: "key" は番号 (0..255)、"src4": true で 4bpp のソース、
                                                 # "bank": 0..15 (4bpp の値の上位)
      {"op": "stretch", "src": 196608, "stride": 8, "sw": 16, "w": 40, "h": 24, "x": 10, "y": 20,
       "sx_step": 26214, "sy_step": 43690, ...},  # STRETCH_BLIT。step は 16.16 (省略すると sw / w と 1.0 から作る:
                                                 # "sh" を書けば sh / h)。ほかのキーは blit と同じ
      {"op": "light_write", "addr": 0, "cells": [[16, 16, 16], ...]},   # ライトマップ (セル cy * 40 + cx、[R, G, B] の倍率 0..63、16 = 1 倍)
      {"op": "pcm_tone", "addr": 2088960, "n": 2048, "tone": 1000},   # 正弦波の PCM (左右同じ、48kHz) を SDRAM に (音のリング用。画には効かない)
      {"op": "upload_image8", "slot": 512},      # 8bpp のテスト画像 (下の test_image8) を slot の面へ
      {"op": "upload_tiles", "kind": "sheet", "addr": 196608},   # tile_words を SDRAM に (4bpp の BLIT のソース。タイル t は addr + 8t、stride 1)
      {"op": "reg", "name": "bg_color", "value": "#rrggbb"},   # 合成のレジスタ (LAYER_REGS の名前)
      {"op": "wait_line", "line": 100},          # 以降の reg がライン 100 から効く
      {"op": "wait_vblank", "mark": true},       # 以降の reg が次のフレームのライン 0 から効く。mark なら次のフレームに印
      {"op": "check"},                           # ここで表示されている画面を比べる (レジスタは最後の値が全ラインに効いている前提)。
                                                 # "capture_min": 0.85 で実機のキャプチャの合格線を下げる (細かい模様の画面)
      {"op": "check_marked"},                    # 印を付けたフレーム (ラインごとのレジスタの変化込み) を比べる
      {"op": "vram_write", "addr": 0, "words": ["deadbeef", ...]},     # VRAM (ワードアドレス、16K ワードで折り返す)
      {"op": "pal_write", "index": 0, "colors": ["#rrggbb", ...]},      # パレット (0..511)
      {"op": "tiles", "kind": "demo", "addr": 0},                        # 下の tile_words (タイル 16 個 = 128 ワード)
      {"op": "m7_tiles", "addr": 4096},          # Mode 7 のタイル 256 個 (8bpp、4096 ワード。下の m7_tile_words)
      {"op": "m7_map", "addr": 0, "kind": "track"},   # Mode 7 のマップ 128 x 128 (4096 ワード。下の m7_map_words)
      {"op": "tilemap", "kind": "demo", "addr": 14336, "w": 32, "h": 28},  # 下の map_entries
      {"op": "palette", "kind": "demo", "index": 0, "count": 64, "offset": 0},  # 下の palette_colors
      {"op": "oam_write", "addr": 0, "words": ["deadbeef", ...]},      # OAM (ワードアドレス、256 ワードで折り返す)
      {"op": "oam", "sprites": [{"x": -4, "y": 10, "w": 2, "h": 1, "tile": 3, "hflip": false, "vflip": false,
                                 "pal": 0, "pri": 0, "order": 0, "bank": 0}, ...]}  # OAM 全体 (書かなかったエントリは無効)。
                                                 # order: 0 列優先、1 16 タイル幅の表、2 行優先。bank: スプライトごとのバンク (spr_bank bit3 のとき)
      {"op": "tri", "v": [[x, y], [x, y], [x, y]], "color": "#rrggbb"}   # 三角形 (3D GPU、raster.py)。座標はピクセル (小数可、1/16 に丸める)。
                                                 # "rgb": ["#..", "#..", "#.."] で Gouraud、"z": [z0, z1, z2] で Z テスト / 書き込み
      {"op": "clear_z", "value": 65535}         # Z バッファ (Z_BASE、320 x 240 x 16bit) を塗る
      {"op": "begin_scene", "color": "#rrggbb", "clear_z": true, "write_z": false}   # TBDR のシーン (G2)。color があれば描く面を
                                                 # その色から、clear_z なら Z を 0xFFFF から (なければ今の面と Z_BASE を読む)。write_z で Z を書き戻す
      {"op": "end_scene"}                       # シーンをタイルごとに描く
      {"op": "upload_tex", "addr": 655360, "fmt": "16", "w": 64, "h": 64, "kind": "checker"}   # テクスチャを SDRAM に (G3)
      {"op": "set_tex", "base": 655360, "fmt": "16", "w": 64, "h": 64, "clut": 0}   # 今のテクスチャ (fmt "16" / "8" / "4")。TRI に "uv": [[u, v], ...] (テクセル)
      {"op": "clut", "index": 0, "colors": ["#rrggbb", ...]}   # CLUT (256 色、8 / 4bpp のテクスチャの色)
      {"op": "demo_setup"}, {"op": "demo_frame", "frame": 120, "mark": true}   # M9 のデモ (demo.py) のコマンド
      {"op": "md_frame", "variant": 0, "mark": true}   # メガドラの形式の決まったフレーム (md.py) を直したもの。印付きの 1 フレーム
  ]}
タイル レイヤの形式は rtl/vdp/tile_layer.sv、スプライト (OAM) は rtl/vdp/sprite_layer.sv。VRAM・パレット・OAM は、
印を付けたフレームの記録中には書かないこと (モデルは最後の内容で合成する)。
色は "#rrggbb" (RGB565 に丸める) か、RGB565 の整数。8bpp (bitmap_fmt = 1) で描くコマンドの色はパレットの番号 (整数、下位 8bit)。
"""
import json

import fbmodel

SRC_W, SRC_H = fbmodel.SRC_W, fbmodel.SRC_H
OP_NOP, OP_CLEAR, OP_FILL_RECT, OP_SWAP, OP_UPLOAD = 0x00, 0x01, 0x02, 0x03, 0x04
OP_POINT, OP_DRAW_LINE, OP_CLIP, OP_BLIT = 0x05, 0x06, 0x07, 0x08
OP_REG_WRITE, OP_WAIT_LINE, OP_WAIT_VBLANK = 0x09, 0x0A, 0x0B
OP_VRAM_WRITE, OP_PAL_WRITE, OP_STRETCH, OP_OAM_WRITE = 0x0C, 0x0D, 0x0E, 0x0F
OP_LIGHT_WRITE = 0x10
OP_TRI, OP_CLEAR_Z = 0x20, 0x24           # 3D GPU (docs/GPU3D_PLAN.md、make TARGET=gpu3d のビットストリームだけ)
OP_BEGIN_SCENE, OP_END_SCENE = 0x25, 0x26  # 3D GPU の TBDR (G2)
OP_SET_TEX, OP_CLUT_WRITE = 0x21, 0x28      # 3D GPU のテクスチャ (G3)
TEX_FMT = {"16": 0, "8": 1, "4": 2}
SCENE_MAX_TRIS, TILE_MAX_TRIS = 4096, 1024  # 1 シーンの三角形、1 タイルのリストの上限 (超えた分は描かない)
LIGHT_W = SRC_W // 8      # ライトマップの 1 行のセル数 (40)
# 合成のレジスタ: 名前 -> (REG_WRITE の番号, ビットの幅のマスク)
LAYER_REGS = {"bg_color": 0, "layer_ctrl": 1, "bitmap_key": 2, "tile_scroll_x": 3, "tile_scroll_y": 4,
              "tile_map_base": 5, "tile_pat_base": 6, "tile_ctrl": 7, "bitmap_rank": 8,
              "spr_pat_base": 9, "spr_bank": 10, "spr_line_px": 11,
              "tileb_scroll_x": 12, "tileb_scroll_y": 13, "tileb_map_base": 14, "tileb_pat_base": 15, "tileb_ctrl": 16,
              "win_h": 17, "win_v": 18, "win_map_base": 19, "hscroll_mode": 20, "hscroll_base": 21,
              "bitmap_fmt": 22, "audio_ctrl": 23, "pcm_base": 24, "pcm_size": 25, "pcm_wr": 26, "z_base": 27,
              "m7_sel": 32, "m7_ctrl": 33, "m7_a": 34, "m7_b": 35, "m7_c": 36, "m7_d": 37,
              "m7_x0": 38, "m7_y0": 39, "m7_hofs": 40, "m7_vofs": 41, "m7_map_base": 42, "m7_pat_base": 43,
              "m7_tbl_base": 44, "m7_sx": 45, "m7_sy": 46,
              "line_mul": 47, "line_add": 48, "line_fx_ctrl": 49, "line_fx_base": 50}
LAYER_MASK = {"bg_color": 0xFFFF, "layer_ctrl": 0x3F, "bitmap_key": 0xFFFF, "tile_scroll_x": 0x3FF, "tile_scroll_y": 0x3FF,
              "tile_map_base": 0x3FFF, "tile_pat_base": 0x3FFF, "tile_ctrl": 0xFF, "bitmap_rank": 0x7,
              "spr_pat_base": 0x3FFF, "spr_bank": 0xF, "spr_line_px": 0x3FF,
              "tileb_scroll_x": 0x3FF, "tileb_scroll_y": 0x3FF, "tileb_map_base": 0x3FFF, "tileb_pat_base": 0x3FFF,
              "tileb_ctrl": 0xFF, "win_h": 0x9F, "win_v": 0x9F, "win_map_base": 0x3FFF, "hscroll_mode": 0x3,
              "hscroll_base": 0x3FFF, "bitmap_fmt": 0x1, "audio_ctrl": 0x3, "pcm_base": 0x1FFF, "pcm_size": 0xF,
              "pcm_wr": 0xFFFF, "z_base": 0x1FFF,
              "m7_sel": 0xC3, "m7_ctrl": 0xF, "m7_a": 0xFFFF, "m7_b": 0xFFFF, "m7_c": 0xFFFF, "m7_d": 0xFFFF,
              "m7_x0": 0x1FFF, "m7_y0": 0x1FFF, "m7_hofs": 0x1FFF, "m7_vofs": 0x1FFF, "m7_map_base": 0x3FFF,
              "m7_pat_base": 0x3FFF, "m7_tbl_base": 0x3FFF, "m7_sx": 0x3FF, "m7_sy": 0x1FF,
              "line_mul": 0x7FFF, "line_add": 0xFFFF, "line_fx_ctrl": 0x1, "line_fx_base": 0x3FFF}
LAYER_RESET = {"bg_color": 0x0000, "layer_ctrl": 0x01, "bitmap_key": 0x0000, "tile_scroll_x": 0, "tile_scroll_y": 0,
               "tile_map_base": 0, "tile_pat_base": 0, "tile_ctrl": 0, "bitmap_rank": 1,
               "spr_pat_base": 0, "spr_bank": 0, "spr_line_px": 320,
               "tileb_scroll_x": 0, "tileb_scroll_y": 0, "tileb_map_base": 0, "tileb_pat_base": 0, "tileb_ctrl": 0,
               "win_h": 0, "win_v": 0, "win_map_base": 0, "hscroll_mode": 0, "hscroll_base": 0, "bitmap_fmt": 0,
               "audio_ctrl": 0, "pcm_base": 0x1FE0, "pcm_size": 11, "pcm_wr": 0, "z_base": 0x0E00,
               "m7_sel": 0, "m7_ctrl": 0, "m7_a": 0x100, "m7_b": 0, "m7_c": 0, "m7_d": 0x100,
               "m7_x0": 0, "m7_y0": 0, "m7_hofs": 0, "m7_vofs": 0, "m7_map_base": 0, "m7_pat_base": 0,
               "m7_tbl_base": 0, "m7_sx": 0, "m7_sy": 0,
               "line_mul": 0x4210, "line_add": 0, "line_fx_ctrl": 0, "line_fx_base": 0}
# Mode 7 (m7_*) と霧 (line_*) は E7 (rtl/vdp/mode7_layer.sv、line_compositor.sv)。
# 音のレジスタ (audio_ctrl 〜 pcm_wr) は画に効かない。参照モデルは値を持つだけ (音は audio_out.sv と harness.py audio で確かめる)
# 合成の順位 (line_compositor.sv): 0 背景色、面 B は優先度ビットで 1 か 4、面 A (とウィンドウ) は 2 か 5、スプライトは 3 か 6、
# ビットマップは bitmap_rank
RANK_B_LO, RANK_B_HI = 1, 4
RANK_A_LO, RANK_A_HI = 2, 5
RANK_S_LO, RANK_S_HI = 3, 6
OAM_WORDS = 256
VRAM_WORDS = 16384
BLIT_MAX_W = 512
STRETCH_MAX = 1024       # STRETCH_BLIT の描く大きさの上限
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
        flags = ((1 if step.get("transparent") else 0) | (2 if step.get("hflip") else 0) | (4 if step.get("vflip") else 0)
                 | (8 if step.get("src4") else 0))
        key = (step.get("bank", 0) & 15) << 8 if step.get("src4") else color565(step.get("key", SPRITE_KEY))
        return [OP_BLIT << 24 | flags << 16 | key, step["src"],
                (step["h"] & 0xFFFF) << 16 | (step["w"] & 0xFFFF), xy(step["x"], step["y"]), step["stride"] & 0xFFFF]
    if op == "stretch":
        flags = ((1 if step.get("transparent") else 0) | (2 if step.get("hflip") else 0) | (4 if step.get("vflip") else 0)
                 | (8 if step.get("src4") else 0))
        key = (step.get("bank", 0) & 15) << 8 if step.get("src4") else color565(step.get("key", SPRITE_KEY))
        xs = step.get("sx_step", step["sw"] * 65536 // step["w"])
        ys = step.get("sy_step", step["sh"] * 65536 // step["h"] if "sh" in step else 65536)
        return [OP_STRETCH << 24 | flags << 16 | key, step["src"], (step["h"] & 0xFFFF) << 16 | (step["w"] & 0xFFFF),
                xy(step["x"], step["y"]), (step["sw"] & 0xFFFF) << 16 | (step["stride"] & 0xFFFF), xs & 0xFFFFFFFF, ys & 0xFFFFFFFF]
    if op == "light_write":
        return light_write_words(step["addr"], step["cells"])
    if op == "pcm_tone":
        import math
        words = []
        for k in range(step["n"]):
            v = int(round(8000 * math.sin(2 * math.pi * step["tone"] * k / 48000))) & 0xFFFF
            words.append(v << 16 | v)
        return [OP_UPLOAD << 24 | len(words), step["addr"]] + words
    if op == "upload_image8":
        img = test_image8()
        out = []
        for y in range(SRC_H):
            words = [sum(img[y * SRC_W + 4 * k + n] << 8 * n for n in range(4)) for k in range(SRC_W // 4)]
            out += [OP_UPLOAD << 24 | len(words), (step["slot"] + y) * fbmodel.WORDS_PER_LINE] + words
        return out
    if op == "upload_tiles":
        words = tile_words(step["kind"])
        return [OP_UPLOAD << 24 | len(words), step["addr"]] + words
    if op == "upload_sprite":
        px = sprite_pixels(step["kind"], step["w"], step["h"])
        return image_words(px, step["w"], step["h"], step["stride"], step["addr"])
    if op == "reg":
        v = step["value"]
        v = color565(v) if isinstance(v, str) else v & 0xFFFF
        return [OP_REG_WRITE << 24 | LAYER_REGS[step["name"]] << 16 | v]
    if op == "wait_line":
        return [OP_WAIT_LINE << 24 | (step["line"] & 0xFF)]
    if op == "wait_vblank":
        return [OP_WAIT_VBLANK << 24 | (1 if step.get("mark") else 0)]
    if op == "vram_write":
        return vram_write_words(step["addr"], [int(w, 16) if isinstance(w, str) else w for w in step["words"]])
    if op == "pal_write":
        return pal_write_words(step["index"], [color565(c) for c in step["colors"]])
    if op == "tiles":
        return vram_write_words(step["addr"], tile_words(step["kind"]))
    if op == "m7_tiles":
        return vram_write_words(step["addr"], m7_tile_words())
    if op == "m7_map":
        return vram_write_words(step["addr"], m7_map_words(step.get("kind", "track")))
    if op == "tilemap":
        return vram_write_words(step["addr"], map_words(map_entries(step["kind"], step["w"], step["h"])))
    if op == "palette":
        return pal_write_words(step["index"], palette_colors(step["kind"], step["count"], step.get("offset", 0)))
    if op == "oam_write":
        return oam_write_words(step["addr"], [int(w, 16) if isinstance(w, str) else w for w in step["words"]])
    if op == "oam":
        return oam_write_words(0, oam_words(step["sprites"]))
    if op == "tri":
        return tri_words(step)
    if op == "begin_scene":
        flags = (1 if "color" in step else 0) | (2 if step.get("clear_z") else 0) | (4 if step.get("write_z") else 0)
        return [OP_BEGIN_SCENE << 24 | flags << 16 | (color565(step["color"]) if "color" in step else 0)]
    if op == "end_scene":
        return [OP_END_SCENE << 24]
    if op == "set_tex":
        fmt, wl, hl = TEX_FMT[str(step.get("fmt", "16"))], int(step["w"]).bit_length() - 1, int(step["h"]).bit_length() - 1
        return [OP_SET_TEX << 24 | fmt << 16 | (step.get("clut", 0) & 0xFF) << 8 | wl << 4 | hl, step["base"] & 0x1FFFFF]
    if op == "clut":
        cols = [color565(c) for c in step["colors"]]
        n = len(cols)
        ws = [cols[i] | (cols[i + 1] << 16 if i + 1 < n else 0) for i in range(0, n, 2)]
        return [OP_CLUT_WRITE << 24 | (step.get("index", 0) & 0xFF) << 16 | n] + ws
    if op == "upload_tex":
        fmt = TEX_FMT[str(step.get("fmt", "16"))]
        words = tex_words(fmt, step["w"], step["h"], step.get("kind", "checker"), step.get("seed", 1))
        return [OP_UPLOAD << 24 | len(words), step["addr"]] + words
    if op == "clear_z":
        return [OP_CLEAR_Z << 24 | (step.get("value", 0xFFFF) & 0xFFFF)]
    if op == "md_frame":
        import md
        return md.translate(md.synthetic(step.get("variant", 0)), step.get("mark", True))[0]
    if op == "demo_setup":
        import demo
        return demo.setup_words()
    if op == "demo_frame":
        import demo
        return demo.frame_words(step["frame"], step.get("mark", False))
    if op in ("check", "check_marked"):
        return []
    raise ValueError(f"unknown op {op!r}")


def tri_words(step):
    """TRI のワード列: [0x20 | flags | 単色 565]、頂点ごとに {y, x} (12.4)、Gouraud なら {r, g, b}、Z なら {z}、テクスチャなら {v, u} (10.6)"""
    import raster
    gouraud, zs, uv = "rgb" in step, step.get("z"), step.get("uv")
    flags = ((raster.FLAG_GOURAUD if gouraud else 0) | (raster.FLAG_Z if zs is not None else 0)
             | (raster.FLAG_TEX if uv is not None else 0))
    words = [OP_TRI << 24 | flags << 16 | (color565(step["color"]) if "color" in step else 0)]
    for k, (x, y) in enumerate(step["v"]):
        xi, yi = int(round(x * 16)), int(round(y * 16))
        words.append((yi & 0xFFFF) << 16 | (xi & 0xFFFF))
        if gouraud:
            c = step["rgb"][k].lstrip("#")
            words.append(int(c, 16))
        if zs is not None:
            words.append(zs[k] & 0xFFFF)
        if uv is not None:
            u, v = (int(round(t * 64)) & 0xFFFF for t in uv[k])     # 10.6
            words.append(v << 16 | u)
    return words


def tex_words(fmt, w, h, kind="checker", seed=1):
    """テクスチャの中身 (raster.py の並び)。16bpp は RGB565、8 / 4bpp は CLUT の番号。checker: 市松と縞、0 (透明) のところもある"""
    import random
    rng = random.Random(seed)
    sh = {0: 1, 1: 2, 2: 3}[fmt]
    words = [0] * ((w * h) >> sh)
    for v in range(h):
        for u in range(w):
            if kind == "checker":
                c = ((u >> 2) ^ (v >> 2)) & 1
                val = (0x07E0 if c else 0xF800) ^ ((u * 37 + v * 11) & 0x1F) if fmt == 0 else (1 + c * 3 + ((u + v) >> 3)) % (256 if fmt == 1 else 16)
                if (u + 2 * v) % 13 == 0:
                    val = 0
            else:
                val = rng.randrange(1 << 16) if fmt == 0 else rng.randrange(256 if fmt == 1 else 16)
            a = (v << (int(w).bit_length() - 1 - sh)) + (u >> sh)
            if fmt == 0:
                words[a] |= val << (16 * (u & 1))
            elif fmt == 1:
                words[a] |= val << (8 * (u & 3))
            else:
                words[a] |= val << (28 - 4 * (u & 7))
    return words


def layer_reset_words():
    """合成のレジスタを既定に戻す REG_WRITE の列 (シナリオを始める前に送る)"""
    return [OP_REG_WRITE << 24 | LAYER_REGS[k] << 16 | v for k, v in LAYER_RESET.items()]


def vram_write_words(addr, words):
    return [OP_VRAM_WRITE << 24 | len(words), addr] + list(words)


def light_write_words(addr, cells):
    """ライトマップのセル ([R, G, B] の倍率) を LIGHT_WRITE に"""
    words = [(r & 63) | (g & 63) << 8 | (b & 63) << 16 for r, g, b in cells]
    return [OP_LIGHT_WRITE << 24 | len(words), addr] + words


def lit(c, cell):
    """line_compositor.sv と同じ: RGB565 の各色に倍率 (16 = 1 倍) を掛けて >> 4、最大値で切る"""
    r, g, b = cell
    return (min(31, (c >> 11) * r >> 4) << 11 | min(63, (c >> 5 & 63) * g >> 4) << 5 | min(31, (c & 31) * b >> 4))


def add565(c, k):
    """line_compositor.sv と同じ: RGB565 の各色に足して最大値で切る (霧の LINE_ADD)"""
    return (min(31, (c >> 11) + (k >> 11)) << 11 | min(63, (c >> 5 & 63) + (k >> 5 & 63)) << 5
            | min(31, (c & 31) + (k & 31)))


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def m7_clip(n):
    """bsnes と同じ: 14bit の差を 11bit の符号付きに"""
    return (n | ~1023) if n & 0x2000 else (n & 1023)


def oam_write_words(addr, words):
    return [OP_OAM_WRITE << 24 | len(words), addr] + list(words)


def oam_entry(sp):
    """スプライト 1 つ (辞書) を OAM の 2 ワードに (sprite_layer.sv の形式)"""
    order = int(sp.get("order", 0))        # True / False も 1 / 0 として受ける
    w0 = (sp["x"] & 0x3FF | (order >> 1 & 1) << 10 | (sp["y"] & 0x3FF) << 16 | (sp.get("w", 1) - 1) << 26
          | (sp.get("h", 1) - 1) << 28 | (order & 1) << 30 | (0 if sp.get("enable", True) is False else 1) << 31)
    w1 = (sp.get("tile", 0) & 0x7FF | (1 if sp.get("hflip") else 0) << 11 | (1 if sp.get("vflip") else 0) << 12
          | (sp.get("pal", 0) & 3) << 13 | (1 if sp.get("pri") else 0) << 15 | (sp.get("bank", 0) & 15) << 16)
    return [w0, w1]


def oam_words(sprites):
    """OAM 全体 (128 エントリ)。sprites の後ろのエントリは無効"""
    if len(sprites) > 128:
        raise ValueError("more than 128 sprites")
    out = []
    for sp in sprites:
        out += oam_entry(sp)
    return out + [0] * (OAM_WORDS - len(out))


def s10(v):
    v &= 0x3FF
    return v - 0x400 if v & 0x200 else v


def pal_write_words(index, colors):
    padded = list(colors) + [0] * (len(colors) % 2)
    return [OP_PAL_WRITE << 24 | len(colors), index] + [padded[k] | padded[k + 1] << 16 for k in range(0, len(padded), 2)]


def tile_row_word(px):
    """8 ピクセルの値 (0..15) を 1 ワードに。ピクセル i は [31-4i -: 4]"""
    w = 0
    for i, v in enumerate(px):
        w |= (v & 15) << (28 - 4 * i)
    return w


def tile_words(kind):
    """シナリオ用の決まったタイル (4bpp、1 タイル 8 ワード)
      demo:  16 個。0 は全部透明、1 は塗りつぶし、ほかは形・グラデーション・左右上下が非対称な模様 (反転がわかる)
      sheet: 64 個 (16 x 4 の表)。タイル t は demo の t % 16 で、不透明なピクセルの値を t // 16 ごとにずらす (行ごとに色が変わる)"""
    if kind == "sheet":
        demo = tile_words("demo")
        out = []
        for t in range(64):
            for y in range(8):
                w = demo[(t % 16) * 8 + y]
                px = [(w >> (28 - 4 * i)) & 15 for i in range(8)]
                out.append(tile_row_word([0 if v == 0 else (v - 1 + 3 * (t // 16)) % 15 + 1 for v in px]))
        return out
    if kind != "demo":
        raise ValueError(f"unknown tiles {kind!r}")
    F = ["11111111", "11000000", "11000000", "11111100", "11000000", "11000000", "11000000", "00000000"]
    out = []
    for t in range(16):
        for y in range(8):
            row = []
            for x in range(8):
                if t == 0:
                    v = 0
                elif t == 1:
                    v = 1
                elif t == 2:
                    v = 2 if x in (0, 7) or y in (0, 7) else 3
                elif t == 3:
                    v = 4 if (x // 2 + y // 2) % 2 else 5
                elif t == 4:
                    v = 6 if (x + y) % 4 < 2 else 0
                elif t == 5:
                    v = 7 if (x - 3.5) ** 2 + (y - 3.5) ** 2 <= 12 else 0
                elif t == 6:
                    v = x + 1
                elif t == 7:
                    v = 9 + y if y < 7 else 1
                elif t == 8:
                    v = 10 if x <= 7 - abs(2 * y - 7) // 2 - 1 else 0       # 右向きの三角
                elif t == 9:
                    v = 11 if F[y][x] == "1" else 12                      # F の字
                elif t == 10:
                    v = 13 if x % 4 < 2 else 14                           # 縦じま
                elif t == 11:
                    v = 15 if y < 4 else (2 if y < 6 else 0)              # 上が濃い横じま (下は透明)
                elif t == 12:
                    v = 3 if x % 3 == 1 and y % 3 == 1 else 0             # 点
                elif t == 13:
                    v = 5 if abs(x - 3.5) + abs(y - 3.5) <= 4 else 1      # ひし形
                elif t == 14:
                    v = 8 if x < 2 or y > 5 else 9                        # L の字
                else:
                    v = (x * 7 + y * 11 + t * 13 + x * y) % 16           # 決まった雑音 (0 = 透明も混ざる)
                row.append(v)
            out.append(tile_row_word(row))
    return out


def map_entries(kind, w, h):
    """マップのエントリ (行優先、w x h)。[10:0] タイル、[11] 左右反転、[12] 上下反転、[14:13] パレット、[15] 優先度
      demo: タイル 0..15 を並べ、場所によって反転・パレットを変える。優先度のビットも混ぜる (E2 では無視される)
      scene: 画面らしい並び。上 2 行は F の字 (4 通りの反転)、空 (透明 = 背景色、ところどころ雲と三角)、
             丘 (斜めじま)、地面 (箱・市松・ひし形・グラデーションなど)"""
    out = []
    for r in range(h):
        for c in range(w):
            if kind == "demo":
                tile = (c + 2 * r) % 16
                hflip = (c // 3 + r) % 2
                vflip = (r // 2 + c) % 3 == 0
                pal = (c // 8 + r // 7) % 4
            elif kind == "scene":
                hflip = vflip = 0
                if r < 2:
                    tile, pal = 9, 0
                    hflip, vflip = c % 2, (c // 2) % 2
                elif r < 13:
                    k = (c * 5 + r * 3) % 23
                    tile, pal = (5, 1) if k == 0 else (8, 1) if k == 7 else (12, 0) if k == 11 else (0, 0)
                    hflip = r % 2
                elif r < 16:
                    tile, pal = 4, 2
                    hflip = r == 14
                else:
                    tile = [2, 3, 13, 6, 7, 10, 14, 1][(c // 2 + r) % 8]
                    pal = 3 if r < 22 else 2
                    hflip, vflip = c % 2, r % 2
            else:
                raise ValueError(f"unknown tilemap {kind!r}")
            out.append(tile | hflip << 11 | vflip << 12 | pal << 13 | (r % 2) << 15)
    return out


def m7_tile_words():
    """Mode 7 のタイル 256 個 (8bpp、タイル t は 16 ワード)。中は色 t、上と左の縁は t ^ 0x80、t % 5 == 0 のタイルはところどころ 0 (透明)。
    t % 7 == 0 のタイルには 0x80 (EXTBG なら [6:0] が 0 で透明) の点がある"""
    words = []
    for t in range(256):
        for y in range(8):
            for x4 in range(2):
                w = 0
                for k in range(4):
                    x = 4 * x4 + k
                    v = t ^ 0x80 if x == 0 or y == 0 else t
                    if t % 5 == 0 and (x + y + t) % 6 == 0:
                        v = 0
                    elif t % 7 == 0 and (x * y) % 5 == 1:
                        v = 0x80
                    w |= v << 8 * k
                words.append(w)
    return words


def m7_map_words(kind):
    """Mode 7 のマップ 128 x 128 セル (1 セル 1 バイト、1 ワードに 4 セル)。track: 帯と市松とまばらな印"""
    cells = []
    for cy in range(128):
        for cx in range(128):
            if kind == "track":
                if abs(cx - 64) < 6:
                    t = 200 + (cy % 8)                 # 道
                elif (cx // 8 + cy // 8) % 2:
                    t = 16 + (cx * 5 + cy * 3) % 40
                else:
                    t = 100 + (cx ^ cy) % 50
                if cx % 32 == 0 or cy % 32 == 0:
                    t = 1 + (cx + cy) % 8
            else:
                t = (cx * 7 + cy * 11) & 0xFF
            cells.append(t)
    return [sum(cells[4 * i + k] << 8 * k for k in range(4)) for i in range(len(cells) // 4)]


def map_words(entries):
    padded = list(entries) + [0] * (len(entries) % 2)
    return [padded[k] | padded[k + 1] << 16 for k in range(0, len(padded), 2)]


def palette_colors(kind, count, offset=0):
    """demo: 決まった色の列 (番号ごとに色相と明るさが変わる)。offset で列をずらす (別のバンク用)"""
    if kind != "demo":
        raise ValueError(f"unknown palette {kind!r}")
    return [fbmodel.to565((i * 53 + 40) % 256, (i * 97 + 90) % 256, (i * 151 + 20) % 256)
            for i in range(offset, offset + count)]


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


def test_image8(w=SRC_W, h=SRC_H):
    """8bpp のテスト画像 (パレットの番号、行優先)。帯ごとに違う模様: 横の階調、8 色の縦縞、市松、番号 0 の格子"""
    out = []
    for y in range(h):
        for x in range(w):
            if y < 60:
                v = (x * 255 // (w - 1)) & 0xFF
            elif y < 120:
                v = 16 * (x * 8 // w) + 3
            elif y < 180:
                v = 200 + ((x // 8) + (y // 8)) % 2 * 17
            else:
                v = 0 if x % 16 == 0 or y % 16 == 0 else (x * 3 + y * 5) & 0xFF
            out.append(v)
    return out


def image_words(px, w, h, stride, addr):
    """w x h のピクセルを、各行 stride ワードで addr から置く UPLOAD (行ごとに 1 コマンド)"""
    out = []
    for y in range(h):
        row = [p & 0xFFFF for p in px[y * w:(y + 1) * w]] + [0] * (2 * stride - w)     # 1 ピクセル 16bit (色の計算のはみ出しを切る)
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
        self.regs = dict(LAYER_RESET)                 # 合成のレジスタ (今の値)
        self.vram = {}                                # VRAM: ワードアドレス -> 32bit (書いていないワードは None)
        self.pal = {}                                 # パレット: 番号 -> RGB565
        self.oam = {}                                 # OAM: ワードアドレス -> 32bit
        self.light = {}                               # ライトマップ: セルの番号 -> (R, G, B) の倍率
        self.scene = None                             # TBDR のシーン (BEGIN_SCENE から END_SCENE まで): {"flags", "color", "tris"}
        self.tex = (0, 3, 3, 0, 0)                     # 今のテクスチャ (形式, 幅の log2, 高さの log2, CLUT のずらし, base)
        self.clut = [0] * 256
        # 印を付けたフレーム: {"line_regs": {ライン: レジスタ}, "fb_base": ..} と、記録中かどうか・今のライン
        self.marked = None
        self.recording = False
        self.cursor = 0

    def put_pixel(self, base, x, y, c):
        """RGB565 は 1 ワードに 2 ピクセル、8bpp (bitmap_fmt) は 4 ピクセル (色の下位 8bit)"""
        if self.regs["bitmap_fmt"]:
            a = (base + y) * 256 + x // 4
            sh = 8 * (x % 4)
            self.mem[a] = (self.mem.get(a, 0) & ~(0xFF << sh) & 0xFFFFFFFF) | (c & 0xFF) << sh
            return
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
        """gpu.sv の BLIT と同じ: ソースの各行はワードの先頭から。透過・左右反転・上下反転、クリップ。
        8bpp のとき: ソースは 8bpp (透過色は key の下位 8bit)、flags bit3 なら 4bpp (タイルの行と同じ並び、値は {key[11:8], ピクセル}、
        透過は値 0)。RGB565 で bit3 はエラー (何も描かない)"""
        f8 = self.regs["bitmap_fmt"]
        if w == 0 or h == 0 or w > BLIT_MAX_W or (flags & 8 and not f8):
            return
        ppw = 8 if flags & 8 else 4 if f8 else 2              # ソースの 1 ワードのピクセル数
        for j in range(h):
            sj = h - 1 - j if flags & 4 else j
            for i in range(w):
                si = w - 1 - i if flags & 2 else i
                a = src + sj * stride + si // ppw
                word = self.mem.get(a)
                if word is None:
                    raise ValueError(f"BLIT reads unwritten word {a:#x}")
                if flags & 8:
                    nib = word >> (28 - 4 * (si % 8)) & 15
                    if flags & 1 and nib == 0:
                        continue
                    p = (key >> 8 & 15) << 4 | nib
                elif f8:
                    p = word >> 8 * (si % 4) & 0xFF
                    if flags & 1 and p == key & 0xFF:
                        continue
                else:
                    p = word >> 16 if si % 2 else word & 0xFFFF
                    if flags & 1 and p == key:
                        continue
                self.plot(x + i, y + j, p)

    def src_pixel(self, src, stride, si, sj, flags, key):
        """BLIT / STRETCH_BLIT のソースのピクセル。(値, 透過か)"""
        f8 = self.regs["bitmap_fmt"]
        ppw = 8 if flags & 8 else 4 if f8 else 2
        a = src + sj * stride + si // ppw
        word = self.mem.get(a)
        if word is None:
            raise ValueError(f"BLIT reads unwritten word {a:#x}")
        if flags & 8:
            nib = word >> (28 - 4 * (si % 8)) & 15
            return (key >> 8 & 15) << 4 | nib, bool(flags & 1 and nib == 0)
        if f8:
            p = word >> 8 * (si % 4) & 0xFF
            return p, bool(flags & 1 and p == key & 0xFF)
        p = word >> 16 if si % 2 else word & 0xFFFF
        return p, bool(flags & 1 and p == key)

    def stretch(self, src, stride, sw, dw, dh, x, y, flags, key, xs, ys):
        """gpu.sv の STRETCH_BLIT と同じ: 描くピクセル (i, j) (反転の前) のソースは ((step >> 1) + i * step) >> 16 (32bit で折り返す)。
        クリップの外の行は読まない。ソースの列が sw 以上になる step はホストの誤り (RTL は前の内容を読む) なのでエラーにする"""
        f8 = self.regs["bitmap_fmt"]
        lim = 4 * BLIT_MAX_W if flags & 8 else 2 * BLIT_MAX_W if f8 else BLIT_MAX_W
        if dw == 0 or dh == 0 or dw > STRETCH_MAX or dh > STRETCH_MAX or (flags & 8 and not f8) or sw > lim:
            return
        cx0, cy0, cx1, cy1 = self.clip
        for j in range(dh):
            yd = y + (dh - 1 - j if flags & 4 else j)
            if not cy0 <= yd <= cy1:
                continue
            sj = ((ys >> 1) + j * ys) & 0xFFFFFFFF
            sj >>= 16
            for i in range(dw):
                xd = x + (dw - 1 - i if flags & 2 else i)
                if not cx0 <= xd <= cx1:
                    continue
                si = (((xs >> 1) + i * xs) & 0xFFFFFFFF) >> 16
                if si >= sw:
                    raise ValueError(f"STRETCH_BLIT samples column {si} of a {sw}-wide source")
                p, tr = self.src_pixel(src, stride, si, sj, flags, key)
                if not tr:
                    self.plot(xd, yd, p)

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
                          (w >> 16) & 15, w & 0xFFFF)
                i += 5
            elif op == OP_STRETCH:
                src, hw, a2, a3, xs, ys = words[i + 1:i + 7]
                self.stretch(src & 0x1FFFFF, a3 & 0xFFFF, a3 >> 16, hw & 0xFFFF, hw >> 16, s16(a2), s16(a2 >> 16),
                             (w >> 16) & 15, w & 0xFFFF, xs, ys)
                i += 7
            elif op == OP_REG_WRITE:
                name = {v: k for k, v in LAYER_REGS.items()}.get((w >> 16) & 0xFF)
                if name:
                    self.regs[name] = w & LAYER_MASK[name]
                    if self.recording:
                        self.marked["line_regs"][self.cursor] = dict(self.regs)
                i += 1
            elif op in (OP_WAIT_LINE, OP_WAIT_VBLANK):
                n = 0 if op == OP_WAIT_VBLANK else w & 0xFF
                if self.recording and (n == 0 or n <= self.cursor):
                    self.recording = False             # 印を付けたフレームが終わった
                if self.recording:
                    if self.cursor == 0:
                        self.marked["fb_base"] = self.fb_base    # ライン 0 は (最初の WAIT_LINE までに) この面
                    self.cursor = n
                    self.marked["line_regs"][n] = dict(self.regs)
                if op == OP_WAIT_VBLANK and w & 1:
                    self.marked = {"line_regs": {0: dict(self.regs)}, "fb_base": None}
                    self.recording = True
                    self.cursor = 0
                i += 1
            elif op == OP_CLIP:
                a0, a1 = words[i + 1], words[i + 2]
                self.set_clip(a0 & 0xFFFF, a0 >> 16, a1 & 0xFFFF, a1 >> 16)
                i += 3
            elif op == OP_SWAP:
                self.fb_base, self.draw_base = self.draw_base, self.fb_base
                i += 1
            elif op == OP_VRAM_WRITE:
                n, addr = w & 0xFFFFFF, words[i + 1]
                for k in range(n):
                    self.vram[(addr + k) % VRAM_WORDS] = words[i + 2 + k]
                i += 2 + n
            elif op == OP_TRI:
                import raster
                n = raster.words_per_tri((w >> 16) & 0xFF)
                if self.scene is not None:
                    self.scene["tris"].append((words[i:i + n], self.clip, self.tex))
                else:
                    self.tri(words[i:i + n])
                i += n
            elif op == OP_SET_TEX:
                w1 = words[i + 1]
                self.tex = ((w >> 16) & 3, (w >> 4) & 15, w & 15, (w >> 8) & 0xFF, w1 & 0x1FFFFF)
                i += 2
            elif op == OP_CLUT_WRITE:
                n, idx = w & 0x1FF, (w >> 16) & 0xFF
                for k in range(n):
                    d = words[i + 1 + k // 2]
                    self.clut[(idx + k) & 0xFF] = d >> 16 if k % 2 else d & 0xFFFF
                i += 1 + (n + 1) // 2
            elif op == OP_BEGIN_SCENE:
                self.scene = {"flags": (w >> 16) & 0xFF, "color": w & 0xFFFF, "tris": []}
                i += 1
            elif op == OP_END_SCENE:
                if self.scene is not None:
                    self.end_scene()
                self.scene = None
                i += 1
            elif op == OP_CLEAR_Z:
                zb = self.regs["z_base"]
                for y in range(SRC_H):
                    for x in range(SRC_W // 2):
                        self.mem[(zb + y) * 256 + x] = (w & 0xFFFF) * 0x10001
                i += 1
            elif op == OP_LIGHT_WRITE:
                n, addr = w & 0xFFFFFF, words[i + 1]
                for k in range(n):
                    d = words[i + 2 + k]
                    self.light[(addr + k) % 2048] = (d & 63, d >> 8 & 63, d >> 16 & 63)
                i += 2 + n
            elif op == OP_OAM_WRITE:
                n, addr = w & 0xFFFFFF, words[i + 1]
                for k in range(n):
                    self.oam[(addr + k) % OAM_WORDS] = words[i + 2 + k]
                i += 2 + n
            elif op == OP_PAL_WRITE:
                n, index = w & 0xFFFFFF, words[i + 1]
                for k in range(n):
                    d = words[i + 2 + k // 2]
                    self.pal[(index + k) % 512] = d >> 16 if k % 2 else d & 0xFFFF
                i += 2 + (n + 1) // 2
            elif op == OP_UPLOAD:
                n, addr = w & 0xFFFFFF, words[i + 1]
                for k in range(n):
                    self.mem[addr + k] = words[i + 2 + k]
                i += 2 + n
            else:          # NOP と知らないコマンドは 1 ワード
                i += 1

    def zget(self, x, y):
        a = (self.regs["z_base"] + y) * 256 + x // 2
        if a not in self.mem:
            raise ValueError(f"TRI reads unwritten Z at ({x},{y}) (clear_z first)")
        return self.mem[a] >> 16 if x % 2 else self.mem[a] & 0xFFFF

    def zset(self, x, y, z):
        a = (self.regs["z_base"] + y) * 256 + x // 2
        w = self.mem.get(a, 0)
        self.mem[a] = (w & 0xFFFF) | z << 16 if x % 2 else (w & 0xFFFF0000) | z

    def tri(self, words, clip=None, zget=None, zset=None, keep=None, tex=None):
        """raster.py の規則で三角形を描く面 (RGB565) に描く。Z なら Z バッファ (既定は Z_BASE、シーンでは zget / zset) でテストして書く。
        keep(x, y) が偽のピクセルは描かない (タイルのリストから落ちた分)"""
        import raster
        zget, zset = zget or self.zget, zset or self.zset
        flags, color, vs = raster.parse(words)
        rec = raster.setup(vs, clip or self.clip)
        if rec is None:
            return
        tex = tex or self.tex
        for x, y, inside, rgb, z, uv in raster.pixels(rec):
            if not inside or (keep and not keep(x, y)):
                continue
            if flags & raster.FLAG_TEX:
                t = raster.texel(self.tex_read, tex, self.clut, uv)
                if t == 0:
                    continue                      # 透明
                c = raster.modulate(t, rgb) if flags & raster.FLAG_GOURAUD else t
            else:
                c = raster.to565(rgb) if flags & raster.FLAG_GOURAUD else color
            if flags & raster.FLAG_Z:
                if not z < zget(x, y):
                    continue
                zset(x, y, z)
            self.put565(self.draw_base, x, y, c)

    def tex_read(self, a):
        w = self.mem.get(a)
        if w is None:
            raise ValueError(f"texture reads unwritten SDRAM word {a:#x}")
        return w

    def put565(self, base, x, y, c):
        a = (base + y) * 256 + x // 2
        w = self.mem.get(a, 0)
        self.mem[a] = (w & 0xFFFF) | c << 16 if x % 2 else (w & 0xFFFF0000) | c

    def end_scene(self):
        """TBDR (rtl/gpu3d/tile_engine.sv と同じ結果): タイル (32 x 32、80 個) ごとに、そのタイルに触れる三角形を投入順に描く。
        BEGIN_SCENE のフラグ: bit0 描く面を色で消してから (でなければ今の面の上に)、bit1 Z を 0xFFFF から (でなければ Z_BASE から読む)、
        bit2 最後の Z を Z_BASE に書き戻す。1 シーン 4,096 個、1 タイル 1,024 個を超えた三角形はそのタイルでは描かない"""
        import raster
        sc = self.scene
        flags = sc["flags"]
        if flags & 1:
            for y in range(SRC_H):
                for x in range(SRC_W):
                    self.put565(self.draw_base, x, y, sc["color"])
        zbuf = {}                                 # このシーンで書いた z (タイルの Z バッファ)。ほかは 0xFFFF か Z_BASE の値

        def zget(x, y):
            if (x, y) in zbuf:
                return zbuf[x, y]
            return 0xFFFF if flags & 2 else self.zget(x, y)
        counts = [0] * 80
        for k, (words, clip, tex) in enumerate(sc["tris"][:SCENE_MAX_TRIS]):
            _, _, vs = raster.parse(words)
            rec = raster.setup(vs, clip)
            if rec is None:
                continue
            bx0, by0, bx1, by1 = rec["bbox"]
            listed = set()
            for ty in range(by0 >> 5, (by1 >> 5) + 1):
                for tx in range(bx0 >> 5, (bx1 >> 5) + 1):
                    t = ty * 10 + tx
                    if counts[t] < TILE_MAX_TRIS:
                        counts[t] += 1
                        listed.add(t)
            self.tri(words, clip, zget, lambda x, y, z: zbuf.__setitem__((x, y), z),
                     lambda x, y: (y >> 5) * 10 + (x >> 5) in listed, tex)
        if flags & 4:
            for y in range(SRC_H):
                for x in range(SRC_W):
                    if (x, y) in zbuf or flags & 2:
                        self.zset(x, y, zget(x, y))

    def vram_word(self, a):
        w = self.vram.get(a % VRAM_WORDS)
        if w is None:
            raise ValueError(f"tile layer reads unwritten VRAM word {a % VRAM_WORDS:#x}")
        return w

    def plane(self, regs, which, y):
        """line_compositor.sv と同じ: 面 ("a" / "b" / "w" = ウィンドウ) の (scroll_x, scroll_y, map_base, pat_base, ctrl)"""
        if which == "w":
            return 0, 0, regs["win_map_base"], regs["tile_pat_base"], (regs["tile_ctrl"] & 0xF0) | 0x01
        pre = "tile_" if which == "a" else "tileb_"
        sx = regs[pre + "scroll_x"]
        mode = regs["hscroll_mode"]
        if mode:
            idx = 0 if mode == 1 else (y & ~7 if mode == 2 else y)
            w = self.vram_word(regs["hscroll_base"] + idx)
            sx = -((w >> 16) if which == "a" else w) & 0x3FF
        return sx, regs[pre + "scroll_y"], regs[pre + "map_base"], regs[pre + "pat_base"], regs[pre + "ctrl"]

    def in_window(self, regs, x, y):
        wh, wv = regs["win_h"], regs["win_v"]
        v8, h16 = (wv & 31) * 8, (wh & 31) * 16
        if (y >= v8) if wv & 0x80 else (y < v8):
            return True
        return x >= h16 if wh & 0x80 else x < h16

    def tile_line(self, y, regs, which="a"):
        """tile_layer.sv と同じ: ライン y の面 (which)。(色, 優先度) のリスト、透明なピクセルは None"""
        scroll_x, scroll_y, map_base, pat_base, ctrl = self.plane(regs, which, y)
        mw = 32 << min(ctrl & 3, 2)
        rows = 28 if (ctrl >> 2) & 3 == 3 else 32 << ((ctrl >> 2) & 3)
        bank = (ctrl >> 4) & 7
        vy = (y + scroll_y) % (rows * 8)
        if (ctrl >> 2) & 3 == 3 and y + scroll_y >= 3 * 224:
            raise ValueError("tile_scroll_y too large for a 28-row map")
        out = []
        for x in range(SRC_W):
            vx = (x + scroll_x) % (mw * 8)
            idx = (vy // 8) * mw + vx // 8
            mword = self.vram_word(map_base + idx // 2)
            e = mword >> 16 if (idx % 2) ^ (ctrl >> 7 & 1) else mword & 0xFFFF
            ty = 7 - vy % 8 if e >> 12 & 1 else vy % 8
            tx = 7 - vx % 8 if e >> 11 & 1 else vx % 8
            row = self.vram_word(pat_base + (e & 0x7FF) * 8 + ty)
            nib = row >> (28 - 4 * tx) & 15
            if nib == 0:
                out.append(None)
                continue
            pi = bank << 6 | (e >> 13 & 3) << 4 | nib
            if pi not in self.pal:
                raise ValueError(f"tile layer uses unwritten palette entry {pi}")
            out.append((self.pal[pi], e >> 15 & 1))
        return out

    def oam_word(self, a):
        w = self.oam.get(a)
        if w is None:
            raise ValueError(f"sprites read unwritten OAM word {a:#x}")
        return w

    def sprite_line(self, y, regs):
        """sprite_layer.sv と同じ: ライン y に出るスプライトのピクセル (x, 色, 優先度) を出す順に。
        OAM の順、ラインの上限は spr_line_px // 8 列 (画面の外の列も数える)。spr_bank bit3 ならパレットはスプライトごとのバンク"""
        cols = regs["spr_line_px"] >> 3
        bank = regs["spr_bank"]
        out = []
        for n in range(128):
            w0 = self.oam_word(2 * n)
            sx, sy = s10(w0), s10(w0 >> 16)
            w, h, order = (w0 >> 26 & 3) + 1, (w0 >> 28 & 3) + 1, (w0 >> 30 & 1) | (w0 >> 10 & 1) << 1
            dy = y - sy
            if not (w0 >> 31 and 0 <= dy < h * 8):
                continue
            w1 = self.oam_word(2 * n + 1)
            first, hflip, vflip, pal, pri = w1 & 0x7FF, w1 >> 11 & 1, w1 >> 12 & 1, w1 >> 13 & 3, w1 >> 15 & 1
            ry = h * 8 - 1 - dy if vflip else dy
            for col in range(w):
                if cols == 0:
                    return out
                cols -= 1
                sc = w - 1 - col if hflip else col
                if order == 1:
                    tile = ((first >> 4) + ry // 8) % 128 << 4 | (first + sc) % 16
                elif order == 0:
                    tile = (first + sc * h + ry // 8) % 2048
                else:                               # 2 (と予約の 3): 行優先
                    tile = (first + (ry // 8) * w + sc) % 2048
                row = self.vram_word(regs["spr_pat_base"] + tile * 8 + ry % 8)
                for k in range(8):
                    x = sx + col * 8 + k
                    nib = row >> (28 - 4 * (7 - k if hflip else k)) & 15
                    if 0 <= x < SRC_W and nib:
                        pi = (w1 >> 16 & 15) << 4 | nib if bank & 8 else (bank & 7) << 6 | pal << 4 | nib
                        if pi not in self.pal:
                            raise ValueError(f"sprites use unwritten palette entry {pi}")
                        out.append((x, self.pal[pi], pri))
        return out

    def compose_line(self, base, y, regs):
        """line_compositor.sv と同じ: 順位の付いた作業ラインに、スプライト (空いているところだけ = OAM の前が勝つ) →
        面 B → 面 A (ウィンドウの外) → ウィンドウ → ビットマップの順に書く。タイルとビットマップは「順位が今より大きいときだけ」。順位 0 (誰も書かなかった) は背景色"""
        bg, ctrl, key = regs["bg_color"], regs["layer_ctrl"], regs["bitmap_key"]
        line = [(0, bg)] * SRC_W                  # (順位, 色)
        if ctrl & 8:
            for x, c, pri in self.sprite_line(y, regs):
                if line[x][0] == 0:
                    line[x] = (RANK_S_HI if pri else RANK_S_LO, c)
        if ctrl & 16:
            for x, t in enumerate(self.tile_line(y, regs, "b")):
                if t is not None:
                    rank = RANK_B_HI if t[1] else RANK_B_LO
                    if rank > line[x][0]:
                        line[x] = (rank, t[0])
        m7 = self.m7_regs(regs, y)
        if ctrl & 4 and m7:
            for x, t in enumerate(self.mode7_line(y, regs, m7)):
                if t is not None:
                    rank = RANK_A_HI if t[1] else RANK_A_LO
                    if rank > line[x][0]:
                        line[x] = (rank, t[0])
        elif ctrl & 4:
            win = [self.in_window(regs, x, y) for x in range(SRC_W)]
            passes = [("a", False)] + ([("w", True)] if any(win) else [])
            for which, inside in passes:
                for x, t in enumerate(self.tile_line(y, regs, which)):
                    if t is not None and win[x] == inside:
                        rank = RANK_A_HI if t[1] else RANK_A_LO
                        if rank > line[x][0]:
                            line[x] = (rank, t[0])
        if ctrl & 1 and regs["bitmap_fmt"]:
            # 8bpp: パレットの番号 (0..255)。透過色は bitmap_key の下位 8bit
            rank = regs["bitmap_rank"]
            for x in range(SRC_W // 4):
                w = self.mem.get((base + y) * 256 + x)
                if w is None:
                    raise ValueError(f"displayed plane {base} has unwritten pixels at ({4 * x},{y})")
                for k in range(4):
                    i = w >> 8 * k & 0xFF
                    if not (ctrl & 2 and i == key & 0xFF) and rank > line[4 * x + k][0]:
                        if i not in self.pal:
                            raise ValueError(f"8bpp bitmap uses unwritten palette entry {i}")
                        line[4 * x + k] = (rank, self.pal[i])
        elif ctrl & 1:
            rank = regs["bitmap_rank"]
            for x in range(SRC_W // 2):
                w = self.mem.get((base + y) * 256 + x)
                if w is None:
                    raise ValueError(f"displayed plane {base} has unwritten pixels at ({2 * x},{y})")
                for k, p in enumerate((w & 0xFFFF, w >> 16)):
                    if not (ctrl & 2 and p == key) and rank > line[2 * x + k][0]:
                        line[2 * x + k] = (rank, p)
        out = [bg if r == 0 else c for r, c in line]
        mul, add = regs["line_mul"], regs["line_add"]
        if regs["line_fx_ctrl"] & 1:             # 霧の表 (E7): {LINE_ADD, LINE_MUL}
            w = self.vram_word(regs["line_fx_base"] + y)
            mul, add = w & 0x7FFF, w >> 16
        lmul = (mul & 31, mul >> 5 & 31, mul >> 10 & 31)
        if ctrl & 32 or lmul != (16, 16, 16) or add:
            # ライトマップ (K4、背景色にも掛かる) と霧 (E7): L_eff = min(63, (L_cell * L_line) >> 4)、lit のあとに LINE_ADD
            for x in range(SRC_W):
                cell = (16, 16, 16)
                if ctrl & 32:
                    cell = self.light.get(y // 8 * LIGHT_W + x // 8)
                    if cell is None:
                        raise ValueError(f"lightmap cell ({x // 8},{y // 8}) is unwritten")
                eff = tuple(min(63, c * m >> 4) for c, m in zip(cell, lmul))
                out[x] = add565(lit(out[x], eff), add)
        return out

    def m7_regs(self, regs, y):
        """line_compositor.sv と同じ: Mode 7 が有効なら、このラインの行列 (表から読んだもの込み)。無効なら None"""
        ctrl = regs["m7_ctrl"]
        if not ctrl & 1:
            return None
        a, b, c, d = regs["m7_a"], regs["m7_b"], regs["m7_c"], regs["m7_d"]
        tab, base, z = ctrl >> 2 & 3, regs["m7_tbl_base"], None
        if tab == 1:
            w0, w1 = self.vram_word(base + 2 * y), self.vram_word(base + 2 * y + 1)
            a, b, c, d = w0 & 0xFFFF, w0 >> 16, w1 & 0xFFFF, w1 >> 16
        elif tab == 2:
            z = self.vram_word(base + y) & 0xFFFF
        if z is not None:                         # 遠近: a = cos、b = sin (1.14)
            ea = sext(z * sext(a, 16) >> 14, 16)
            eb = sext(z * sext(b, 16) >> 14, 16)
            a, b, c, d = ea, eb, sext(-eb, 16), ea
        else:
            a, b, c, d = sext(a, 16), sext(b, 16), sext(c, 16), sext(d, 16)
        return a, b, c, d

    def vbyte(self, byte_addr):
        return self.vram_word(byte_addr >> 2) >> 8 * (byte_addr & 3) & 0xFF

    def mode7_line(self, y, regs, m):
        """mode7_layer.sv と同じ (bsnes の式): ライン y の (色, 優先度) のリスト、透明なピクセルは None"""
        a, b, c, d = m
        sel, extbg = regs["m7_sel"], regs["m7_ctrl"] >> 1 & 1
        hflip, vflip, over = sel & 1, sel >> 1 & 1, sel >> 6 & 3
        x0, y0 = sext(regs["m7_x0"], 13), sext(regs["m7_y0"], 13)
        h = m7_clip(sext(regs["m7_hofs"], 13) - x0)
        v = m7_clip(sext(regs["m7_vofs"], 13) - y0)
        yy = y - sext(regs["m7_sy"], 9)
        if vflip:
            yy = 255 - yy
        sx = sext(regs["m7_sx"], 10)
        xs = 255 + sx if hflip else -sx
        ox = ((a * h) & ~63) + ((b * v) & ~63) + ((b * yy) & ~63) + (x0 << 8)
        oy = ((c * h) & ~63) + ((d * v) & ~63) + ((d * yy) & ~63) + (y0 << 8)
        mb, pb = regs["m7_map_base"] * 4, regs["m7_pat_base"] * 4
        out = []
        for i in range(SRC_W):
            xx = xs - i if hflip else xs + i
            px, py = (ox + a * xx) >> 8, (oy + c * xx) >> 8
            oob = (px | py) & ~1023
            if oob and over == 2:
                out.append(None)
                continue
            t = 0 if oob and over == 3 else self.vbyte((mb + ((py >> 3) & 127) * 128 + ((px >> 3) & 127)) & 0xFFFF)
            pix = self.vbyte((pb + t * 64 + (py & 7) * 8 + (px & 7)) & 0xFFFF)
            idx = pix & 127 if extbg else pix
            if idx == 0:
                out.append(None)
                continue
            if idx not in self.pal:
                raise ValueError(f"mode 7 uses unwritten palette entry {idx}")
            out.append((self.pal[idx], pix >> 7 if extbg else 0))
        return out

    def displayed565(self):
        """今表示されている画面 (レジスタは今の値が全ラインに効いている) の 320x240 RGB565"""
        img = []
        for y in range(SRC_H):
            img += self.compose_line(self.fb_base, y, self.regs)
        return img

    def marked565(self):
        """印を付けたフレーム: ラインごとに、そのラインで効いていたレジスタで合成する"""
        if self.marked is None:
            raise ValueError("check_marked without a preceding wait_vblank mark")
        base = self.marked["fb_base"] if self.marked["fb_base"] is not None else self.fb_base
        starts = sorted(self.marked["line_regs"])
        img, k = [], 0
        for y in range(SRC_H):
            while k + 1 < len(starts) and starts[k + 1] <= y:
                k += 1
            img += self.compose_line(base, y, self.marked["line_regs"][starts[k]])
        return img


def load(path):
    with open(path) as f:
        return json.load(f)


def expected(scenario, kinds=None):
    """シナリオを最初から走らせ、check ごとに (そこまでのワード数, 画像 565, CRC) を返す。
    kinds にリストを渡すと、check の種類 ("check" / "check_marked") を入れる"""
    m = Model()
    words, checks = [], []
    for step in scenario["steps"]:
        if step["op"] in ("check", "check_marked"):
            img = m.displayed565() if step["op"] == "check" else m.marked565()
            checks.append((len(words), img, fbmodel.expected_crc(img)))
            if kinds is not None:
                kinds.append(step["op"])
        else:
            w = encode(step)
            m.run(w)
            words += w
    return words, checks


def export(path, out_dir):
    """Verilator のシナリオ実行 (sim/scenario/gpu_scenario_tb.sv) の入力を書く"""
    import os
    sc = load(path)
    kinds = []
    words, checks = expected(sc, kinds)
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "cmds.hex"), "w") as f:
        f.write(f"{len(words)}\n" + "".join(f"{w:08x}\n" for w in words))
    with open(os.path.join(out_dir, "checks.txt"), "w") as f:
        # 1 行に「ワード数 種類」(種類 0 = 普通の check、1 = 印を付けたフレーム)
        f.write(f"{len(checks)}\n" + "".join(f"{n} {int(k == 'check_marked')}\n" for (n, _, _), k in zip(checks, kinds)))
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
            rtl_crc, frame, under, max_fetch, max_line = f.read().split()
        with open(os.path.join(out_dir, f"frame_{i}.ppm"), "rb") as f:
            ppm = f.read()
        ppm_crc = zlib.crc32(ppm[ppm.index(b"255\n") + 4:])
        r = {"check": i, "model": f"0x{crc:08x}", "rtl_frame_crc": f"0x{int(rtl_crc, 16):08x}",
             "ppm": f"0x{ppm_crc:08x}", "frame": int(frame), "underflow": int(under),
             "max_fetch_cycles": int(max_fetch), "max_line_cycles": int(max_line)}
        # 1 ラインの合成 (タイルのパス + 表示のライン読み出し) は出力 2 ライン (63.5us = clk_sys 4000 クロック) までに終われば間に合う
        r["ok"] = (int(rtl_crc, 16) == crc == ppm_crc and int(under) == 0 and int(max_fetch) < 4000
                   and int(max_line) < 4000)
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
