# CLAUDE.md

Tang Nano 20K (FPGA, VDP 本体) + RP2350 (ホスト CPU) でレトロゲーム機風の VDP を作るプロジェクト。
詳細と現在の状態は README.md を参照。

## 前提

- ツールはすべて Docker で動かす。ホストにツールをインストールしない (ボードへの書き込み用の `openFPGALoader` だけは例外)
- オープンソースのツールだけを使う (Gowin EDA は使わない)
- 操作は `Makefile` を通す。新しい処理を足すときも、コンテナ内で動く Make ターゲットとして追加する
- ホストは Apple Silicon の macOS + Docker Desktop。メモリに余裕がないので、重い `docker build` は並列に走らせない
- 社内ネットワークは TLS が中継される。プロキシの CA は `make certs.pem` が `~/.zscaler/certs.pem` からコピーし、
  BuildKit secret (`id=ca_cert`) で渡す (../chromedp-container-mcp と同じ方式)。
  Dockerfile で HTTPS を使うステップは `RUN --mount=type=secret,id=ca_cert,required=false` で受け取り、
  そのステップ内だけ `CURL_CA_BUNDLE` / `GIT_SSL_CAINFO` に渡す。証明書をイメージのレイヤに残したりコミットしたりしない

## RTL の方針

- SystemVerilog (`.sv`) で書く。合成は yosys-slang (`yosys -m slang` の `read_slang`)、シミュレーションは Icarus Verilog と Verilator の両方で通る書き方にする
  - Yosys 標準の `read_verilog -sv` は関数内の `return` などを読めないので使わない
  - Icarus Verilog は `@(posedge clk iff ...)` や、ブロック途中での `automatic` 変数宣言に対応していない (テストベンチで注意)
- Gowin プリミティブを新たに使うときは `rtl/gowin/blackbox/gowin_prims.sv` にブラックボックス定義を足す (read_slang はパラメータ付きの未知モジュールを受け付けないため)
- Tang Nano 20K の HDMI ピンは TLVDS (`TLVDS_OBUF`, `IO_TYPE=LVDS25`, p/n を個別に制約)。`synth_gowin` には `-family gw2a` が必要。迷ったら apicula の `examples/` (特に `tangnano20k.cst`, `DVI/`) を参照する
- `rtl/vdp/` はベンダ非依存に保つ。Gowin のプリミティブ (rPLL, CLKDIV, OSER10, TLVDS_OBUF など) は `rtl/gowin/` にだけ置く
- `rtl/vdp/` にモジュールを足したら `sim/tb_<名前>.sv` にテストベンチを書く。テストベンチは成功時に `PASS:`、失敗時に `FAIL:` を出力し、VCD は `build/sim/` に出す
- 映像まわりを変えたら `make render` で PNG を出し、見た目を確認する

## よく使うコマンド

```bash
make lint
make sim
make render
make bitstream
make fw
```
