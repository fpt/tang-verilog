# ハーネス v2: Pico 2 (Pico ピン配置) ⇔ Tang Nano 20K

本番のホストリンク (HSTX 4 データ + CLK) をそのまま載せたハーネス。戻りは v1 と同じ SPI と IRQ/READY、VSYNC、HEARTBEAT、RESET。
M9 までのハーネスで使わなかった線 (ERROR、LED0〜5、OLED) は省いた。
**40 ピン RGB LCD、I2S (MAX98357A)、HDMI のピンは使わない**ので、ハーネスのまま LCD と音を出せる。

- ホスト: **Raspberry Pi Pico 2** (RP2350A、PSRAM なし。リンクと翻訳層の検証には足りる)。同じ Pico ピン配置の **Pico Plus 2** (RP2350B、PSRAM 8MB、CS = GPIO 47) と
  **Pico LiPo 2** (同) にもそのまま載る。RP2350-PiZero は入手できなくなったので使わない
- 回路図: [`harness/kicad/v2/rp-tang-harness-v2.kicad_sch`](../harness/kicad/v2/rp-tang-harness-v2.kicad_sch) (基板は同じ場所の `rp-tang-harness-v2.kicad_pcb`)
- 配線表: [`harness/kicad/v2/pins_v2.json`](../harness/kicad/v2/pins_v2.json) (v1 と同じ形式。信号名も v1 に合わせてあるので `gen_pins_h.py` がそのまま使える)

## 1. 配線表 (13 本 + GND)

| 信号 | 向き | RP2350 GPIO | Pico 物理ピン | FPGA ピン | FPGA 側の共有 | 備考 |
|---|---|---|---|---|---|---|
| HSTX_D0 | P → F | GP12 (HSTX bit0) | 16 | 71 | なし | 直列 33R (R4) |
| HSTX_D1 | P → F | GP13 (bit1) | 17 | 72 | なし | 直列 33R (R5) |
| HSTX_D2 | P → F | GP14 (bit2) | 19 | 73 | なし | 直列 33R (R6) |
| HSTX_D3 | P → F | GP15 (bit3) | 20 | 74 | なし | 直列 33R (R7) |
| HSTX_CLK | P → F | GP16 (bit4) | 21 | 80 (GCLKT_0) | SD D2、10k プルアップ | 直列 33R (R8) |
| SCK | P → F | GP10 (SPI1 SCK) | 14 | 20 | LED5 | |
| COPI | P → F | GP11 (SPI1 TX) | 15 | 19 | LED4 | |
| CIPO | F → P | GP8 (SPI1 RX) | 11 | 75 | BL616 MISO | v1 で実績 |
| CS | P → F | GP9 | 12 | 86 | BL616 SPI_DIR | v1 で実績。正論理、4.7k プルダウン (R9) |
| IRQ (/READY) | F → P | GP20 | 26 | 85 | SD D1、10k プルアップ | v1 と同じ意味 (CONTROL bit4 で READY)。未コンフィグ時 High |
| VSYNC | F → P | GP22 | 29 | 16 | LED1 / LCD YD (LCD_INIT1) | JP1 (既定 閉) |
| HEARTBEAT | F → P | GP7 | 10 | 15 | LED0 / LCD XR (LCD_INIT0) | JP2 (既定 閉) |
| RESET | P → F | GP21 | 27 | 79 | WS2812 DIN | 4.7k プルダウン (R10) |
| GND | | | 3, 8, 13, 18, 23, 28, 33, 38 | GND | | 隣り合う GND を HSTX の線の間に |

**HSTX のビット割り当て**: bit0..3 = D0..D3 (GP12〜15、ピン 16/17/19/20、間の 18 が GND)、bit4 = CLK (GP16、ピン 21)。
Pico ピン配置では HSTX の 8 本が 16〜25 に連続して並ぶので、5 本がまとまる。GP17〜19 (ピン 22/24/25) は bit5..7 で、レーンを増やすときの予備。配線しない。

### 1.1 選んだ理由

- **FPGA 側**: LCD を使うとヘッダに出ているクロック入力は 80 (GCLKT_0) しか残らない。他の部品がつながっていないヘッダピンは 71〜74 の 4 本だけ。
  残りは共有先が無害なもの (19/20 の LED、85 の SD プルアップ、79 の WS2812) と v1 で実績のある 75/86。
  棚卸しの詳細は Tang Nano 20K 回路図 Rev 1.3 のヘッダ J5/J6
- **RP2350 側**: HSTX は GPIO 12〜19 固定。SPI1 は GPIO 8〜11 にまとめた。GP4/5 (Qw/ST の I2C になるボードがある) と GP0/1 (UART) は空けてある
- **正論理のまま** (v1 と同じ)。CS と RESET に外付け 4.7k プルダウン (RP2350-E9: 入力のピンが内蔵プルダウンで約 2V に留まる不具合。外付けは 8.2k 以下が要る)
- **IRQ と READY は 1 本** (v1 と同じく CONTROL bit4 で切り替え)。HSTX は片方向なので VBLANK のタイミングは VSYNC の線で取る
- **VSYNC / HEARTBEAT は LCD_INIT0/1 と共有**。ST7701 系のパネル (SPI 初期化にこの線を使う) のときだけ JP1/JP2 を開ける。HEARTBEAT は ready の判定に使っているので、
  開けたときは ready の判定を SPI の ID レジスタのポーリングに置き換える

## 2. 電気的な注意

- 全部 3.3V。レベル変換なし
- HSTX の 5 本は RP2350 側に直列 33R (R4〜R8)。最初 33R、波形を見て 0〜47R。15cm 程度のリボンまでなら 37.5MHz DDR で問題ない見込み。
  各 HSTX 線の隣に GND を 1 本置く (Pico の GND はピン 18 が D1 (17) と D2 (19) の間、23 が CLK (21) の 2 つ隣。間の 22 は予備の GP17)。75MHz DDR に上げるときは基板化する
- 85 と 80 の 10k プルアップ、19/20 の LED は RP2350 の出力でそのまま駆動できる
- 電源: **GND だけ共通にして USB を 2 本**挿す。5V の線はない (Pico の VBUS と Tang の 5V はどちらもつながない)。3V3 同士もつながない
- PSRAM: Pico 2 にはない (リンクと翻訳層の検証には不要)。Pico Plus 2 / Pico LiPo 2 では CS = GPIO 47、SDK の `psram` 初期化に 47 を渡す

## 3. FPGA 側

- 80 (GCLKT_0) を `IBUF` → グローバルクロック、71〜74 を `IDDR` で受けて 8bit/クロック。非同期 FIFO (BSRAM) で `clk_sys` へ
- パケット: マジック 32bit + 長さ + ペイロード + CRC16。ニブル単位でマジックを探して同期、CRC 不一致は捨ててカウンタを上げる
- SPI (86/20/19/75) と IRQ (85)、VSYNC (16)、HEARTBEAT (15)、RESET (79) は v1 と同じモジュールのままピンだけ変える。SPI と HSTX は同じパケット解析器 → コマンド FIFO に入れる
- `.cst`:

```
IO_LOC "hstx_clk"  80; IO_PORT "hstx_clk"  IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC "hstx_d[0]" 71; IO_PORT "hstx_d[0]" IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC "hstx_d[1]" 72; IO_PORT "hstx_d[1]" IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC "hstx_d[2]" 73; IO_PORT "hstx_d[2]" IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC "hstx_d[3]" 74; IO_PORT "hstx_d[3]" IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC "spi_sck"   20; IO_PORT "spi_sck"   IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC "spi_copi"  19; IO_PORT "spi_copi"  IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC "spi_cipo"  75; IO_PORT "spi_cipo"  IO_TYPE=LVCMOS33 DRIVE=8;
IO_LOC "spi_cs"    86; IO_PORT "spi_cs"    IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC "irq"       85; IO_PORT "irq"       IO_TYPE=LVCMOS33 DRIVE=8;
IO_LOC "vsync_out" 16; IO_PORT "vsync_out" IO_TYPE=LVCMOS33 DRIVE=8;
IO_LOC "heartbeat" 15; IO_PORT "heartbeat" IO_TYPE=LVCMOS33 DRIVE=8;
IO_LOC "reset_in"  79; IO_PORT "reset_in"  IO_TYPE=LVCMOS33 PULL_MODE=NONE;
```

## 4. v1 からの変更

| | v1 (RP2040-Zero) | v2 (Pico 2) |
|---|---|---|
| 本線 | SPI 8MHz | HSTX 4 + CLK (37.5MHz DDR、37MB/s)。SPI はレジスタの読み書きに残る |
| SPI の GPIO | SPI0 GP2〜5 | SPI1 GPIO 8〜11 (`pins.h` の番号と SPI インスタンスだけ) |
| 戻り線 | IRQ, VSYNC, HEARTBEAT, ERROR, LED0〜5 | IRQ, VSYNC, HEARTBEAT (ERROR と LED は廃止。`wiretest` の表から外す) |
| LCD との衝突 | 41, 42, 48 (VSYNC/HEARTBEAT/ERROR) | なし |
| OLED | I2C | 廃止 |
| 電源 | 別々の USB | 別々の USB (5V の線はない) |

## 5. 完成形に向けて (ホストのモジュールの選択)

同じ Pico ピン配置で、ハーネス v2 の配線のまま載せ替えられるものと、ベースボードを起こすときの選択肢。

| | GPIO | PSRAM | 固定の方法 | 向き |
|---|---|---|---|---|
| Pico 2 | 0〜22, 26〜28 | なし | ピンヘッダ / ソケット | ハーネス (今) |
| Pico Plus 2 | 同上 (+ 30〜47 は小さいコネクタ) | 8MB (CS 47) | ピンヘッダ / ソケット、キャステレーションをハンダ | ハーネス v2 の配線のままの最短の完成形 |
| Pico LiPo 2 | 同上 | 8MB (CS 47) | キャステレーションをベースボードに直接ハンダ (クリップは仮止め向き) | 電池を使うとき |
| PGA2350 | 0〜47 全部 (7x7 の PGA) | 8MB (CS 47) | 2.54mm のソケット (丸ピン) | 取り外せる完成形。USB-C、BOOTSEL / RESET のボタンをベースボードに持つ |

ベースボードを起こすなら PGA2350 を勧める。40 ピン FPC (LCD)、バックライトの昇圧、Tang Nano 20K のソケット、HSTX 5 本 + SPI 4 本 + 戻り 4 本、
に USB-C とボタン 2 つが増えるだけで、48 本の GPIO が全部使える (HSTX 8 レーン、音、ボタン、SD)。
ハーネス v2 の配線表 (GPIO 番号) はそのまま使えるので、ファームウェアは変わらない。
