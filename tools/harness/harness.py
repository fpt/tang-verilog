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
  memtest [--size N] [--samples 2,3,..] [--seed S]
                            SDRAM の BIST を読み出しの取り込み位置ごとに実行 (size はワード数の log2、既定 21 = 8MiB)
  frametest [--ref-dir DIR] [--no-capture] [--out DIR]
                            アニメーションを止め、FRAME_CRC を参照 (make render FREEZE=1 の frames.json) と比べ、
                            HDMI キャプチャも参照画像と比べる。キャプチャと差分画像を --out に保存
  fb upload [<png>] [--slot N]  320x240 の画像 (省略時はテスト画像) を SDRAM のフレームバッファへ (slot は 1KiB 単位)
  fb show [--slot N] / fb off   フレームバッファの表示 / テストパターンに戻す
  fbtest [<png>] [--slot N] [--keep] [--no-capture]
                            アップロードして表示し、FRAME_CRC と UNDERFLOW を参照モデル (fbmodel.py) と比べ、
                            HDMI キャプチャも比べる。--keep でそのまま表示を残す
  mem read <word_addr> [n]  SDRAM を 1 ワードずつ読む
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
    "FB_BASE": 0x0A,        # 13bit、256 ワード (1KiB) 単位 (0x0A..0x0B)
    "SCRATCH": 0x7D,
    "ID": 0x7E,
    "VERSION": 0x7F,
}
# rtl/vdp/mem_test.sv (SDRAM のテスト)
MEM = {
    "CMD": 0x10, "CFG": 0x11, "STATUS": 0x12, "SIZE": 0x13, "SEED": 0x14,
    "ERRORS": 0x18, "FAIL_ADDR": 0x1C, "FAIL_EXP": 0x20, "FAIL_GOT": 0x24, "ADDR": 0x28, "DATA": 0x2C,
    "PORT": 0x30,
}
MEM_ST_PORT_OVERFLOW = 0x10
MEM_CMD_BIST, MEM_CMD_READ, MEM_CMD_WRITE = 1, 2, 3
MEM_ST_INIT, MEM_ST_BUSY, MEM_ST_DONE, MEM_ST_PASS = 0x01, 0x02, 0x04, 0x08
REGS.update({f"MEM_{k}": v for k, v in MEM.items()})
VDP_ID = 0x5A
SYNC_BYTE = 0xA5            # spi_slave が 1 バイト目に返す値
CONTROL_FREEZE = 0x02
CONTROL_IRQ_EN = 0x04
CONTROL_FB = 0x08
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

    def close(self):
        os.close(self.fd)

    def command(self, line, timeout=5.0):
        data = (line + "\n").encode()
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
        self._spi([addr & 0x7F] + list(data))

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


def memtest(bridge, size, samples, seed):
    """SDRAM の BIST を取り込み位置 (rd_sample) ごとに実行する"""
    vdp = Vdp(bridge)
    st = vdp.read1(MEM["STATUS"])
    if not st & MEM_ST_INIT:
        return {"ok": False, "error": "SDRAM not initialized", "status": st}
    runs = []
    cfg = vdp.read1(MEM["CFG"])     # 終わったら元の取り込み位置に戻す (表示も同じ設定を使うので)
    for h in samples:
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
        runs.append(run)
    vdp.write(MEM["CFG"], [cfg])
    passing = [r["rd_sample"] for r in runs if r["pass"]]
    return {"ok": bool(passing), "words": 1 << size, "passing_rd_sample": passing, "runs": runs}


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
    """1 ライン 1 トランザクション: 0x28 (MEM_ADDR) から書き始め、MEM_DATA を飛ばして 0x30 (ポート) に 640 バイト流す"""
    import fbmodel
    vdp = Vdp(bridge)
    if not vdp.read1(MEM["STATUS"]) & MEM_ST_INIT:
        raise HarnessError("SDRAM not initialized")
    start = time.monotonic()
    # 8MHz で流す (ポートは 1 ワード 4us に間に合うように作ってある。あふれたら MEM_STATUS bit4 でわかる)
    bridge.command("freq 8000000")
    try:
        for y in range(fbmodel.SRC_H):
            word_addr = (slot + y) * fbmodel.WORDS_PER_LINE
            vdp.write(MEM["ADDR"], word_addr.to_bytes(4, "little") + bytes(4) + fbmodel.line_bytes(img565, y))
    finally:
        bridge.command("freq 1000000")
    st = vdp.mem_wait(timeout=2.0)
    if st & MEM_ST_PORT_OVERFLOW:
        raise HarnessError("upload overflow (MEM_STATUS bit4)")
    return round(time.monotonic() - start, 2)


def fb_show(vdp, slot, on):
    vdp.write(REGS["FB_BASE"], slot.to_bytes(2, "little"))
    control = vdp.read1(REGS["CONTROL"])
    vdp.write(REGS["CONTROL"], [(control | CONTROL_FB) if on else (control & ~CONTROL_FB)])


def fbtest(bridge, png, slot, keep, do_capture, out_dir):
    """アップロード -> 表示 -> FRAME_CRC / UNDERFLOW / キャプチャを参照モデルと比べる"""
    import fbmodel
    import imgcmp
    vdp = Vdp(bridge)
    img565, _ = load_fb_image(png)
    expect = fbmodel.expected_output(img565)
    expect_crc = f"0x{fbmodel.expected_crc(img565):08x}"
    result = {"image": png or "test_image", "slot": slot, "expected_crc": expect_crc}

    control = vdp.read1(REGS["CONTROL"])
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
    ap.add_argument("--ref-dir", default=os.path.join(REPO, "build", "render_frozen"),
                    help="frametest: reference from make render FREEZE=1")
    ap.add_argument("--no-capture", action="store_true", help="frametest / fbtest: CRC only")
    ap.add_argument("--slot", type=int, default=0, help="fb / fbtest: framebuffer base in 1KiB units")
    ap.add_argument("--keep", action="store_true", help="fbtest: leave the framebuffer displayed")
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
    elif a.command in ("reg", "selftest", "memtest", "mem", "frametest", "fb", "fbtest"):
        bridge = Bridge(find_port(a.port))
        try:
            vdp = Vdp(bridge)
            if a.command == "selftest":
                result = selftest(bridge, a.iterations)
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
                result = memtest(bridge, a.size, samples, a.seed)
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
        simple = {"ping", "status", "wiretest", "bootsel", "spi", "freq", "reset", "irqwait"}
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
