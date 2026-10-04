# tang-verilog

Tang Nano 20K (Gowin GW2AR-18) と RP2350 で、レトロゲーム機の VDP のようなものを作るためのプロジェクトです。

- FPGA 側 (Tang Nano 20K): VDP 本体。今は HDMI (DVI) に 640x480@60Hz の映像を出す
- RP2350 側: ホスト CPU 役。SPI などで VDP にコマンドを送る (予定)

ツールはすべてオープンソースのものを Docker コンテナ内で動かします。ホストに必要なのは Docker と make だけです
(ボードへの書き込みだけは例外です。下の「書き込み」を参照)。

## ドキュメント

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): 設計方針 (レジスタバス、タイル方式の画面生成)
- [docs/WIRING.md](docs/WIRING.md): RP2350 と Tang Nano 20K の配線・SPI ピン割り当て
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): 開発環境の補足

## 状態

- [x] Docker イメージ (`tang-fpga` / `tang-pico`) のビルド
- [x] `make lint` / `make sim` (Icarus Verilog・Verilator とも PASS) / `make render`
- [x] `make bitstream` (`build/top.fs` まで生成)
- [x] `make fw` (`firmware/build/vdp_host.uf2` まで生成)
- [ ] 実機での HDMI 出力・LED・ボタンの確認
- [ ] RP2350 ↔ FPGA 間のインターフェース (SPI など) の設計

## ツール

| 用途 | ツール | 入手元 |
| --- | --- | --- |
| 論理合成 | Yosys + yosys-slang プラグイン (SystemVerilog フロントエンド) | [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) |
| 配置配線 | nextpnr-himbaechel (Gowin) | 同上 |
| ビットストリーム生成 | apicula (`gowin_pack`) | 同上 |
| シミュレーション | Icarus Verilog / Verilator / cocotb | 同上 |
| 書き込み | openFPGALoader | 同上 (ただしコンテナからは USB が使えない) |
| RP2350 ファームウェア | arm-none-eabi-gcc + pico-sdk 2.3.1 + picotool | Debian パッケージ / GitHub |

## セットアップ

```bash
make images
```

`docker/fpga` と `docker/pico` の 2 つのイメージを順番にビルドします (`make image-fpga` / `make image-pico` で個別にも可)。
FPGA 側は OSS CAD Suite (約 1GB) をダウンロードするので時間がかかります。
開発環境についての補足は [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) を参照してください。

### メモリについて

Docker Desktop の割り当てメモリが少ないと、イメージのビルド (特に picotool のコンパイル) でメモリが足りなくなることがあります。
2 つのイメージは並列ではなく 1 つずつビルドしてください。

## 使い方

```bash
make help
```

| コマンド | 内容 |
| --- | --- |
| `make lint` | Verilator で RTL を lint |
| `make sim` | `sim/tb_*.sv` を全部実行 (`SIM=verilator` で Verilator を使う)。VCD は `build/sim/` に出力 |
| `make sim-tb_tmds_encoder` | テストベンチを 1 つだけ実行 |
| `make render` | Verilator で映像出力を回し、各フレームを `build/render/frame_*.png` に保存 |
| `make bitstream` | 合成 → 配置配線 → `build/top.fs` |
| `make prog` / `make flash` | Tang Nano 20K の SRAM / Flash に書き込み |
| `make fw` | RP2350 ファームウェアをビルド (`firmware/build/vdp_host.uf2`) |
| `make shell` / `make shell-pico` | 各コンテナのシェルに入る |
| `make zip` | 別環境へ持っていくためのソース一式を `dist/<ディレクトリ名>.zip` に作成 (ホストの git と zip を使用) |

### 波形を見る

GTKWave は GUI ツールなので、macOS 上の Docker からは簡単には開けません。ローカルに何も入れずに見るなら
[Surfer のブラウザ版](https://app.surfer-project.org/) で `build/sim/*.vcd` を開いてください。

### 書き込み

macOS 上の Docker Desktop のコンテナからは USB デバイスにアクセスできないため、`make prog` だけはホストの `openFPGALoader` を使います。

```bash
brew install openfpgaloader
```

ホストに何も入れたくない場合は、Gowin 公式の Programmer を使う方法もあります。

RP2350 は BOOTSEL ボタンを押しながら USB 接続し、出てきたドライブに `firmware/build/vdp_host.uf2` をコピーすれば書き込めます (ツール不要)。
ボードを変えるときは `make fw PICO_BOARD=<ボード名>`、RISC-V コア (Hazard3) を使うときは `make fw PICO_PLATFORM=rp2350-riscv` です。

## ディレクトリ構成

```
docker/
  fpga/Dockerfile        FPGA ツール (OSS CAD Suite)
  pico/Dockerfile        RP2350 ツール (pico-sdk, picotool)
rtl/
  vdp/                   ベンダ非依存の RTL (シミュレーション可能)
    video_timing.sv      640x480@60Hz のタイミング生成
    vdp_core.sv          VDP コアの雛形 (カラーバー + 市松模様 + 跳ね回る四角)
    tmds_encoder.sv      DVI の TMDS エンコーダ
    vdp_video.sv         タイミング + コアをまとめたもの
  gowin/                 Gowin のプリミティブを使う部分
    dvi_tx.sv            OSER10 + TLVDS_OBUF による DVI 送信
    top.sv               トップ (rPLL 126MHz → CLKDIV /5 → 25.2MHz)
    blackbox/            Gowin プリミティブのブラックボックス定義 (合成専用)
constraints/
  tangnano20k.cst        ピン配置
sim/
  tb_*.sv                テストベンチ (Icarus Verilog / Verilator)
  verilator/render_main.cpp  フレームを画像に書き出すシミュレータ
firmware/                RP2350 ファームウェア (pico-sdk)
scripts/
  ppm2png.py             PPM → PNG 変換
```

## ハードウェアメモ (Tang Nano 20K)

| 信号 | ピン |
| --- | --- |
| 27MHz クロック | 4 |
| ボタン S1 / S2 (押下で 1) | 88 / 87 |
| LED0〜5 (負論理) | 15〜20 |
| HDMI CLK / D0 / D1 / D2 (P,N) | 33,34 / 35,36 / 37,38 / 39,40 |

- デバイス: `GW2AR-LV18QN88C8/I7` (nextpnr の family は `GW2A-18C`)
- ピクセルクロックは 25.2MHz で、規格値の 25.175MHz からわずかにずれています (たいていのモニタは問題なく表示します)
