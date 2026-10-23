# ハーネス v2: Pico LiPo 2 (RP2350B) ⇔ Tang Nano 20K

本番のホストリンク ([EMU_GPU_PLAN.md](EMU_GPU_PLAN.md) の「本番のリンク」) をそのまま載せたハーネス。
HSTX 4 データ + CLK を本線に、戻りは READY の GPIO 1 本と SPI (レジスタの読み書き、今のハーネスの機能) で持つ。
**40 ピン RGB LCD、I2S (MAX98357A)、HDMI のピンは一切使わない**ので、ハーネスのまま LCD と音を出せる。

回路図: [`harness/kicad/rp2350-tang-harness.kicad_sch`](../harness/kicad/rp2350-tang-harness.kicad_sch) (自作シンボル、グローバルラベルで結線)。
配線表: [`harness/pins_v2.json`](../harness/pins_v2.json)。

## 1. Tang Nano 20K のヘッダピンの棚卸し (回路図 Rev 1.3)

| 用途 | FPGA ピン | 判断 |
|---|---|---|
| 40 ピン RGB LCD (FPC) | 77 CK, 25 HS, 26 VS, 48 DE, 49 BL, 27〜31 B7..B3, 41 R4, 42 R3 (+ ヘッダに出ていない 32〜40) | **使わない** |
| LCD の XR/YD/XL/YU (LCD_INIT0..3、ST7701 系の SPI 初期化やタッチ) | 15, 16, 17, 18 (= LED0..3) | **既定では使わない**。任意の戻り線をハンダジャンパ経由で |
| I2S → MAX98357A | 54 DIN, 55 LRCK, 56 BCLK, 51 PA_SD/EN | **使わない** |
| HDMI | 33〜40 (LCD の R5..R7 / G2..G6 と同じピン)、52/53 DDC (5V プルアップ + レベルシフタ) | 33〜40 はヘッダに出ていない。52/53 は使わない |
| microSD | 80 D2 (**GCLKT_0**), 85 D1 (どちらも 10k プルアップ)、81〜84 はヘッダに出ていない | SD は使わない前提で 80 を HSTX の CLK、85 を READY に |
| BL616 (USB JTAG) の SPI | 75 MISO, 76 MOSI, 86 DIR (13 SCLK はヘッダに出ていない) | 75 (FPGA 出力) と 86 (FPGA 入力) は今のハーネスで実績あり。76 は使わない |
| WS2812 | 79 (DIN) | RESET に使う。リセット時に LED が 1 回光るだけ |
| LED4, LED5 | 19, 20 | SPI の COPI / SCK に。LED がうっすら光る |
| 他の部品なし | 71, 72, 73, 74 (HSPI_D0..3) | HSTX のデータ 4 本 |

HSTX のクロックは DDR で受けるので、グローバルクロックに入る **80 (IOT27A/GCLKT_0)** に置く。
ヘッダに出ているクロック入力は 77 (GCLKT_1、LCD_CK) と 79/80 (GCLK0 のペア) と 76 (GCLKC_1、BL616) しかなく、LCD を使うと 80 が唯一の選択肢。

## 2. 配線表

| 信号 | 向き | Pico GPIO | Pico 物理ピン | FPGA ピン | FPGA 側の共有 | 備考 |
|---|---|---|---|---|---|---|
| HSTX_D0 | P → F | GP12 (HSTX bit0) | 16 | 71 | なし | 直列 33R (R1) |
| HSTX_D1 | P → F | GP13 (bit1) | 17 | 72 | なし | 直列 33R (R2) |
| HSTX_D2 | P → F | GP14 (bit2) | 19 | 73 | なし | 直列 33R (R3) |
| HSTX_D3 | P → F | GP15 (bit3) | 20 | 74 | なし | 直列 33R (R4) |
| HSTX_CLK | P → F | GP16 (bit4) | 21 | 80 (GCLKT_0) | SD D2、10k プルアップ | 直列 33R (R5) |
| SPI_SCK | P → F | GP10 (SPI1 SCK) | 14 | 20 | LED5 | |
| SPI_COPI | P → F | GP11 (SPI1 TX) | 15 | 19 | LED4 | |
| SPI_CIPO | F → P | GP8 (SPI1 RX) | 11 | 75 | BL616 MISO | 実績あり |
| SPI_CS | P → F | GP9 (SPI1 CSn) | 12 | 86 | BL616 SPI_DIR | 実績あり。10k プルダウン (R6) |
| READY | F → P | GP20 | 26 | 85 | SD D1、10k プルアップ | FPGA 未コンフィグのときは High に見える |
| RESET | P → F | GP21 | 27 | 79 | WS2812 DIN | 10k プルダウン (R7) |
| VSYNC (任意) | F → P | GP22 | 29 | 18 | LED3 / LCD YU | JP2 |
| HEARTBEAT (任意) | F → P | GP7 | 10 | 17 | LED2 / LCD XL | JP3 |
| ERROR (任意) | F → P | GP6 | 9 | 16 | LED1 / LCD YD | JP4 |
| 5V | Tang → Pico | VBUS | 40 | 5V | | JP1 + SS14 (D1) |
| GND | | GND | 3, 8, 13, 18, 23, 28, 33, 38 | GND | | 全部つなぐ |
| 予備 (J1) | | GP17, GP18, GP19 (HSTX bit5..7)、GP0, GP1 (UART) | 22, 24, 25, 1, 2 | 15 (LED0 / LCD XR) | | ピンヘッダ |

Pico 側で空くもの: GP2〜GP5 (GP4/5 は Qw/ST の I2C。OLED はそこに挿す)、GP26〜GP28 (ADC 可。PT8211 やボタン)。

Pico LiPo 2 は RP2350B で、PSRAM の CS は GP47 (ヘッダに出ていない GPIO) なので HSTX の GP12〜19 とぶつからない。

### 2.1 ピンを選んだ理由

- **HSTX は GP12〜GP19 固定** (bit0..7)。データを bit0..3、クロックを bit4 にして、bit5..7 (GP17〜19) を J1 に出しておくので、レーンを 7 本に増やすときは FPGA 側の線を 3 本足すだけ
- **SPI1 を GP8〜GP11 にまとめた**。GP4/5 (SPI0 の候補) は Qw/ST コネクタの I2C と同じ線なので避けた。今のハーネスの SPI0 (GP2〜5) からは変わるが、ファームウェアは `pins.h` の番号と SPI インスタンスだけ
- **正論理のまま** (今のハーネスと同じ。Pico が離すとプルダウンで Low = 何もしていない)。CS と RESET に外付け 10k プルダウンを付け、RP2350 の内蔵プルダウンの不具合 (E9) を避ける
- **READY は 85 (SD D1)**。LED のピン (510R + LED で 3V3 に) に FPGA → Pico の信号を置くと、FPGA 未コンフィグのあいだ中間電位になる。85 は 10k プルアップだけなので High に確定する。Pico 側は HEARTBEAT (またはSPI の ID レジスタ) を見るまで READY を信用しない
- **16/17/18 は任意**。LCD_INIT0..3 (タッチ、または ST7701 系パネルの SPI 初期化) と共有なので、ハンダジャンパで切れるようにした。使うパネルがこれらを使わないなら閉じてよい

## 3. 電気的な注意

- 全部 3.3V。レベル変換なし
- HSTX の 5 本は Pico 側に直列抵抗 (R1〜R5)。最初 33R、波形を見て 0〜47R。配線は短く長さをそろえ、裏面のベタ GND を切らない。37.5MHz DDR (75Mbps) なら 10cm 程度のジャンパ線でも動くはずだが、基板にするときは 5 本の間に GND を挟む
- 85 と 80 の 10k プルアップ、19/20 の LED は Pico の出力でそのまま駆動できる (数 mA)
- 電源: Tang Nano の USB から JP1 → SS14 → Pico の VBUS。Pico の USB を同時に挿しても逆流しない。**3V3 同士はつながない** (両方のレギュレータがぶつかる)。LiPo を使うときは JP1 を開ける
- Pico LiPo 2 の電源ラッチ (74LVC1G74) は VBUS が来れば既定でオンになる

## 4. FPGA 側の受信

- 80 (GCLKT_0) を `IBUF` → グローバルクロックに乗せ、71〜74 を `IDDR` で受けて 8bit/クロック。非同期 FIFO (BSRAM) で `clk_sys` へ
- パケット: マジック 32bit + 長さ + ペイロード + CRC16。受信側はニブル単位でマジックを探して同期し、CRC 不一致は捨ててカウンタを上げる
- SPI (86/20/19/75) は今の SPI スレーブのまま。SPI と HSTX が同じパケット解析器 → コマンド FIFO に入るようにして、ハーネスのシナリオを本番の経路でも使う
- `.cst` の例:

```
IO_LOC  "hstx_clk"  80;  IO_PORT "hstx_clk"  IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC  "hstx_d[0]" 71;  IO_PORT "hstx_d[0]" IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC  "hstx_d[1]" 72;  IO_PORT "hstx_d[1]" IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC  "hstx_d[2]" 73;  IO_PORT "hstx_d[2]" IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC  "hstx_d[3]" 74;  IO_PORT "hstx_d[3]" IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC  "spi_sck"   20;  IO_PORT "spi_sck"   IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC  "spi_copi"  19;  IO_PORT "spi_copi"  IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC  "spi_cipo"  75;  IO_PORT "spi_cipo"  IO_TYPE=LVCMOS33 DRIVE=8;
IO_LOC  "spi_cs"    86;  IO_PORT "spi_cs"    IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC  "ready"     85;  IO_PORT "ready"     IO_TYPE=LVCMOS33 DRIVE=8;
IO_LOC  "reset"     79;  IO_PORT "reset"     IO_TYPE=LVCMOS33 PULL_MODE=NONE;
```

## 5. 今のハーネス (RP2040-Zero) との違い

| | v1 (RP2040-Zero) | v2 (Pico LiPo 2) |
|---|---|---|
| 本線 | SPI 8MHz | HSTX 4 + CLK (37.5MHz DDR、37MB/s) |
| 戻り | SPI 読み出し + IRQ/VSYNC/HEARTBEAT/ERROR | READY + SPI 読み出し (+ 任意の 3 本) |
| LCD との衝突 | 41, 42, 48 (VSYNC/HEARTBEAT/ERROR) | なし |
| LED0..5 | 15〜20 を Pico に出す | 19/20 を SPI に、16〜18 は任意、15 は予備 |
| 電源 | 別々の USB | Tang → Pico (ダイオード経由)、または別々の USB |
