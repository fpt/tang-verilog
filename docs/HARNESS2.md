# ハーネス v2: RP2350-PiZero (+PSRAM) ⇔ Tang Nano 20K

本番のホストリンク (HSTX 4 データ + CLK) をそのまま載せたハーネス。戻りは v1 と同じ SPI と IRQ/READY、VSYNC、HEARTBEAT、RESET。
M9 までのハーネスで使わなかった線 (ERROR、LED0〜5、OLED) は省いた。
**40 ピン RGB LCD、I2S (MAX98357A)、HDMI のピンは使わない**ので、ハーネスのまま LCD と音を出せる。

- ホスト: Waveshare RP2350-PiZero (RP2350B、Pi 互換 40 ピンヘッダ、BCM 番号 = GPIO 番号)。PSRAM は APS6404L-3SQR-ZR を自分で実装、CS は GPIO 47
- 回路図: [`harness/kicad/v2/rp2350-pizero-tang-harness.kicad_sch`](../harness/kicad/v2/rp2350-pizero-tang-harness.kicad_sch)
- 配線表: [`harness/kicad/v2/pins_v2.json`](../harness/kicad/v2/pins_v2.json) (v1 と同じ形式。信号名も v1 に合わせてあるので `gen_pins_h.py` がそのまま使える)

## 1. 配線表 (13 本 + GND)

| 信号 | 向き | RP2350 GPIO | ヘッダ物理ピン | FPGA ピン | FPGA 側の共有 | 備考 |
|---|---|---|---|---|---|---|
| HSTX_D0 | P → F | GPIO12 (HSTX bit0) | 32 | 71 | なし | 直列 33R (R1) |
| HSTX_D1 | P → F | GPIO13 (bit1) | 33 | 72 | なし | 直列 33R (R2) |
| HSTX_D2 | P → F | GPIO19 (bit7) | 35 | 73 | なし | 直列 33R (R3) |
| HSTX_D3 | P → F | GPIO16 (bit4) | 36 | 74 | なし | 直列 33R (R4) |
| HSTX_CLK | P → F | GPIO14 (bit2) | 8 | 80 (GCLKT_0) | SD D2、10k プルアップ | 直列 33R (R5) |
| SCK | P → F | GPIO10 (SPI1 SCK) | 19 | 20 | LED5 | |
| COPI | P → F | GPIO11 (SPI1 TX) | 23 | 19 | LED4 | |
| CIPO | F → P | GPIO8 (SPI1 RX) | 24 | 75 | BL616 MISO | v1 で実績 |
| CS | P → F | GPIO9 | 21 | 86 | BL616 SPI_DIR | v1 で実績。正論理、10k プルダウン (R6) |
| IRQ (/READY) | F → P | GPIO20 | 38 | 85 | SD D1、10k プルアップ | v1 と同じ意味 (CONTROL bit4 で READY)。未コンフィグ時 High (2 章) |
| VSYNC | F → P | GPIO22 | 15 | 16 | LED1 / LCD YD (LCD_INIT1) | JP2 (既定 閉) |
| HEARTBEAT | F → P | GPIO23 | 16 | 15 | LED0 / LCD XR (LCD_INIT0) | JP3 (既定 閉) |
| RESET | P → F | GPIO21 | 40 | 79 | WS2812 DIN | 10k プルダウン (R7) |
| GND | | | 6, 9, 14, 20, 25, 30, 34, 39 | GND | | 隣り合う線は 2 章 |
| 5V (任意) | Tang → Pi | | 2 または 4 | 5V | | JP1 + SS14 (D1)。2 章 |

**HSTX のビット割り当て** (RP2350 側の設定): bit0 = D0, bit1 = D1, bit7 = D2, bit4 = D3, bit2 = CLK。HSTX はどのビットをどの GPIO に出すか自由なので、
ヘッダ上でまとまる GPIO 12/13/19/16 (ピン 32/33/35/36、間の 34 が GND) をデータにし、クロックだけ GPIO 14 (ピン 8) に置いた。
3cm ほど離れるが 37.5MHz DDR (ビット幅 13ns) に対して 0.15ns なので問題ない。GPIO 17/18 (ピン 11/12) は HSTX の bit5/6 で、レーンを増やすときの予備。配線しない。

### 1.1 選んだ理由

- **FPGA 側**: LCD を使うとヘッダに出ているクロック入力は 80 (GCLKT_0) しか残らない。他の部品がつながっていないヘッダピンは 71〜74 の 4 本だけ。
  残りは共有先が無害なもの (19/20 の LED、85 の SD プルアップ、79 の WS2812) と v1 で実績のある 75/86。
  棚卸しの詳細は Tang Nano 20K 回路図 Rev 1.3 のヘッダ J5/J6
- **RP2350 側**: HSTX は GPIO 12〜19 固定。SPI1 は GPIO 8〜11 にまとめた。GPIO 6/7 は PIO-USB コネクタにつながっているので使わない。
  オンボードの DVI は GPIO 41〜46 と 6/7 (PIO のビットバング) で、HSTX とは独立 (回路図の読み。届いたらヘッダの GPIO 12〜19 と HDMI 側の抵抗が導通していないことを確認)
- **正論理のまま** (v1 と同じ)。CS と RESET に外付け 10k プルダウン (RP2350-E9 の内蔵プルダウンの不具合を避ける)
- **IRQ と READY は 1 本** (v1 と同じく CONTROL bit4 で切り替え)。HSTX は片方向なので VBLANK のタイミングは VSYNC の線で取る
- **VSYNC / HEARTBEAT は LCD の XR / YD (LCD_INIT0/1) と共有**。FPGA の 15〜18 は LCD の XR / YD / XL / YU (LCD_INIT) につながっていて、
  ハーネスが使うのは 15 と 16 だけ (17 / 18 は使わない)。ST7701 系のパネル (SPI 初期化にこの線を使う) のときだけ JP2/JP3 を開ける。
  開けると HEARTBEAT が来なくなる。HEARTBEAT は FPGA が動いているかの判定 (2 章の READY) に使っているので、そのときは代わりに SPI で ID レジスタをポーリングする

## 2. 電気的な注意

- 全部 3.3V。レベル変換なし
- HSTX の 5 本は RP2350 側に直列 33R (R1〜R5)。最初 33R、波形を見て 0〜47R。15cm 程度のリボンまでなら 37.5MHz DDR で問題ない見込み。
  75MHz DDR に上げるときは基板化する
- **隣り合う線**: 40 芯のリボンでは隣の線はピン番号 ±1 (ヘッダの物理的な隣とは違う)。今の割り当てでは
  - CLK (8): 7 と 9。9 が GND
  - D1 (33)、D2 (35): 34 の GND を挟む
  - D0 (32): 31 (GPIO 6、使わない) と 33 (D1)。D3 (36): 35 (D2) と 37 (GPIO 26、使わない)。**隣に GND がない**
  - 39 の GND は IRQ (38) と RESET (40) の隣で、データの隣ではない

  37.5MHz DDR・15cm なら、D0 / D3 の隣は何もつながない線 (31、37) なので許容とする。ジャンパワイヤで配線するときは、HSTX の各線に GND の線を 1 本ずつ撚り合わせる
- **IRQ / READY は FPGA が未コンフィグのとき High** (85 の SD のプルアップ)。正論理なので「READY」に見える。ファームウェアは HEARTBEAT のトグル
  (JP3 を開けているときは SPI の ID レジスタ = `0x5A`) を確かめてからでないと IRQ / READY を信じない。リセット直後とビットストリームの書き込み中も同じ
- 85 と 80 の 10k プルアップ、19/20 の LED は RP2350 の出力でそのまま駆動できる
- 電源: 最初は **GND だけ共通にして USB を 2 本**挿す。Tang の 5V → JP1 → SS14 → ヘッダ 5V は、PiZero のヘッダ 5V が VBUS か VSYS (ダイオードと充電 IC の後) かを回路図で確かめてから閉じる。3V3 同士はつながない
- PSRAM: APS6404L-3SQR-ZR、CS = GPIO 47。SDK の `psram` 初期化に 47 を渡す。QMI のクロックは 133MHz 以下

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

| | v1 (RP2040-Zero) | v2 (RP2350-PiZero) |
|---|---|---|
| 本線 | SPI 8MHz | HSTX 4 + CLK (37.5MHz DDR、37MB/s)。SPI はレジスタの読み書きに残る |
| SPI の GPIO | SPI0 GP2〜5 | SPI1 GPIO 8〜11 (`pins.h` の番号と SPI インスタンスだけ) |
| 戻り線 | IRQ, VSYNC, HEARTBEAT, ERROR, LED0〜5 | IRQ, VSYNC, HEARTBEAT (ERROR と LED は廃止。`wiretest` の表から外す) |
| LCD との衝突 | 41, 42, 48 (VSYNC/HEARTBEAT/ERROR) | なし |
| OLED | I2C | 廃止 |
| 電源 | 別々の USB | 別々の USB (JP1 を閉じれば Tang → Pi) |
