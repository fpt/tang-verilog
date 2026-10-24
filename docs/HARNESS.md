# AI 開発ハーネス — Raspberry Pi Pico 2 ↔ Tang Nano 20K

Tang Nano 20K 上の VDP を、Linux ホストと Raspberry Pi Pico 2 から書き込み・操作・観測できるようにするためのハーネスの設計です。
[ARCHITECTURE.md](ARCHITECTURE.md) の「レジスタバスのマスタは差し替え可能」という方針に沿って、
Pico 2 を **レジスタバスを叩くマスタ + 観測係** として扱います。Pico 2 は最終的な VDP ホスト (RP2350) そのものなので、
ハーネスの配線は [WIRING.md](WIRING.md) の配線をそのまま拡張したものになります。

## 目的

- Claude Code などのエージェントが、人手を介さずに **ビットストリーム生成 → 書き込み → コマンド実行 → 結果確認** の 1 周を回せるようにする
- 「ハーネスが壊れているのか、設計が壊れているのか」をすぐ切り分けられるように、ハーネス自身の自己診断を持つ
- ハーネスと本番のホストを同じ RP2350・同じ SPI プロトコル・同じ配線にして、「ハーネスから本番への移行」という作業をなくす
- 将来 SDRAM を使った簡易 GPU に発展させても、ハーネス (レジスタバス + コマンド FIFO + 観測線) を作り直さずに済むようにする

## Pico 2 にした理由

当初は Raspberry Pi 3B+ を考えていましたが、Pico 2 + Linux ホストにしました。

- **本番と同じ構成**: Pico 2 は VDP のホスト CPU そのもの。配線・SPI ドライバ・シナリオ実行部を本番と共有できる
- **タイミングが正確**: VSYNC / HEARTBEAT の周期を µs 単位で測れる。Linux の GPIO ポーリングのようなジッタがない
- **ボードが 1 枚減る**: Pi の役割のうち、USB-JTAG・UART・キャプチャ・ネットワークは Linux ホストが受け持つ

Pico 2 にはネットワークも USB ホスト機能もないので、Pi が持っていた「Tang Nano を USB で書き込む」「ssh で呼ばれる」役は Linux ホストに移ります。

### 使えるボード

Pico 2 の代わりに Waveshare の小型ボードも使えます。GPIO 番号は全ボード共通なので、配線もファームウェアのピン定義も同じです。
このドキュメントで「Pico 2」と書いているところは、どのボードに読み替えてもかまいません。

| ボード | チップ | `make fw` の指定 | 備考 |
| --- | --- | --- | --- |
| Raspberry Pi Pico 2 | RP2350 | (既定) | 本命。本番のホストと同じ |
| Waveshare RP2350-Zero | RP2350 | `PICO_BOARD=waveshare_rp2350_zero` | 小型で、本番と同じチップのまま |
| Waveshare RP2040-Zero | RP2040 | `PICO_BOARD=waveshare_rp2040_zero PICO_PLATFORM=rp2040` | 手持ちがあるなら使える (rp-commander と同じボード) |

RP2040-Zero について:

- 3.3V I/O、GPIO の駆動能力 (最大 12mA)、SPI・PIO・USB CDC・`picotool` での書き込みは Pico 2 と同じで、ハーネスの機能はすべて実現できる。Cortex-M0+ 133MHz でも、6MHz 程度の SPI と µs 単位のエッジ測定には十分
- ただし **ハーネスと本番でチップが変わる** (RP2040 で試験して RP2350 で動かす)。プロトコルとピンが同じなのでリスクは小さいが、RP2350 にしかない機能 (追加の PIO、Hazard3 など) に依存するコードはハーネスで確かめられない
- 本番と同じチップのまま小型にしたいなら RP2350-Zero を選ぶ

Zero 系 2 種の共通の注意:

- GP16 はオンボードの WS2812 につながっているので使わない (下のピン割り当てで LED5 を GP26 にしているのはこのため)
- 端のピンヘッダに出ている GPIO は GP0〜GP15, GP26〜GP29 だけ (GP17〜GP25 は裏面のはんだパッド)。このドキュメントの割り当ては全部ピンヘッダに収まる
- ピンヘッダの GND は 1 本だけ。Tang Nano への GND 線 2 本と OLED の GND は、同じピンからブレッドボードの GND レールに出して分ける
- USB は USB-C

## 役割分担

| 役割 | 担当 | 内容 |
| --- | --- | --- |
| ビルド | Linux ホスト (Docker) | 合成・配置配線・シミュレーション・`make render` による参照画像の生成。Mac でビルドして成果物だけ渡してもよい |
| 書き込み・FPGA 側の観測 | Linux ホスト (Docker) | `openFPGALoader` で書き込み、BL616 の UART を受信、HDMI キャプチャ、参照との比較 |
| 実行・ピン側の観測 | Pico 2 | SPI でコマンド実行、GPIO 監視 (周期測定)、RESET、シナリオ実行 |
| 判断 | エージェント | `make hw-test` などを呼び、返ってきた JSON と差分画像を読んで次の修正を決める |

```text
                  ┌──────────────── Linux ホスト (Docker) ────────────────┐
                  │ make bitstream / render / fw → harness CLI → JSON     │
                  └────┬───────────────────┬──────────────────────┬───────┘
                       │USB (BL616)        │USB (CDC)             │USB (UVC, 任意)
                       │JTAG + UART        │                      │
                       ▼                   ▼                      │
                 Tang Nano 20K ◄─SPI+GPIO─ Pico 2                 │
                       │                                          │
                       └──────────HDMI──────► HDMI キャプチャ ────┘
```

macOS の Docker Desktop はコンテナに USB デバイスを渡せないため、実機を使うループは Linux ホストで回します。
Linux なら `openFPGALoader` もコンテナ内で動かせるので、ホストにツールを入れずに済みます。

## できること

### BL616 (オンボードデバッガ) 経由 — Linux ホストから

Tang Nano 20K の BL616 は FPGA の JTAG に基板内部でつながっています。表面の JTAG パッドは外部デバッガ用の予備なので、**パッドは使いません**。
Linux ホストに USB-C で挿すと FT2232 互換のデバイスとして見え、次のことができます。

| 機能 | Linux ホストから | 用途 |
| --- | --- | --- |
| USB-JTAG | ○ `openFPGALoader -b tangnano20k` | SRAM / Flash 書き込み、`--detect` でチップ ID 確認、書き込み後のステータス確認 |
| USB-UART (FPGA pin 69 = TX, 70 = RX) | ○ `/dev/ttyUSB1` 相当 | FPGA からのデバッグ出力。SPI を介さない独立した観測経路 |
| USB-SPI | △ | BL616 がスレーブ、FPGA がマスタという向きなので今回は使わない |
| GAO (Gowin のロジックアナライザ) | × | Gowin EDA 専用。オープンソースツールチェーンでは JTAG で波形を覗く手段はない |

JTAG で内部を覗くのは諦め、**UART を FPGA 側の自己申告チャネル**、**Pico 2 の GPIO を独立観測チャネル** として使い分けます。

### Pico 2 経由

- SPI でレジスタバスを駆動し、VDP にコマンドを送る (本番と同じプロトコル)
- VSYNC / HEARTBEAT / ERROR / IRQ を GPIO で直接観測し、エッジの時刻を µs 精度で記録する
- オンボード LED (ヘッダに出ている) を読む
- RESET で VDP をリセットする
- シナリオを Pico 2 上で実行する (`wait_vsync` のようなタイミング依存の操作を USB の遅延に左右されずに実行できる)

Pico 2 のファームウェアも Linux ホストから更新できます。`make fw` でビルドし、`picotool load -f -x` で書き込みます
(USB stdio の reset インターフェースで BOOTSEL に入れるので、ボタンを押す必要はない)。

### 画面の確認

| 段階 | 手段 | 精度 | 費用 |
| --- | --- | --- | --- |
| 1 | FPGA 内部で 1 フレームの CRC を計算し、`FRAME_CRC` レジスタを SPI で読む | ピクセル完全一致 | 0 円 |
| 2 | USB HDMI キャプチャ (MS2109 系) を Linux ホストに挿す | YUV 変換を通るので許容誤差付き比較 | 1,000〜2,000 円 |
| 3 | HDMI→CSI-2 ブリッジ (TC358743) など、非圧縮 RGB で取れるキャプチャ | ピクセルそのまま | 5,000 円〜 |

1 → 2 の順で進め、3 は「2 の色誤差で判定できないケースが実際に出てから」で十分です。
段階 1 は Pico 2 だけで完結するので、キャプチャ機材なしで閉ループが回ります。

## 配線

Pico 2 も Tang Nano 20K も I/O は 3.3V なので、レベル変換なしで直結できます。
Pico 2 と Tang Nano 20K はそれぞれ Linux ホストの USB から給電し、**3V3 同士・5V 同士はつながない** (GND だけ共通にする)。

### ピン割り当て

SCK〜IRQ は [WIRING.md](WIRING.md) と同じです。ハーネス用に観測線と RESET、LED を足しています。

| 信号 | 向き | Tang Nano ピン | Pico 2 GPIO | Pico 2 物理ピン | 備考 |
| --- | --- | --- | --- | --- | --- |
| SCK | Pico → FPGA | 73 | GP2 (SPI0 SCK) | 4 | WIRING.md と同じ |
| COPI | Pico → FPGA | 74 | GP3 (SPI0 TX) | 5 | 同上 |
| CIPO | FPGA → Pico | 75 | GP4 (SPI0 RX) | 6 | 同上 |
| CS | Pico → FPGA | 72 | GP5 | 7 | 同上。GPIO で制御 |
| IRQ | FPGA → Pico | 71 | GP6 | 9 | 同上。VBLANK 割り込み |
| VSYNC | FPGA → Pico | 42 | GP7 | 10 | `video_timing` の vsync をそのまま出す |
| HEARTBEAT | FPGA → Pico | 41 | GP8 | 11 | フレームごとにトグル (30Hz 方形波) |
| ERROR | FPGA → Pico | 48 | GP9 | 12 | コマンド FIFO あふれなど。将来は SDRAM 初期化失敗も |
| RESET | Pico → FPGA | 86 | GP10 | 14 | Pico から VDP をリセット |
| LED0〜4 | FPGA → Pico | 15〜19 | GP11〜GP15 | 15, 16, 17, 19, 20 | 読むだけ。負論理・プルアップ付き |
| LED5 | FPGA → Pico | 20 | GP26 | 31 | 同上。Zero 系では GP16 が WS2812 なので GP26 に飛ばしている |
| GND | — | GND ×2 | GND | 3, 18 | SCK の近くと LED 束の近くに 1 本ずつ |

Tang Nano 側のピン選定:

- 73, 74, 75, 72, 71: WIRING.md と同じ (どのオンボード部品ともつながっていない)
- 42, 41, 48: 40 ピン LCD コネクタと共用。LCD を使わない前提で借りる
- 86: WIRING.md で予備としていたピン。RESET に使う
- 15〜20: オンボード LED。ヘッダにも出ているので FPGA 側のピンを追加消費せずに読める
- 76: GCLK 入力なので引き続き温存
- 69, 70: BL616 の UART。ヘッダには出ていないので配線不要 (Linux ホストが USB 経由で受ける)

Pico 2 側は GP2〜GP15 と GP26 を使います。Pico 2 本体で使われている GP23〜GP25, GP29 と、Zero 系の WS2812 につながっている GP16 は避けています。
GP0 / GP1 は状態表示用の OLED (下記) に使います。

### 状態表示 OLED (SSD1306)

Pico 2 に SSD1306 の I2C OLED (128x64 または 128x32) をつなぎ、ハーネスの状態をその場で見られるようにします。
エージェントがループを回している横で、人間が「今どの段階で、何が起きているか」を確認するためのものです。

| OLED | Pico 2 GPIO | Pico 2 物理ピン | 備考 |
| --- | --- | --- | --- |
| SDA | GP0 (I2C0 SDA) | 1 | |
| SCL | GP1 (I2C0 SCL) | 2 | |
| VCC | 3V3 (OUT) | 36 | Zero 系は 3V3 ピン |
| GND | GND | 38 | Zero 系は GND レールから |

- I2C アドレスは `0x3C` (モジュールによっては `0x3D`)。クロックは 400kHz
- 多くのモジュールは SDA / SCL のプルアップ抵抗を載せているので、外付けは不要。載っていない場合は 4.7kΩ で 3V3 へプルアップする
- I2C 線には直列抵抗を入れない (Tang Nano とはつながらないので衝突の心配がない)
- OLED は Pico 2 の 3V3 から給電する。Tang Nano 20K の 3V3 とはつながない
- OLED は任意の部品として扱う。起動時に I2C で応答がなければ表示を無効にして、ハーネスの動作は続ける

### 配線図

```text
  Raspberry Pi Pico 2                           Tang Nano 20K
  (物理ピン / GPIO)                             (FPGA ピン)

   4  GP2  SCK        ──────────────────────►  73
   5  GP3  COPI       ──────────────────────►  74
   6  GP4  CIPO       ◄──────────────────────  75
   7  GP5  CS       ──────────────────────►  72
   9  GP6  IRQ      ◄──────────────────────  71
  10  GP7  VSYNC      ◄──────────────────────  42
  11  GP8  HEARTBEAT  ◄──────────────────────  41
  12  GP9  ERROR      ◄──────────────────────  48
  14  GP10 RESET    ──────────────────────►  86
  15  GP11 LED0       ◄──────────────────────  15
  16  GP12 LED1       ◄──────────────────────  16
  17  GP13 LED2       ◄──────────────────────  17
  19  GP14 LED3       ◄──────────────────────  18
  20  GP15 LED4       ◄──────────────────────  19
  31  GP26 LED5       ◄──────────────────────  20
   3  GND             ───────────────────────  GND (左列いちばん下)
  18  GND             ───────────────────────  GND (右列上から 2 本目)

   1  GP0  SDA        ───────────────────────  SSD1306 SDA
   2  GP1  SCL        ───────────────────────  SSD1306 SCL
  36  3V3             ───────────────────────  SSD1306 VCC
  38  GND             ───────────────────────  SSD1306 GND

  Linux ホスト USB ──USB-C──► Tang Nano 20K (給電 + JTAG + UART)
  Linux ホスト USB ──micro-B─► Pico 2 (給電 + USB CDC。Zero 系は USB-C)
```

物理ピン番号は Pico 2 のものです。Pico 2 では Tang Nano への線は LED5 (GP26) 以外が左列 (物理ピン 1〜20) に収まります。Zero 系はシルクの GPIO 番号に合わせて配線してください。

### 直列抵抗

信号線は直結せず、直列抵抗を挟みます。目的は 3 つです。

1. **衝突保護 (主目的)**: エージェントに cst や RTL、Pico のファームウェアを触らせる以上、「Pico が出力しているピンを FPGA も出力にしてしまった」は起こり得ます。
   書き込み中の不定状態やリセット中も含めて、両側が逆の値を押し合ったときの電流を小さく抑えます。
   ただし本命の対策は、書き込む前にピンの向きを検査すること ([ピン方向の検査](#ピン方向の検査)) で、抵抗は検査が効かない瞬間のための保険です
2. **片側だけ電源が入っているときの保護**: 電源の入っていない側の入力保護ダイオード経由で、もう片側が電源を供給してしまう (バックパワー) 電流を抑えます
3. **リンギング抑制**: ジャンパ線の反射を減らしてエッジをきれいにします

| 線 | 抵抗 | 衝突時の電流 | 理由 |
| --- | --- | --- | --- |
| SCK / COPI / CIPO / CS | 220Ω | 15mA | 速度が要る線。6MHz まではこれで成立する |
| VSYNC / HEARTBEAT / ERROR / IRQ / RESET / LED0〜5 | 1kΩ | 3.3mA | 変化は数 ms に 1 回なので、遅いエッジでも困らない |
| GND | なし | — | — |

- 抵抗は **ドライバ側 (信号の出口)** に置きます。Pico → FPGA の線は Pico 側、FPGA → Pico の線は Tang Nano 側
- 衝突時の電流は 3.3V ÷ 抵抗値。1kΩ なら複数本が同時に衝突しても、RP2040 / RP2350 の GPIO 合計電流の上限に対して十分小さい
- 1kΩ × 線路容量 50pF (15cm ジャンパ + 入力容量) で時定数 50ns、立ち上がり 110ns 程度。低速線には影響がない。Pico の内蔵プルアップ / プルダウン (約 50kΩ) との分圧も無視できる
- 220Ω × 50pF なら立ち上がり 25ns 程度。SCK を 10MHz 以上に上げるときは SPI 線を 100Ω へ落とす (衝突時 33mA になるので、ピン方向の検査を通っていることが前提)
- 実装はブレッドボード上で Pico 2 と Tang Nano の間に抵抗を並べる。理想は各ボードのヘッダのすぐ横だが、片端にまとめても実用上は困らない
- 集合抵抗を使うなら **独立型 (アイソレーテッド型)** に限る。よくある SIP の 1 ピン共通型 (バスド型) は片側が全部つながっているので直列には使えない。DIP 16 ピン 8 素子独立型 (Bourns 4116R-2 など) ならブレッドボードに挿して向かい合う 2 ピンが 1 本の抵抗になる。本数は増えるが普通のリード抵抗 15 本でも構わない
- 本番の配線 (WIRING.md) でも同じ考え方で SPI 線に抵抗を入れておくとよい

使わないもの:

- **ロジックバッファ (74LVC125 / 244 / 245)**: FPGA 側の向きを間違えると、今度はバッファの出力と衝突するだけで、問題が移動するだけ。しかもバッファは 24mA 級で強く駆動するので FPGA にはかえって厳しい
- **バススイッチ・自動方向判定のレベル変換 (74CBT, TXS0108)**: 双方向に素通しするので電流を制限しない。TXS0108 は直列抵抗と組み合わせると誤動作しやすい
- **ポリスイッチ (リセッタブルヒューズ)**: 動作電流が数百 mA で、GPIO を守るには大きすぎる

### ピン方向の検査

衝突の現実的な原因は偶然の故障ではなく、エージェントが cst・RTL・Pico のピン設定を書き換えて、入力のはずのピンを出力にしてしまうことです。
これは書き込む前にソフトウェアで検出できるので、ハーネスで電気的に衝突させる前に止めます。

**ピン表を 1 か所に置く**: 上のピン割り当て表を機械可読な形 ([`harness/pins.json`](../harness/pins.json)) で持ち、FPGA 側の検査と Pico 側のファームウェアの両方がこれを使います。
向きは FPGA から見たものです (`input` = ハーネスが駆動する線)。ツールのイメージに PyYAML が無いので JSON にしています。

**FPGA 側 (`make pincheck`, [`scripts/pincheck.py`](../scripts/pincheck.py))**: `make prog` / `make flash` が書き込みの前に必ず実行し、失敗したら書き込まない。

- `TARGET` の cst の `IO_LOC` から「ポート名 → ピン番号」を、合成結果の `build/<top>.json` (Yosys の JSON) から「ポート名 → 向き (`input` / `output` / `inout`)」を取り出して突き合わせる
- ピン表で `input` のピンに `output` か `inout` のポートが割り当てられていたら失敗
- ピン表で `output` のピンに `input` が割り当てられているのは衝突しないが、観測できなくなるので警告
- ピン表にあるピンを cst が使っていない (ポートがない) 場合は、FPGA 側は弱プルアップの入力になるだけなので許可する
- ビットストリームが検査済みの JSON から作られたことを確かめるため、JSON と `.fs` の更新時刻も見る

**Pico 側**:

- ピンの向きと機能の設定 (`gpio_set_dir` / `gpio_set_function` / プル設定) は、ピン表から生成したヘッダ (`pins.h`。`make harness-fw` が [`scripts/gen_pins_h.py`](../scripts/gen_pins_h.py) で生成) を使う 1 つのモジュールで、起動時に 1 回だけ行う
- それ以外の場所でこれらの関数を呼んでいたら `make fw` を失敗させる (grep で十分)
- ホストからのコマンドは観測ピンを読めるが、ピンの向きは変えられない。出力として動かせるのは CS・RESET と SPI だけ

この 2 つがあれば、ピンの向きの間違いは「電気的な衝突」ではなく「selftest の失敗」として表に出ます。
直列抵抗が受け持つのは、電源投入直後や FPGA の書き込み中など、検査が及ばない瞬間だけになります。

### 制約ファイルに足す内容

WIRING.md の SPI 分に加えて `constraints/tangnano20k.cst` へ追加します。

```text
// ハーネス観測用 (docs/HARNESS.md)
IO_LOC  "vsync_out"   42;
IO_PORT "vsync_out"   IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8;
IO_LOC  "heartbeat"   41;
IO_PORT "heartbeat"   IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8;
IO_LOC  "error_out"   48;
IO_PORT "error_out"   IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8;
IO_LOC  "rst_in"      86;
IO_PORT "rst_in"      IO_TYPE=LVCMOS33 PULL_MODE=DOWN;
IO_LOC  "uart_tx"     69;
IO_PORT "uart_tx"     IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8;
IO_LOC  "uart_rx"     70;
IO_PORT "uart_rx"     IO_TYPE=LVCMOS33 PULL_MODE=UP;
```

### 注意

- ジャンパワイヤは 10〜15 cm 程度に収める
- FPGA を書き込み直している間は CIPO / IRQ / 観測線が不定になるので、Pico 2 側はその間の値を信用しない
- Pico 2 の入力ピンにはプルを設定しておく (ハーネスの全ピンは、駆動するとき以外は入力 + プルダウン。RP2 → FPGA の線はすべて正論理なので、プルダウンされた状態が「何もしていない」になる)

## FPGA 側に追加するもの

### レジスタ

ARCHITECTURE.md のレジスタマップに、ハーネス用として以下を足します。

| アドレス | 名前 | 内容 |
| --- | --- | --- |
| `0x04` | `FRAME_COUNT` | フレームカウンタ下位 8bit (読み出し)。キャプチャしたフレームを特定する |
| `0x05` | `FRAME_CRC_0`〜`0x08` `FRAME_CRC_3` | 直前フレームの CRC32 (読み出し)。VSYNC でラッチ |
| `0x7D` | `SCRATCH` | 書いた値がそのまま読める。SPI リンクの確認用 |
| `0x7E` | `ID` | マジック `0x5A` (読み出し) |
| `0x7F` | `VERSION` | RTL のバージョン (読み出し) |

`CONTROL` にはアニメーション停止 (フレームカウンタを進めない) ビットを設けます。
跳ね回る四角のような動きがあると、キャプチャしたフレームと参照フレームが一致しなくなるためです。

### 観測信号

- `heartbeat`: VSYNC ごとにトグル
- `vsync_out`: `video_timing` の vsync
- `error_out`: コマンド FIFO あふれ、不正レジスタアクセスなどを OR したもの。`STATUS` を読むとクリア
- LED: SPI 受信回数の下位ビットなどを出しておくと、SPI が届いているかを目でも Pico 2 からも確認できる
- UART (115200 8N1): 起動時にバナー (`VDP v0.1 ok`)、以降はデバッグ出力

### 「FPGA ready」の判定について

READY を「High になったら準備完了」という静的レベルにすると誤判定します。
Gowin FPGA は未コンフィグ時に I/O が弱プルアップになるので、何も書き込んでいない状態でも High に見えることがあるためです。
ready は次の 3 つを合わせて判定します。

1. openFPGALoader の書き込みが成功した (JTAG のステータス)
2. HEARTBEAT が 30Hz でトグルしている (未コンフィグで偶然トグルすることはない)
3. SPI で `ID` が `0x5A`、`SCRATCH` が往復する

## Pico 2 側のファームウェア

`firmware/` のファームウェアにハーネス用のコマンドインタプリタを持たせます。本番用のコードと SPI ドライバ・シナリオ実行部を共有します。
ピン定義は全ボード共通で、ボードの違いは `make fw` の `PICO_BOARD` / `PICO_PLATFORM` だけです ([使えるボード](#使えるボード))。

USB CDC 上で 1 行 1 JSON のやりとりをします。

```text
→ {"cmd": "ping"}
← {"ok": true, "fw": "harness 0.1"}
→ {"cmd": "spi", "tx": "fe00"}
← {"ok": true, "rx": "005a"}
→ {"cmd": "measure", "pin": "heartbeat", "ms": 200}
← {"ok": true, "edges": 12, "period_us": [33367, 33366, ...]}
```

| コマンド | 内容 |
| --- | --- |
| `ping` | ファームウェアのバージョンを返す |
| `spi` | 1 トランザクション (CS を上げて送受信して下げる) |
| `read` / `write` | レジスタ名かアドレスで読み書き (`spi` の薄いラッパ) |
| `gpio` | 全観測ピンの現在値 |
| `measure` | 指定ピンのエッジ時刻を指定時間記録し、周期を返す (GPIO 割り込み + µs タイマ) |
| `reset` | RESET を指定時間 High にする |
| `run` | シナリオ (後述) を受け取って Pico 2 上で実行し、結果をまとめて返す |
| `status` | OLED に任意の 1 行を表示する (ホスト側から段階名などを出す) |

### OLED の表示

USB の接続が切れていても読めるように、Pico 2 が自分で観測できる情報を中心に出します。

```text
┌────────────────────────┐
│ HARNESS 0.1   USB:ok   │  ファームウェアのバージョン、ホストとの接続
│ FPGA:ready  ID:5A v01  │  ready 判定の結果、ID / VERSION レジスタ
│ HB 30.0Hz  VS 60.0Hz   │  HEARTBEAT / VSYNC の実測周波数
│ ERR:0  SPI:1234/0      │  ERROR ピン、SPI トランザクション数 / エラー数
│ LED ●○○●○○  F:7A       │  LED0〜5、FRAME_COUNT
│ > run tile_hello 3/6   │  ホストから送られた現在の段階 (status コマンド)
└────────────────────────┘
```

- 表示の更新は数 Hz に抑え、SPI やエッジ測定の邪魔をしない (I2C の転送はメインループの空き時間か DMA で行う)
- `selftest` の失敗時は、失敗した項目番号と理由を大きく表示したまま止める

## Linux ホスト側のセットアップ

- Linux なら x86_64 / arm64 どちらでもよい。Docker を入れる
- 実機を触るコンテナには USB デバイスを渡す。抜き差しでデバイス番号が変わっても困らないように、`--device` で個別に渡すのではなく `/dev` ごとマウントし、デバイスの種類 (メジャー番号) 単位で cgroup ルールで許可する

  ```bash
  # 189: USB (openFPGALoader, picotool) / 166: ttyACM (Pico 2) / 188: ttyUSB (BL616 の UART) / 81: video4linux (キャプチャ)
  docker run --rm \
    -v /dev:/dev \
    --device-cgroup-rule='c 189:* rmw' \
    --device-cgroup-rule='c 166:* rmw' \
    --device-cgroup-rule='c 188:* rmw' \
    --device-cgroup-rule='c 81:* rmw' \
    ...
  ```

- udev ルール (BL616 は VID `0403` / PID `6010`、Pico 2 は VID `2e8a` として見える)。`/dev/ttyACM*` などの番号に依存しないよう、シンボリックリンクも作る:

  ```text
  SUBSYSTEM=="usb", ATTR{idVendor}=="0403", ATTR{idProduct}=="6010", MODE="0666"
  SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", MODE="0666"
  SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", SYMLINK+="vdp-harness", MODE="0666"
  SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6010", ENV{ID_USB_INTERFACE_NUM}=="01", SYMLINK+="vdp-uart", MODE="0666"
  ```

- ハーネス CLI (Python + pyserial)、`openFPGALoader`、`picotool`、`ffmpeg` が入ったイメージを使う。`openFPGALoader` は OSS CAD Suite に入っているので `tang-fpga` イメージに足すのが手軽
- 古い BL616 ファームウェアでは UART のボーレートが 4 倍ずれる既知の問題があります。文字化けしたらファームウェア更新を疑ってください
- Mac で開発を続ける場合は、Mac でビルドして Linux ホストへ `rsync` し、実機ループだけ `ssh linux make hw-run` で回す形でもよい

## 検証方法

### RP2 ブリッジとホストツール (実装済み)

RP2 には [`harness/firmware`](../harness/firmware/src/main.c) のブリッジを一度だけ書き込み、以降はホストの
[`tools/harness/harness.py`](../tools/harness/harness.py) から操作します ([GPU_PLAN.md](GPU_PLAN.md) の M0)。
ブリッジは GPU のレジスタやコマンドの意味を知らず、SPI のバイト列を素通しするだけなので、GPU を作り変えても書き換える必要がありません。

```bash
make harness-fw                                  # ブリッジ (既定は RP2040-Zero。HARNESS_BOARD / HARNESS_PLATFORM で変更)
# 初回だけ: BOOT を押しながら USB をつなぎ、harness/firmware/build/harness_bridge.uf2 を RPI-RP2 ドライブへコピー
python3 tools/harness/harness.py bootsel         # 2 回目以降は BOOT ボタンなしで BOOTSEL に入れる
python3 tools/harness/harness.py status          # ピンの値、HEARTBEAT / VSYNC / IRQ の周期、ready
python3 tools/harness/harness.py spi a55a0102    # SPI の 1 トランザクション
python3 tools/harness/harness.py prog hdmi       # make prog TARGET=hdmi (pincheck 込み)
```

| コマンド | 内容 |
| --- | --- |
| `ping` | ファームウェア名・版・ボード |
| `status` | 全ハーネスピンの値、HEARTBEAT / VSYNC / IRQ の周期と最後のエッジからの時間、ready、SPI の周波数と回数 |
| `spi <hex>` | CS を上げて送受信し、受信を hex で返す (最大 4096 バイト)。ready でなければ何も駆動しない |
| `spib <n>` | 改行 (`\n` 1 文字) の直後に n バイトの生データを続ける書き込み専用の版 (v2 から)。応答は受信の最初の 1 バイト (同期バイト) だけ。ホストツールは書き込みに自動で使う |
| `freq <hz>` | SPI の周波数 (既定 1MHz) |
| `reset [ms]` | RESET を指定時間 High にする (FPGA が止まったときの復旧用なので ready は見ない) |
| `irqwait [ms]` | IRQ の立ち上がりを待つ |
| `wiretest` | 配線テスト (下記) |
| `bootsel` | BOOTSEL モードで再起動する |

ホストツールだけのコマンド (ブリッジの `spi` を使う):

| コマンド | 内容 |
| --- | --- |
| `reg read <reg> [n]` | レジスタを読む (`<reg>` は `ID` のような名前か `0x7e` のような番地) |
| `reg write <reg> <hex>` | レジスタに書く |
| `selftest [--iterations N]` | 下記 |
| `frametest [--ref-dir DIR] [--no-capture] [--out DIR]` | アニメーションを止め、`FRAME_CRC` を参照 (`make render FREEZE=1`) と比べ、HDMI キャプチャも比べる。キャプチャと差分画像を `build/hw/` に保存 |
| `memtest [--size N] [--samples 2,..,7] [--seed S] [--phases 0-15]` | SDRAM の BIST を読み出しの取り込み位置ごとに実行 (`--size 21` で 8MiB 全域、1 回 0.6 秒)。`--phases` で SDRAM クロックの位相も変え、位相 x 取り込み位置の合否表を出す |
| `mem read <addr> [n]` / `mem write <addr> <hex32>...` | SDRAM を 1 ワードずつ読み書き |
| `fb upload [<png>] [--slot N]` / `fb show` / `fb off` | 320x240 の画像 (省略時はテスト画像) をフレームバッファへ / 表示の切り替え |
| `scenario <scenarios/*.json> [--no-capture]` | シナリオを GPU に送り、check ごとに `FRAME_CRC` (とキャプチャ) を参照モデル (`gpu_model.py`) と比べる。`check_marked` は印を付けたフレームの `MARK_CRC` を比べる (キャプチャなし)。Verilator 側は `make scenario`。キャプチャは 95% 以上で合格 (正しさは CRC で決める) |
| `fps <file.json> [--frames N]` | `{"setup", "frame"}` の frame (`SWAP` か `WAIT_VBLANK` で区切る) を N 回くり返し、fps・表示フレーム / 描画フレーム・`UNDERFLOW` を測る。`"frames": [[...], ...]` ならフレームごとに順に使う (`e7_fps` の回る道路) |
| `audio [--seconds S] [--tone HZ] [--stream]` | 音 (K5a): 正弦波を PCM のリングに流し、`PCM_RD` / `PCM_WR` で先回りを保ちながら、アンダーラン 0 と 48kHz を確かめる。既定はリングに 1 回書いて `PCM_WR` を進めるだけ (音の周期がリングを割り切る 750Hz など)。`--stream` は毎回 `UPLOAD` するが、192KB/s 要り、このハーネス (約 180KB/s) では途切れる |
| `fbtest [<png>] [--slot N] [--keep] [--no-capture]` | アップロードして表示し、`FRAME_CRC`・`UNDERFLOW`・キャプチャを参照モデル (`fbmodel.py`) と比べる |
| `prog <target>` | `make prog TARGET=<target>` |

- 出力は 1 つの JSON。`"ok"` が true でなければ終了コード 1
- **ready**: HEARTBEAT が直近 100ms 以内に立ち上がっていること。FPGA の書き込み中や、HEARTBEAT を出さない設計 (今の HDMI など) では `spi` を拒否する
- ハーネスのピンは、駆動するとき以外は常に入力 + プルダウン。SPI 線もトランザクションの間だけ SPI 機能にする
- ブリッジは自分からは何も駆動しない (コマンドを受けたときだけ)
- v2 (M5 のあと): USB の入力を 1 文字ずつではなくまとめて読み、書き込みは `spib` (生データ、受信を送り返さない) にした。
  2KiB の書き込みが 62ms → 9.6ms、320x240 の画像のアップロードが 4.8 秒 → 0.9 秒。ホストツールは `ping` の版を見て、v1 なら `spi` を使う
- macOS 26 では `cp` で `RPI-RP2` にコピーすると固まることがあったので、Finder でドラッグするのが確実 (`make harness-deploy` は Linux 向け)
- ハーネスのピンを使わない設計 (今の HDMI など) では、FPGA の未使用ピンの弱いプルアップが RP2 のプルダウンに勝ち、全部 High に読める。弱いプル同士なので衝突ではない

### 配線テスト (実装済み)

ハーネスを組んだら、まずこれで全部の線を確かめます。

```bash
python3 tools/harness/harness.py prog harness_probe   # FPGA の SRAM にテスト用の設計を書き込む (Flash の内容はそのまま)
python3 tools/harness/harness.py wiretest
```

- FPGA ([`rtl/gowin/top_harness_probe.sv`](../rtl/gowin/top_harness_probe.sv)): FPGA → RP2 の 11 本をそれぞれ違う周波数 (13.2kHz〜12.9Hz) でトグルさせる。RP2 → FPGA の 4 本のどれかが High の間は、SCK→CIPO, COPI→IRQ, CS→VSYNC, RESET→HEARTBEAT と折り返す。RP2 → FPGA の線は FPGA 側でもプルダウン
- RP2 の `wiretest`:
  1. 全ピンを入力 + プルダウンにする
  2. 500ms 読むだけ。FPGA → RP2 の各線の立ち上がり回数が期待値 ±10% か、RP2 → FPGA の線がずっと Low か
  3. 2 が全部通ったときだけ、RP2 → FPGA の線を 1 本ずつ 100µs High にし、折り返し先だけが High になるかを見る
  4. 全ピンを入力 + プルダウンに戻す
- FPGA にテスト用の設計が入っていないと 2 で失敗するので、RP2 は何も駆動しない

### `harness selftest`

エージェントが最初に呼ぶ 1 コマンドです。各項目を pass/fail の JSON で返し、失敗した段階で止めます。

**実装済み (M1)**: `python3 tools/harness/harness.py selftest [--iterations N]`。FPGA に設計 (今は `hdmi`) が入っている前提で、
ブリッジの ping → ready → HEARTBEAT 30Hz・VSYNC 60Hz (ブリッジの時計で測る) → `ID` → `FRAME_COUNT` →
`SCRATCH` の往復 (1 / 4 / 8MHz、各 N 回) → IRQ → RESET → SDRAM クロックの位相の余裕 (前後 2 段以上) → READY の線 の順に確かめます。`--iterations 10000` で 26 秒ほど。
書き込み (`prog`) と UART のバナーはまだ含みません。下の表は最終的な形です。

| # | 項目 | 担当 | 失敗したときの意味 |
| --- | --- | --- | --- |
| 1 | `openFPGALoader --detect` で GW2AR-18 が見える | ホスト | USB / udev / ケーブル / コンテナへのデバイス受け渡し |
| 2 | Pico 2 が `ping` に応答する | ホスト → Pico | USB / ファームウェア未書き込み |
| 3 | `harness pincheck` が通る (ピン方向の検査) | ホスト | cst か RTL でピンの向きを間違えている。**ここで止めて書き込まない** |
| 4 | `top.fs` を SRAM に書き込み、終了コード 0 | ホスト | ビットストリーム破損、BL616 |
| 5 | HEARTBEAT を 200ms 測定し 30Hz ±5% | Pico | PLL ロック失敗、タイミング生成が動いていない、配線 |
| 6 | VSYNC のエッジ間隔が 16.67ms ±1% | Pico | `video_timing` の異常 |
| 7 | `ID` = `0x5A`、`SCRATCH` に乱数を書いて読み返し、1MHz で 100 往復してエラー 0 | Pico | 配線か SPI スレーブ |
| 8 | UART に起動バナーが出ている | ホスト | UART TX、リセット系 |
| 9 | LED0〜5 の現在値を報告 | Pico | (情報のみ) |
| 10 | RESET を上げると HEARTBEAT が止まり、下げると再開する | Pico | リセット配線 |

項目 2 が失敗し、項目 1 が通る場合は Pico 2 側の問題、と切り分けられます。

### 画面の検証

- `make render` で出した `build/render/frame_N.png` と同じ CRC32 を Python で計算し、実機の `FRAME_CRC` と比較する (段階 1)
- HDMI キャプチャがある場合は `ffmpeg -f v4l2 -i /dev/video0 -frames 1 out.png` で取り込み、参照 PNG と許容誤差付きで比較して差分画像を出す (段階 2)
- どちらも `CONTROL` のアニメーション停止ビットを立て、`FRAME_COUNT` を読んでから取り込む

### シナリオ

SPI コマンド列を YAML で書き、同じファイルを以下の 2 つで実行できるようにします。

- Pico 2 (ホストの CLI が JSON に変換して `run` で送る)
- Verilator テストベンチ (`make render` の入力)

エージェントはシナリオを書き足すだけでよくなります。
ハーネスと本番が同じ Pico 2 なので、シナリオ実行部はそのまま本番のファームウェアでも使えます。

```yaml
# scenarios/tile_hello.yaml
- {write: CONTROL, value: 0x01}        # 表示 ON
- {write: VRAM_ADDR_L, value: 0x00}
- {write: VRAM_ADDR_H, value: 0x00}
- {write: VRAM_DATA, bytes: [0x41, 0x42, 0x43]}
- {wait_vsync: 2}
- {expect_crc: 0x12345678}
```

## 開発ループ

```text
make hw-test
  ├─ make bitstream              (Docker)
  ├─ make render SCENARIO=...    (Docker, 参照画像と期待 CRC)
  ├─ make fw                     (Docker, Pico 2 のファームウェアを変えたときだけ)
  └─ harness run                 (Docker, USB デバイスを渡したコンテナ)
       ├─ selftest (短縮版: 1, 2, 3, 5, 7 のみ)
       ├─ picotool load          (ファームウェアを変えたときだけ)
       ├─ openFPGALoader で SRAM に書き込み (pincheck を通ったときだけ)
       ├─ Pico 2 でシナリオ実行
       ├─ FRAME_CRC 読み出し / キャプチャ
       ├─ compare → 差分 PNG
       └─ JSON 出力
```

- 失敗時にエージェントが読むのは JSON と差分画像だけにする
- タイムアウトと復旧: FPGA が固まったら RESET → 効かなければ USB 経由で再書き込み (SRAM 書き込みなので再起動相当) → それでもだめなら `uhubctl` で USB 給電を落とす (ポート個別の電源制御に対応したハブが必要)
- Pico 2 が応答しなくなったら `picotool reboot` → 効かなければ `uhubctl` で Pico 2 のポートの給電を落とす
- `harness` は小さな Python CLI として実装し、`pincheck` / `prog` / `spi` / `gpio` / `uart` / `capture` / `compare` / `selftest` / `run` のサブコマンドを持たせる。`prog` は内部で必ず `pincheck` を先に実行し、`--force` のような回避手段は用意しない

## その後の改善案

- **HDMI→CSI-2 などの非圧縮キャプチャ**: 色誤差なしの比較が必要になったら
- **USB 給電の自動制御**: `uhubctl` で電源からの完全リセット。Tang Nano 20K と Pico 2 を別ポートにして個別に落とせるようにする
- **MCP サーバ化**: `harness` を MCP サーバとして包み、エージェントから直接ツールとして呼べるようにする
- **ロジックアナライザ**: 空き GPIO (Pico 2 は GP16〜GP22, GP27, GP28。Zero 系のピンヘッダでは GP27〜GP29) と PIO で、FPGA のデバッグ用ピンを数 MHz でサンプリングする。JTAG で波形を覗けない分を補う
- **SDRAM / 簡易 GPU 化**: Tang Nano 20K の 64Mbit SDRAM はパッケージ内蔵でヘッダに出ていないため、配線はこのまま。ホスト側インターフェースは「レジスタバス + コマンド FIFO」のまま維持し、SDRAM 初期化失敗を `ERROR` と `STATUS` に載せる
- **UART の活用**: FPGA 内のレジスタダンプや FIFO 状態を UART で吐き、ホスト側でログとして残す
- **フレーム比較の強化**: CRC だけでなく、タイル単位のハッシュを読めるようにして「どのタイルがずれたか」まで FPGA 側で特定できるようにする

## 最初の一歩

機材を買う前に閉ループが回り始める順番:

1. `ID` / `SCRATCH` / `FRAME_CRC` レジスタと `heartbeat` 出力を RTL に追加
2. ~~`harness/pins.json` と `make pincheck`、配線テスト~~ (実装済み)
3. Pico 2 のファームウェアに `ping` / `spi` / `measure` を実装し、ピン設定を `pins.json` から生成したヘッダに寄せる
4. Linux ホストで USB デバイスを渡したコンテナから `openFPGALoader` と Pico 2 の両方が見えることを確認
5. ホスト側に Python の `harness selftest` を実装
6. `make render` の PNG から CRC を計算し、実機の `FRAME_CRC` と比較する `make hw-test` を作る
