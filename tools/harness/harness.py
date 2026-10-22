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
    "SCRATCH": 0x7D,
    "ID": 0x7E,
    "VERSION": 0x7F,
}
VDP_ID = 0x5A
SYNC_BYTE = 0xA5            # spi_slave が 1 バイト目に返す値
CONTROL_IRQ_EN = 0x04
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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port")
    ap.add_argument("--iterations", type=int, default=1000, help="selftest: SCRATCH round trips per SPI speed")
    ap.add_argument("command")
    ap.add_argument("args", nargs="*")
    a = ap.parse_args()

    if a.command == "prog":
        if len(a.args) != 1:
            ap.error("prog <target>")
        # make の出力は標準エラーへ (標準出力は JSON だけにする)
        r = subprocess.run(["make", "prog", f"TARGET={a.args[0]}"], cwd=REPO, stdout=sys.stderr)
        result = {"ok": r.returncode == 0, "target": a.args[0]}
    elif a.command in ("reg", "selftest"):
        bridge = Bridge(find_port(a.port))
        try:
            if a.command == "selftest":
                result = selftest(bridge, a.iterations)
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
