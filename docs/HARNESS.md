# AI 開発ハーネス — Raspberry Pi 3B+ ↔ Tang Nano 20K

Tang Nano 20K 上の VDP を、Raspberry Pi 3B+ から書き込み・操作・観測できるようにするためのハーネスの設計です。
[ARCHITECTURE.md](ARCHITECTURE.md) の「レジスタバスのマスタは差し替え可能」という方針に沿って、
Pi 3B+ を **RP2350 の代わりにレジスタバスを叩くマスタ + 観測係** として扱います。
RP2350 との最小配線は [WIRING.md](WIRING.md) を参照してください。

## 目的

- Claude Code などのエージェントが、人手を介さずに **ビットストリーム生成 → 書き込み → コマンド実行 → 結果確認** の 1 周を回せるようにする
- 「ハーネスが壊れているのか、設計が壊れているのか」をすぐ切り分けられるように、ハーネス自身の自己診断を持つ
- RP2350 版と同じ SPI プロトコルを使い、ホストを Pi から RP2350 に差し替えても VDP 側を変えずに済むようにする
- 将来 SDRAM を使った簡易 GPU に発展させても、ハーネス (レジスタバス + コマンド FIFO + 観測線) を作り直さずに済むようにする

## 役割分担

| 役割 | 担当 | 内容 |
| --- | --- | --- |
| ビルド | Mac (Docker) | 合成・配置配線・シミュレーション・`make render` による参照画像の生成。今まで通り |
| 実行・観測 | Pi 3B+ | 書き込み・SPI 実行・GPIO 監視・UART 受信・キャプチャ・参照との比較。Pi 上では合成しない (1GB RAM では nextpnr が厳しい) |
| 判断 | エージェント | Mac から `ssh pi harness ...` を呼び、返ってきた JSON と差分画像を読んで次の修正を決める |

```text
Mac: make bitstream / make render ──scp──► Pi: harness prog → scenario → capture → compare → JSON
                                                   │USB         │SPI+GPIO   │USB or CSI
                                                   ▼            ▼           ▼
                                                 Tang Nano 20K ──HDMI──► キャプチャ
```

## できること

### BL616 (オンボードデバッガ) 経由

Tang Nano 20K の BL616 は FPGA の JTAG に基板内部でつながっています。表面の JTAG パッドは外部デバッガ用の予備なので、**パッドは使いません**。
Pi に USB-C で挿すと FT2232 互換のデバイスとして見え、次のことができます。

| 機能 | Pi 3B+ から | 用途 |
| --- | --- | --- |
| USB-JTAG | ○ `openFPGALoader -b tangnano20k` | SRAM / Flash 書き込み、`--detect` でチップ ID 確認、書き込み後のステータス確認 |
| USB-UART (FPGA pin 69 = TX, 70 = RX) | ○ `/dev/ttyUSB1` 相当 | FPGA からのデバッグ出力。SPI を介さない独立した観測経路 |
| USB-SPI | △ | BL616 がスレーブ、FPGA がマスタという向きなので今回は使わない |
| GAO (Gowin のロジックアナライザ) | × | Gowin EDA 専用。オープンソースツールチェーンでは JTAG で波形を覗く手段はない |

JTAG で内部を覗くのは諦め、**UART を FPGA 側の自己申告チャネル**、**GPIO を Pi 側の独立観測チャネル** として使い分けます。

### GPIO / SPI 経由

- SPI でレジスタバスを駆動し、VDP にコマンドを送る (RP2350 と同じプロトコル)
- VSYNC / HEARTBEAT / ERROR / IRQ を Pi の GPIO で直接観測する
- オンボード LED (ヘッダに出ている) を Pi から読む
- Pi から VDP をリセットする

### 画面の確認

| 段階 | 手段 | 精度 | 費用 |
| --- | --- | --- | --- |
| 1 | FPGA 内部で 1 フレームの CRC を計算し、`FRAME_CRC` レジスタで読む | ピクセル完全一致 | 0 円 |
| 2 | USB HDMI キャプチャ (MS2109 系) を Pi に挿す | YUV 変換を通るので許容誤差付き比較 | 1,000〜2,000 円 |
| 3 | HDMI→CSI-2 ブリッジ (TC358743: Geekworm C790, Auvidea B101 など) | RGB 非圧縮、ピクセルそのまま | 5,000〜8,000 円 |

1 → 2 の順で進め、3 は「2 の色誤差で判定できないケースが実際に出てから」で十分です。

## 配線

Pi 3B+ も Tang Nano 20K も I/O は 3.3V なので、レベル変換なしで直結できます。
Tang Nano 20K は Pi の USB から給電し、**3V3 同士・5V 同士はつながない** (GND だけ共通にする)。Pi の電源アダプタは 2.5A 以上を推奨。

### ピン割り当て

| 信号 | 向き | Tang Nano ピン | Pi GPIO (BCM) | Pi 物理ピン | 備考 |
| --- | --- | --- | --- | --- | --- |
| SCK | Pi → FPGA | 73 | GPIO11 (SPI0 SCLK) | 23 | WIRING.md と同じ |
| COPI | Pi → FPGA | 74 | GPIO10 (SPI0 MOSI) | 19 | 同上 |
| CIPO | FPGA → Pi | 75 | GPIO9 (SPI0 MISO) | 21 | 同上 |
| CS_N | Pi → FPGA | 72 | GPIO8 (SPI0 CE0) | 24 | spidev はトランザクション中 CE0 を下げたままにするので HW CS でよい |
| IRQ_N | FPGA → Pi | 71 | GPIO25 | 22 | VBLANK 割り込み |
| VSYNC | FPGA → Pi | 42 | GPIO23 | 16 | `video_timing` の vsync をそのまま出す |
| HEARTBEAT | FPGA → Pi | 41 | GPIO24 | 18 | フレームごとにトグル (30Hz 方形波) |
| ERROR | FPGA → Pi | 48 | GPIO27 | 13 | コマンド FIFO あふれなど。将来は SDRAM 初期化失敗も |
| RESET_N | Pi → FPGA | 86 | GPIO22 | 15 | Pi から VDP をリセット |
| LED0〜5 | FPGA → Pi | 15〜20 | GPIO5, 6, 12, 13, 16, 26 | 29, 31, 32, 33, 36, 37 | 読むだけ。負論理・プルアップ付き |
| GND | — | GND ×2 | GND | 6, 25 | SCK の近くと LED 束の近くに 1 本ずつ |

Tang Nano 側のピン選定:

- 73, 74, 75, 72, 71: WIRING.md と同じ (どのオンボード部品ともつながっていない)
- 42, 41, 48: 40 ピン LCD コネクタと共用。LCD を使わない前提で借りる
- 86: WIRING.md で予備としていたピン。RESET に使う
- 15〜20: オンボード LED。ヘッダにも出ているので FPGA 側のピンを追加消費せずに読める
- 76: GCLK 入力なので引き続き温存
- 69, 70: BL616 の UART。ヘッダには出ていないので配線不要

### 配線図

```text
  Raspberry Pi 3B+                              Tang Nano 20K
  (物理ピン / BCM)                              (FPGA ピン)

  23  GPIO11 SCK      ──────────────────────►  73
  19  GPIO10 COPI     ──────────────────────►  74
  21  GPIO9  CIPO     ◄──────────────────────  75
  24  GPIO8  CS_N     ──────────────────────►  72
  22  GPIO25 IRQ_N    ◄──────────────────────  71
  16  GPIO23 VSYNC    ◄──────────────────────  42
  18  GPIO24 HEARTBEAT◄──────────────────────  41
  13  GPIO27 ERROR    ◄──────────────────────  48
  15  GPIO22 RESET_N  ──────────────────────►  86
  29  GPIO5  LED0     ◄──────────────────────  15
  31  GPIO6  LED1     ◄──────────────────────  16
  32  GPIO12 LED2     ◄──────────────────────  17
  33  GPIO13 LED3     ◄──────────────────────  18
  36  GPIO16 LED4     ◄──────────────────────  19
  37  GPIO26 LED5     ◄──────────────────────  20
   6  GND             ───────────────────────  GND (左列いちばん下)
  25  GND             ───────────────────────  GND (右列上から 2 本目)

  Pi USB ──USB-C──► Tang Nano 20K (給電 + JTAG + UART)
```

### 直列抵抗

信号線は直結せず、直列抵抗を挟みます。目的は 2 つです。

1. **衝突保護 (主目的)**: エージェントに cst や RTL を触らせる以上、「Pi が出力しているピンを FPGA も出力にしてしまった」は必ず起きます。書き込み中の不定状態やリセット中も含めて、両側が逆の値を押し合ったときに電流を定格内に抑えます
2. **リンギング抑制**: ジャンパ線の反射を減らしてエッジをきれいにします

| 線 | 抵抗 | 理由 |
| --- | --- | --- |
| SCK / COPI / CIPO / CS_N | 100Ω | 速度を出したい線。6MHz までなら 220Ω でも成立する |
| VSYNC / HEARTBEAT / ERROR / IRQ_N / RESET_N / LED0〜5 | 220〜330Ω | 低速なので RC 遅延は気にならず、衝突時 10〜15mA で Pi の GPIO 定格 (16mA) 内 |
| GND | なし | — |

- 抵抗は **ドライバ側 (信号の出口)** に置きます。Pi → FPGA の線は Pi 側、FPGA → Pi の線は Tang Nano 側
- 衝突時の電流は 3.3V ÷ 抵抗値。100Ω で 33mA、220Ω で 15mA、330Ω で 10mA
- 220Ω × 線路容量 50pF (15cm ジャンパ + 入力容量) で時定数 11ns、立ち上がり 25ns 程度。SCK を 10MHz 以上に上げるときに SPI 線を 100Ω へ落とす
- 実装はブレッドボード上で Pi と Tang Nano の間に抵抗を並べる。理想は各ボードのヘッダのすぐ横だが、片端にまとめても実用上は困らない
- 集合抵抗を使うなら **独立型 (アイソレーテッド型)** に限る。よくある SIP の 1 ピン共通型 (バスド型) は片側が全部つながっているので直列には使えない。DIP 16 ピン 8 素子独立型 (Bourns 4116R-2 など) ならブレッドボードに挿して向かい合う 2 ピンが 1 本の抵抗になる。本数は増えるが普通のリード抵抗 15 本でも構わない
- RP2350 に差し替えるときも同じ考え方で配線する

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
- FPGA を書き込み直している間は CIPO / IRQ / 観測線が不定になるので、Pi 側はその間の値を信用しない
- Pi 3B+ の USB 4 ポートとイーサネットは同じ USB2 バスを共有する。キャプチャ中の大きな転送は避ける (ビットストリームは小さいので実用上は問題なし)

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
- LED: SPI 受信回数の下位ビットなどを出しておくと、SPI が届いているかを目でも Pi からも確認できる
- UART (115200 8N1): 起動時にバナー (`VDP v0.1 ok`)、以降はデバッグ出力

### 「FPGA ready」の判定について

READY を「High になったら準備完了」という静的レベルにすると誤判定します。
Gowin FPGA は未コンフィグ時に I/O が弱プルアップになるので、何も書き込んでいない状態でも High に見えることがあるためです。
ready は次の 3 つを合わせて判定します。

1. openFPGALoader の書き込みが成功した (JTAG のステータス)
2. HEARTBEAT が 60Hz でトグルしている (未コンフィグで偶然トグルすることはない)
3. SPI で `ID` が `0x5A`、`SCRATCH` が往復する

## Pi 側のセットアップ

- Raspberry Pi OS (Bookworm, 64bit, Lite)
- `sudo apt install openfpgaloader python3-spidev python3-lgpio ffmpeg v4l-utils`
- `raspi-config` で SPI を有効化
- udev ルール (BL616 は VID `0403` / PID `6010` として見える):

  ```text
  SUBSYSTEM=="usb", ATTR{idVendor}=="0403", ATTR{idProduct}=="6010", MODE="0666"
  ```

- 古い BL616 ファームウェアでは UART のボーレートが 4 倍ずれる既知の問題があります。文字化けしたらファームウェア更新を疑ってください
- Mac から `ssh pi` できるように鍵を配置しておく

## 検証方法

### `harness selftest`

エージェントが最初に呼ぶ 1 コマンドです。各項目を pass/fail の JSON で返し、失敗した段階で止めます。

| # | 項目 | 失敗したときの意味 |
| --- | --- | --- |
| 1 | `openFPGALoader --detect` で GW2AR-18 が見える | USB / udev / ケーブル |
| 2 | `top.fs` を SRAM に書き込み、終了コード 0 | ビットストリーム破損、BL616 |
| 3 | HEARTBEAT を 200ms 観測し 25〜35Hz | PLL ロック失敗、タイミング生成が動いていない |
| 4 | VSYNC のエッジ間隔が 16.6ms ±5% | `video_timing` の異常 |
| 5 | `ID` = `0x5A`、`SCRATCH` に乱数を書いて読み返し、1MHz で 100 往復してエラー 0 | 配線か SPI スレーブ |
| 6 | UART に起動バナーが出ている | UART TX、リセット系 |
| 7 | LED0〜5 の現在値を報告 | (情報のみ) |
| 8 | RESET_N を落とすと HEARTBEAT が止まり、戻すと再開する | リセット配線 |

### 画面の検証

- `make render` で出した `build/render/frame_N.png` と同じ CRC32 を Python で計算し、実機の `FRAME_CRC` と比較する (段階 1)
- HDMI キャプチャがある場合は `ffmpeg -f v4l2 -i /dev/video0 -frames 1 out.png` で取り込み、参照 PNG と許容誤差付きで比較して差分画像を出す (段階 2)
- どちらも `CONTROL` のアニメーション停止ビットを立て、`FRAME_COUNT` を読んでから取り込む

### シナリオ

SPI コマンド列を YAML/JSON で書き、同じファイルを以下の 3 つで実行できるようにします。

- Pi (Python / spidev)
- RP2350 (ファームウェア)
- Verilator テストベンチ (`make render` の入力)

エージェントはシナリオを書き足すだけでよくなり、RP2350 移行時の差分も最小になります。

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
  ├─ make bitstream              (Mac, Docker)
  ├─ make render SCENARIO=...    (Mac, 参照画像と期待 CRC)
  ├─ scp build/top.fs scenarios/ pi:
  └─ ssh pi harness run
       ├─ selftest (短縮版: 1, 3, 5 のみ)
       ├─ prog
       ├─ scenario 実行
       ├─ FRAME_CRC 読み出し / キャプチャ
       ├─ compare → 差分 PNG
       └─ JSON 出力
```

- 失敗時にエージェントが読むのは JSON と差分画像だけにする
- タイムアウトと復旧: FPGA が固まったら RESET_N → 効かなければ USB 経由で再書き込み (SRAM 書き込みなので再起動相当) → それでもだめなら `uhubctl` で USB 給電を落とす
- `harness` は Pi 上の小さな Python CLI として実装し、`prog` / `spi` / `gpio` / `uart` / `capture` / `compare` / `selftest` / `run` のサブコマンドを持たせる

## その後の改善案

- **HDMI→CSI-2 ブリッジ**: 色誤差なしの比較が必要になったら。Pi 3B+ でも `tc358743` オーバーレイ + v4l2 で動く。EDID は自分で書き込む
- **USB 給電の自動制御**: `uhubctl` で電源からの完全リセット。Pi 3B+ はポート個別ではなく全ポート一括になるので、キャプチャデバイスを同じ Pi につなぐ場合は注意
- **MCP サーバ化**: `ssh pi harness ...` を MCP サーバとして包み、エージェントから直接ツールとして呼べるようにする
- **RP2350 への移行**: Pi 版と RP2350 版で SPI プロトコルを完全に同一に保ち、`firmware/main.c` と Pi 側 Python を同じ仕様書から書く。移行後も Pi は観測係 (GPIO / UART / キャプチャ) として残せる
- **SDRAM / 簡易 GPU 化**: Tang Nano 20K の 64Mbit SDRAM はパッケージ内蔵でヘッダに出ていないため、配線はこのまま。ホスト側インターフェースは「レジスタバス + コマンド FIFO」のまま維持し、SDRAM 初期化失敗を `ERROR` と `STATUS` に載せる
- **UART の活用**: FPGA 内のレジスタダンプや FIFO 状態を UART で吐き、Pi 側でログとして残す。JTAG で波形を覗けない分をここで補う
- **フレーム比較の強化**: CRC だけでなく、タイル単位のハッシュを読めるようにして「どのタイルがずれたか」まで FPGA 側で特定できるようにする

## 最初の一歩

機材を買う前に閉ループが回り始める順番:

1. `ID` / `SCRATCH` / `FRAME_CRC` レジスタと `heartbeat` 出力を RTL に追加
2. Pi 側に Python の SPI クライアントと `selftest` を実装
3. `make render` の PNG から CRC を計算し、実機の `FRAME_CRC` と比較する `make hw-test` を作る
