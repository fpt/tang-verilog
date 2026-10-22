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
RP2 ──SPI──► spi_slave ──► register bus ──┬─► vdp_regs   (ID, STATUS, CONTROL, FRAME_COUNT, FRAME_CRC, SCRATCH)   ✅ M1, M2
                                          ├─► mem_test   (SDRAM の BIST と 1 ワード読み書き)          ✅ M3
                                          └─► command FIFO → GPU core (clear / rect / line / blit / tilemap)  M5〜
                                                                │
                                         sdram_ctrl ◄── arbiter ┘◄── line buffer ◄── 表示 (320x240 → 640x480)  M4
                                              │
                                     パッケージ内 SDRAM 8MiB
```

今の HDMI 用ビットストリーム (`make bitstream`) には、映像 (カラーバーのテストパターン)・SPI スレーブ・レジスタ・SDRAM のテストが入っています。

## クロック

| クロック | 周波数 | 作り方 | 中身 |
| --- | --- | --- | --- |
| `clk_ser` | 126MHz | rPLL | DVI のシリアライザ (OSER10) |
| `clk_pix` | 25.2MHz | CLKDIV /5 | 表示タイミング、テストパターン、DVI |
| `clk_sys` | 63MHz | rPLL の CLKOUTD /2 | SPI スレーブ、レジスタ、SDRAM コントローラ (GPU もここ) |
| SDRAM クロック | 63MHz | `clk_sys` の逆相 (ODDR) | パッケージ内 SDRAM |

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
| `0x01` | `CONTROL` | bit1: アニメーション停止 (比較用), bit2: IRQ 許可 (IRQ = VBLANK 中)。bit0 は予約 (表示 ON) | `vdp_regs` |
| `0x04` | `FRAME_COUNT` | フレームカウンタの下位 8bit | `vdp_regs` |
| `0x05`〜`0x08` | `FRAME_CRC` | 直前のフレームの表示ピクセルの CRC-32 (リトルエンディアン、`zlib.crc32` と同じ) | `frame_crc` + `vdp_regs` |
| `0x10`〜`0x2F` | `MEM_*` | SDRAM の BIST と 1 ワード読み書き ([`mem_test.sv`](../rtl/vdp/mem_test.sv) の先頭に一覧) | `mem_test` |
| `0x7D` | `SCRATCH` | 書いた値がそのまま読める | `vdp_regs` |
| `0x7E` | `ID` | `0x5A` | `vdp_regs` |
| `0x7F` | `VERSION` | RTL の版 | `vdp_regs` |

GPU のコマンド FIFO (M5) などは、空いているアドレスに足していきます。

## SDRAM

GW2AR-18 のパッケージ内 SDRAM (64Mbit、2M ワード x 32bit、4 バンク x 2048 行 x 256 列) を使います。

- パッケージのピンではないので、cst の `IO_LOC` には apicula の [doc/sdram.md](https://github.com/YosysHQ/apicula/blob/master/doc/sdram.md) にある内部 I/O の名前 (`IOR11B` など) を書く。nextpnr-himbaechel と gowin_pack はこれでそのまま通る
- コントローラ ([`sdram_ctrl.sv`](../rtl/vdp/sdram_ctrl.sv)) は今は 1 ワードずつ、CL2、オートプリチャージ付き。表示用のバースト読み出しは M4 で足す
- 読み出しデータを取り込む位置は半周期単位で変えられる (`MEM_CFG`)。実機では 5〜7 で 8MiB 全域の BIST に合格し、既定は 6
- ワードアドレスは `{行, バンク, 列}`。1 ライン (320 ピクセル x 16bit = 160 ワード) を 1 行 (256 ワード) に置くと、隣のラインは別のバンクになる

メモリ配置 (フレームバッファ 2 枚 + アセット) は [GPU_PLAN.md](GPU_PLAN.md) にあります。

配線とピン割り当ては [WIRING.md](WIRING.md) を参照してください。
