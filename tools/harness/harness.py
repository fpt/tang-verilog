#!/usr/bin/env python3
"""ハーネスのホスト側ツール (docs/GPU_PLAN.md の M0)

RP2 ブリッジ (harness/firmware) と USB シリアルで話す。標準ライブラリだけで動く。
USB を使うので Docker ではなくホスト (macOS / Linux) で直接動かす。

usage: harness.py [--port PORT] <command> [args...]
  ping | status | wiretest | bootsel
  spi <hex>        SPI の 1 トランザクション
  freq <hz>        SPI の周波数
  reset [ms]       RESET を High にする
  irqwait [ms]     IRQ の立ち上がりを待つ
  raw <line>       ブリッジに 1 行そのまま送る
  prog <target>    make prog TARGET=<target> (pincheck 込みで FPGA の SRAM に書き込む)
  reg read <reg> [n]        レジスタを読む (<reg> は名前か 0x7e のような番地)
  reg write <reg> <hex>     レジスタに書く (複数バイトなら番地が 1 ずつ進む)
  selftest [--iterations N] HARNESS.md の selftest (FPGA に hdmi などの設計が入っている前提)
  memtest [--size N] [--samples 2,3,..] [--seed S] [--phases 0-15]
                            SDRAM の BIST を読み出しの取り込み位置ごと (と SDRAM クロックの位相ごと) に実行
                            (size はワード数の log2、既定 21 = 8MiB)。--phases を付けると位相 x 取り込み位置の合否表を出す
  frametest [--ref-dir DIR] [--no-capture] [--out DIR]
                            アニメーションを止め、FRAME_CRC を参照 (make render FREEZE=1 の frames.json) と比べ、
                            HDMI キャプチャも参照画像と比べる。キャプチャと差分画像を --out に保存
  fps <file.json> [--frames N]
                            {"setup", "frame"} の frame を N 回くり返して速さを測る (fps、表示フレーム / 描画フレーム、UNDERFLOW)。
                            "frames": [[...], ...] ならフレームごとに順に使う
  demo [<scene>] [--frames N] [--start K] [--shot PNG]
                            M9 のデモ (demo.py) を流す。N フレーム (0 なら Ctrl-C まで)。速さ・表示フレーム / 描画フレーム・UNDERFLOW。
                            <scene> (logo / tunnel / room / city) なら G5 の 3D の場面 (demo3d.py、make TARGET=gpu3d のビットストリーム)。
                            --shot で最後のフレームの HDMI キャプチャを PNG に
  scenario <file.json> [--no-capture]
                            シナリオを実機で走らせ、check ごとに FRAME_CRC を参照モデル (gpu_model.py) と比べる
  fb upload [<png>] [--slot N]  320x240 の画像 (省略時はテスト画像) を SDRAM のフレームバッファへ (slot は 1KiB 単位)
  fb show [--slot N] / fb off   フレームバッファの表示 / テストパターンに戻す
  fbtest [<png>] [--slot N] [--keep] [--no-capture]
                            アップロードして表示し、FRAME_CRC と UNDERFLOW を参照モデル (fbmodel.py) と比べ、
                            HDMI キャプチャも比べる。--keep でそのまま表示を残す
  mem read <word_addr> [n]  SDRAM を 1 ワードずつ読む
  mulprobe [--iterations N] 3D GPU のビットストリーム (make TARGET=gpu3d) の乗算器 (mul_probe、DSP) を端の値と乱数で確かめる
  mem write <word_addr> <hex32>...  SDRAM に書く

出力は 1 つの JSON (標準出力)。"ok" が true でなければ終了コード 1。
ポートは --port、環境変数 HARNESS_PORT、/dev/cu.usbmodem* / /dev/ttyACM* の順で探す。
"""
import argparse
import glob
import json
import os
import random
import select
import subprocess
import sys
import termios
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# rtl/vdp/vdp_regs.sv のレジスタマップ
REGS = {
    "STATUS": 0x00,
    "CONTROL": 0x01,
    "FRAME_COUNT": 0x04,
    "FRAME_CRC": 0x05,      # 32bit、リトルエンディアン (0x05..0x08)
    "UNDERFLOW": 0x09,
    "CRC_FRAME": 0x0A,      # FRAME_CRC のフレーム番号 (16bit、0x05 を読んだ時点の値)
    "MARK_COUNT": 0x02,     # 印を付けたフレームの CRC を更新するたびに 1 増える
    "MARK_CRC": 0x0C,       # 印を付けたフレーム (WAIT_VBLANK、印付き) の CRC (32bit)
    # rtl/vdp/gpu.sv
    "CMD": 0x30,            # コマンドのポート (アドレスが進まない)
    "GPU_STATUS": 0x40,     # bit0 実行中, bit1 エラー, bit2 FIFO あふれ (読むとクリア) / 書き込み bit0 で FIFO を空に
    "GPU_FREE": 0x41,       # FIFO の空き (ワード数、16bit)
    "FB_BASE": 0x44,        # 表示する面 (13bit、256 ワード = 1KiB 単位)
    "DRAW_BASE": 0x46,      # 描く面
    "BG_COLOR": 0x48,       # 合成の背景色 (RGB565)
    "LAYER_CTRL": 0x4A,     # bit0 ビットマップ レイヤ有効, bit1 ビットマップの透過色を有効
    "BITMAP_KEY": 0x4C,     # ビットマップの透過色
    "SCRATCH": 0x7D,
    "ID": 0x7E,
    "VERSION": 0x7F,
}
# rtl/vdp/mem_test.sv (SDRAM のテスト)
MEM = {
    "CMD": 0x10, "CFG": 0x11, "STATUS": 0x12, "SIZE": 0x13, "SEED": 0x14, "CLK": 0x15,
    "ERRORS": 0x18, "FAIL_ADDR": 0x1C, "FAIL_EXP": 0x20, "FAIL_GOT": 0x24, "ADDR": 0x28, "DATA": 0x2C,
}
GPU_ST_BUSY, GPU_ST_ERROR, GPU_ST_OVERFLOW = 0x01, 0x02, 0x04
CAPTURE_OK = 0.95      # scenario のキャプチャの合格線 (正しさは FRAME_CRC で決める)
SPI_MAX_DATA = 4092    # ブリッジの spi は 1 回 4096 バイトまで (先頭のアドレス 1 バイトを除き、4 の倍数)
MEM_CMD_BIST, MEM_CMD_READ, MEM_CMD_WRITE = 1, 2, 3
MEM_ST_INIT, MEM_ST_BUSY, MEM_ST_DONE, MEM_ST_PASS = 0x01, 0x02, 0x04, 0x08
REGS.update({f"MEM_{k}": v for k, v in MEM.items()})
VDP_ID = 0x5A
SYNC_BYTE = 0xA5            # spi_slave が 1 バイト目に返す値
CONTROL_FREEZE = 0x02
CONTROL_IRQ_EN = 0x04
CONTROL_FB = 0x08
CONTROL_IRQ_READY = 0x10   # IRQ ピンを READY (GPU の FIFO が半分以上空いている) にする
STATUS_ERROR = 0x02


def find_port(explicit):
    if explicit:
        return explicit
    if os.environ.get("HARNESS_PORT"):
        return os.environ["HARNESS_PORT"]
    for pattern in ("/dev/cu.usbmodem*", "/dev/ttyACM*"):
        ports = sorted(glob.glob(pattern))
        if ports:
            return ports[0]
    raise SystemExit(json.dumps({"ok": False, "error": "bridge not found (no /dev/cu.usbmodem* or /dev/ttyACM*)"}))


class Bridge:
    def __init__(self, port):
        self.fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
        attrs = termios.tcgetattr(self.fd)
        attrs[0] = 0                                                  # iflag
        attrs[1] = 0                                                  # oflag
        attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL      # cflag
        attrs[3] = 0                                                  # lflag (raw)
        attrs[4] = attrs[5] = termios.B115200                        # USB CDC なので実際の速度は関係ない
        attrs[6][termios.VMIN] = 0
        attrs[6][termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW, attrs)
        termios.tcflush(self.fd, termios.TCIOFLUSH)
        self.buf = b""
        self._version = None

    def version(self):
        """ブリッジの版 (ping)。v2 から spib (生データの書き込み)、v3 から stream (空きを見ながら流す) が使える"""
        if self._version is None:
            r = self.command("ping")
            self._version = r.get("version", 1) if r.get("ok") else 1
        return self._version

    def close(self):
        os.close(self.fd)

    def command(self, line, timeout=5.0, payload=b""):
        """1 行のコマンドを送り、1 行の JSON の応答を返す。payload は改行の直後に続けて送る生データ (spib 用)"""
        data = (line + "\n").encode() + payload
        while data:
            n = os.write(self.fd, data)
            data = data[n:]
        deadline = time.monotonic() + timeout
        while True:
            while b"\n" in self.buf:
                raw, self.buf = self.buf.split(b"\n", 1)
                text = raw.strip().decode(errors="replace")
                if not text or text.startswith("#"):
                    continue
                return json.loads(text)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return {"ok": False, "error": f"timeout waiting for reply to {line.split()[0]!r}"}
            ready, _, _ = select.select([self.fd], [], [], remaining)
            if ready:
                self.buf += os.read(self.fd, 65536)


class HarnessError(Exception):
    pass


class Gpu:
    """コマンド GPU (rtl/vdp/gpu.sv) にワードを送る。FIFO の空き (GPU_FREE) を見て、その分だけ送る"""

    def __init__(self, vdp):
        self.vdp = vdp

    def free(self):
        return int.from_bytes(self.vdp.read(REGS["GPU_FREE"], 2), "little")

    def send(self, words, timeout=10.0):
        data = b"".join((w & 0xFFFFFFFF).to_bytes(4, "little") for w in words)
        if not data:
            return
        if self.vdp.bridge.version() >= 3:
            # ブリッジが GPU_FREE を SPI で読みながら CMD に流す (USB の往復は 1 回)
            r = self.vdp.bridge.command(f"stream {len(data)} {REGS['CMD']} {REGS['GPU_FREE']}", timeout=timeout, payload=data)
            if not r.get("ok"):
                raise HarnessError(r.get("error", "stream failed"))
            return
        deadline = time.monotonic() + timeout
        while data:
            n = min(self.free() * 4, SPI_MAX_DATA, len(data))
            if n == 0:
                if time.monotonic() > deadline:
                    raise HarnessError("GPU FIFO stays full")
                time.sleep(0.001)
                continue
            self.vdp.write(REGS["CMD"], data[:n])
            data = data[n:]

    def status(self):
        return self.vdp.read1(REGS["GPU_STATUS"])      # 読むとエラーとあふれが消える

    def wait_idle(self, timeout=5.0):
        """busy が落ちるまで待つ。読むたびにエラーとあふれが消えるので、待つあいだに見えたものも返す"""
        deadline = time.monotonic() + timeout
        seen = 0
        while True:
            st = self.status()
            seen |= st & (GPU_ST_ERROR | GPU_ST_OVERFLOW)
            if not st & GPU_ST_BUSY:
                return st | seen
            if time.monotonic() > deadline:
                raise HarnessError("GPU stays busy")
            time.sleep(0.002)

    def flush(self):
        self.vdp.write(REGS["GPU_STATUS"], [0x01])


class Vdp:
    """ブリッジ経由で VDP のレジスタを読み書きする (プロトコルは rtl/vdp/spi_slave.sv)"""

    def __init__(self, bridge):
        self.bridge = bridge

    def _spi(self, data):
        r = self.bridge.command("spi " + bytes(data).hex(), timeout=5.0)
        if not r.get("ok"):
            raise HarnessError(r.get("error", "spi failed"))
        rx = bytes.fromhex(r["rx"])
        if rx[0] != SYNC_BYTE:
            raise HarnessError(f"bad sync byte 0x{rx[0]:02x} (expected 0x{SYNC_BYTE:02x})")
        return rx[1:]

    def read(self, addr, n=1):
        return self._spi([0x80 | addr] + [0] * n)

    def write(self, addr, data):
        frame = bytes([addr & 0x7F]) + bytes(data)
        if self.bridge.version() >= 2:
            # 生データで送る (16 進にしないので速い)。応答は受信の最初の 1 バイトだけ = 同期バイト
            r = self.bridge.command(f"spib {len(frame)}", timeout=5.0, payload=frame)
            if not r.get("ok"):
                raise HarnessError(r.get("error", "spib failed"))
            if int(r["rx0"], 16) != SYNC_BYTE:
                raise HarnessError(f"bad sync byte 0x{r['rx0']} (expected 0x{SYNC_BYTE:02x})")
        else:
            self._spi(frame)

    def read1(self, addr):
        return self.read(addr)[0]

    def read32(self, addr):
        return int.from_bytes(self.read(addr, 4), "little")

    def write32(self, addr, value):
        self.write(addr, value.to_bytes(4, "little"))

    def mem_wait(self, timeout):
        deadline = time.monotonic() + timeout
        while True:
            st = self.read1(MEM["STATUS"])
            if not st & MEM_ST_BUSY:
                return st
            if time.monotonic() > deadline:
                raise HarnessError("SDRAM test timed out")
            time.sleep(0.01)


def memtest(bridge, size, samples, seed, phases=None):
    """SDRAM の BIST を取り込み位置 (rd_sample) ごとに実行する。
    phases を渡すと SDRAM クロックの位相 (MEM_CLK) も変え、位相 x 取り込み位置の合否表 (eye) を作る"""
    vdp = Vdp(bridge)
    st = vdp.read1(MEM["STATUS"])
    if not st & MEM_ST_INIT:
        return {"ok": False, "error": "SDRAM not initialized", "status": st}
    cfg = vdp.read1(MEM["CFG"])     # 終わったら元に戻す (表示も同じ設定を使うので)
    clk = vdp.read1(MEM["CLK"])

    def run_bist(h):
        vdp.write(MEM["CFG"], [h])
        vdp.write(MEM["SIZE"], [size])
        vdp.write(MEM["SEED"], [seed])
        start = time.monotonic()
        vdp.write(MEM["CMD"], [MEM_CMD_BIST])
        st = vdp.mem_wait(timeout=30.0)
        run = {"rd_sample": h, "pass": bool(st & MEM_ST_PASS), "errors": vdp.read32(MEM["ERRORS"]),
               "seconds": round(time.monotonic() - start, 2)}
        if not run["pass"]:
            exp, got = vdp.read32(MEM["FAIL_EXP"]), vdp.read32(MEM["FAIL_GOT"])
            run.update(first_fail_addr=f"0x{vdp.read32(MEM['FAIL_ADDR']):06x}", expected=f"0x{exp:08x}",
                       got=f"0x{got:08x}", bad_bits=f"0x{exp ^ got:08x}")
        return run

    try:
        if phases is None:
            runs = [run_bist(h) for h in samples]
            passing = [r["rd_sample"] for r in runs if r["pass"]]
            return {"ok": bool(passing), "words": 1 << size, "passing_rd_sample": passing, "runs": runs}

        eye = {}
        for ph in phases:
            vdp.write(MEM["CLK"], [ph])
            time.sleep(0.01)                       # PLL の位相が落ち着くまで
            eye[ph] = [h for h in samples if run_bist(h)["pass"]]
        # 表: 行 = 位相、列 = 取り込み位置。# が合格
        table = ["phase " + " ".join(str(h) for h in samples)]
        for ph in phases:
            table.append(f"{ph:5d} " + " ".join("#" if h in eye[ph] else "." for h in samples))
        return {"ok": any(eye.values()), "words": 1 << size,
                "eye": {str(k): v for k, v in eye.items()}, "table": table}
    finally:
        vdp.write(MEM["CFG"], [cfg])
        vdp.write(MEM["CLK"], [clk])


def parse_reg(text):
    if text.upper() in REGS:
        return REGS[text.upper()]
    return int(text, 0)


def edge_rate(bridge, name, seconds):
    """status を 2 回取り、その間の立ち上がり回数から平均周波数を求める。
    時間はブリッジの時計で、各 status の時点での「最後の立ち上がり」(uptime_ms - age_ms) の間隔を使う
    (ホスト側の時計や USB の遅れの影響を受けない)"""
    s1 = bridge.command("status")
    time.sleep(seconds)
    s2 = bridge.command("status")
    t1 = s1["uptime_ms"] - s1[name]["age_ms"]
    t2 = s2["uptime_ms"] - s2[name]["age_ms"]
    return (s2[name]["rises"] - s1[name]["rises"]) / ((t2 - t1) / 1000)


def selftest(bridge, iterations):
    """HARNESS.md の selftest。最初に失敗した項目で止める"""
    vdp = Vdp(bridge)
    items = []

    def item(name, ok, **info):
        items.append({"name": name, "ok": bool(ok), **info})
        if not ok:
            raise HarnessError(name)

    try:
        r = bridge.command("ping")
        item("bridge ping", r.get("ok"), fw=r.get("fw"), version=r.get("version"), board=r.get("board"))

        r = bridge.command("status")
        item("fpga ready (HEARTBEAT toggling)", r.get("ready"), heartbeat=r.get("heartbeat"))

        hz = edge_rate(bridge, "heartbeat", 1.0)
        item("HEARTBEAT 30Hz +-5%", abs(hz - 30.0) <= 1.5, hz=round(hz, 2))

        hz = edge_rate(bridge, "vsync", 1.0)
        item("VSYNC 60Hz +-1%", abs(hz - 60.0) <= 0.6, hz=round(hz, 2))

        bridge.command("freq 1000000")
        vid, ver = vdp.read(REGS["ID"], 2)
        item("ID == 0x5A", vid == VDP_ID, id=f"0x{vid:02x}", version=ver)

        f1 = vdp.read1(REGS["FRAME_COUNT"])
        time.sleep(0.5)
        f2 = vdp.read1(REGS["FRAME_COUNT"])
        frames = (f2 - f1) & 0xFF
        item("FRAME_COUNT advances (~30 in 0.5s)", 27 <= frames <= 33, frames=frames)

        vdp.read1(REGS["STATUS"])   # 以前のエラーをクリア
        for hz in (1_000_000, 4_000_000, 8_000_000):
            actual = bridge.command(f"freq {hz}")["spi_hz"]
            errors = 0
            start = time.monotonic()
            for _ in range(iterations):
                v = random.randrange(256)
                vdp.write(REGS["SCRATCH"], [v])
                if vdp.read1(REGS["SCRATCH"]) != v:
                    errors += 1
            status = vdp.read1(REGS["STATUS"])
            item(f"SCRATCH round trip at {hz // 1_000_000}MHz", errors == 0 and not status & STATUS_ERROR,
                 spi_hz=actual, iterations=iterations, errors=errors, frame_error=bool(status & STATUS_ERROR),
                 seconds=round(time.monotonic() - start, 1))
        bridge.command("freq 1000000")

        vdp.write(REGS["CONTROL"], [CONTROL_IRQ_EN])
        r = bridge.command("irqwait 50", timeout=2.0)
        vdp.write(REGS["CONTROL"], [0])
        item("IRQ (VBLANK) with CONTROL.IRQ_EN", r.get("ok"), waited_us=r.get("waited_us"))

        # 動いていれば 300ms で HEARTBEAT の立ち上がりは約 9 回。リセット中は止まり、解除直後に 1 回立ち上がる
        vdp.write(REGS["SCRATCH"], [0xA5])
        r0 = bridge.command("status")["heartbeat"]["rises"]
        bridge.command("reset 300", timeout=3.0)
        r1 = bridge.command("status")["heartbeat"]["rises"]
        time.sleep(0.3)
        r2 = bridge.command("status")["heartbeat"]["rises"]
        scratch = vdp.read1(REGS["SCRATCH"])
        item("RESET stops HEARTBEAT and clears registers", r1 - r0 <= 2 and r2 - r1 >= 7 and scratch == 0,
             heartbeat_rises_during_300ms_reset=r1 - r0, heartbeat_rises_300ms_after=r2 - r1, scratch=scratch)

        # SDRAM: 今の取り込み位置で、位相を何段ずらしても読めるか (前後の余裕)。毎回記録する
        vdp = Vdp(bridge)
        cfg, phase = vdp.read1(MEM["CFG"]), vdp.read1(MEM["CLK"])
        r = memtest(bridge, 16, [cfg], 0x3C, list(range(16)))
        ok_phases = {int(p) for p, hs in r["eye"].items() if cfg in hs}
        early = late = 0
        while (phase - early - 1) % 16 in ok_phases and early < 8:
            early += 1
        while (phase + late + 1) % 16 in ok_phases and late < 8:
            late += 1
        item("SDRAM phase margin >= 2 steps each side", phase in ok_phases and early >= 2 and late >= 2,
             rd_sample=cfg, phase=phase, margin_early=early, margin_late=late,
             passing_phases=sorted(ok_phases))

        # READY の線 (IRQ ピンを READY にする): FIFO が空なら High、GPU を WAIT_LINE で 2 フレームほど止めて
        # FIFO を半分以上 (深さの 6 割。VDP は 512、3D は 2,048 ワード) 埋めると Low、空になると High に戻る
        control = vdp.read1(REGS["CONTROL"])
        gpu = Gpu(vdp)
        vdp.write(REGS["CONTROL"], [control | CONTROL_IRQ_READY])
        try:
            idle_level = bridge.command("status")["pins"]["IRQ"]
            depth = gpu.free()                                          # 空のときの空き = FIFO の深さ
            block = [0x0A00_0000 | n for n in (200, 100) * 4]           # 下がるたびに次のフレームまで待つ (約 4 フレーム)
            queued = depth * 6 // 10
            bridge.command("freq 8000000")                              # 送り終わる前に待ちが明けないように (1MHz だと 2,048 ワードで 40ms)
            try:
                gpu.send(block + [0] * queued)
            finally:
                bridge.command("freq 1000000")
            busy_level = bridge.command("status")["pins"]["IRQ"]
            gpu.wait_idle()
            after_level = bridge.command("status")["pins"]["IRQ"]
        finally:
            vdp.write(REGS["CONTROL"], [control])
        item("READY wire (IRQ pin with CONTROL bit4)", idle_level == 1 and busy_level == 0 and after_level == 1,
             idle=idle_level, queued=queued, fifo_words=depth, while_queued=busy_level, after_drain=after_level)

        pins = bridge.command("status")["pins"]
        items.append({"name": "LED0-5 (info)", "ok": True, "leds": [pins[f"LED{i}"] for i in range(6)]})
        items.append({"name": "UART banner", "ok": True, "skipped": "not implemented yet"})
    except HarnessError:
        pass
    return {"ok": all(i["ok"] for i in items), "items": items}


def frametest(bridge, ref_dir, do_capture, out_dir):
    """アニメーションを止めた画面を、参照 (make render FREEZE=1) と CRC とキャプチャで比べる"""
    import imgcmp

    with open(os.path.join(ref_dir, "frames.json")) as f:
        ref = json.load(f)[0]
    vdp = Vdp(bridge)
    result = {"reference": os.path.join(ref_dir, ref["png"]), "expected_crc": ref["crc"]}
    control = vdp.read1(REGS["CONTROL"])
    try:
        vdp.write(REGS["CONTROL"], [control | CONTROL_FREEZE])
        time.sleep(0.1)    # 数フレーム待って、止めたあとのフレームの CRC にする
        crcs = []
        for _ in range(3):
            crcs.append(f"0x{vdp.read32(REGS['FRAME_CRC']):08x}")
            time.sleep(0.05)
        result["crc"] = {"ok": all(c == ref["crc"] for c in crcs), "read": crcs}

        if do_capture:
            w, h, ref_rgb = imgcmp.read_png(result["reference"])
            cap = imgcmp.capture(w, h)
            stats, diff = imgcmp.compare(ref_rgb, cap, w, h)
            os.makedirs(out_dir, exist_ok=True)
            imgcmp.write_png(os.path.join(out_dir, "capture.png"), w, h, cap)
            imgcmp.write_png(os.path.join(out_dir, "diff.png"), w, h, diff)
            stats.update(ok=stats["match_ratio"] >= 0.99, capture=os.path.join(out_dir, "capture.png"),
                         diff=os.path.join(out_dir, "diff.png"))
            result["capture"] = stats
    finally:
        vdp.write(REGS["CONTROL"], [control])
    result["ok"] = result["crc"]["ok"] and result.get("capture", {"ok": True})["ok"]
    return result


def load_fb_image(path):
    """フレームバッファに置く 320x240 の画像 (RGB565 のリスト) と、元の RGB を返す"""
    import fbmodel
    import imgcmp
    if path:
        w, h, rgb = imgcmp.read_png(path)
        if (w, h) != (fbmodel.SRC_W, fbmodel.SRC_H):
            raise HarnessError(f"image must be {fbmodel.SRC_W}x{fbmodel.SRC_H}, got {w}x{h}")
    else:
        rgb = fbmodel.test_image()
    return fbmodel.rgb_to_565(rgb, fbmodel.SRC_W, fbmodel.SRC_H), rgb


def fb_upload(bridge, img565, slot):
    """GPU の UPLOAD コマンド (1 ライン 1 コマンド) で送る。FIFO の空きを見ながら 4KiB ずつ"""
    import gpu_model
    vdp = Vdp(bridge)
    if not vdp.read1(MEM["STATUS"]) & MEM_ST_INIT:
        raise HarnessError("SDRAM not initialized")
    gpu = Gpu(vdp)
    start = time.monotonic()
    bridge.command("freq 8000000")
    try:
        gpu.send(gpu_model.upload_image_words(img565, slot))
        st = gpu.wait_idle()
    finally:
        bridge.command("freq 1000000")
    if st & (GPU_ST_ERROR | GPU_ST_OVERFLOW):
        raise HarnessError(f"GPU status 0x{st:02x} after upload")
    return round(time.monotonic() - start, 2)


def read_crc(vdp):
    """(CRC, そのフレーム番号) を読む。0x05 を読むと残りのバイトとフレーム番号が同じフレームの値で固定される"""
    crc = int.from_bytes(vdp.read(REGS["FRAME_CRC"], 4), "little")
    frame = int.from_bytes(vdp.read(REGS["CRC_FRAME"], 2), "little")
    return crc, frame


def settled_crc(vdp, frames=2, timeout=1.0):
    """今の表示が確定してから frames フレーム後の CRC を読む (SWAP が終わった直後は前の面のフレームの CRC が残っているため)"""
    _, f0 = read_crc(vdp)
    deadline = time.monotonic() + timeout
    while True:
        crc, f = read_crc(vdp)
        if (f - f0) & 0xFFFF >= frames:
            return crc, f
        if time.monotonic() > deadline:
            raise HarnessError("CRC_FRAME does not advance")
        time.sleep(0.005)


def scenario(bridge, path, do_capture, out_dir):
    """シナリオ (scenarios/*.json) を実機で走らせ、check ごとに参照モデル (gpu_model.py) の CRC と比べる"""
    import fbmodel
    import gpu_model
    import imgcmp
    sc = gpu_model.load(path)
    kinds = []
    errors = []                                  # check ごとに、エラーが立つはずか (タイルのリストの溢れなど)
    words, checks = gpu_model.expected(sc, kinds, errors)
    check_steps = [st for st in sc["steps"] if st["op"] in ("check", "check_marked")]
    vdp = Vdp(bridge)
    gpu = Gpu(vdp)
    control = vdp.read1(REGS["CONTROL"])
    results = []
    bridge.command("freq 8000000")
    try:
        # モデルと同じ初期状態にする
        gpu.flush()
        gpu.wait_idle()
        gpu.status()
        vdp.write(REGS["FB_BASE"], gpu_model.FB_BASE_RESET.to_bytes(2, "little"))
        vdp.write(REGS["DRAW_BASE"], gpu_model.DRAW_BASE_RESET.to_bytes(2, "little"))
        # 合成のレジスタ (タイル レイヤのものはホストから直接書けないので REG_WRITE で)
        gpu.send(gpu_model.layer_reset_words())
        gpu.wait_idle()
        vdp.write(REGS["CONTROL"], [control | CONTROL_FB])
        under0 = vdp.read1(REGS["UNDERFLOW"])
        sent = 0
        for i, ((n, img, crc), kind, want_err) in enumerate(zip(checks, kinds, errors)):
            start = time.monotonic()
            marks0 = vdp.read1(REGS["MARK_COUNT"])
            gpu.send(words[sent:n])
            sent = n
            st = gpu.wait_idle()
            if kind == "check_marked":
                # 印を付けたフレームが表示し終わるのを待ち、そのフレームの CRC を読む
                deadline = time.monotonic() + 1.0
                while vdp.read1(REGS["MARK_COUNT"]) == marks0:
                    if time.monotonic() > deadline:
                        raise HarnessError("marked frame did not complete")
                    time.sleep(0.002)
                got = int.from_bytes(vdp.read(REGS["MARK_CRC"], 4), "little")
                frame = None
            else:
                got, frame = settled_crc(vdp)
            r = {"check": i, "kind": kind, "words": n, "expected_crc": f"0x{crc:08x}", "crc": f"0x{got:08x}", "frame": frame,
                 "gpu_status": st, "ok": got == crc and bool(st & GPU_ST_ERROR) == want_err and not st & GPU_ST_OVERFLOW,
                 "seconds": round(time.monotonic() - start, 2)}
            if do_capture and kind == "check":       # 印のフレームは過ぎてしまっているのでキャプチャしない (CRC だけ)
                w, h = 2 * fbmodel.SRC_W, 2 * fbmodel.SRC_H
                expect = fbmodel.expected_output(img)
                cap = imgcmp.capture(w, h)
                stats, diff = imgcmp.compare(expect, cap, w, h)
                os.makedirs(out_dir, exist_ok=True)
                name = f"{sc['name']}_{i}"
                imgcmp.write_png(os.path.join(out_dir, f"{name}_expected.png"), w, h, expect)
                imgcmp.write_png(os.path.join(out_dir, f"{name}_capture.png"), w, h, cap)
                imgcmp.write_png(os.path.join(out_dir, f"{name}_diff.png"), w, h, diff)
                # 正しさは CRC で決める。キャプチャは「画面に出ているか」を見るだけなので 95% で合格にする
                # (グラデーションの色変換の非線形や、細かいスプライトの縁の 4:2:2 のにじみで 99% を少し切ることがある)。
                # 1〜2 ピクセルの縞や市松で埋まった画面は、check の "capture_min" で下げる
                need = check_steps[i].get("capture_min", CAPTURE_OK)
                r["capture"] = {"match_ratio": stats["match_ratio"], "ok": stats["match_ratio"] >= need}
                r["ok"] = r["ok"] and r["capture"]["ok"]
            results.append(r)
        under = (vdp.read1(REGS["UNDERFLOW"]) - under0) & 0xFF
    finally:
        bridge.command("freq 1000000")
        vdp.write(REGS["CONTROL"], [control])
    return {"ok": all(r["ok"] for r in results) and under == 0, "scenario": sc["name"], "underflow": under,
            "checks": results}


def fps(bridge, path, frames):
    """{"setup": [...], "frame": [...]} の frame (SWAP で終わる) を frames 回くり返し、速さを測る。
    SWAP は表示がフレームの先頭で取り込むまで待つので、間に合っていれば 60 フレーム / 秒 (表示 1 フレームに 1 回の SWAP) になる。
    "frame" の代わりに "frames": [[...], [...], ...] なら、フレームごとに順に使う (回る道路など、毎フレーム中身が変わるもの)"""
    import gpu_model
    sc = gpu_model.load(path)
    setup = [w for st in sc["setup"] for w in gpu_model.encode(st)]
    seq = [[w for st in fr for w in gpu_model.encode(st)] for fr in (sc["frames"] if "frames" in sc else [sc["frame"]])]
    vdp = Vdp(bridge)
    gpu = Gpu(vdp)
    control = vdp.read1(REGS["CONTROL"])
    bridge.command("freq 8000000")
    try:
        gpu.flush()
        gpu.wait_idle()
        gpu.status()
        vdp.write(REGS["FB_BASE"], gpu_model.FB_BASE_RESET.to_bytes(2, "little"))
        vdp.write(REGS["DRAW_BASE"], gpu_model.DRAW_BASE_RESET.to_bytes(2, "little"))
        gpu.send(setup)
        gpu.wait_idle(timeout=20)
        vdp.write(REGS["CONTROL"], [control | CONTROL_FB])
        under0 = vdp.read1(REGS["UNDERFLOW"])
        _, f0 = read_crc(vdp)
        start = time.monotonic()
        for k in range(frames):
            gpu.send(seq[k % len(seq)])
        st = gpu.wait_idle(timeout=20)
        elapsed = time.monotonic() - start
        _, f1 = read_crc(vdp)
        under = (vdp.read1(REGS["UNDERFLOW"]) - under0) & 0xFF
    finally:
        bridge.command("freq 1000000")
        vdp.write(REGS["CONTROL"], [control])
    shown = (f1 - f0) & 0xFFFF
    return {"ok": under == 0 and not st & (GPU_ST_ERROR | GPU_ST_OVERFLOW), "scenario": sc["name"], "frames": frames,
            "words_per_frame": max(len(f) for f in seq), "seconds": round(elapsed, 2), "fps": round(frames / elapsed, 1),
            "display_frames_per_drawn_frame": round(shown / frames, 2), "underflow": under, "gpu_status": st}


def mulprobe(bridge, iterations):
    """3D GPU のビットストリームの mul_probe (0x50..: A, B は符号付き 18bit。P = 符号付きの DSP の乗算、Q = 符号なしの DSP + 符号の補正、
    どちらも 36bit) を端の値と乱数で確かめる (docs/GPU3D_PLAN.md の G0)。符号の組み合わせごとに数える"""
    import random
    vdp = Vdp(bridge)
    version = vdp.read1(REGS["VERSION"])
    if not version & 0x80:
        return {"ok": False, "error": f"not a gpu3d bitstream (VERSION 0x{version:02x})"}
    rng = random.Random(1)
    lo, hi = -(1 << 17), (1 << 17) - 1
    pairs = [(0, 0), (1, -1), (hi, hi), (lo, lo), (lo, hi), (hi, -1)]
    pairs += [(rng.randint(lo, hi), rng.randint(lo, hi)) for _ in range(iterations)]

    def s36(v):
        v &= (1 << 36) - 1
        return v - (1 << 36) if v >> 35 else v

    stats = {k: {"n": 0, "p_errors": 0, "q_errors": 0} for k in ("++", "+-", "-+", "--")}
    first = []
    for a, b in pairs:
        vdp.write(0x50, (a & 0x3FFFF).to_bytes(3, "little") + (b & 0x3FFFF).to_bytes(3, "little"))
        raw = int.from_bytes(vdp.read(0x56, 10), "little")
        p, q = s36(raw), s36(raw >> 40)
        st = stats[("-" if a < 0 else "+") + ("-" if b < 0 else "+")]
        st["n"] += 1
        st["p_errors"] += p != a * b
        st["q_errors"] += q != a * b
        if (p != a * b or q != a * b) and len(first) < 3:
            first.append({"a": a, "b": b, "p": p, "q": q, "expected": a * b})
    q_ok = all(v["q_errors"] == 0 for v in stats.values())
    p_ok = all(v["p_errors"] == 0 for v in stats.values())
    return {"ok": q_ok, "signed_dsp_ok": p_ok, "version": f"0x{version:02x}", "checked": len(pairs),
            "by_sign": stats, "first_errors": first}


def demo(bridge, frames, start, scene=None, shot=None):
    """M9 のデモ (demo.py) を流し続ける。フレームは WAIT_VBLANK で区切られるので、間に合っていれば 60 フレーム / 秒。
    scene があれば G5 の 3D の場面 (demo3d.py)。速さはハーネス v1 の SPI (1 秒に約 45,000 ワード) で決まる"""
    import gpu_model
    if scene:
        import demo3d

        class demo_mod:
            setup_words = staticmethod(lambda: demo3d.setup_words(scene))
            frame_words = staticmethod(lambda k: demo3d.frame_words(scene, k))
    else:
        import demo as demo_mod
    vdp = Vdp(bridge)
    gpu = Gpu(vdp)
    control = vdp.read1(REGS["CONTROL"])
    bridge.command("freq 8000000")
    k = start
    words = 0
    try:
        gpu.flush()
        gpu.wait_idle()
        gpu.status()
        vdp.write(REGS["FB_BASE"], gpu_model.FB_BASE_RESET.to_bytes(2, "little"))
        vdp.write(REGS["DRAW_BASE"], gpu_model.DRAW_BASE_RESET.to_bytes(2, "little"))
        gpu.send(gpu_model.layer_reset_words() + demo_mod.setup_words())
        gpu.wait_idle(timeout=20)
        vdp.write(REGS["CONTROL"], [control | CONTROL_FB])
        under0 = vdp.read1(REGS["UNDERFLOW"])
        f0 = vdp.read1(REGS["FRAME_COUNT"])
        shown, last = 0, f0
        t0 = time.monotonic()
        try:
            while frames == 0 or k < start + frames:
                w = demo_mod.frame_words(k)
                gpu.send(w)
                words += len(w)
                k += 1
                f = vdp.read1(REGS["FRAME_COUNT"])      # 8bit で回るので、こまめに足す
                shown += (f - last) & 0xFF
                last = f
        except KeyboardInterrupt:
            pass
        st = gpu.wait_idle(timeout=20)
        elapsed = time.monotonic() - t0
        f = vdp.read1(REGS["FRAME_COUNT"])
        shown += (f - last) & 0xFF
        under = (vdp.read1(REGS["UNDERFLOW"]) - under0) & 0xFF
        if shot:
            import fbmodel
            import imgcmp
            w, h = 2 * fbmodel.SRC_W, 2 * fbmodel.SRC_H
            imgcmp.write_png(shot, w, h, imgcmp.capture(w, h))
    finally:
        bridge.command("freq 1000000")
    drawn = k - start
    # M9 のデモは 60fps で間に合うこと (表示フレーム ≒ 描画フレーム) まで見る。3D の場面はリンクで遅くなるので見ない
    r = {"ok": under == 0 and not st & (GPU_ST_ERROR | GPU_ST_OVERFLOW) and drawn > 0 and (bool(scene) or shown <= drawn + 2),
         "frames": drawn, "words_per_frame": round(words / max(drawn, 1)), "seconds": round(elapsed, 2),
         "fps": round(drawn / elapsed, 1), "display_frames_per_drawn_frame": round(shown / max(drawn, 1), 2),
         "underflow": under, "gpu_status": st}
    if scene:
        r["scene"] = scene
    if shot:
        r["shot"] = shot
    return r


AUDIO = {"PCM_RD": 0x50, "UNDERRUN": 0x52}     # audio_out.sv (読み出しだけ)


def audio(bridge, seconds, tone, stream=False, ring_log2=11, target=1600):
    """K5a: 正弦波 (tone Hz、左右同じ) を SDRAM の PCM のリングに流し続け、アンダーランが 0 で、再生がちょうど 48kHz で進むことを確かめる。
    ホストは PCM_RD を読み、先回りが target 標本より少なくなったら PCM_WR を進める。
      stream=True: 足す分を毎回 UPLOAD してから REG_WRITE PCM_WR (FIFO の順なので UPLOAD のあとに効く)。48kHz x 4 バイト = 192KB/s 要るが、
                   ハーネス v1 (USB → RP2040 → SPI) は 180KB/s ほどしか通らないので途切れる (本番の RP2350 は SPI / HSTX を直接駆動する)
      stream=False (既定): 周期がリングの大きさを割り切る音 (例: 750Hz = 64 標本) をリングに 1 回だけ書き、あとは PCM_WR を進めるだけ。
                   ホストの数え方 (PCM_RD / PCM_WR) と再生の速さ・途切れを、リンクの速さに関係なく長時間確かめる"""
    import math
    import gpu_model as g
    vdp = Vdp(bridge)
    gpu = Gpu(vdp)
    base = g.LAYER_RESET["pcm_base"] * 256           # 既定の場所 (SDRAM の最後の 32KiB)
    mask = (1 << ring_log2) - 1

    def reg(name, v):
        return g.OP_REG_WRITE << 24 | g.LAYER_REGS[name] << 16 | (v & g.LAYER_MASK[name])

    def sample(k):
        v = int(round(8000 * math.sin(2 * math.pi * tone * k / 48000))) & 0xFFFF
        return v << 16 | v

    if not stream and (48000 / tone) % 1 or not stream and (mask + 1) % round(48000 / tone):
        raise HarnessError(f"--tone {tone}: the period must divide the {mask + 1}-sample ring (e.g. 750, 1500) unless --stream")

    def put(wr, n):
        """標本 wr .. wr + n - 1 をリングへ (折り返すところで 2 つに分ける) し、PCM_WR を wr + n に。
        stream でなければリングはもう正しいので PCM_WR だけ"""
        if not stream:
            gpu.send([reg("pcm_wr", (wr + n) & 0xFFFF)])
            return
        out, k = [], wr
        while k < wr + n:
            m = min(wr + n - k, mask + 1 - (k & mask))
            out += [g.OP_UPLOAD << 24 | m, base + (k & mask)] + [sample(j) for j in range(k, k + m)]
            k += m
        gpu.send(out + [reg("pcm_wr", (wr + n) & 0xFFFF)])

    def rd():
        return int.from_bytes(vdp.read(AUDIO["PCM_RD"], 2), "little")

    bridge.command("freq 8000000")
    try:
        gpu.flush()
        gpu.wait_idle()
        gpu.send([reg("audio_ctrl", 2), reg("pcm_base", base >> 8), reg("pcm_size", ring_log2), reg("pcm_wr", 0)])
        wr = 0
        if not stream:
            gpu.send([g.OP_UPLOAD << 24 | (mask + 1), base] + [sample(j) for j in range(mask + 1)])
        put(wr, target)
        wr += target
        gpu.send([reg("audio_ctrl", 1)])
        gpu.wait_idle()
        t0 = time.monotonic()
        r0 = last = rd()
        played, min_fill, sends = 0, target, 0
        bad_reads, max_gap, t_last = 0, 0.0, time.monotonic()
        while time.monotonic() - t0 < seconds:
            r = rd()
            now = time.monotonic()
            max_gap = max(max_gap, now - t_last)       # ホストが PCM_RD を読む間隔の最大 (先回り target / 48kHz より長いと途切れる)
            t_last = now
            step = (r - last) & 0xFFFF
            if step > 4096:              # 前の読みから数ミリ秒で 4096 標本 (85ms 分) は進まない: 読み違い。数えずに読み直す
                bad_reads += 1
                continue
            played += step
            last = r
            fill = (wr - (r0 + played)) & 0xFFFF
            min_fill = min(min_fill, fill)
            if fill < target:
                n = target - fill
                put(wr, n)
                wr += n
                sends += 1
            else:
                time.sleep(0.002)
        elapsed = time.monotonic() - t0
        under = vdp.read1(AUDIO["UNDERRUN"])
        gpu.send([reg("audio_ctrl", 0)])
        st = gpu.wait_idle()
    finally:
        bridge.command("freq 1000000")
    rate = played / elapsed
    return {"ok": under == 0 and min_fill > 0 and bad_reads == 0 and abs(rate - 48000) < 48 and not st & (GPU_ST_ERROR | GPU_ST_OVERFLOW),
            "seconds": round(elapsed, 1), "samples": played, "rate_hz": round(rate, 1), "underrun": under,
            "min_fill": min_fill, "target_fill": target, "ring": mask + 1, "max_host_gap_ms": round(max_gap * 1000, 1),
            "refills": sends, "bad_reads": bad_reads, "stream": stream, "tone_hz": tone, "gpu_status": st}


def fb_show(vdp, slot, on):
    vdp.write(REGS["FB_BASE"], slot.to_bytes(2, "little"))
    control = vdp.read1(REGS["CONTROL"])
    vdp.write(REGS["CONTROL"], [(control | CONTROL_FB) if on else (control & ~CONTROL_FB)])


def fbtest(bridge, png, slot, keep, do_capture, out_dir):
    """アップロード -> 表示 -> FRAME_CRC / UNDERFLOW / キャプチャを参照モデルと比べる"""
    import fbmodel
    import gpu_model
    import imgcmp
    vdp = Vdp(bridge)
    img565, _ = load_fb_image(png)
    expect = fbmodel.expected_output(img565)
    expect_crc = f"0x{fbmodel.expected_crc(img565):08x}"
    result = {"image": png or "test_image", "slot": slot, "expected_crc": expect_crc}

    control = vdp.read1(REGS["CONTROL"])
    # 前のシナリオが残したタイル レイヤや BITMAP_RANK を既定に戻す
    gpu = Gpu(vdp)
    gpu.send(gpu_model.layer_reset_words())
    gpu.wait_idle()
    result["upload_seconds"] = fb_upload(bridge, img565, slot)
    under0 = vdp.read1(REGS["UNDERFLOW"])
    try:
        fb_show(vdp, slot, True)
        time.sleep(0.1)
        crcs = []
        for _ in range(3):
            crcs.append(f"0x{vdp.read32(REGS['FRAME_CRC']):08x}")
            time.sleep(0.05)
        result["crc"] = {"ok": all(c == expect_crc for c in crcs), "read": crcs}
        if do_capture:
            w, h = 2 * fbmodel.SRC_W, 2 * fbmodel.SRC_H
            cap = imgcmp.capture(w, h)
            stats, diff = imgcmp.compare(expect, cap, w, h)
            os.makedirs(out_dir, exist_ok=True)
            imgcmp.write_png(os.path.join(out_dir, "fb_expected.png"), w, h, expect)
            imgcmp.write_png(os.path.join(out_dir, "fb_capture.png"), w, h, cap)
            imgcmp.write_png(os.path.join(out_dir, "fb_diff.png"), w, h, diff)
            stats.update(ok=stats["match_ratio"] >= 0.99, capture=os.path.join(out_dir, "fb_capture.png"),
                         diff=os.path.join(out_dir, "fb_diff.png"))
            result["capture"] = stats
        under = (vdp.read1(REGS["UNDERFLOW"]) - under0) & 0xFF
        result["underflow"] = {"ok": under == 0, "count": under}
    finally:
        if not keep:
            vdp.write(REGS["CONTROL"], [control])
    result["ok"] = (result["crc"]["ok"] and result["underflow"]["ok"]
                    and result.get("capture", {"ok": True})["ok"])
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port")
    ap.add_argument("--iterations", type=int, default=1000, help="selftest: SCRATCH round trips per SPI speed")
    ap.add_argument("--size", type=int, default=21, help="memtest: log2 of the number of words (1..21)")
    ap.add_argument("--samples", default="2,3,4,5,6,7", help="memtest: rd_sample values to try")
    ap.add_argument("--seed", type=int, default=0x3C, help="memtest: pattern seed (0..255)")
    ap.add_argument("--phases", help="memtest: SDRAM clock phases to sweep, e.g. 0-15")
    ap.add_argument("--ref-dir", default=os.path.join(REPO, "build", "render_frozen"),
                    help="frametest: reference from make render FREEZE=1")
    ap.add_argument("--no-capture", action="store_true", help="frametest / fbtest: CRC only")
    ap.add_argument("--slot", type=int, default=0, help="fb / fbtest: framebuffer base in 1KiB units")
    ap.add_argument("--frames", type=int, default=120, help="fps / demo: number of frames (demo: 0 = until Ctrl-C)")
    ap.add_argument("--start", type=int, default=0, help="demo: first frame number")
    ap.add_argument("--shot", help="demo: save an HDMI capture of the last frame to this PNG")
    ap.add_argument("--keep", action="store_true", help="fbtest: leave the framebuffer displayed")
    ap.add_argument("--seconds", type=float, default=10.0, help="audio: how long to play")
    ap.add_argument("--tone", type=float, default=750.0, help="audio: sine frequency in Hz (without --stream its period must divide 2048)")
    ap.add_argument("--ring", type=int, default=11, help="audio: log2 of the ring size in samples")
    ap.add_argument("--lead", type=int, default=1600, help="audio: samples to keep queued ahead of playback")
    ap.add_argument("--stream", action="store_true", help="audio: upload every refill (needs 192KB/s; harness v1 manages about 180)")
    ap.add_argument("--out", default=os.path.join(REPO, "build", "hw"), help="frametest: where to save capture/diff")
    ap.add_argument("command")
    ap.add_argument("args", nargs="*")
    a = ap.parse_args()

    if a.command == "prog":
        if len(a.args) != 1:
            ap.error("prog <target>")
        # make の出力は標準エラーへ (標準出力は JSON だけにする)
        r = subprocess.run(["make", "prog", f"TARGET={a.args[0]}"], cwd=REPO, stdout=sys.stderr)
        result = {"ok": r.returncode == 0, "target": a.args[0]}
    elif a.command in ("reg", "selftest", "memtest", "mem", "frametest", "fb", "fbtest", "scenario", "fps", "demo", "audio",
                       "mulprobe"):
        bridge = Bridge(find_port(a.port))
        try:
            vdp = Vdp(bridge)
            if a.command == "selftest":
                result = selftest(bridge, a.iterations)
            elif a.command == "fps":
                if len(a.args) != 1:
                    ap.error("fps <scenarios/*.json> [--frames N]")
                result = fps(bridge, a.args[0], a.frames)
            elif a.command == "demo":
                result = demo(bridge, a.frames, a.start, a.args[0] if a.args else None, a.shot)
            elif a.command == "mulprobe":
                result = mulprobe(bridge, a.iterations)
            elif a.command == "audio":
                result = audio(bridge, a.seconds, a.tone, a.stream, a.ring, a.lead)
            elif a.command == "scenario":
                if len(a.args) != 1:
                    ap.error("scenario <scenarios/*.json>")
                result = scenario(bridge, a.args[0], not a.no_capture, a.out)
            elif a.command == "fbtest":
                result = fbtest(bridge, a.args[0] if a.args else None, a.slot, a.keep, not a.no_capture, a.out)
            elif a.command == "fb" and a.args and a.args[0] == "upload":
                img565, _ = load_fb_image(a.args[1] if len(a.args) > 1 else None)
                result = {"ok": True, "slot": a.slot, "seconds": fb_upload(bridge, img565, a.slot)}
            elif a.command == "fb" and a.args and a.args[0] in ("show", "off"):
                fb_show(vdp, a.slot, a.args[0] == "show")
                result = {"ok": True, "slot": a.slot, "display": a.args[0]}
            elif a.command == "fb":
                ap.error("fb upload [<png>] | fb show | fb off")
            elif a.command == "frametest":
                result = frametest(bridge, a.ref_dir, not a.no_capture, a.out)
            elif a.command == "memtest":
                samples = [int(x) for x in a.samples.split(",")]
                phases = None
                if a.phases:
                    lo, _, hi = a.phases.partition("-")
                    phases = list(range(int(lo), int(hi or lo) + 1))
                result = memtest(bridge, a.size, samples, a.seed, phases)
            elif a.command == "mem" and len(a.args) >= 2 and a.args[0] == "read":
                vdp.write32(MEM["ADDR"], int(a.args[1], 0))
                words = []
                for _ in range(int(a.args[2]) if len(a.args) > 2 else 1):
                    vdp.write(MEM["CMD"], [MEM_CMD_READ])
                    vdp.mem_wait(timeout=1.0)
                    words.append(f"{vdp.read32(MEM['DATA']):08x}")
                result = {"ok": True, "addr": a.args[1], "words": words}
            elif a.command == "mem" and len(a.args) >= 3 and a.args[0] == "write":
                vdp.write32(MEM["ADDR"], int(a.args[1], 0))
                for w in a.args[2:]:
                    vdp.write32(MEM["DATA"], int(w, 16))
                    vdp.write(MEM["CMD"], [MEM_CMD_WRITE])
                    vdp.mem_wait(timeout=1.0)
                result = {"ok": True, "addr": a.args[1], "words": len(a.args) - 2}
            elif a.command == "mem":
                ap.error("mem read <word_addr> [n] | mem write <word_addr> <hex32>...")
            elif len(a.args) >= 2 and a.args[0] == "read":
                addr = parse_reg(a.args[1])
                n = int(a.args[2]) if len(a.args) > 2 else 1
                result = {"ok": True, "addr": f"0x{addr:02x}", "data": Vdp(bridge).read(addr, n).hex()}
            elif len(a.args) == 3 and a.args[0] == "write":
                addr = parse_reg(a.args[1])
                Vdp(bridge).write(addr, bytes.fromhex(a.args[2]))
                result = {"ok": True, "addr": f"0x{addr:02x}"}
            else:
                ap.error("reg read <reg> [n] | reg write <reg> <hex>")
        except HarnessError as e:
            result = {"ok": False, "error": str(e)}
        finally:
            bridge.close()
    else:
        simple = {"ping", "status", "wiretest", "bootsel", "spi", "freq", "reset", "irqwait"}   # spib はホストツール内部で使う
        if a.command == "raw":
            line = " ".join(a.args)
        elif a.command in simple:
            line = " ".join([a.command] + a.args)
        else:
            ap.error(f"unknown command {a.command!r}")
        # 時間のかかるコマンドは待ち時間を延ばす
        ms = int(a.args[0]) if a.command in ("reset", "irqwait") and a.args else 0
        bridge = Bridge(find_port(a.port))
        try:
            result = bridge.command(line, timeout=5.0 + ms / 1000)
        finally:
            bridge.close()

    print(json.dumps(result))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
