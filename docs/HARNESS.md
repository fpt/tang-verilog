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
- ピンヘッダの GND は 1 本だけ。GND 線 2 本は同じピンから分岐するか、裏面の GND パッドから取る
- USB は USB-C

## 役割分担

| 役割 | 担当 | 内容 |
| --- | --- | --- |
| ビルド | Linux ホスト (Docker) | 合成・配置配線・シミュレーション・`make render` による参照画像の生成。Mac でビルドして成果物だけ渡してもよい |
| 書き込み・FPGA 側の観測 | Linux ホスト (Docker) | `openFPGALoader` で書き込み、BL616 の UART を受信、HDMI キャプチャ、参照との比較 |
| 実行・ピン側の観測 | Pico 2 | SPI でコマンド実行、GPIO 監視 (周期測定)、RESET_N、シナリオ実行 |
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
- RESET_N で VDP をリセットする
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

SCK〜IRQ_N は [WIRING.md](WIRING.md) と同じです。ハーネス用に観測線と RESET_N、LED を足しています。

| 信号 | 向き | Tang Nano ピン | Pico 2 GPIO | Pico 2 物理ピン | 備考 |
| --- | --- | --- | --- | --- | --- |
| SCK | Pico → FPGA | 73 | GP2 (SPI0 SCK) | 4 | WIRING.md と同じ |
| COPI | Pico → FPGA | 74 | GP3 (SPI0 TX) | 5 | 同上 |
| CIPO | FPGA → Pico | 75 | GP4 (SPI0 RX) | 6 | 同上 |
| CS_N | Pico → FPGA | 72 | GP5 | 7 | 同上。GPIO で制御 |
| IRQ_N | FPGA → Pico | 71 | GP6 | 9 | 同上。VBLANK 割り込み |
| VSYNC | FPGA → Pico | 42 | GP7 | 10 | `video_timing` の vsync をそのまま出す |
| HEARTBEAT | FPGA → Pico | 41 | GP8 | 11 | フレームごとにトグル (30Hz 方形波) |
| ERROR | FPGA → Pico | 48 | GP9 | 12 | コマンド FIFO あふれなど。将来は SDRAM 初期化失敗も |
| RESET_N | Pico → FPGA | 86 | GP10 | 14 | Pico から VDP をリセット |
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
GP0 / GP1 (UART0) は Pico 2 自身のデバッグ出力用に空けておきます。

### 配線図

```text
  Raspberry Pi Pico 2                           Tang Nano 20K
  (物理ピン / GPIO)                             (FPGA ピン)

   4  GP2  SCK        ──────────────────────►  73
   5  GP3  COPI       ──────────────────────►  74
   6  GP4  CIPO       ◄──────────────────────  75
   7  GP5  CS_N       ──────────────────────►  72
   9  GP6  IRQ_N      ◄──────────────────────  71
  10  GP7  VSYNC      ◄──────────────────────  42
  11  GP8  HEARTBEAT  ◄──────────────────────  41
  12  GP9  ERROR      ◄──────────────────────  48
  14  GP10 RESET_N    ──────────────────────►  86
  15  GP11 LED0       ◄──────────────────────  15
  16  GP12 LED1       ◄──────────────────────  16
  17  GP13 LED2       ◄──────────────────────  17
  19  GP14 LED3       ◄──────────────────────  18
  20  GP15 LED4       ◄──────────────────────  19
  31  GP26 LED5       ◄──────────────────────  20
   3  GND             ───────────────────────  GND (左列いちばん下)
  18  GND             ───────────────────────  GND (右列上から 2 本目)

  Linux ホスト USB ──USB-C──► Tang Nano 20K (給電 + JTAG + UART)
  Linux ホスト USB ──micro-B─► Pico 2 (給電 + USB CDC。Zero 系は USB-C)
```

物理ピン番号は Pico 2 のものです。Pico 2 では LED5 (GP26) 以外が左列 (物理ピン 1〜20) に収まります。Zero 系はシルクの GPIO 番号に合わせて配線してください。

### 直列抵抗

信号線は直結せず、直列抵抗を挟みます。目的は 2 つです。

1. **衝突保護 (主目的)**: エージェントに cst や RTL、Pico のファームウェアを触らせる以上、「Pico が出力しているピンを FPGA も出力にしてしまった」は必ず起きます。書き込み中の不定状態やリセット中も含めて、両側が逆の値を押し合ったときに電流を定格内に抑えます
2. **リンギング抑制**: ジャンパ線の反射を減らしてエッジをきれいにします

| 線 | 抵抗 | 理由 |
| --- | --- | --- |
| SCK / COPI / CIPO / CS_N | 100Ω | 速度を出したい線。6MHz までなら 220Ω でも成立する |
| VSYNC / HEARTBEAT / ERROR / IRQ_N / RESET_N / LED0〜5 | 330Ω | 低速なので RC 遅延は気にならない。衝突時 10mA |
| GND | なし | — |

- 抵抗は **ドライバ側 (信号の出口)** に置きます。Pico → FPGA の線は Pico 側、FPGA → Pico の線は Tang Nano 側
- 衝突時の電流は 3.3V ÷ 抵抗値。100Ω で 33mA、220Ω で 15mA、330Ω で 10mA
- RP2350 の GPIO は駆動能力の設定が最大 12mA で、全 GPIO 合計の電流にも上限があります。低速線は 330Ω にしておくと、複数本が同時に衝突しても余裕があります
- 220Ω × 線路容量 50pF (15cm ジャンパ + 入力容量) で時定数 11ns、立ち上がり 25ns 程度。SCK を 10MHz 以上に上げるときに SPI 線を 100Ω へ落とす
- 実装はブレッドボード上で Pico 2 と Tang Nano の間に抵抗を並べる。理想は各ボードのヘッダのすぐ横だが、片端にまとめても実用上は困らない
- 集合抵抗を使うなら **独立型 (アイソレーテッド型)** に限る。よくある SIP の 1 ピン共通型 (バスド型) は片側が全部つながっているので直列には使えない。DIP 16 ピン 8 素子独立型 (Bourns 4116R-2 など) ならブレッドボードに挿して向かい合う 2 ピンが 1 本の抵抗になる。本数は増えるが普通のリード抵抗 15 本でも構わない
- 本番の配線 (WIRING.md) でも同じ考え方で SPI 線に抵抗を入れておくとよい

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
IO_LOC  "rst_n_in"    86;
IO_PORT "rst_n_in"    IO_TYPE=LVCMOS33 PULL_MODE=UP;
IO_LOC  "uart_tx"     69;
IO_PORT "uart_tx"     IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8;
IO_LOC  "uart_rx"     70;
IO_PORT "uart_rx"     IO_TYPE=LVCMOS33 PULL_MODE=UP;
```

### 注意

- ジャンパワイヤは 10〜15 cm 程度に収める
- FPGA を書き込み直している間は CIPO / IRQ / 観測線が不定になるので、Pico 2 側はその間の値を信用しない
- Pico 2 の入力ピンにはプルを設定しておく (CS_N / RESET_N の出力は起動直後に High を出す。入力は IRQ_N・LED がプルアップ、それ以外はプルダウン)

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
| `spi` | 1 トランザクション (CS_N を下げて送受信して上げる) |
| `read` / `write` | レジスタ名かアドレスで読み書き (`spi` の薄いラッパ) |
| `gpio` | 全観測ピンの現在値 |
| `measure` | 指定ピンのエッジ時刻を指定時間記録し、周期を返す (GPIO 割り込み + µs タイマ) |
| `reset` | RESET_N を指定時間 Low にする |
| `run` | シナリオ (後述) を受け取って Pico 2 上で実行し、結果をまとめて返す |

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

### `harness selftest`

エージェントが最初に呼ぶ 1 コマンドです。各項目を pass/fail の JSON で返し、失敗した段階で止めます。

| # | 項目 | 担当 | 失敗したときの意味 |
| --- | --- | --- | --- |
| 1 | `openFPGALoader --detect` で GW2AR-18 が見える | ホスト | USB / udev / ケーブル / コンテナへのデバイス受け渡し |
| 2 | Pico 2 が `ping` に応答する | ホスト → Pico | USB / ファームウェア未書き込み |
| 3 | `top.fs` を SRAM に書き込み、終了コード 0 | ホスト | ビットストリーム破損、BL616 |
| 4 | HEARTBEAT を 200ms 測定し 30Hz ±5% | Pico | PLL ロック失敗、タイミング生成が動いていない、配線 |
| 5 | VSYNC のエッジ間隔が 16.67ms ±1% | Pico | `video_timing` の異常 |
| 6 | `ID` = `0x5A`、`SCRATCH` に乱数を書いて読み返し、1MHz で 100 往復してエラー 0 | Pico | 配線か SPI スレーブ |
| 7 | UART に起動バナーが出ている | ホスト | UART TX、リセット系 |
| 8 | LED0〜5 の現在値を報告 | Pico | (情報のみ) |
| 9 | RESET_N を落とすと HEARTBEAT が止まり、戻すと再開する | Pico | リセット配線 |

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
       ├─ selftest (短縮版: 1, 2, 4, 6 のみ)
       ├─ picotool load          (ファームウェアを変えたときだけ)
       ├─ openFPGALoader で SRAM に書き込み
       ├─ Pico 2 でシナリオ実行
       ├─ FRAME_CRC 読み出し / キャプチャ
       ├─ compare → 差分 PNG
       └─ JSON 出力
```

- 失敗時にエージェントが読むのは JSON と差分画像だけにする
- タイムアウトと復旧: FPGA が固まったら RESET_N → 効かなければ USB 経由で再書き込み (SRAM 書き込みなので再起動相当) → それでもだめなら `uhubctl` で USB 給電を落とす (ポート個別の電源制御に対応したハブが必要)
- Pico 2 が応答しなくなったら `picotool reboot` → 効かなければ `uhubctl` で Pico 2 のポートの給電を落とす
- `harness` は小さな Python CLI として実装し、`prog` / `spi` / `gpio` / `uart` / `capture` / `compare` / `selftest` / `run` のサブコマンドを持たせる

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
2. Pico 2 のファームウェアに `ping` / `spi` / `measure` を実装
3. Linux ホストで USB デバイスを渡したコンテナから `openFPGALoader` と Pico 2 の両方が見えることを確認
4. ホスト側に Python の `harness selftest` を実装
5. `make render` の PNG から CRC を計算し、実機の `FRAME_CRC` と比較する `make hw-test` を作る
