# 配線 — RP2350 ↔ Tang Nano 20K (試作 1 号)

ジャンパワイヤで RP2350 ボードと Tang Nano 20K をつなぐ最初の試作の配線です。
RP2350 が SPI マスタ、FPGA が SPI スレーブです。設計の背景は [ARCHITECTURE.md](ARCHITECTURE.md) を参照してください。

- RP2350 ボード: Raspberry Pi Pico 2 (`make fw` の既定 `PICO_BOARD=pico2`)。XIAO RP2350 でも同じ GPIO 番号で配線できます
- 両ボードとも I/O は 3.3V なので、レベル変換なしで直結できます

## ピン割り当て

| 信号 | 向き | RP2350 GPIO | Pico 2 物理ピン | XIAO RP2350 | Tang Nano 20K ピン | FPGA ポート名 (予定) |
| --- | --- | --- | --- | --- | --- | --- |
| SCK | RP2350 → FPGA | GP2 (SPI0 SCK) | 4 | D8 | **73** | `spi_sck` |
| COPI (MOSI) | RP2350 → FPGA | GP3 (SPI0 TX) | 5 | D10 | **74** | `spi_copi` |
| CIPO (MISO) | FPGA → RP2350 | GP4 (SPI0 RX) | 6 | D9 | **75** | `spi_cipo` |
| CS (負論理) | RP2350 → FPGA | GP5 (GPIO 出力) | 7 | D3 | **72** | `spi_cs_n` |
| IRQ (負論理) | FPGA → RP2350 | GP6 (GPIO 入力) | 9 | D4 | **71** | `vdp_irq_n` |
| GND | — | GND | 3 または 8 | GND | GND (左列いちばん下 / 右列 2 番目) | — |

- SCK / COPI / CIPO / CS の GPIO は `firmware/main.c` の `PIN_SCK` / `PIN_MOSI` / `PIN_MISO` / `PIN_CS` と同じです
- CS はハードウェアの SPI0 CSn ではなく GPIO で制御します (複数バイトのトランザクション中に CS を下げたままにするため)
- IRQ は VBLANK 通知用です。最初の試作では未使用でもかまいません (RP2350 側でプルアップしておく)
- 電源はそれぞれの USB から取り、**3V3 同士・5V 同士はつながない** (GND だけ共通にする)

### Tang Nano 20K 側のピンを選んだ理由

Tang Nano 20K のヘッダピンの多くはオンボードの部品 (LED、SD カード、40 ピン LCD コネクタ、I2S アンプ、WS2812、HDMI の EDID) と共用です。
上の割り当ては、どの部品ともつながっていないピンだけを使っています。

| ヘッダ | ピン (上から) | 用途 |
| --- | --- | --- |
| 左列 | 73, 74, 75 | SCK, COPI, CIPO (USB-C 側から 1〜3 本目で隣り合っている) |
| 右列 | 72, 71 | CS, IRQ (3V3 の下、HDMI 側から 3〜4 本目) |
| 右列 | 86 | 予備 (将来の RESET 用など) |

避けたピン:

- 85, 80: SD カード (SDIO_D1 / SDIO_D2)
- 15〜20: オンボード LED
- 25〜31, 77, 42, 41, 48, 49: 40 ピン RGB LCD コネクタ
- 56, 54, 55, 51: I2S アンプ (MAX98357A)
- 79: WS2812
- 52, 53: HDMI の EDID (DDC)
- 76: 使えるが、GCLK 入力なので将来クロック入力用に空けておく

## 配線図

```text
  Raspberry Pi Pico 2                         Tang Nano 20K
  (物理ピン番号)                              (FPGA ピン番号)

   4  GP2  SCK   ───────────────────────────►  73   左列 1 本目
   5  GP3  COPI  ───────────────────────────►  74   左列 2 本目
   6  GP4  CIPO  ◄───────────────────────────  75   左列 3 本目
   7  GP5  CS    ───────────────────────────►  72   右列 下から 4 本目
   9  GP6  IRQ   ◄───────────────────────────  71   右列 下から 3 本目
   3  GND        ────────────────────────────  GND  左列 いちばん下
   8  GND        ────────────────────────────  GND  右列 上から 2 本目
```

Tang Nano 20K のヘッダ (USB-C を上にして、部品面から見た並び):

```text
          左列                       右列
   73   ◄ SCK                    5V
   74   ◄ COPI                   GND  ◄ GND
   75   ► CIPO                   76
   85                            80
   77                            42
   15                            41
   16                            56
   27                            54
   28                            51
   25                            48
   26                            55
   29                            49
   30                            86   (予備)
   31                            79
   17                            GND
   20                            3V3
   19                            72   ◄ CS
   18                            71   ► IRQ
   3V3                           53
   GND  ◄ GND                    52
```

## SPI の設定

| 項目 | 値 |
| --- | --- |
| モード | Mode 0 (CPOL=0, CPHA=0) |
| ビット順 | MSB first |
| ワード長 | 8 bit |
| クロック | 最初は 1 MHz。動作確認後に上げる |

FPGA 側は SCK をシステムクロック (ピクセルクロック 25.2 MHz) でサンプリングしてエッジを検出する想定なので、
SCK の上限はシステムクロックの 1/4 程度 (約 6 MHz) です。`firmware/main.c` は今 10 MHz に設定しているので、
SPI スレーブを実装するときに下げてください。

トランザクションの形式 (案):

```text
書き込み: CS↓  [0x00 | addr(7bit)] [data] ... CS↑
読み出し: CS↓  [0x80 | addr(7bit)] [dummy → data] CS↑
```

先頭バイトの最上位ビットで読み書きを区別し、残り 7 bit がレジスタアドレスです ([ARCHITECTURE.md](ARCHITECTURE.md) のレジスタマップ)。
`VRAM_DATA` への連続書き込みは、CS を下げたままデータバイトを続けて送るとアドレスが自動インクリメントされる想定です。

## 制約ファイルに足す内容

SPI スレーブを実装するときに `constraints/tangnano20k.cst` へ追加します。

```text
// RP2350 との SPI (docs/WIRING.md)
IO_LOC  "spi_sck" 73;
IO_PORT "spi_sck" IO_TYPE=LVCMOS33 PULL_MODE=DOWN;
IO_LOC  "spi_copi" 74;
IO_PORT "spi_copi" IO_TYPE=LVCMOS33 PULL_MODE=DOWN;
IO_LOC  "spi_cipo" 75;
IO_PORT "spi_cipo" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8;
IO_LOC  "spi_cs_n" 72;
IO_PORT "spi_cs_n" IO_TYPE=LVCMOS33 PULL_MODE=UP;
IO_LOC  "vdp_irq_n" 71;
IO_PORT "vdp_irq_n" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8;
```

CS をプルアップしておくと、RP2350 をつないでいないときや起動中に FPGA が誤って選択されません。

## 注意

- ジャンパワイヤは 10〜15 cm 程度に収める。長いと SCK のエッジが鈍ってリンギングが出る
- GND は SCK の近くにもう 1 本引くと安定しやすい
- FPGA を書き込み直している間は CIPO / IRQ が不定になるので、RP2350 側はその間の値を信用しない
