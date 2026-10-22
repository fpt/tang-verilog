# 開発計画 — SDRAM フレームバッファの tiny-GPU

Tang Nano 20K のパッケージ内 SDRAM にフレームバッファを置き、図形 (矩形・線)・スプライト・背景をコマンドで描く小さな GPU を作る計画です。
開発は [HARNESS.md](HARNESS.md) のハーネス (RP2 + HDMI キャプチャ) で検証しながら進めます。

[ARCHITECTURE.md](ARCHITECTURE.md) の「フレームバッファを持たず、走査しながら生成する」方針からの転換です。
「レジスタバスの先に VDP がある」「SPI はレジスタバスへの変換器」「RP2 は描画しない」はそのまま引き継ぎます。
ARCHITECTURE.md は M3 (SDRAM) が通ったので書き直しました。

## 方針

1. **RP2 のファームウェアは早い段階で固定する。** UF2 の書き込みが面倒なので、RP2 は「状態を見る + SPI を素通しする」だけのブリッジにして、
   GPU のレジスタやコマンドの意味はすべてホスト側 (Python) に置く。GPU を作り変えても RP2 を書き直さずに済む
2. **画は 3 通りで突き合わせる。** 同じシナリオ (コマンド列) から
   (a) Python の参照モデル、(b) Verilator の RTL シミュレーション、(c) 実機を動かし、
   (a)=(b) はピクセル完全一致、(a)=(c) は `FRAME_CRC` で完全一致、HDMI キャプチャは許容誤差付きで比べる
3. **リスクの大きい SDRAM を先に確かめる。** → M3 で確認済み。オープンソースのツールチェーンでパッケージ内 SDRAM が動いた (後述)
4. **ハーネスの線は「Low = 何もしていない」にそろえる。** RP2 は毎回ピンを入力 + プルダウンに戻すので、
   プルダウンされた状態が「リセット中」や「選択中」にならないようにする (M0 で CS_N / RESET_N の極性を変える)

## 全体像

```text
 ホスト (macOS)                         RP2 (ブリッジ, 固定)            Tang Nano 20K
┌────────────────────────┐   USB    ┌──────────────────┐  SPI   ┌──────────────────────────────┐
│ harness.py             ├─────────►│ status / spi /   ├───────►│ SPI slave → register bus     │
│  シナリオ → SPI 列      │  CDC     │ reset / wiretest │  GPIO  │   ├ regs (ID, STATUS, CRC…)  │
│  参照モデル (Python)    │          └──────────────────┘◄───────┤   └ command FIFO → GPU core  │
│  比較 → JSON + 差分 PNG │                                       │        │  (clear/rect/line/ │
│                        │   USB-JTAG (openFPGALoader)          │        │   blit/tilemap)    │
│                        ├─────────────────────────────────────►│        ▼                    │
│                        │                                       │   SDRAM 8MiB ◄─► arbiter    │
│ ffmpeg (avfoundation)  │◄──────── HDMI キャプチャ (MS2109) ◄───┤        │                    │
└────────────────────────┘                                       │   line buffer → DVI → HDMI   │
                                                                  └──────────────────────────────┘
```

## 決めること (初期値)

| 項目 | 初期値 | 理由 |
| --- | --- | --- |
| 論理解像度 | 320x240、縦横 2 倍で 640x480 に出す | 帯域とメモリが 1/4 で済み、レトロ機らしい。後で 640x480 にも上げられる |
| ピクセル形式 | RGB565 (2 ピクセル / 32bit ワード) | SDRAM が 32bit 幅。パレットは後で |
| フレームバッファ | 2 枚 (表示用と描画用)、VBLANK で切り替え | ちらつき防止 |
| メモリ配置 | 1 ライン = 1KiB (320 ピクセル + 余り) = SDRAM の 1 行 | 1 ラインを 1 回の行アクティブ + バーストで読める |
| GPU / SDRAM クロック | 63MHz (既存の 126MHz を CLKDIV /2) | まずは余裕のある速さで。足りなければ別の rPLL で上げる |
| SPI | 最初 1MHz、M1 で 4〜8MHz まで確認 | FPGA 側は 63MHz で SCK をサンプリングするので上限は 15MHz 程度 |

### メモリ配置

パッケージ内 SDRAM は 64Mbit (2M ワード x 32bit、4 バンク x 2048 行 x 256 列)。

| アドレス (バイト) | 大きさ | 用途 |
| --- | --- | --- |
| `0x000000` | 256KiB | フレームバッファ 0 (240 ライン x 1KiB) |
| `0x040000` | 256KiB | フレームバッファ 1 |
| `0x080000` | 512KiB | 予備 (640x480 にするとき用) |
| `0x100000`〜 | 7MiB | アセット (スプライト・タイル・背景画像)。ホストが `UPLOAD` で書き込む |

### 帯域の見積もり

| 用途 | 帯域 |
| --- | --- |
| SDRAM のピーク (63MHz x 4B) | 252MB/s (実効はその半分程度と見る) |
| 表示の読み出し (320x240 x 2B x 60Hz、1 ラインを 2 回表示) | 9.2MB/s |
| 全画面クリア 1 回 | 150KiB / フレーム |
| 16x16 スプライト 64 枚 (読み + 書き) | 64KiB / フレーム |

1 フレームあたり全画面の塗りつぶし 10 回分以上の余裕があります。表示の読み出しを最優先にし、
間に合わなかったら `UNDERFLOW_COUNT` を数えて見えるようにします (調査が楽になる)。

## RP2 ブリッジファームウェア

`harness/firmware/` の配線テストを発展させ、次のコマンドだけを持つブリッジにします。1 行 1 コマンドのテキスト、応答は 1 行 JSON。

| コマンド | 内容 |
| --- | --- |
| `ping` | ファームウェア名・版・ボード |
| `status` | 全ハーネスピンの値、HEARTBEAT / VSYNC の実測周波数、IRQ・ERROR、ready 判定、SPI 周波数、各種カウンタ |
| `spi <hex>` | CS を立てて送受信し、受信を hex で返す (1 行 4KiB まで)。ready でなければ何も駆動せずエラー |
| `freq <hz>` | SPI の周波数 |
| `reset <ms>` | RESET を指定時間 High にする |
| `irqwait <ms>` | IRQ (VBLANK) の立ち上がりを待つ。フレームに同期した操作用 |
| `wiretest` | 今の配線テスト (FPGA に `harness_probe` を入れたとき) |

- レジスタの番地もコマンドの形式も知らない。ホストが組み立てた SPI のバイト列を流すだけ
- **ready**: HEARTBEAT が直近 100ms 以内にトグルしているときだけ SPI 線を駆動する。FPGA の書き込み中や、別の設計が入っているときは駆動しない
- **ピンの扱い**: トランザクションの間だけ SPI 機能にし、終わったら入力 + プルダウンに戻す (配線テストと同じ約束)
- 一度書き込んだら、原則として書き換えない。書き換えるのはブリッジ自体のバグや、新しい観測機能が必要になったときだけ

### ハーネスの線の極性を変える (M0)

RP2 がピンを手放すとプルダウンで Low になるので、Low が「何もしていない」になるようにします。

| 今 | 変更後 | 理由 |
| --- | --- | --- |
| `CS_N` (負論理) | `CS` (正論理) | プルダウン中に FPGA が「選択された」と思わないように |
| `RESET_N` (負論理) | `RESET` (正論理) | プルダウン中に FPGA がリセットされ続けないように |
| `IRQ_N` (負論理) | `IRQ` (正論理) | 合わせておく |

CS はもともと GPIO で動かしているので、RP2 のハードウェア SPI の都合はありません。`harness/pins.json`・HARNESS.md・WIRING.md を合わせて直します。

## ホスト側

`tools/harness/` に Python (標準ライブラリだけ) で作ります。USB を使うので macOS のホストで直接動かします
(Docker Desktop から USB が見えないため。`openFPGALoader` と同じ扱いの例外として CLAUDE.md に書き足す)。

| サブコマンド | 内容 |
| --- | --- |
| `harness status` | ブリッジの `status` |
| `harness reg read/write` | レジスタの読み書き (レジスタマップはここで持つ) |
| `harness prog <fs>` | `make pincheck` を通してから `openFPGALoader` で SRAM に書き込む |
| `harness selftest` | HARNESS.md の selftest (ID・SCRATCH 往復・HEARTBEAT・VSYNC・RESET) |
| `harness run <scenario.json>` | シナリオを SPI 列にして実行し、`FRAME_CRC` を読み、キャプチャし、参照と比べる |
| `harness capture` | `ffmpeg -f avfoundation` で 1 フレームを rgb24 の生データで取り込む |

- **シナリオ** (`scenarios/*.json`): GPU コマンドの列。同じファイルを参照モデル・Verilator テストベンチ・実機が読む
- **参照モデル** (`tools/harness/gpu_model.py`): コマンドを解釈して 320x240 の画像と、出力 640x480 の CRC32 を作る
- 出力は 1 つの JSON (各段階の pass/fail・CRC・差分の割合) と差分 PNG。エージェントはこれだけ読めばよい
- `make hw-test SCENARIO=...` で、ビットストリーム・render (Docker) → `harness run` (ホスト) を 1 回で回す

### キャプチャとの比較

MS2109 は YUV (4:2:2、リミテッドレンジ) を通るので、色が少しずれ、横方向に色がにじみます
(HDMI のテストパターンを取り込んだとき、`#303040` が暗く写っていた)。そこで:

- 正しさの判定は `FRAME_CRC` (完全一致) で行い、キャプチャは「実際に画面に出ているか」の確認に使う
- **実装 (M2)**: [`tools/harness/imgcmp.py`](../tools/harness/imgcmp.py)。`harness.py frametest` から使う
  - 640x480 のまま取り込める (MS2109 が 640x480 を出せる)。最初の 5 フレームは捨てる
  - 比べるたびに、チャンネルごとの「キャプチャ ≒ 倍率 x 参照 + オフセット」を最小二乗で求めて補正する (実測は倍率 0.97〜1.01、オフセット -6〜+1)
  - 色の境目から横 2 ピクセル・縦 1 ライン以内は必ずにじむので割合から外し、別に数える。それ以外で「補正後の差が 40 以内のピクセルが 99% 以上」を合格にする
  - 差分 PNG: 合っているところは暗い灰色、境目のにじみは黄色、それ以外の不一致は赤
  - 結果 (テストパターン): 境目以外は 100% 一致、境目 (画面の 19%) は 92.5% 一致
- キャプチャデバイスは番号ではなく名前 (`-i "USB3. 0 capture:none"`、環境変数 `HARNESS_CAPTURE` で変更) で選ぶ。
  番号は一覧と実際に開くときで変わることがあり、別のカメラを開いてしまった

## マイルストーン

各段階の「完了条件」は、ハーネスで自動的に確かめられる形にします。

| # | 内容 | 完了条件 |
| --- | --- | --- |
| M0 ✅ | ブリッジファームウェアとホストツール。ハーネスの線の極性変更 | `harness status` が読める。`harness_probe` を入れて `wiretest` が通る。ready でないとき `spi` が何も駆動しない |
| M1 ✅ | SPI スレーブ + レジスタ (`ID` `VERSION` `SCRATCH` `STATUS` `CONTROL` `FRAME_COUNT`)、HEARTBEAT・VSYNC・IRQ の出力。今の HDMI テストパターンに載せる | `harness selftest` が通る。SCRATCH の往復 10,000 回が 1 / 4 / 8MHz でエラー 0 |
| M2 ✅ | `FRAME_CRC`、`CONTROL` のアニメーション停止、キャプチャ比較の仕組み | テストパターンで Verilator の CRC と実機の `FRAME_CRC` が一致。キャプチャが補正後に 99% 一致 |
| M3 ✅ | **SDRAM**: 制約 (内部 I/O 位置)、コントローラ (初期化・リフレッシュ・1 ワードずつの読み書き。バーストは M4 へ)、FPGA 内のメモリテスト (BIST) とレジスタ経由の読み書き | 8MiB 全域の BIST (アドレスごとに違うパターンとその反転) が 10 回連続で通る。SPI 経由の読み書きも一致 |
| M4 | フレームバッファ表示: SDRAM のバースト読み出し → ライン バッファ → DVI (320x240 を 2 倍)。`UPLOAD` で画像を書き込む | ホストから送った画像が `FRAME_CRC` 一致・キャプチャ一致。`UNDERFLOW_COUNT` が 0 |
| M5 | コマンド FIFO と `CLEAR` `FILL_RECT` `SWAP` (VBLANK で表示面切り替え) | 3 通りの比較が一致。`STATUS` の busy / FIFO 残量が正しい |
| M6 | `DRAW_LINE` (ブレゼンハム)、`POINT`、クリップ矩形 | 3 通りの比較が一致 (画面外・端・傾きの全方向を含むシナリオ) |
| M7 | スプライト: `BLIT` (アセット領域 → フレームバッファ、透過色、左右・上下反転) | 3 通りの比較が一致。16x16 を 64 枚、60fps で `UNDERFLOW_COUNT` 0 |
| M8 | 背景: `DRAW_TILEMAP` (タイルマップ + タイルから描く、スクロール付き) と大きい画像の `BLIT` | 3 通りの比較が一致。スクロールのシナリオで毎フレームの CRC が一致 |
| M9 | デモ (背景スクロール + スプライト + 図形) と Flash への書き込み | ホストのスクリプトだけで 60fps のデモが動く |

その先の候補: 塗りつぶし三角形、パレット (8bpp) モード、半透明、640x480 表示、本番ホスト (RP2350) からの直接駆動。

### M2 の結果 ✅

- [`rtl/vdp/frame_crc.sv`](../rtl/vdp/frame_crc.sv): 表示ピクセルを R, G, B の順のバイト列とした標準の CRC-32 (`zlib.crc32` と同じ値)。
  VBLANK でラッチし、`FRAME_CRC` (`0x05`〜`0x08`) で読む。`0x05` を読んだ時点の値を残りの 3 バイト用に取っておくので、4 バイトが同じフレームの値になる
- `CONTROL` bit1 (アニメーション停止) でスプライトをリセット位置に止めると、毎フレーム同じ画面になる
- `make render FREEZE=1` が参照画像と、Python で計算した各フレームの CRC (`build/render_frozen/frames.json`) を出す
- 実機の `FRAME_CRC` = `0x82f897f9` が参照と完全に一致。止めないと毎フレーム変わる
- `harness.py frametest`: CRC の比較とキャプチャの比較を 1 回で行う (2 秒ほど)。違う参照を渡すと不合格になることも確認

### M3 (SDRAM) の結果 ✅

オープンソースのツールチェーンでパッケージ内 SDRAM が使えることを確かめました。BSRAM に切り替える代わりの案は不要になりました。

- apicula の [doc/sdram.md](https://github.com/YosysHQ/apicula/blob/master/doc/sdram.md) にある内部 I/O の名前 (`O_sdram_clk` = `IOR11B` など 55 本) を
  cst の `IO_LOC` にそのまま書けば、nextpnr-himbaechel が指定どおりに配置し、gowin_pack もビットストリームにできる
- コントローラ ([`sdram_ctrl.sv`](../rtl/vdp/sdram_ctrl.sv)): 63MHz、CL2、1 ワードずつ (オートプリチャージ付き)。SDRAM のクロックは逆相 (ODDR)
- 読み出しの取り込み位置を半周期単位で変えて BIST を回すと、実機では 5〜7 が合格、2〜4 が不合格 (データがまだ来ていない)。
  シミュレーションのモデル (4〜5 が合格) より 1 半周期ほど遅い。既定は真ん中の 6。
  7 は SDRAM が出し終えたあとなので、浮いたバスが値を保っているだけと考えられる。もっと詰めたいときは rPLL の位相調整 (PSDA) で SDRAM のクロックをずらす
- 8MiB 全域の BIST (パターンとその反転を書いて読む、1 回 1.2 秒) が 10 回連続で合格。1 回が 64ms より十分長いので、リフレッシュも効いている
- `harness.py memtest` (取り込み位置ごとの BIST)、`harness.py mem read/write` (1 ワード)

### M3 で作ったもの

| ファイル | 内容 |
| --- | --- |
| `rtl/vdp/sdram_ctrl.sv` | SDRAM コントローラ (初期化・リフレッシュ・1 ワード読み書き・取り込み位置の切り替え) |
| `rtl/vdp/mem_test.sv` | BIST とレジスタ経由の読み書き (レジスタ `0x10`〜`0x2F`) |
| `sim/sdram_model.sv` | SDRAM の振る舞いモデル (タイミング違反・リフレッシュ間隔も検査) |
| `constraints/tangnano20k.cst` | SDRAM の 55 本 |

### FPGA 側の構成

`rtl/vdp/` (ベンダ非依存) に置くもの: SPI スレーブ、レジスタ、コマンド FIFO、GPU コア (描画エンジン)、SDRAM コントローラ、
アービタ、ライン バッファ、CRC。`rtl/gowin/` には PLL・CLKDIV・DVI 出力と、SDRAM のクロック出力 (逆相) だけを置きます。

| クロックドメイン | 周波数 | 中身 |
| --- | --- | --- |
| `clk_sys` | 63MHz | SPI スレーブ (SCK をサンプリング)、レジスタ、GPU、SDRAM |
| `clk_pix` | 25.2MHz | 表示タイミング、ライン バッファの読み出し、CRC、DVI |

ドメイン間は、ライン バッファ (デュアルポート BSRAM) と「次のラインを読んで」のトグル同期だけにします。
`rtl/vdp/` に足したモジュールには、いつも通り `sim/tb_<名前>.sv` を書きます。

### GPU コマンド (初版の案)

コマンド FIFO にはレジスタ `CMD` (1 アドレス) へ連続で書き込みます。1 コマンドは 32bit ワードの並び。

| コマンド | 引数 | 段階 |
| --- | --- | --- |
| `CLEAR` | color | M5 |
| `FILL_RECT` | x, y, w, h, color | M5 |
| `SWAP` | — (次の VBLANK で表示面を切り替え、終わるまで後続を待たせる) | M5 |
| `CLIP` | x0, y0, x1, y1 | M6 |
| `POINT` / `DRAW_LINE` | x0, y0, (x1, y1,) color | M6 |
| `UPLOAD` | addr, len, data… | M4 |
| `BLIT` | src_addr, src_stride, x, y, w, h, flags (透過・反転), key_color | M7 |
| `DRAW_TILEMAP` | map_addr, tile_addr, cols, rows, scroll_x, scroll_y | M8 |

## 進める順番

```text
M0 ブリッジ + ホストツール ─► M1 SPI + レジスタ ─► M2 CRC + キャプチャ比較 ─┐
                                                                          ├─► M4 表示 ─► M5 ─► M6 ─► M7 ─► M8 ─► M9
M3 SDRAM ✅ (オープンソースのツールで動いた) ──────────────────────────┘
```

M0〜M2 で「書き込み → 実行 → 確認」のループが回るようになれば、M4 以降はシナリオと参照モデルを足しながら機能を増やしていくだけになります。
