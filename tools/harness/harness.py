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

出力は 1 つの JSON (標準出力)。"ok" が true でなければ終了コード 1。
ポートは --port、環境変数 HARNESS_PORT、/dev/cu.usbmodem* / /dev/ttyACM* の順で探す。
"""
import argparse
import glob
import json
import os
import select
import subprocess
import sys
import termios
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port")
    ap.add_argument("command")
    ap.add_argument("args", nargs="*")
    a = ap.parse_args()

    if a.command == "prog":
        if len(a.args) != 1:
            ap.error("prog <target>")
        # make の出力は標準エラーへ (標準出力は JSON だけにする)
        r = subprocess.run(["make", "prog", f"TARGET={a.args[0]}"], cwd=REPO, stdout=sys.stderr)
        result = {"ok": r.returncode == 0, "target": a.args[0]}
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
