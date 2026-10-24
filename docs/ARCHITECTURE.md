# アーキテクチャ

Tang Nano 20K を VDP (小さな GPU) 本体、RP2 (RP2350 / RP2040) をホスト CPU とする構成の設計方針と、今の実装の姿をまとめます。
開発の段階と今後の予定は [GPU_PLAN.md](GPU_PLAN.md)、ハーネス (検証用の RP2 + HDMI キャプチャ) は [HARNESS.md](HARNESS.md) を参照してください。

## 方針

1. **通信方式より先に「CPU から VDP がどう見えるか」(レジスタインターフェース) を決める**
2. **SPI 受信ロジックと VDP 本体を直接結びつけない。** SPI は「レジスタバスへの変換器」として扱う
3. **パッケージ内 SDRAM にフレームバッファを置き、コマンドで描く。** 図形・スプライト・背景を GPU が SDRAM に描き、表示回路が読み出して出す
   (当初はフレームバッファを持たないタイル方式の予定だったが、M3 で SDRAM がオープンソースのツールで使えると確かめたので切り替えた)
4. **高速な処理は FPGA 内に閉じ込め、外部との境界は低速にする。** RP2 は描画せず、コマンドを送るだけ

## 全体像

```text
RP2 ──SPI──► spi_slave ──► register bus ──┬─► vdp_regs   (ID, STATUS, CONTROL, FRAME_COUNT, FRAME_CRC, SCRATCH)  ✅ M1, M2
                                          ├─► mem_test   (SDRAM の BIST、1 ワード読み書き、クロックの位相)        ✅ M3
                                          └─► gpu        (コマンド FIFO → CLEAR / FILL_RECT / SWAP / UPLOAD     ✅ M5
                                                │                 / POINT / DRAW_LINE / CLIP            ✅ M6
                                                │                 / BLIT)                               ✅ M7
                                                │                 8bpp の面と BLIT4 (4bpp → 8bpp)        ✅ K1
                                                │                                       (TILEMAP は M8)
                       sdram_ctrl ◄── sdram_arb ◄┴── line_compositor (ラインごとに背景色 + ビットマップ レイヤ        ✅ M4, E1
                                                         + タイル レイヤ (VRAM 64KiB・パレット 512 色、BSRAM) ✅ E2
                                                         + スプライト (OAM 128 個、ライン上限)            ✅ E3
                                                         + 面 B・ウィンドウ・横スクロールの表            ✅ E4
                                                         + 8bpp のビットマップ (パレット 0..255)         ✅ K1
                                                         を順位付きの作業ラインで合成 → 320x240 を 640x480 で表示) ✅ E2.5
                          │           (表示 > GPU > メモリテスト)
                 パッケージ内 SDRAM 8MiB
```

今の HDMI 用ビットストリーム (`make bitstream`) には、映像 (カラーバーのテストパターンか、SDRAM のフレームバッファ)・SPI スレーブ・
レジスタ・SDRAM のテストとアップロードが入っています。

## クロック

| クロック | 周波数 | 作り方 | 中身 |
| --- | --- | --- | --- |
| `clk_ser` | 126MHz | rPLL | DVI のシリアライザ (OSER10) |
| `clk_pix` | 25.2MHz | CLKDIV /5 | 表示タイミング、テストパターン、DVI |
| `clk_sys` | 63MHz | 2 つ目の rPLL (27MHz x 7/3) | SPI スレーブ、レジスタ、SDRAM コントローラ (GPU もここ) |
| SDRAM クロック | 63MHz | 同じ rPLL の `CLKOUTP` を ODDR で反転 | パッケージ内 SDRAM。位相は `MEM_CLK` で約 1ns 刻みに変えられる (既定 0 = 逆相) |

`clk_pix` と `clk_sys` の間は非同期として扱い、同期化 (2 段の FF、トグル) だけでまたぎます。

## レジスタバス

VDP 本体は「レジスタバス」だけを外部に見せます。バスを駆動する側 (マスタ) は差し替え可能にします。
SPI を UART や別の MCU に変えても VDP 側は触らずに済み、`rtl/vdp/` はベンダ非依存なので他の FPGA にも持っていけます。

バスは `clk_sys` の単純な同期バスです ([`rtl/vdp/spi_slave.sv`](../rtl/vdp/spi_slave.sv) が駆動する):

| 信号 | 向き (VDP から見て) | 内容 |
| --- | --- | --- |
| `reg_addr[6:0]` | in | レジスタアドレス |
| `reg_wdata[7:0]` | in | 書き込みデータ |
| `reg_we` | in | 1 クロックのパルスで書き込み |
| `reg_re` | in | 読み出した値を取り込んだとき 1 クロック (読むとクリアされるレジスタ用) |
| `reg_rdata[7:0]` | out | `reg_addr` の値 (組み合わせ回路) |

SPI のトランザクションの形式 (同期バイト `0xA5`、アドレスの自動インクリメント) は [WIRING.md](WIRING.md) にあります。

## レジスタマップ

| アドレス | 名前 | 内容 | 実装 |
| --- | --- | --- | --- |
| `0x00` | `STATUS` | bit0: VBLANK 中, bit1: エラー (読むとクリア) | `vdp_regs` |
| `0x01` | `CONTROL` | bit1: アニメーション停止 (比較用), bit2: IRQ 許可 (IRQ = VBLANK 中), bit3: 合成した画面を表示 (0 ならテストパターン), bit4: IRQ ピンを READY (GPU の FIFO が半分以上空いている) にする。bit0 は予約 (表示 ON) | `vdp_regs` |
| `0x02` | `MARK_COUNT` | 印を付けたフレームの CRC (`MARK_CRC`) を更新するたびに 1 増える | `frame_crc` + `vdp_regs` |
| `0x04` | `FRAME_COUNT` | フレームカウンタの下位 8bit | `vdp_regs` |
| `0x05`〜`0x08` | `FRAME_CRC` | 直前のフレームの表示ピクセルの CRC-32 (リトルエンディアン、`zlib.crc32` と同じ) | `frame_crc` + `vdp_regs` |
| `0x09` | `UNDERFLOW` | 表示に間に合わなかったライン数 (飽和) | `line_compositor` + `vdp_regs` |
| `0x0A`〜`0x0B` | `CRC_FRAME` | `FRAME_CRC` がどのフレームの値か (`0x05` を読んだ時点の値) | `frame_crc` + `vdp_regs` |
| `0x0C`〜`0x0F` | `MARK_CRC` | 印を付けたフレーム (`WAIT_VBLANK`、印付き) の CRC-32 | `frame_crc` + `vdp_regs` |
| `0x10`〜`0x2F` | `MEM_*` | SDRAM の BIST と 1 ワード読み書き ([`mem_test.sv`](../rtl/vdp/mem_test.sv) の先頭に一覧) | `mem_test` |
| `0x30` | `CMD` | GPU のコマンドのポート (4 バイトで 1 ワード)。`0x30`〜`0x3F` は SPI でアドレスが進まない | `gpu` |
| `0x40` | `GPU_STATUS` | bit0 実行中、bit1 エラー、bit2 FIFO あふれ (読むとクリア)。書き込みの bit0 で FIFO を空に | `gpu` |
| `0x41`〜`0x42` | `GPU_FREE` | コマンド FIFO の空き (ワード数) | `gpu` |
| `0x44`〜`0x45` | `FB_BASE` | 表示する面の先頭 (1KiB 単位、13bit)。`line_compositor` がフレームの先頭で 1 回だけ取り込む | `gpu` |
| `0x46`〜`0x47` | `DRAW_BASE` | 描く面の先頭 (同じ単位、既定 256)。`SWAP` で `FB_BASE` と入れ替わる | `gpu` |
| `0x48`〜`0x49` | `BG_COLOR` | 合成の背景色 (RGB565)。ラインごとに取り込まれる | `gpu` |
| `0x4A` | `LAYER_CTRL` | bit0: ビットマップ レイヤ有効 (既定 1), bit1: ビットマップの透過色を有効, bit2: 面 A (タイル レイヤ) 有効, bit3: スプライト有効, bit4: 面 B 有効 | `gpu` |
| `0x4C`〜`0x4D` | `BITMAP_KEY` | ビットマップの透過色 | `gpu` |

GPU のコマンド (`CLEAR` `FILL_RECT` `SWAP` `UPLOAD` `POINT` `DRAW_LINE` `CLIP` `BLIT` `REG_WRITE` `WAIT_LINE` `WAIT_VBLANK`
`VRAM_WRITE` `PAL_WRITE` `OAM_WRITE`) の形式は [`gpu.sv`](../rtl/vdp/gpu.sv) の先頭にあります。タイル レイヤのレジスタ (スクロール・マップ・タイルの場所・
マップの大きさ・パレットのバンク)、ビットマップの順位 (`BITMAP_RANK`)、スプライトのレジスタ (タイルの場所・パレットのバンク・1 ラインの上限)、面 B・ウィンドウ・横スクロールの表のレジスタ、
ビットマップの形式 (`BITMAP_FMT`、RGB565 / 8bpp) は `REG_WRITE` でだけ書けます。VRAM とタイルの形式は [`tile_layer.sv`](../rtl/vdp/tile_layer.sv)、OAM の形式は [`sprite_layer.sv`](../rtl/vdp/sprite_layer.sv) の先頭にあります。
| `0x7D` | `SCRATCH` | 書いた値がそのまま読める | `vdp_regs` |
| `0x7E` | `ID` | `0x5A` | `vdp_regs` |
| `0x7F` | `VERSION` | RTL の版 | `vdp_regs` |

GPU のコマンド FIFO (M5) などは、空いているアドレスに足していきます。

## SDRAM

GW2AR-18 のパッケージ内 SDRAM (64Mbit、2M ワード x 32bit、4 バンク x 2048 行 x 256 列) を使います。

- パッケージのピンではないので、cst の `IO_LOC` には apicula の [doc/sdram.md](https://github.com/YosysHQ/apicula/blob/master/doc/sdram.md) にある内部 I/O の名前 (`IOR11B` など) を書く。nextpnr-himbaechel と gowin_pack はこれでそのまま通る
- コントローラ ([`sdram_ctrl.sv`](../rtl/vdp/sdram_ctrl.sv)): CL2。読み書きとも同じ行の中のバースト。書き込みはワードごとのバイトマスク (DQM) 付きで、
  奇数の x で始まる / 終わる矩形の端も読み‐修正‐書きなしで書ける。
  利用者は [`sdram_arb.sv`](../rtl/vdp/sdram_arb.sv) で調停する (表示 > GPU > メモリテスト)。GPU のバーストは 64 ワードまでなので、
  表示の読み出しが待たされても最大約 5.6us (締め切りは 63.5us。Verilator のシナリオで測る)
- 読み出しデータを取り込む位置は半周期単位で変えられる (`MEM_CFG`、既定 5)。SDRAM クロックの位相も約 1ns 刻みで変えられ (`MEM_CLK`、既定 0)、
  既定のまま前後に 3〜4ns の余裕がある (GPU_PLAN.md の「M5 の前に: SDRAM クロックの位相」)
  (1 ワードずつなら 6, 7 でも読めてしまうが、浮いたバスが値を保っているだけ)
- ワードアドレスは `{行, バンク, 列}`。1 ライン (320 ピクセル x 16bit = 160 ワード) を 1 行 (256 ワード) に置くと、隣のラインは別のバンクになる

メモリ配置 (フレームバッファ 2 枚 + アセット) は [GPU_PLAN.md](GPU_PLAN.md) にあります。

配線とピン割り当ては [WIRING.md](WIRING.md) を参照してください。
