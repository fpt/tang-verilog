# ハーネス v2: Pico 2 (Pico ピン配置) ⇔ Tang Nano 20K

本番のホストリンク (HSTX 4 データ + CLK) をそのまま載せたハーネス。戻りは v1 と同じ SPI と IRQ/READY、VSYNC、RESET。
M9 までのハーネスで使わなかった線 (ERROR、LED0〜5、OLED) と、VSYNC と同じ情報しか持たない HEARTBEAT は省いた。
**40 ピン RGB LCD (LCD_INIT の 15〜18 も)、I2S (MAX98357A)、HDMI の映像のピンは使わない**ので、ハーネスのまま LCD と音を出せる。
HDMI からは DDC_CLK (52) だけを借りる (EDID は読まない)。ジャンパはない。

- ホスト: **Raspberry Pi Pico 2** (RP2350A、PSRAM なし。リンクと翻訳層の検証には足りる)。同じ Pico ピン配置の **Pico Plus 2** (RP2350B、PSRAM 8MB、CS = GPIO 47) と
  **Pico LiPo 2** (同) にもそのまま載る。RP2350-PiZero は入手できなくなったので使わない
- 回路図: [`harness/kicad/v2/rp-tang-harness-v2.kicad_sch`](../harness/kicad/v2/rp-tang-harness-v2.kicad_sch) (基板は同じ場所の `rp-tang-harness-v2.kicad_pcb`)
- 配線表: [`harness/kicad/v2/pins_v2.json`](../harness/kicad/v2/pins_v2.json) (v1 と同じ形式。信号名も v1 に合わせてあるので `gen_pins_h.py` がそのまま使える)

## 1. 配線表 (12 本 + GND)

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
| VSYNC | F → P | GP22 | 29 | 52 | HDMI DDC_CLK、2.2k プルアップ (3.3V) | 同期パルス中 High。ready の判定にも使う (§1.2)。未コンフィグ時 High |
| RESET | P → F | GP21 | 27 | 79 | WS2812 DIN | 4.7k プルダウン (R10) |
| GND | | | 3, 8, 13, 18, 23, 28, 33, 38 | GND | | 隣り合う GND を HSTX の線の間に |

**HSTX のビット割り当て**: bit0..3 = D0..D3 (GP12〜15、ピン 16/17/19/20、間の 18 が GND)、bit4 = CLK (GP16、ピン 21)。
Pico ピン配置では HSTX の 8 本が 16〜25 に連続して並ぶので、5 本がまとまる。GP17〜19 (ピン 22/24/25) は bit5..7 で、レーンを増やすときの予備。配線しない。

### 1.1 選んだ理由

- **FPGA 側**: LCD を使うとヘッダに出ているクロック入力は 80 (GCLKT_0) しか残らない。他の部品がつながっていないヘッダピンは 71〜74 の 4 本だけ。
  残りは共有先が無害なもの (19/20 の LED、85 の SD プルアップ、79 の WS2812、52 の DDC_CLK) と v1 で実績のある 75/86。
  76 は BL616 の JTAG MOSI につながっていて BL616 が駆動するので使わない。
  棚卸しの詳細は Tang Nano 20K 回路図 Rev 1.3 のヘッダ J5/J6
- **RP2350 側**: HSTX は GPIO 12〜19 固定。SPI1 は GPIO 8〜11 にまとめた。GP4/5 (Qw/ST の I2C になるボードがある) と GP0/1 (UART) は空けてある
- **正論理のまま** (v1 と同じ)。CS と RESET に外付け 4.7k プルダウン (RP2350-E9: 入力のピンが内蔵プルダウンで約 2V に留まる不具合。外付けは 8.2k 以下が要る)
- **IRQ と READY は 1 本** (v1 と同じく CONTROL bit4 で切り替え)。HSTX は片方向なので VBLANK のタイミングは VSYNC の線で取る
- **VSYNC は HDMI の DDC_CLK (52) と共有**。LCD_INIT (15〜18、ST7701 系のパネルの SPI 初期化) とぶつからないので、ジャンパが要らない。
  HDMI にモニタやキャプチャをつないだままでも、SDA (53) は触らないので High のままで、I2C の開始条件ができず EDID の EEPROM は応答しない (EEPROM は SCL を駆動しない)

### 1.2 HEARTBEAT をやめた理由

- v1 の HEARTBEAT はフレームの先頭ごとに反転するだけ (`rtl/gowin/top.sv`) で、VSYNC と同じ情報しか持たない。どちらも `video_timing` から作られ、RESET 中は止まる
  (リセットでカウンタが 0 に戻り、`vsync` は非アクティブのまま)
- ファームウェアの ready の判定 (`fpga_ready()`: 直近 100ms 以内にエッジがある) は VSYNC (60Hz) のエッジで見る。ハーネスの設計が入っていないと 52 は 60Hz で動かないので、
  「SPI の線を駆動してよいか」の判定の意味は変わらない
- v2 のファームウェアとテストで変えるところ: `fpga_ready()` を `edge_vs` に、`harness.py` の HEARTBEAT 30Hz の項目を VSYNC 60Hz に、
  RESET の項目は VSYNC の立ち上がりを数える。`top_harness_probe` のエコーの線が 1 本減る

## 2. 電気的な注意

- 全部 3.3V。レベル変換なし
- HSTX の 5 本は RP2350 側に直列 33R (R4〜R8)。最初 33R、波形を見て 0〜47R。15cm 程度のリボンまでなら 37.5MHz DDR で問題ない見込み。
  各 HSTX 線の隣に GND を 1 本置く (Pico の GND はピン 18 が D1 (17) と D2 (19) の間、23 が CLK (21) の 2 つ隣。間の 22 は予備の GP17)。75MHz DDR に上げるときは基板化する
- 85 と 80 の 10k プルアップ、19/20 の LED は RP2350 の出力でそのまま駆動できる
- 52 の 2.2k プルアップ (3.3V) は FPGA の出力でそのまま駆動できる。VSYNC はほとんどの時間 Low なので約 1.5mA 流れる (気になるなら極性を反転して High を既定にする)
- 電源: **GND だけ共通にして USB を 2 本**挿す。5V の線はない (Pico の VBUS と Tang の 5V はどちらもつながない)。3V3 同士もつながない
- PSRAM: Pico 2 にはない (リンクと翻訳層の検証には不要)。Pico Plus 2 / Pico LiPo 2 では CS = GPIO 47、SDK の `psram` 初期化に 47 を渡す
- DDC_CLK を VSYNC に使うので、ハーネス v2 をつないでいるあいだは EDID を読めない (今の VDP / 3D GPU は読んでいない)

### 2.1 基板の確かめ (`rp-tang-harness-v2.kicad_pcb` のネット)

- 12 本の信号は Pico と Tang の両方で表の物理ピンにつながっている (Tang の記号のピン名: 1 = 73、2 = 74、3 = 75、4 = 85、16 = 20、17 = 19、21 = 52、
  23 = 71、24 = 72、27 = 79、28 = 86、37 = 80。22 = 53 はつながない)。GND は Pico の 8 本と Tang の 20 / 26 / 39、両面に GND のベタ
- +3V3 は Pico の 36 (3V3 の出力) と C4 (0.1u) だけ。Tang の 3V3 とはつながっていない
- HSTX の配線長 (Pico → 33R → Tang): D0 17mm、D1 12mm、D2 61mm、D3 61mm、CLK 66mm。最大の差 54mm で約 0.35ns。37.5MHz DDR の 1 ビット (13ns) にも
  75MHz DDR (6.7ns) にも小さい。CLK が一番長いので、データはクロックより少し先に着く

### 2.2 v2 で動かすときに変えるもの

- ファームウェア: `pins.h` を `pins_v2.json` から作る (`make harness-fw` の `HARNESS_PINS`)。`fpga_ready()` を VSYNC のエッジで、SPI1 (GPIO 8〜11)、
  `wiretest` の表から HEARTBEAT / ERROR / LED を外す。HSTX の送り出し (`stream` を HSTX に)
- FPGA: 制約ファイル (上の `.cst`)、HEARTBEAT の出力をなくし、VSYNC を 52 に。`pincheck` は `pins_v2.json` で見る。`top_harness_probe` の折り返しの線を減らす
- `harness.py`: selftest の HEARTBEAT 30Hz の項目を VSYNC 60Hz に、RESET の項目は VSYNC の立ち上がりで数える

## 3. FPGA 側

- 80 (GCLKT_0) を `IBUF` → グローバルクロック、71〜74 を `IDDR` で受けて 8bit/クロック。非同期 FIFO (BSRAM) で `clk_sys` へ
- パケット: マジック 32bit + 長さ + ペイロード + CRC16。ニブル単位でマジックを探して同期、CRC 不一致は捨ててカウンタを上げる
- SPI (86/20/19/75) と IRQ (85)、VSYNC (52)、RESET (79) は v1 と同じモジュールのままピンだけ変える。HEARTBEAT の出力はなくす。SPI と HSTX は同じパケット解析器 → コマンド FIFO に入れる
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
IO_LOC "vsync_out" 52; IO_PORT "vsync_out" IO_TYPE=LVCMOS33 DRIVE=8;
IO_LOC "reset_in"  79; IO_PORT "reset_in"  IO_TYPE=LVCMOS33 PULL_MODE=NONE;
```

## 4. v1 からの変更

| | v1 (RP2040-Zero) | v2 (Pico 2) |
|---|---|---|
| 本線 | SPI 8MHz | HSTX 4 + CLK (37.5MHz DDR、37MB/s)。SPI はレジスタの読み書きに残る |
| SPI の GPIO | SPI0 GP2〜5 | SPI1 GPIO 8〜11 (`pins.h` の番号と SPI インスタンスだけ) |
| 戻り線 | IRQ, VSYNC, HEARTBEAT, ERROR, LED0〜5 | IRQ, VSYNC (HEARTBEAT、ERROR、LED は廃止。`wiretest` の表から外す。ready は VSYNC で判定) |
| LCD との衝突 | 41, 42, 48 (VSYNC/HEARTBEAT/ERROR) | なし (LCD_INIT の 15〜18 も空いている) |
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
