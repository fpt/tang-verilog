# Pico 2 + Tang Nano 20K ベースボード設計

Pico 2 (RP2350) をホスト CPU、Tang Nano 20K (GW2AR-18) をグラフィックアダプタ (VDP) として、1 枚のベースボードで接続するための設計メモ。対象は配線までで、VDP 内部の描画方式は扱わない。

## 1. システム構成

| 部分 | 担当 |
|---|---|
| Pico 2 (RP2350) | ホスト CPU。ゲームロジック、VDP へのコマンド送信、サウンド (PT8211)、ボタン入力 |
| Tang Nano 20K | VDP。スプライト・パレット・BG などの描画と HDMI (DVI) 出力 (640x480@60Hz) |
| ベースボード | 両ボードの接続、PT8211 とオーディオ出力、ボタン、電源 |

```
           QSPI (6本) + 制御 (3本)
 [Pico 2] <────────────────────────> [Tang Nano 20K] ──HDMI──> モニタ
    │ │
    │ └── PT8211 ── ライン出力
    └──── ボタン x8
```

## 2. 通信方式の方針

### 2.1 帯域の見積もり

VDP はスプライトのパターンやパレットを FPGA 側に保持するので、毎フレーム送るのは変化した分だけでよい。SPI 液晶のように全画面を毎回送る必要はない。

| 転送内容 | 1フレームあたり | 60fps での帯域 |
|---|---|---|
| スプライト属性 (64枚 x 8バイト) | 512B | 約 31KB/s |
| パレット全体 (256色 x 3バイト) | 768B | 約 46KB/s |
| スクロール値などのレジスタ | 数十B | ほぼゼロ |
| 320x240 8bpp 全画面ビットマップ | 76.8KB | 約 4.6MB/s |

| 方式 | 実効帯域の目安 | 1フレームあたり (60fps) |
|---|---|---|
| SPI 20MHz (FPGA でオーバーサンプリング) | 約 2.5MB/s | 約 40KB |
| QSPI 20MHz (同上) | 約 10MB/s | 約 160KB |
| QSPI 50MHz (SCK をクロックとして直接使用) | 約 25MB/s | 約 400KB |

スプライト・パレット・スクロール中心なら SPI で十分。パターンデータの大量入れ替えやビットマップ転送で足りなくなったら QSPI にする。

### 2.2 段階的な立ち上げ

1. **ハードウェア SPI1** で通信する (D0 = MOSI、D1 = MISO として使う)
2. **PIO による QSPI** に切り替える (配線はそのまま)
3. 必要なら FPGA 側で **SCK をクロックとして直接使う** 受信方式に切り替える

配線は最初から QSPI 用に引いておき、基板を作り直さずに 1 → 3 へ進めるようにする。

### 2.3 戻り信号

| 信号 | 用途 |
|---|---|
| VBLANK_N | 垂直帰線期間の通知。スプライト座標やパレットを画面が乱れないタイミングで更新するため |
| BUSY | FPGA 側コマンド FIFO がほぼ満杯であることの通知 |
| FPGA_RST_N | Pico 2 から FPGA 内部のロジックをリセットする |

## 3. Tang Nano 20K のヘッダーピン

ヘッダーは 2x20 ピン (2.54mm ピッチ)。I/O は 34 本出ているが、多くは基板上の部品と共有されている。以下は回路図 (Tang_Nano_20K_3921, Rev 1.22) のネット名から整理したもの。

### 3.1 使わないピン

| FPGA ピン | 共有先 | 理由 |
|---|---|---|
| 15〜20 | LED0〜5 | LED の負荷がつながっている |
| 79 | WS2812 (RGB LED) | 同上 |
| 51 | MAX98357A のイネーブル | 基板上のアンプ |
| 52, 53 | HDMI の EDID (DDC) | HDMI コネクタにつながっている |
| 54〜56 | MAX98357A の I2S | 基板上のアンプ。コンフィグ用ピン (SSPI) も兼ねる |
| 75, 76, 86 | HSPI_DIR / HSPI_DAT / HSPI_CSN | BL616 の SPI につながっていると読める (要確認) |
| 80, 85 | microSD | SD スロットにつながっている |

### 3.2 使うピン

| FPGA ピン | ネット名 | 備考 |
|---|---|---|
| 71〜74 | HSPI_DIN0〜3 | 他の部品につながっていない。QSPI データ線に使う |
| 77 | LCD_CK (IOT30A / GCLKT_1) | クロック専用ピン。QSPI の SCK に使う |
| 27, 41, 42, 48 | LCD_B7 / LCD_R4 / LCD_R3 / LCD_DE | 液晶コネクタ (FPC) のみ。液晶を使わなければ空き |
| 25, 26, 28〜32 | LCD_* | 予備 (同上) |

## 4. ピン割り当て

### 4.1 Pico 2 ⇔ Tang Nano 20K

| 信号 | 向き | Pico 2 GPIO | Pico 2 物理ピン | Tang Nano 20K | 共有先 |
|---|---|---|---|---|---|
| QSPI_CS_N | Pico → FPGA | GP9 | 12 | 48 | LCD_DE |
| QSPI_SCK | Pico → FPGA | GP10 | 14 | 77 (GCLKT_1) | LCD_CK |
| QSPI_D0 | 双方向 | GP11 | 15 | 71 | なし |
| QSPI_D1 | 双方向 | GP12 | 16 | 72 | なし |
| QSPI_D2 | 双方向 | GP13 | 17 | 73 | なし |
| QSPI_D3 | 双方向 | GP14 | 19 | 74 | なし |
| VBLANK_N | FPGA → Pico | GP15 | 20 | 41 | LCD_R4 |
| BUSY | FPGA → Pico | GP8 | 11 | 42 | LCD_R3 |
| FPGA_RST_N | Pico → FPGA | GP7 | 10 | 27 | LCD_B7 |

Pico 2 側の割り当ての意図:

- GP9〜GP12 はハードウェア SPI1 の CSn / SCK / TX / RX に割り当てられるピン。QSPI の慣習どおり D0 = MOSI、D1 = MISO にしてあるので、同じ配線でハードウェア SPI が使える。
- データ線 D0〜D3 が連続した GPIO (GP11〜GP14) なので、PIO の 1 命令で 4bit を入出力できる。
- Pico 2 の物理ピン 13 番と 18 番が GND なので、QSPI の配線の間に GND が入る。

### 4.2 Pico 2 側の周辺

| 用途 | Pico 2 GPIO | Pico 2 物理ピン |
|---|---|---|
| PT8211 DIN | GP16 | 21 |
| PT8211 BCK | GP17 | 22 |
| PT8211 WS | GP18 | 24 |
| ボタン 1〜5 | GP2〜GP6 | 4, 5, 6, 7, 9 |
| ボタン 6〜8 | GP19〜GP21 | 25, 26, 27 |
| デバッグ用 UART TX / RX | GP0 / GP1 | 1, 2 |
| 予備 | GP22 | 29 |
| 予備 (アナログ入力可) | GP26〜GP28 | 31, 32, 34 |

## 5. 周辺回路

### 5.1 PT8211

- BCK と WS を連続した GPIO (GP17, GP18) にしてあるので、PIO のサイドセットで 2 本まとめて出力できる。間に GND (物理ピン 23) が入る。
- 入力形式は標準の I2S ではなく **LSB 詰め (LSBJ)**、MSB から先、2 の補数。PIO プログラムは標準 I2S のサンプルをこの形式に合わせて修正する。WS の極性 (どちらが L か) はデータシートで確認する。
- 電源は 3〜6V で動作し、3.3V の信号をそのまま受けられる。出力振幅を稼ぐため 5V で動かし、電源ラインに抵抗とコンデンサ (またはフェライトビーズ) のフィルタを入れる。
- 出力には DC カット用コンデンサ、負荷抵抗、RC ローパスフィルタを付けてライン出力とする。ヘッドホンを直接鳴らす場合は別途アンプが必要。

参考: Tang Nano 20K 側にもモノラルのスピーカー用アンプ (MAX98357A、FPGA ピン 51, 54〜56) が載っているので、FPGA 側で音を出す用途にも使える。

### 5.2 ボタン

- スイッチの片側を GND につなぎ、RP2350 の内蔵プルアップを使う。
- RP2350 には内蔵プルダウンが正しく働かない不具合 (エラッタ E9) がある版があるため、プルダウンは使わない。
- チャタリング除去はソフトウェアで行う。

## 6. 電源と GND

- Tang Nano 20K の USB からシステム全体に給電する。
- Tang Nano 20K のヘッダーの 5V ピンから、ショットキーダイオードを通して Pico 2 の VSYS に給電する。Pico 2 の VBUS → VSYS の経路にもダイオードがあるので、開発中に Pico 2 の USB を同時に挿してもよい。
- **3V3 同士はつながない** (両ボードのレギュレータがぶつかる)。
- Tang Nano 20K のヘッダーの GND ピンはすべてベースボードの GND プレーンにつなぐ。
- 消費電流の合計が Tang Nano 20K の USB 給電 (5V 0.5A) の範囲に収まるか確認する。

## 7. 基板設計の注意

- 裏面は全面 GND プレーンにし、QSPI の配線の下で GND を途切れさせない。
- QSPI の 6 本は配線長をそろえ、なるべく短くする。
- QSPI のデータ線 4 本と SCK には、Pico 2 側に 22〜33Ω の直列抵抗のフットプリントを置く。最初は 0Ω で実装し、波形を見て調整する。データ線は双方向なので、出力同士がぶつかったときの保護も兼ねる。
- QSPI_CS_N と FPGA_RST_N には 10kΩ のプルアップを付け、どちらかのボードが起動していない間も確定させる。
- ロジックアナライザやオシロスコープを当てられるよう、QSPI と制御信号のテストポイント (またはピンヘッダー) を出しておく。
- 予備ピン (FPGA 側 25, 26, 28〜32、Pico 2 側 GP22, GP26〜GP28) はピンヘッダーに引き出しておく。

## 8. FPGA 側の受信回路の方針

- 最初は FPGA の内部クロック (100MHz 程度) で SCK / CS / データ線を 2 段のフリップフロップで同期化し、SCK の立ち上がりを検出してデータを取り込む (オーバーサンプリング方式)。SCK は 20MHz 程度まで。
- 速度が必要になったら、SCK (77 番、GCLKT_1) をクロックとして直接受信し、非同期 FIFO で内部クロックへ渡す方式に切り替える。
- SPI 受信回路と QSPI 受信回路は、どちらも同じコマンド FIFO に書き込む構造にし、FIFO より後ろを共通化する。
- 読み出し時はプロトコル上で 1〜2 クロックのターンアラウンドを入れ、FPGA と Pico 2 が同時にデータ線を駆動しないようにする。

### 8.1 制約ファイル (.cst) の例

```
// QSPI
IO_LOC  "qspi_cs_n" 48;
IO_PORT "qspi_cs_n" IO_TYPE=LVCMOS33 PULL_MODE=UP;
IO_LOC  "qspi_sck" 77;
IO_PORT "qspi_sck" IO_TYPE=LVCMOS33 PULL_MODE=NONE;
IO_LOC  "qspi_d[0]" 71;
IO_PORT "qspi_d[0]" IO_TYPE=LVCMOS33 PULL_MODE=UP;
IO_LOC  "qspi_d[1]" 72;
IO_PORT "qspi_d[1]" IO_TYPE=LVCMOS33 PULL_MODE=UP;
IO_LOC  "qspi_d[2]" 73;
IO_PORT "qspi_d[2]" IO_TYPE=LVCMOS33 PULL_MODE=UP;
IO_LOC  "qspi_d[3]" 74;
IO_PORT "qspi_d[3]" IO_TYPE=LVCMOS33 PULL_MODE=UP;

// 制御信号
IO_LOC  "vblank_n" 41;
IO_PORT "vblank_n" IO_TYPE=LVCMOS33 DRIVE=8;
IO_LOC  "busy" 42;
IO_PORT "busy" IO_TYPE=LVCMOS33 DRIVE=8;
IO_LOC  "fpga_rst_n" 27;
IO_PORT "fpga_rst_n" IO_TYPE=LVCMOS33 PULL_MODE=UP;
```

### 8.2 Pico 2 側のピン定義の例

```c
// Pico 2 <-> Tang Nano 20K
#define PIN_FPGA_RST_N  7
#define PIN_BUSY        8
#define PIN_QSPI_CS_N   9   // SPI1 CSn
#define PIN_QSPI_SCK    10  // SPI1 SCK
#define PIN_QSPI_D0     11  // SPI1 TX (MOSI)
#define PIN_QSPI_D1     12  // SPI1 RX (MISO)
#define PIN_QSPI_D2     13
#define PIN_QSPI_D3     14
#define PIN_VBLANK_N    15

// PT8211
#define PIN_AUDIO_DIN   16
#define PIN_AUDIO_BCK   17
#define PIN_AUDIO_WS    18  // BCK + 1 (PIO side-set)

// Buttons (active low, internal pull-up)
static const uint PIN_BUTTONS[8] = {2, 3, 4, 5, 6, 19, 20, 21};
```

## 9. 発注前の確認事項

- [ ] **ヘッダーの物理的な並び**をデータシート v1.3 の図で確認する。古いピン配置図には誤りがあり (25/26 番の入れ替わり、75/76 番が反対側のヘッダー)、それを引き継いだ資料もある。可能なら実物でテスターを当てて導通を確認する。
- [ ] ヘッダーの列間隔 (20.32mm) と外形 (54.04 x 22.55mm) を外形図で確認し、KiCad のフットプリントを作る。
- [ ] 75, 76, 86 番が BL616 につながっているかを回路図の USB_JTAG のページで確認する (今回の割り当てでは使っていない)。
- [ ] 上の .cst で一度、合成と配置配線まで通す。
- [ ] `docs/WIRING.md` の既存の割り当てと整合させる。
- [ ] PT8211 のデータシートで WS の極性と推奨出力回路を確認する。

