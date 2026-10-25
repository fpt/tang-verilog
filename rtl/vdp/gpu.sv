// コマンド GPU (docs/GPU_PLAN.md の M5〜M7、docs/EMU_GPU_PLAN.md の E1、docs/KESSEL_ON_VDP.md の K1・K3・K4・K5a)。コマンド FIFO から 32bit ワードのコマンドを読み、SDRAM のフレームバッファに描く
//
// レジスタ (0x30..0x4F。複数バイトの値はリトルエンディアン):
//   0x30 CMD        W  コマンドのポート。書いたバイトを 4 つずつ (リトルエンディアン) 1 ワードにして FIFO に入れる。
//                      spi_slave は 0x30..0x3F ではアドレスを進めないので、1 回のトランザクションで続けて流し込める
//   0x40 GPU_STATUS R  bit0: 実行中 (FIFO にワードがある、またはコマンドを実行している), bit1: エラー (知らないコマンド。読むとクリア),
//                      bit2: FIFO があふれた (読むとクリア)
//                   W  bit0 を 1 にすると FIFO とワードの組み立てを空にする (実行中のコマンドはそのまま)
//   0x41 GPU_FREE   R  FIFO の空き (ワード数、16bit、0x41..0x42)。ホストはこの数 x 4 バイトまで送ってよい
//   0x44 FB_BASE    RW 表示するフレームバッファの先頭 (256 ワード = 1KiB 単位、13bit、0x44..0x45)。既定 0
//   0x46 DRAW_BASE  RW 描くフレームバッファの先頭 (同じ単位、0x46..0x47)。既定 256 (= 0x040000 バイト)
//   0x48 BG_COLOR   RW 背景色 (RGB565、0x48..0x49)。既定 0。line_compositor がラインごとに取り込む
//   0x4A LAYER_CTRL RW bit0: ビットマップ レイヤ有効 (既定 1), bit1: ビットマップの透過色を有効 (既定 0), bit2: タイル レイヤ有効 (既定 0),
//                      bit3: スプライト有効 (既定 0), bit4: 面 B 有効 (既定 0), bit5: ライトマップを掛ける (既定 0、K4)
//   0x4C BITMAP_KEY RW ビットマップの透過色 (RGB565、0x4C..0x4D)。既定 0
//
// コマンド (先頭ワードの [31:24] がコマンド番号。座標の組は {y[15:0], x[15:0]}):
//   0x00 NOP
//   0x01 CLEAR      [15:0] 色 (RGB565)。描く面の全体 (320x240) を塗る。クリップ矩形は無視する
//   0x02 FILL_RECT  [15:0] 色、次のワード {y, x} (符号なし)、次のワード {h, w}。クリップ矩形の外は描かない
//   0x03 SWAP       FB_BASE と DRAW_BASE を入れ替え、表示が新しい面を取り込む (次のフレームの先頭) まで後続を待たせる
//   0x04 UPLOAD     [23:0] ワード数 n、次のワードに SDRAM のワードアドレス、そのあとに n ワードのデータ。1 ワードずつ書く
//   0x05 POINT      [15:0] 色、次のワード {y, x} (符号付き)。クリップ矩形の中なら 1 ピクセル描く
//   0x06 DRAW_LINE  [15:0] 色、次のワード {y0, x0}、次のワード {y1, x1} (符号付き)。ブレゼンハムで両端を含めて描き、
//                   クリップ矩形の外のピクセルは飛ばす (画面の外から始まる線もよい)
//   0x07 CLIP       次のワード {y0, x0}、次のワード {y1, x1} (符号なし、両端を含む)。以降の FILL_RECT / POINT / DRAW_LINE を
//                   この矩形の中だけにする。画面の外は画面の端に丸める。x0 > x1 などなら何も描かなくなる。既定は画面全体
//   0x08 BLIT       [23:16] フラグ (bit0: 透過, bit1: 左右反転, bit2: 上下反転, bit3: 4bpp のソース (8bpp のときだけ))、[15:0] 透過色 (RGB565)、
//                   次のワードにソースのワードアドレス、次のワード {h, w} (w は 512 まで)、次のワード {y, x} (描く位置、符号付き)、
//                   次のワードにソースの 1 行のワード数 (stride)。ソースは SDRAM の RGB565 の画像で、各行はワードの先頭 (偶数のピクセル) から始まる。
//                   透過のときは透過色のピクセルを書かない。クリップ矩形の外は描かない。
//                   8bpp (BITMAP_FMT = 1) のとき: ソースは 8bpp (1 ワードに 4 ピクセル)、透過色は [7:0]。
//                   4bpp のソース (bit3) は 1 ワードに 8 ピクセルで、ピクセル i は [31-4i -: 4] (タイルの 1 行と同じ並び。VRAM のタイルを
//                   そのまま SDRAM に置けば stride 1 で描ける)。書く値は {[11:8] のバンク, ピクセルの値}、透過のときは値 0 を書かない (BLIT4)。
//                   RGB565 のときに bit3 を立てるとエラー (何も描かない)
//   0x09 REG_WRITE  [23:16] レジスタ番号、[15:0] 値。合成のレジスタを書く (タイル レイヤの意味は tile_layer.sv、
//                   ウィンドウと横スクロールの表は line_compositor.sv)。
//                   0: BG_COLOR, 1: LAYER_CTRL, 2: BITMAP_KEY, 3: TILE_SCROLL_X (10bit), 4: TILE_SCROLL_Y (10bit),
//                   5: TILE_MAP_BASE (VRAM のワードアドレス, 14bit), 6: TILE_PAT_BASE (同じ), 7: TILE_CTRL (8bit) (3〜7 は面 A),
//                   8: BITMAP_RANK (3bit、合成の順位。line_compositor.sv)、9: SPR_PAT_BASE (VRAM のワードアドレス, 14bit)、
//                   10: SPR_BANK (4bit。[2:0] スプライトのパレットのバンク、[3] スプライトごとのバンク (OAM ワード 1 の [19:16]) を使う)、11: SPR_LINE_PX (10bit、1 ラインのスプライトのピクセル数の上限。
//                   8 の倍数に切り捨て。sprite_layer.sv)、12〜16: 面 B の TILEB_SCROLL_X / TILEB_SCROLL_Y / TILEB_MAP_BASE /
//                   TILEB_PAT_BASE / TILEB_CTRL (面 A と同じ形)、17: WIN_H ([7] 右, [4:0] 位置 x 16 ピクセル)、
//                   18: WIN_V ([7] 下, [4:0] 位置 x 8 ライン)、19: WIN_MAP_BASE、20: HSCROLL_MODE (2bit)、21: HSCROLL_BASE (14bit)、
//                   22: BITMAP_FMT (1bit、0 = RGB565、1 = 8bpp。描くコマンドにはすぐ、表示には次のラインから効く)、
//                   23: AUDIO_CTRL ([0] 音を出す、[1] に 1 を書くと PCM_RD と UNDERRUN と先読みを空にする)、24: PCM_BASE (13bit、PCM のリングの
//                   SDRAM の先頭、256 ワード単位。既定 0x1FE0)、25: PCM_SIZE (4bit、リングは 1 << n ワード。既定 11)、26: PCM_WR (16bit、ホストが書いた標本の数)。
//                   27: Z_BASE (13bit、Z バッファの SDRAM の先頭、256 ワード単位。既定 0x0E00。3D GPU の TRI / CLEAR_Z が使う)。
//                   音のレジスタはすぐ効く (ラインに合わせない)。音の動き方は audio_out.sv。
//                   32..50: Mode 7 と霧のレジスタ (E7)。line_compositor が持つ (意味は line_compositor.sv と mode7_layer.sv)
//                   どれも既定 0 (LAYER_CTRL と BITMAP_RANK は 1、SPR_LINE_PX は 320)
//   0x0A WAIT_LINE  [7:0] ライン n。以降の REG_WRITE がライン n から効くところ (ライン n-1 の合成が始まったところ) まで待つ
//   0x0B WAIT_VBLANK  WAIT_LINE 0 と同じ (以降の REG_WRITE が次のフレームのライン 0 から効く)。
//                   [0] = 1 なら、次のフレーム (このあとライン 0 から合成するフレーム) に印を付け、その CRC を MARK_CRC に残す
//   0x0C VRAM_WRITE [23:0] ワード数 n、次のワードに VRAM のワードアドレス、そのあとに n ワードのデータ (VRAM は 16K ワードで折り返す)
//   0x0D PAL_WRITE  [23:0] 色の数 n、次のワードに最初のパレットの番号 (0..511)、そのあとに (n + 1) / 2 ワード。
//                   1 ワードに 2 色 (下位 16bit が先)。n が奇数なら最後のワードの上位は使わない
//   0x0E STRETCH_BLIT  BLIT の拡大縮小版 (最近傍)。先頭ワードは BLIT と同じ ([23:16] フラグ、[15:0] 透過色 / バンク)。
//                   次のワードにソースのワードアドレス、{dh, dw} (描く大きさ、1024 まで)、{y, x} (描く位置、符号付き)、
//                   {sw, stride} (ソースの幅 (ピクセル) と 1 行のワード数)、sx_step、sy_step (どちらも 16.16 の固定小数点。ソースのピクセル / 描くピクセル)。
//                   描くピクセル (i, j) (反転の前) のソースは ((sx_step >> 1) + i * sx_step) >> 16 列目、((sy_step >> 1) + j * sy_step) >> 16 行目
//                   (32bit で計算して折り返す)。ソースの列は sw より小さくなるようにホストが step を選ぶ。左右反転は描く列を右から、上下反転は行を下から。
//                   ソースの形式・透過・クリップは BLIT と同じ。ソースの 1 行は 256 ワードまで (sw: 565 で 512、8bpp で 1024、4bpp で 2048 まで)
//   0x0F OAM_WRITE  [23:0] ワード数 n、次のワードに OAM のワードアドレス (エントリ k はワード 2k と 2k+1)、そのあとに n ワード
//                   (OAM は 256 ワードで折り返す。形式は sprite_layer.sv)
//   0x10 LIGHT_WRITE [23:0] ワード数 n、次のワードにライトマップのセルの番号 (cy * 40 + cx、2048 で折り返す)、そのあとに n ワード。
//                   1 ワードに 1 セル: [5:0] R、[13:8] G、[21:16] B の倍率 (16 = 1 倍、0..63)。使い方は line_compositor.sv
//   0x20 TRI        (GPU3D = 1 のときだけ) 三角形。[23:16] フラグ (bit0 Gouraud、bit3 Z)、[15:0] 単色。続けて頂点ごとに {y, x} (12.4)、
//                   [{r, g, b}]、[{z}]。描き方は rtl/gpu3d/tri_engine.sv、計算の規則は tools/harness/raster.py
//   0x24 CLEAR_Z    (GPU3D = 1 のときだけ) Z バッファ (Z_BASE から 320 x 240 x 16bit) を [15:0] で塗る
//   0x25 BEGIN_SCENE / 0x26 END_SCENE  (GPU3D = 1 のときだけ) TBDR のシーン。意味は rtl/gpu3d/raster3d.sv
//   0x21 SET_TEX / 0x28 CLUT_WRITE     (GPU3D = 1 のときだけ) テクスチャ。意味は rtl/gpu3d/raster3d.sv
//   それ以外        エラーを立て、1 ワードのコマンドとして読み飛ばす
//
// WAIT_LINE のあとの REG_WRITE は、FIFO にすでに入っていれば数クロックで実行されるので、次のラインの合成 (約 63us 後) に間に合う。
// ホストは 1 フレームぶんのコマンドを先に送っておく (FIFO が空になって遅れると、効くラインがずれる)。
//
// RGB565 は 1 ワードに 2 ピクセル (下位 16bit が偶数の x)。8bpp (BITMAP_FMT = 1) は 1 ワードに 4 ピクセル (ピクセル x はバイト x % 4、
// 色はパレットの番号 0..255 で、コマンドの色の [7:0])。矩形の端がワードの途中で始まる / 終わるとき、線と点の 1 ピクセル、BLIT の透過色は、
// SDRAM のバイトマスク (DQM) で書くピクセルだけを書く (読み‐修正‐書きはしない)。矩形と BLIT の書き込みは 1 行の中で 64 ワードずつのバースト。
//
// BLIT は 1 行ずつ: ソースの 1 行をバーストで読んでライン バッファに置き、描く行をバーストで書く。ライン バッファは偶数番目と奇数番目の
// ソースのワードを別の BSRAM に置く。書くワードのピクセル (2 か 4 個、ソースでは並んでいる) は多くてもソースの 2 ワードにまたがるだけなので、
// 隣り合う 2 ワードを 1 クロックで読めば、描く位置がどこでも、左右反転でも、ソースの形式 (565 / 8bpp / 4bpp) がどれでも足りる。
//
// STRETCH_BLIT は描く 1 行ずつ: ソースの行が前の行と違えば読み直し (ライン バッファは BLIT と同じ)、1 クロックに 1 ピクセルずつソースを拾って
// 描く行のワードを組み立てて行バッファ (drow) に置き (ピクセルごとの透過の印つき)、その行をバーストで書く。
module gpu #(
    parameter int SRC_W = 320,
    parameter int SRC_H = 240,
    parameter int FIFO_WORDS = 512,
    parameter int GPU3D = 0              // 1: 3D GPU のコマンド (TRI、CLEAR_Z) を受ける (docs/GPU3D_PLAN.md、rtl/gpu3d/tri_engine.sv)
) (
    input  logic        clk,
    input  logic        rst,
    // レジスタバス
    input  logic [6:0]  addr,
    input  logic [7:0]  wdata,
    input  logic        we,
    input  logic        re,
    output logic [7:0]  rdata,
    // SDRAM (sdram_arb 経由)
    output logic        mem_req,
    output logic        mem_we,
    output logic [20:0] mem_addr,
    output logic [31:0] mem_wdata,
    output logic [3:0]  mem_wmask,
    output logic [8:0]  mem_len,
    input  logic        mem_ack,
    input  logic        mem_wnext,
    input  logic        mem_rvalid,
    input  logic [31:0] mem_rdata,
    // 表示
    output logic [12:0] fb_base,
    input  logic        base_latched,    // line_compositor が fb_base を取り込んだとき 1 クロック
    // 合成のレジスタ (line_compositor がラインごとに取り込む)
    output logic [15:0] bg_color,
    output logic [5:0]  layer_ctrl,
    output logic [15:0] bitmap_key,
    output logic [2:0]  bitmap_rank,
    output logic        bitmap_fmt,      // 0 = RGB565、1 = 8bpp
    output logic [9:0]  tile_scroll_x,
    output logic [9:0]  tile_scroll_y,
    output logic [13:0] tile_map_base,
    output logic [13:0] tile_pat_base,
    output logic [7:0]  tile_ctrl,
    output logic [9:0]  tileb_scroll_x,
    output logic [9:0]  tileb_scroll_y,
    output logic [13:0] tileb_map_base,
    output logic [13:0] tileb_pat_base,
    output logic [7:0]  tileb_ctrl,
    output logic [5:0]  win_h,           // {右, 位置}
    output logic [5:0]  win_v,           // {下, 位置}
    output logic [13:0] win_map_base,
    output logic [1:0]  hs_mode,
    output logic [13:0] hs_base,
    output logic [13:0] spr_pat_base,
    output logic [3:0]  spr_bank,
    output logic [6:0]  spr_line_cols,   // SPR_LINE_PX / 8
    // 音 (audio_out)
    output logic        audio_en,
    output logic        audio_clear,     // AUDIO_CTRL の [1] を書いたとき 1 クロック
    output logic [12:0] pcm_base,
    output logic [3:0]  pcm_size,
    output logic [15:0] pcm_wr,
    // E7 のレジスタ (REG_WRITE 32..50。line_compositor が持つ。xreg_idx = 番号 - 32)
    output logic        xreg_we,
    output logic [4:0]  xreg_idx,
    output logic [15:0] xreg_data,
    // VRAM・パレット・OAM の書き込み (line_compositor へ。OAM は vram_waddr[7:0] と vram_wdata を使う)
    output logic        vram_we,
    output logic [13:0] vram_waddr,
    output logic [31:0] vram_wdata,
    output logic        pal_we,
    output logic [8:0]  pal_waddr,
    output logic [15:0] pal_wdata,
    output logic        oam_we,
    output logic        light_we,        // ライトマップの書き込み (vram_waddr[10:0] と vram_wdata の {[21:16], [13:8], [5:0]} を使う)
    output logic        mark_req,        // WAIT_VBLANK (印付き) が終わったとき 1 クロック
    input  logic        line_start,      // line_compositor がラインの合成を始めたとき 1 クロック
    input  logic [7:0]  line_num,
    output logic        ready,           // FIFO が半分以上空いている (READY の線)
    // 3D GPU (GPU3D = 1): TRI のワード列を tri_engine に渡す。t3_go のあと t3_busy が落ちるまで次のコマンドを待つ
    output logic        t3_push,
    output logic [31:0] t3_word,
    output logic        t3_go,
    input  logic        t3_busy,
    input  logic        t3_error,        // 3D の描画のエラー (シーンの上限) を GPU_STATUS のエラーに
    output logic [12:0] draw_base_o,     // 描く面 (tri_engine へ)
    output logic [12:0] z_base,          // Z バッファの先頭 (REG_WRITE 27、256 ワード単位。既定 0x0E00 = SDRAM の 0x380000 バイト)
    output logic [8:0]  clip_x0, clip_x1,
    output logic [7:0]  clip_y0, clip_y1
);
    localparam int PTR_W = $clog2(FIFO_WORDS);
    localparam int MAX_BURST = 64;
    localparam logic [6:0] A_CMD    = 7'h30;
    localparam logic [6:0] A_STATUS = 7'h40;

    localparam logic [7:0] OP_NOP = 8'h00, OP_CLEAR = 8'h01, OP_FILL_RECT = 8'h02, OP_SWAP = 8'h03, OP_UPLOAD = 8'h04,
                           OP_POINT = 8'h05, OP_DRAW_LINE = 8'h06, OP_CLIP = 8'h07, OP_BLIT = 8'h08,
                           OP_REG_WRITE = 8'h09, OP_WAIT_LINE = 8'h0A, OP_WAIT_VBLANK = 8'h0B,
                           OP_VRAM_WRITE = 8'h0C, OP_PAL_WRITE = 8'h0D, OP_STRETCH = 8'h0E, OP_OAM_WRITE = 8'h0F,
                           OP_LIGHT_WRITE = 8'h10, OP_TRI = 8'h20, OP_CLEAR_Z = 8'h24,
                           OP_BEGIN_SCENE = 8'h25, OP_END_SCENE = 8'h26,
                           OP_SET_TEX = 8'h21, OP_CLUT_WRITE = 8'h28;
    localparam int BLIT_MAX_W = 512;      // ライン バッファ (256 ワード) に入る幅
    localparam int STRETCH_MAX = 1024;    // STRETCH_BLIT の描く大きさの上限

    // ================================================================ コマンド FIFO
    logic [31:0]     fifo [0:FIFO_WORDS-1];
    logic [PTR_W:0]  wr_ptr, rd_ptr;           // 1 ビット多く持って満杯と空を区別する
    logic [PTR_W:0]  count;
    logic [31:0]     fifo_head;                // fifo[rd_ptr] を 1 クロック遅れで読んだもの
    logic [23:0]     asm_bytes;
    logic [1:0]      asm_cnt;
    logic            push, pop, flush;
    logic [31:0]     push_word;

    assign count = wr_ptr - rd_ptr;

    always_ff @(posedge clk) begin
        if (push) fifo[wr_ptr[PTR_W-1:0]] <= push_word;
        fifo_head <= fifo[rd_ptr[PTR_W-1:0]];
    end

    // ================================================================ 実行
    typedef enum logic [4:0] {
        S_FETCH, S_FETCH_WAIT, S_DECODE, S_ARG, S_EXEC, S_RECT_BURST, S_SWAP_WAIT,
        S_UPLOAD_WRITE, S_LINE_STEP, S_LINE_PLOT, S_LINE_ADV,
        S_BLIT_SETUP, S_BLIT_SKIP, S_BLIT_READ, S_BLIT_WRITE, S_WAIT_LINE,
        S_ST_SETUP, S_ST_ROW, S_ST_GEN, S_ST_WRITE,
        S_VRAM_WRITE, S_PAL_WRITE, S_PAL_HI, S_TRI_ARG, S_T3_GO, S_TRI_WAIT
    } state_t;
    state_t state, after_fetch;

    logic [31:0] word;
    logic [7:0]  op;
    logic [31:0] arg0, arg1, arg2, arg3, arg4, arg5;
    logic [2:0]  arg_idx, arg_last;        // 何個目の引数を読んでいるか、最後の引数の番号
    logic [3:0]  flags;                    // 先頭ワードの [19:16] (BLIT: bit0 透過, bit1 左右反転, bit2 上下反転, bit3 4bpp のソース)
    logic [7:0]  flags_raw;                // 先頭ワードの [23:16] (REG_WRITE のレジスタ番号)
    logic        error, overflow, swap_seen;
    logic [7:0]  wait_target;              // WAIT_LINE: このラインの合成が始まるのを待つ
    logic        wait_armed, wait_mark;
    logic [12:0] draw_base;
    logic [15:0] color;
    logic [23:0] up_left;
    logic [1:0]  w_tgt;                    // S_VRAM_WRITE が書く先: 0 VRAM、1 OAM (OAM_WRITE)、2 ライトマップ (LIGHT_WRITE)
    logic [20:0] up_addr;

    // クリップ矩形 (両端を含む)。FILL_RECT / POINT / DRAW_LINE に効く
    logic [8:0]  cx0, cx1;
    logic [7:0]  cy0, cy1;

    // --- 矩形 (FILL_RECT と CLEAR) ---
    // 矩形 {rx, ry, rw, rh} と範囲 {bx0..bx1, by0..by1} (クリップ矩形か画面全体) の重なりを塗る
    logic [15:0] rx, ry, rw, rh;
    logic [8:0]  bx0, bx1;
    logic [7:0]  by0, by1;
    logic [16:0] rx_end, ry_end, xs, xe, ys, ye;
    logic        rect_empty;
    assign rx_end     = 17'(rx) + 17'(rw) - 17'd1;
    assign ry_end     = 17'(ry) + 17'(rh) - 17'd1;
    assign xs         = (17'(rx) > 17'(bx0)) ? 17'(rx) : 17'(bx0);
    assign xe         = (rx_end < 17'(bx1)) ? rx_end : 17'(bx1);
    assign ys         = (17'(ry) > 17'(by0)) ? 17'(ry) : 17'(by0);
    assign ye         = (ry_end < 17'(by1)) ? ry_end : 17'(by1);
    assign rect_empty = rw == 0 || rh == 0 || xs > xe || ys > ye;

    logic        fmt8;                     // 8bpp で描く
    logic        rect_z;                   // CLEAR_Z: 矩形を Z バッファに (16bit、RGB565 と同じ並び)
    assign fmt8 = bitmap_fmt && !rect_z;
    assign draw_base_o = draw_base;
    assign {clip_x0, clip_x1, clip_y0, clip_y1} = {cx0, cx1, cy0, cy1};
    logic [1:0]  x0_b, x1_b;               // 塗る範囲の最初 / 最後 (含む) のピクセルの、ワードの中の最初 / 最後のバイト
    logic [7:0]  y_cur, y_last;
    logic [7:0]  w_first, w_last, w_cur;   // ワード単位

    // ピクセル x のワード、最初 / 最後のバイト (565 は 2 バイトで 1 ピクセル)
    function automatic logic [7:0] word_of(input logic [16:0] px, input logic f8);
        return f8 ? 8'(px >> 2) : 8'(px >> 1);
    endfunction
    function automatic logic [1:0] first_byte(input logic [1:0] px, input logic f8);    // px は x の下位 2bit
        return f8 ? px : {px[0], 1'b0};
    endfunction
    function automatic logic [1:0] last_byte(input logic [1:0] px, input logic f8);
        return f8 ? px : {px[0], 1'b1};
    endfunction

    // バーストの中の今のワードのマスク: 最初のワードは x0_b より前のバイトを、最後のワードは x1_b より後のバイトを書かない
    logic [3:0] cur_mask;
    always_comb begin
        for (int k = 0; k < 4; k++)
            cur_mask[k] = !(w_cur == w_first && 2'(k) < x0_b) && !(w_cur == w_last && 2'(k) > x1_b);
    end

    logic [8:0] burst_len;
    // 今のバーストの最後のワード。行の終わりは ack のときにこれで判断する (sdram_ctrl の ack は最後の wnext の次のクロックなので、
    // w_cur は次のバーストの先頭に進んでいる。残りがちょうど 1 ワードのとき w_cur == w_last で判断すると、そのワードを書かずに終わっていた)
    logic [7:0] seg_last;
    assign burst_len = (9'(w_last) - 9'(w_cur) + 9'd1 > 9'(MAX_BURST)) ? 9'(MAX_BURST) : 9'(w_last) - 9'(w_cur) + 9'd1;

    // --- 線 (DRAW_LINE と POINT)。ブレゼンハム: err = dx + dy (dy は負)、e2 = 2 err ---
    logic signed [17:0] lx, ly, ex, ey;
    logic signed [18:0] ldx, ldy;           // ldx = |x1 - x0| (正), ldy = -|y1 - y0| (負または 0)
    logic signed [19:0] err, e2;
    logic               lsx, lsy;           // 1 なら -1 方向
    logic               in_clip;
    assign e2     = err <<< 1;
    assign in_clip = lx >= $signed({9'b0, cx0}) && lx <= $signed({9'b0, cx1}) &&
                    ly >= $signed({10'b0, cy0}) && ly <= $signed({10'b0, cy1});

    // --- BLIT ---
    logic [20:0]        b_src;              // 今のソースの行の先頭 (ワードアドレス)
    logic [15:0]        b_stride, b_w, b_h;
    logic signed [17:0] b_dx, b_dy;
    logic [15:0]        b_skip;             // 最初に描く行のソースの行まで、stride を何回足すか
    logic [20:0]        b_rd_addr;
    logic [8:0]         b_rd_left;          // この行で読み残しているワード数
    logic [7:0]         b_widx;             // ライン バッファに書く位置 (ワード)
    logic signed [18:0] bxs, bxe, bys, bye; // 描く範囲 (クリップしたあと、両端を含む)

    // 描く範囲 = 置く場所の矩形とクリップ矩形の重なり
    always_comb begin
        logic signed [18:0] xe_raw, ye_raw;
        xe_raw = 19'(b_dx) + 19'(b_w) - 19'sd1;
        ye_raw = 19'(b_dy) + 19'(b_h) - 19'sd1;
        bxs = (19'(b_dx) > $signed({10'b0, cx0})) ? 19'(b_dx) : $signed({10'b0, cx0});
        bxe = (xe_raw < $signed({10'b0, cx1})) ? xe_raw : $signed({10'b0, cx1});
        bys = (19'(b_dy) > $signed({11'b0, cy0})) ? 19'(b_dy) : $signed({11'b0, cy0});
        bye = (ye_raw < $signed({11'b0, cy1})) ? ye_raw : $signed({11'b0, cy1});
    end

    logic        src4;                      // 4bpp のソース
    assign src4 = flags[3];

    // --- STRETCH_BLIT ---
    logic               stretch;            // 今の BLIT は STRETCH_BLIT
    logic [15:0]        st_sw;              // ソースの幅 (ピクセル)
    logic [31:0]        st_xstep, st_ystep, st_xacc, st_yacc;
    logic [15:0]        st_j, st_i;         // 描く行 / 行の中のピクセル (反転の前)
    logic [15:0]        st_row;             // st_ptr が指しているソースの行
    logic [20:0]        st_ptr;
    logic [15:0]        st_loaded;          // ライン バッファにあるソースの行 (st_have のとき)
    logic               st_have;
    logic signed [18:0] st_x;               // 次に拾うピクセルの描く x
    logic signed [18:0] st_yd;              // 今の描く行の y
    logic [15:0]        st_sy;              // 今の描く行のソースの行
    assign st_yd = flags[2] ? 19'(b_dy) + 19'(b_h) - 19'sd1 - 19'(st_j) : 19'(b_dy) + 19'(st_j);
    assign st_sy = st_yacc[31:16];

    // ソースの 1 行のワード数
    logic [15:0] src_px;
    logic [8:0]  src_words;
    assign src_px    = stretch ? st_sw : b_w;
    assign src_words = src4 ? 9'((17'(src_px) + 17'd7) >> 3) : fmt8 ? 9'((17'(src_px) + 17'd3) >> 2) : 9'((17'(src_px) + 17'd1) >> 1);

    // ライン バッファ: ソースの 1 行 (256 ワードまで)。偶数番目と奇数番目のワードを別の BSRAM に置く
    logic [31:0] lb_even [0:127];
    logic [31:0] lb_odd  [0:127];
    logic [31:0] lb_even_q, lb_odd_q;
    logic        w0_odd_q;
    logic [2:0]  boff_q;

    always_ff @(posedge clk) begin
        if (state == S_BLIT_READ && mem_req && mem_rvalid) begin
            if (b_widx[0]) lb_odd[b_widx[7:1]]  <= mem_rdata;
            else           lb_even[b_widx[7:1]] <= mem_rdata;
        end
    end

    // 書くワード (wnext で使われるなら次のワードを先読み) の最初のピクセル (x0) のソースでの番号 s0。左右反転なら s = (w - 1) - (x - dx)。
    // このワードのピクセル (N = 2 か 4 個) はソースの smin .. smin + N - 1 (反転なら smin = s0 - (N - 1))。
    // smin を含むソースのワード W0 と W0 + 1 を読み、W0 の中の smin の位置を boff に残す (負の値でも下位ビットは正しい。その分は書かない)
    logic [7:0] w_rd;
    logic [7:0] w0;
    logic [2:0] boff;
    always_comb begin
        logic signed [18:0] x0, s0, smin;
        w_rd = ((state == S_BLIT_WRITE || state == S_ST_WRITE) && mem_wnext) ? w_cur + 8'd1 : w_cur;
        x0   = fmt8 ? $signed({9'b0, w_rd, 2'b0}) : $signed({10'b0, w_rd, 1'b0});
        s0   = flags[1] ? 19'(b_w) - 19'sd1 - (x0 - 19'(b_dx)) : x0 - 19'(b_dx);
        smin = flags[1] ? s0 - (fmt8 ? 19'sd3 : 19'sd1) : s0;
        w0   = src4 ? 8'(smin >>> 3) : fmt8 ? 8'(smin >>> 2) : 8'(smin >>> 1);
        boff = src4 ? smin[2:0] : fmt8 ? {1'b0, smin[1:0]} : {2'b0, smin[0]};
        // STRETCH_BLIT: 拾うソースのピクセル (st_xacc の整数部) を含むワードを W0 にする
        if (state == S_ST_GEN) begin
            w0   = src4 ? st_xacc[26:19] : fmt8 ? st_xacc[25:18] : st_xacc[24:17];
            boff = src4 ? st_xacc[18:16] : fmt8 ? {1'b0, st_xacc[17:16]} : {2'b0, st_xacc[16]};
        end
    end

    always_ff @(posedge clk) begin
        lb_even_q <= lb_even[7'((9'(w0) + 9'(w0[0])) >> 1)];
        lb_odd_q  <= lb_odd[w0[7:1]];
        w0_odd_q  <= w0[0];
        boff_q    <= boff;
    end

    // 読んだ 2 ワード {W0 + 1, W0} から、書くワードのピクセル k (k = 0 が下位 = 左) を取り出す。
    // ピクセル k はウィンドウの中で boff + k (反転なら boff + N - 1 - k) 番目
    logic [63:0] b_win;
    logic [31:0] b_data;
    logic [3:0]  b_mask;
    assign b_win = w0_odd_q ? {lb_even_q, lb_odd_q} : {lb_odd_q, lb_even_q};
    always_comb begin
        logic [1:0]  o2;
        logic [15:0] p;
        logic [3:0]  o4, nib;
        logic [7:0]  v;
        b_mask = cur_mask;
        b_data = '0;
        o2 = '0; p = '0; o4 = '0; nib = '0; v = '0;
        if (!fmt8) begin
            for (int k = 0; k < 2; k++) begin
                o2 = 2'(boff_q) + (flags[1] ? 2'(1 - k) : 2'(k));
                p  = b_win[16 * o2 +: 16];
                b_data[16 * k +: 16] = p;
                if (flags[0] && p == color) b_mask[2 * k +: 2] = 2'b00;      // 透過色は書かない
            end
        end else begin
            for (int k = 0; k < 4; k++) begin
                o4  = 4'(boff_q) + (flags[1] ? 4'(3 - k) : 4'(k));
                nib = b_win[{o4[3], 5'b0} + 6'd28 - {1'b0, o4[2:0], 2'b0} +: 4];   // 4bpp: ワードの中は上位のニブルが左
                v   = src4 ? {color[11:8], nib} : b_win[{o4[2:0], 3'b0} +: 8];
                b_data[8 * k +: 8] = v;
                if (flags[0] && (src4 ? nib == 4'd0 : v == color[7:0])) b_mask[k] = 1'b0;
            end
        end
    end

    // STRETCH_BLIT の 1 段目: ライン バッファから読んだワード W0 の中の boff 番目のピクセルを、描く x = g_x のところに置く
    logic               g_v;                // このクロックに置くピクセルがある (クリップの中)
    logic signed [18:0] g_x;
    logic [31:0]        g_lane_data;        // そのピクセルを、置くバイトの位置に並べたもの
    logic [3:0]         g_lane, g_tr;       // 置くバイト、そのうち透過のバイト
    logic [7:0]         g_widx;             // 置く描くワード
    always_comb begin
        logic [31:0] wd;
        logic [15:0] p16;
        logic [3:0]  nib;
        logic [7:0]  v;
        wd  = b_win[31:0];
        p16 = wd[{boff_q[0], 4'b0} +: 16];
        nib = wd[5'd28 - {boff_q, 2'b0} +: 4];
        v   = src4 ? {color[11:8], nib} : wd[{boff_q[1:0], 3'b0} +: 8];
        if (!fmt8) begin
            g_lane_data = {p16, p16};
            g_lane      = g_x[0] ? 4'b1100 : 4'b0011;
            g_tr        = (flags[0] && p16 == color) ? g_lane : 4'b0000;
            g_widx      = 8'(g_x >>> 1);
        end else begin
            g_lane_data = {4{v}};
            g_lane      = 4'b0001 << g_x[1:0];
            g_tr        = (flags[0] && (src4 ? nib == 4'd0 : v == color[7:0])) ? g_lane : 4'b0000;
            g_widx      = 8'(g_x >>> 2);
        end
    end

    // 組み立て中の描くワード {透過の印, データ}。ワードが変わったら行バッファに書く (印の 1 = 書かない。置いていないバイトも 1)
    logic        a_on;
    logic [7:0]  a_idx;
    logic [31:0] a_data;
    logic [3:0]  a_tr;
    logic [31:0] lane_bits;
    logic [31:0] m_data;
    logic [3:0]  m_tr;
    logic        a_same;
    always_comb begin
        for (int k = 0; k < 4; k++) lane_bits[8 * k +: 8] = {8{g_lane[k]}};
        a_same = a_on && a_idx == g_widx;
        m_data = ((a_same ? a_data : 32'h0) & ~lane_bits) | (g_lane_data & lane_bits);
        m_tr   = ((a_same ? a_tr : 4'hF) & ~g_lane) | g_tr;
    end

    // 描く 1 行のバッファ (160 ワード x {透過の印 4bit, データ 32bit})
    logic [35:0] drow [0:159];
    logic [35:0] drow_q;
    logic        drow_we;
    always_comb drow_we = state == S_ST_GEN && a_on && ((g_v && !a_same) || (!g_v && st_i == b_w));
    always_ff @(posedge clk) begin
        if (drow_we) drow[a_idx] <= {a_tr, a_data};
        drow_q <= drow[w_rd];
    end

    logic [31:0] fill_data;
    assign fill_data = fmt8 ? {4{color[7:0]}} : {color, color};
    assign mem_wmask = (state == S_RECT_BURST) ? cur_mask :
                       (state == S_BLIT_WRITE) ? b_mask :
                       (state == S_ST_WRITE)   ? cur_mask & ~drow_q[35:32] :
                       (state == S_LINE_PLOT)  ? (fmt8 ? 4'b0001 << lx[1:0] : (lx[0] ? 4'b1100 : 4'b0011)) : 4'hF;
    assign mem_wdata = (state == S_BLIT_WRITE) ? b_data :
                       (state == S_ST_WRITE)   ? drow_q[31:0] :
                       (state == S_RECT_BURST || state == S_LINE_PLOT) ? fill_data : word;

    assign pop = (state == S_FETCH && count != 0 && !flush);

    // 引数の数 (先頭ワードのあとに続くワード。UPLOAD は先頭のアドレスだけ数え、データは S_UPLOAD_WRITE で読む)
    function automatic logic [2:0] nargs(input logic [7:0] o);
        unique case (o)
            OP_STRETCH:                          return 3'd6;
            OP_BLIT:                             return 3'd4;
            OP_FILL_RECT, OP_DRAW_LINE, OP_CLIP: return 3'd2;
            OP_UPLOAD, OP_POINT, OP_VRAM_WRITE, OP_PAL_WRITE, OP_OAM_WRITE, OP_LIGHT_WRITE: return 3'd1;
            default:                             return 3'd0;
        endcase
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            state       <= S_FETCH;
            after_fetch <= S_DECODE;
            rd_ptr      <= '0;
            mem_req     <= 1'b0;
            mem_we      <= 1'b1;
            mem_len     <= 9'd1;
            error       <= 1'b0;
            fb_base     <= 13'd0;
            draw_base   <= 13'd256;
            swap_seen   <= 1'b0;
            cx0 <= 9'd0; cx1 <= 9'(SRC_W - 1);
            cy0 <= 8'd0; cy1 <= 8'(SRC_H - 1);
            bg_color    <= 16'h0000;
            layer_ctrl  <= 6'b000001;
            bitmap_key  <= 16'h0000;
            bitmap_rank <= 3'd1;
            bitmap_fmt  <= 1'b0;
            audio_en    <= 1'b0;
            audio_clear <= 1'b0;
            xreg_we     <= 1'b0;
            pcm_base    <= 13'h1FE0;
            pcm_size    <= 4'd11;
            pcm_wr      <= '0;
            z_base      <= 13'h0E00;
            rect_z      <= 1'b0;
            t3_push     <= 1'b0;
            t3_go       <= 1'b0;
            tile_scroll_x <= '0;
            tile_scroll_y <= '0;
            tile_map_base <= '0;
            tile_pat_base <= '0;
            tile_ctrl     <= '0;
            tileb_scroll_x <= '0;
            tileb_scroll_y <= '0;
            tileb_map_base <= '0;
            tileb_pat_base <= '0;
            tileb_ctrl     <= '0;
            win_h          <= '0;
            win_v          <= '0;
            win_map_base   <= '0;
            hs_mode        <= '0;
            hs_base        <= '0;
            spr_pat_base  <= '0;
            spr_bank      <= '0;
            spr_line_cols <= 7'd40;
            oam_we      <= 1'b0;
            light_we    <= 1'b0;
            mark_req    <= 1'b0;
            vram_we     <= 1'b0;
            pal_we      <= 1'b0;
        end else begin
            mark_req <= 1'b0;
            vram_we  <= 1'b0;
            pal_we   <= 1'b0;
            oam_we   <= 1'b0;
            light_we <= 1'b0;
            audio_clear <= 1'b0;
            xreg_we  <= 1'b0;
            t3_push  <= 1'b0;
            t3_go    <= 1'b0;
            if (flush) rd_ptr <= wr_ptr;
            if (re && addr == A_STATUS) error <= 1'b0;
            if (t3_error) error <= 1'b1;

            // 表示用レジスタはホストからも書ける
            if (we) begin
                unique case (addr)
                    7'h44: fb_base[7:0]    <= wdata;
                    7'h45: fb_base[12:8]   <= wdata[4:0];
                    7'h46: draw_base[7:0]  <= wdata;
                    7'h47: draw_base[12:8] <= wdata[4:0];
                    7'h48: bg_color[7:0]   <= wdata;
                    7'h49: bg_color[15:8]  <= wdata;
                    7'h4A: layer_ctrl      <= wdata[5:0];
                    7'h4C: bitmap_key[7:0] <= wdata;
                    7'h4D: bitmap_key[15:8] <= wdata;
                    default: ;
                endcase
            end

            unique case (state)
                // FIFO から 1 ワード: pop した次のクロックで fifo_head が新しい先頭になるので 1 クロック待つ
                S_FETCH: if (pop) begin
                    rd_ptr <= rd_ptr + 1'b1;
                    state  <= S_FETCH_WAIT;
                end
                S_FETCH_WAIT: begin
                    word  <= fifo_head;
                    state <= after_fetch;
                end

                // 先頭ワード: 引数があれば読んでから S_EXEC、なければすぐ実行
                S_DECODE: begin
                    op      <= word[31:24];
                    flags   <= word[19:16];
                    flags_raw <= word[23:16];
                    color   <= word[15:0];
                    up_left <= word[23:0];
                    arg_idx <= 3'd0;
                    if (GPU3D != 0 && word[31:24] == OP_TRI) begin
                        // TRI: 先頭ワードと、頂点 3 つ x (1 + Gouraud + テクスチャ + Z) ワードを tri_engine に渡す
                        t3_push     <= 1'b1;
                        t3_word     <= word;
                        up_left     <= 24'd3 * (24'd1 + 24'(word[16]) + 24'(word[17]) + 24'(word[19]));
                        state       <= S_FETCH;
                        after_fetch <= S_TRI_ARG;
                    end else if (GPU3D != 0 && (word[31:24] == OP_SET_TEX || (word[31:24] == OP_CLUT_WRITE && word[8:0] != 9'd0))) begin
                        // SET_TEX (1 ワード) / CLUT_WRITE ((n + 1) / 2 ワード): TRI と同じく渡す
                        t3_push     <= 1'b1;
                        t3_word     <= word;
                        up_left     <= (word[31:24] == OP_SET_TEX) ? 24'd1 : 24'(word[8:1]) + 24'(word[0]);
                        state       <= S_FETCH;
                        after_fetch <= S_TRI_ARG;
                    end else if (GPU3D != 0 && (word[31:24] == OP_BEGIN_SCENE || word[31:24] == OP_END_SCENE)) begin
                        // BEGIN_SCENE / END_SCENE: 先頭ワードだけを渡し、次のクロックに go
                        t3_push <= 1'b1;
                        t3_word <= word;
                        state   <= S_T3_GO;
                    end else if (nargs(word[31:24]) != 3'd0) begin
                        arg_last    <= nargs(word[31:24]) - 3'd1;
                        state       <= S_FETCH;
                        after_fetch <= S_ARG;
                    end else begin
                        state <= S_EXEC;
                    end
                end
                S_ARG: begin
                    unique case (arg_idx)
                        3'd0: arg0 <= word;
                        3'd1: arg1 <= word;
                        3'd2: arg2 <= word;
                        3'd3: arg3 <= word;
                        3'd4: arg4 <= word;
                        default: arg5 <= word;
                    endcase
                    arg_idx <= arg_idx + 3'd1;
                    if (arg_idx == arg_last) begin
                        state       <= S_EXEC;
                        after_fetch <= S_DECODE;
                    end else begin
                        state <= S_FETCH;
                    end
                end

                S_EXEC: begin
                    state <= S_FETCH;          // 下で上書きしなければ次のコマンドへ
                    unique case (op)
                        OP_NOP: ;
                        OP_CLEAR, OP_CLEAR_Z: begin
                            // CLEAR_Z (3D GPU だけ): Z バッファ全体を [15:0] で塗る
                            if (op == OP_CLEAR_Z && GPU3D == 0) begin
                                error <= 1'b1;
                            end else begin
                                rect_z <= op == OP_CLEAR_Z;
                                rx <= 16'd0; ry <= 16'd0; rw <= 16'(SRC_W); rh <= 16'(SRC_H);
                                bx0 <= 9'd0; bx1 <= 9'(SRC_W - 1); by0 <= 8'd0; by1 <= 8'(SRC_H - 1);
                                state <= S_RECT_BURST;
                            end
                        end
                        OP_FILL_RECT: begin
                            rect_z <= 1'b0;
                            {ry, rx} <= arg0;
                            {rh, rw} <= arg1;
                            bx0 <= cx0; bx1 <= cx1; by0 <= cy0; by1 <= cy1;
                            state <= S_RECT_BURST;
                        end
                        OP_SWAP: begin
                            fb_base   <= draw_base;
                            draw_base <= fb_base;
                            swap_seen <= 1'b0;
                            state     <= S_SWAP_WAIT;
                        end
                        OP_UPLOAD: begin
                            up_addr <= arg0[20:0];
                            if (up_left != 0) after_fetch <= S_UPLOAD_WRITE;
                        end
                        OP_POINT, OP_DRAW_LINE: begin
                            // POINT は (x, y) から (x, y) への線
                            logic signed [17:0] x0, y0, x1, y1;
                            x0 = 18'(signed'(arg0[15:0]));
                            y0 = 18'(signed'(arg0[31:16]));
                            x1 = (op == OP_POINT) ? x0 : 18'(signed'(arg1[15:0]));
                            y1 = (op == OP_POINT) ? y0 : 18'(signed'(arg1[31:16]));
                            lx  <= x0;  ly <= y0;
                            ex  <= x1;  ey <= y1;
                            lsx <= x1 < x0;
                            lsy <= y1 < y0;
                            ldx <= (x1 < x0) ? 19'(x0 - x1) : 19'(x1 - x0);
                            ldy <= (y1 < y0) ? 19'(y1 - y0) : 19'(y0 - y1);
                            err <= ((x1 < x0) ? 20'(x0 - x1) : 20'(x1 - x0)) + ((y1 < y0) ? 20'(y1 - y0) : 20'(y0 - y1));
                            state <= S_LINE_STEP;
                        end
                        OP_CLIP: begin
                            // 画面の外は画面の端に丸める (x0 > x1 なら空のまま)
                            cx0 <= (arg0[15:0] > 16'(SRC_W - 1)) ? 9'(SRC_W - 1) : 9'(arg0[15:0]);
                            cy0 <= (arg0[31:16] > 16'(SRC_H - 1)) ? 8'(SRC_H - 1) : 8'(arg0[31:16]);
                            cx1 <= (arg1[15:0] > 16'(SRC_W - 1)) ? 9'(SRC_W - 1) : 9'(arg1[15:0]);
                            cy1 <= (arg1[31:16] > 16'(SRC_H - 1)) ? 8'(SRC_H - 1) : 8'(arg1[31:16]);
                            // x0 / y0 が画面の外 (丸めても x1 以上) で x1 が画面の端なら、丸めると 1 列だけ残ってしまうので空にする
                            if (arg0[15:0] > 16'(SRC_W - 1)) cx1 <= 9'd0;
                            if (arg0[31:16] > 16'(SRC_H - 1)) cy1 <= 8'd0;
                            if (arg0[15:0] > 16'(SRC_W - 1)) cx0 <= 9'd1;
                            if (arg0[31:16] > 16'(SRC_H - 1)) cy0 <= 8'd1;
                        end
                        OP_BLIT: begin
                            b_src    <= arg0[20:0];
                            {b_h, b_w} <= arg1;
                            b_dx     <= 18'(signed'(arg2[15:0]));
                            b_dy     <= 18'(signed'(arg2[31:16]));
                            b_stride <= arg3[15:0];
                            stretch  <= 1'b0;
                            if (arg1[15:0] > 16'(BLIT_MAX_W) || (flags[3] && !fmt8)) error <= 1'b1;
                            else                                                     state <= S_BLIT_SETUP;
                        end
                        OP_STRETCH: begin
                            b_src    <= arg0[20:0];
                            {b_h, b_w} <= arg1;
                            b_dx     <= 18'(signed'(arg2[15:0]));
                            b_dy     <= 18'(signed'(arg2[31:16]));
                            b_stride <= arg3[15:0];
                            st_sw    <= arg3[31:16];
                            st_xstep <= arg4;
                            st_ystep <= arg5;
                            stretch  <= 1'b1;
                            if (arg1[15:0] > 16'(STRETCH_MAX) || arg1[31:16] > 16'(STRETCH_MAX) || (flags[3] && !fmt8) ||
                                arg3[31:16] > (flags[3] ? 16'(4 * BLIT_MAX_W) : fmt8 ? 16'(2 * BLIT_MAX_W) : 16'(BLIT_MAX_W)))
                                error <= 1'b1;
                            else
                                state <= S_ST_SETUP;
                        end
                        OP_REG_WRITE: begin
                            unique case (flags_raw)
                                8'd0: bg_color   <= color;
                                8'd1: layer_ctrl <= color[5:0];
                                8'd2: bitmap_key <= color;
                                8'd3: tile_scroll_x <= color[9:0];
                                8'd4: tile_scroll_y <= color[9:0];
                                8'd5: tile_map_base <= color[13:0];
                                8'd6: tile_pat_base <= color[13:0];
                                8'd7: tile_ctrl     <= color[7:0];
                                8'd8: bitmap_rank   <= color[2:0];
                                8'd9: spr_pat_base  <= color[13:0];
                                8'd10: spr_bank     <= color[3:0];
                                8'd11: spr_line_cols <= color[9:3];
                                8'd12: tileb_scroll_x <= color[9:0];
                                8'd13: tileb_scroll_y <= color[9:0];
                                8'd14: tileb_map_base <= color[13:0];
                                8'd15: tileb_pat_base <= color[13:0];
                                8'd16: tileb_ctrl     <= color[7:0];
                                8'd17: win_h          <= {color[7], color[4:0]};
                                8'd18: win_v          <= {color[7], color[4:0]};
                                8'd19: win_map_base   <= color[13:0];
                                8'd20: hs_mode        <= color[1:0];
                                8'd21: hs_base        <= color[13:0];
                                8'd22: bitmap_fmt     <= color[0];
                                8'd23: begin
                                    audio_en    <= color[0];
                                    audio_clear <= color[1];
                                end
                                8'd24: pcm_base       <= color[12:0];
                                8'd25: pcm_size       <= color[3:0];
                                8'd26: pcm_wr         <= color;
                                8'd27: z_base         <= color[12:0];
                                default: begin
                                    // 32..50: E7 (Mode 7 と霧) のレジスタ
                                    if (flags_raw >= 8'd32 && flags_raw <= 8'd50) begin
                                        xreg_we   <= 1'b1;
                                        xreg_idx  <= 5'(flags_raw - 8'd32);
                                        xreg_data <= color;
                                    end else begin
                                        error <= 1'b1;
                                    end
                                end
                            endcase
                        end
                        OP_VRAM_WRITE, OP_OAM_WRITE, OP_LIGHT_WRITE: begin
                            w_tgt      <= (op == OP_OAM_WRITE) ? 2'd1 : (op == OP_LIGHT_WRITE) ? 2'd2 : 2'd0;
                            vram_waddr <= arg0[13:0] - 14'd1;      // S_VRAM_WRITE が先に 1 進める
                            if (up_left != 0) after_fetch <= S_VRAM_WRITE;
                        end
                        OP_PAL_WRITE: begin
                            pal_waddr <= arg0[8:0] - 9'd1;
                            if (up_left != 0) after_fetch <= S_PAL_WRITE;
                        end
                        OP_WAIT_LINE, OP_WAIT_VBLANK: begin
                            // ライン n-1 の合成が始まるのを待つ (n = 0 / WAIT_VBLANK なら最後のライン)
                            logic [7:0] n;
                            n = (op == OP_WAIT_VBLANK) ? 8'd0 : color[7:0];
                            wait_target <= (n == 8'd0) ? 8'(SRC_H - 1) : n - 8'd1;
                            wait_mark   <= op == OP_WAIT_VBLANK && color[0];
                            wait_armed  <= 1'b0;
                            state       <= S_WAIT_LINE;
                        end
                        default: error <= 1'b1;
                    endcase
                end

                // VRAM_WRITE / OAM_WRITE / LIGHT_WRITE / PAL_WRITE: FIFO から読んだワードを 1 クロックで書く (PAL_WRITE は 1 ワードに 2 色)
                S_TRI_ARG: begin
                    t3_push <= 1'b1;
                    t3_word <= word;
                    up_left <= up_left - 24'd1;
                    if (up_left == 24'd1) begin
                        t3_go       <= 1'b1;
                        after_fetch <= S_DECODE;
                        state       <= S_TRI_WAIT;
                    end else begin
                        state <= S_FETCH;
                    end
                end
                S_T3_GO: begin
                    t3_go <= 1'b1;
                    state <= S_TRI_WAIT;
                end
                // t3_go のクロックの t3_busy はまだ 0 のことがあるので、go の次のクロックから見る
                S_TRI_WAIT: if (!t3_go && !t3_busy) state <= S_FETCH;
                S_VRAM_WRITE: begin
                    vram_we    <= w_tgt == 2'd0;
                    oam_we     <= w_tgt == 2'd1;
                    light_we   <= w_tgt == 2'd2;
                    vram_waddr <= vram_waddr + 14'd1;
                    vram_wdata <= word;
                    up_left    <= up_left - 24'd1;
                    state      <= S_FETCH;
                    if (up_left == 24'd1) after_fetch <= S_DECODE;
                end
                S_PAL_WRITE, S_PAL_HI: begin
                    pal_we    <= 1'b1;
                    pal_waddr <= pal_waddr + 9'd1;
                    pal_wdata <= (state == S_PAL_HI) ? word[31:16] : word[15:0];
                    up_left   <= up_left - 24'd1;
                    if (up_left == 24'd1) begin
                        after_fetch <= S_DECODE;
                        state       <= S_FETCH;
                    end else if (state == S_PAL_HI) begin
                        state <= S_FETCH;
                    end else begin
                        state <= S_PAL_HI;
                    end
                end

                // 同じクロックの line_start は数えない (入る前に始まったラインなので)
                S_WAIT_LINE: begin
                    wait_armed <= 1'b1;
                    if (wait_armed && line_start && line_num == wait_target) begin
                        mark_req <= wait_mark;
                        state    <= S_FETCH;
                    end
                end

                // ---- BLIT ----
                // 描く範囲を決め、最初に描く行がソースの何行目か (上下反転なら下から) を数える
                S_BLIT_SETUP: begin
                    if (b_w == 0 || b_h == 0 || bxs > bxe || bys > bye) begin
                        state <= S_FETCH;
                    end else begin
                        y_cur   <= 8'(bys);
                        y_last  <= 8'(bye);
                        x0_b    <= first_byte(bxs[1:0], fmt8);
                        x1_b    <= last_byte(bxe[1:0], fmt8);
                        w_first <= word_of(17'(bxs), fmt8);
                        w_last  <= word_of(17'(bxe), fmt8);
                        b_skip  <= flags[2] ? 16'(19'(b_h) - 19'sd1 - (bys - 19'(b_dy))) : 16'(bys - 19'(b_dy));
                        state   <= S_BLIT_SKIP;
                    end
                end
                // ソースの最初の行まで進める (掛け算を使わず、stride を足していく)
                S_BLIT_SKIP: begin
                    if (b_skip != 0) begin
                        b_src  <= b_src + 21'(b_stride);
                        b_skip <= b_skip - 16'd1;
                    end else begin
                        b_rd_addr <= b_src;
                        b_rd_left <= src_words;
                        b_widx    <= '0;
                        state     <= S_BLIT_READ;
                    end
                end
                // ソースの 1 行をライン バッファへ (SDRAM の行をまたぐときはバーストを分ける)
                S_BLIT_READ: begin
                    if (!mem_req) begin
                        if (b_rd_left == 0) begin
                            w_cur <= w_first;
                            if (stretch) state <= S_ST_ROW;
                            else         state <= S_BLIT_WRITE;
                        end else begin
                            mem_req  <= 1'b1;
                            mem_we   <= 1'b0;
                            mem_addr <= b_rd_addr;
                            mem_len  <= (b_rd_left > 9'd256 - 9'(b_rd_addr[7:0])) ? 9'd256 - 9'(b_rd_addr[7:0]) : b_rd_left;
                        end
                    end else begin
                        if (mem_rvalid) b_widx <= b_widx + 8'd1;
                        if (mem_ack) begin
                            mem_req   <= 1'b0;
                            b_rd_addr <= b_rd_addr + 21'(mem_len);
                            b_rd_left <= b_rd_left - mem_len;
                        end
                    end
                end

                // ---- STRETCH_BLIT ----
                S_ST_SETUP: begin
                    if (b_w == 0 || b_h == 0 || bxs > bxe || bys > bye) begin
                        state <= S_FETCH;
                    end else begin
                        x0_b      <= first_byte(bxs[1:0], fmt8);
                        x1_b      <= last_byte(bxe[1:0], fmt8);
                        w_first   <= word_of(17'(bxs), fmt8);
                        w_last    <= word_of(17'(bxe), fmt8);
                        st_j      <= '0;
                        st_yacc   <= st_ystep >> 1;
                        st_row    <= '0;
                        st_ptr    <= b_src;
                        st_have   <= 1'b0;
                        state     <= S_ST_ROW;
                    end
                end
                // 描く行 st_j: クリップの外なら飛ばす。ソースの行がライン バッファになければ、そこまで進めて読む
                S_ST_ROW: begin
                    if (st_j == b_h) begin
                        state <= S_FETCH;
                    end else if (st_yd < bys || st_yd > bye) begin
                        st_j    <= st_j + 16'd1;
                        st_yacc <= st_yacc + st_ystep;
                    end else if (st_have && st_loaded == st_sy) begin
                        y_cur   <= 8'(st_yd);
                        st_i    <= '0;
                        st_xacc <= st_xstep >> 1;
                        st_x    <= flags[1] ? 19'(b_dx) + 19'(b_w) - 19'sd1 : 19'(b_dx);
                        g_v     <= 1'b0;
                        a_on    <= 1'b0;
                        state   <= S_ST_GEN;
                    end else if (st_row != st_sy) begin
                        st_ptr  <= st_ptr + 21'(b_stride);
                        st_row  <= st_row + 16'd1;
                    end else begin
                        b_rd_addr <= st_ptr;
                        b_rd_left <= src_words;
                        b_widx    <= '0;
                        st_loaded <= st_sy;
                        st_have   <= 1'b1;
                        state     <= S_BLIT_READ;
                    end
                end
                // 1 クロックに 1 ピクセル: ソースのワードを読み (0 段目)、次のクロックに描くワードへ置く (1 段目)
                S_ST_GEN: begin
                    g_v <= st_i != b_w && st_x >= bxs && st_x <= bxe;
                    g_x <= st_x;
                    if (st_i != b_w) begin
                        st_i    <= st_i + 16'd1;
                        st_xacc <= st_xacc + st_xstep;
                        st_x    <= flags[1] ? st_x - 19'sd1 : st_x + 19'sd1;
                    end
                    if (g_v) begin
                        a_on   <= 1'b1;
                        a_idx  <= g_widx;
                        a_data <= m_data;
                        a_tr   <= m_tr;
                    end else if (st_i == b_w) begin
                        // 最後のワードは drow_we で書いた
                        a_on  <= 1'b0;
                        w_cur <= w_first;
                        state <= S_ST_WRITE;
                    end
                end
                S_ST_WRITE: begin
                    if (!mem_req) begin
                        mem_req  <= 1'b1;
                        mem_we   <= 1'b1;
                        mem_addr <= {draw_base + 13'(y_cur), w_cur};
                        mem_len  <= burst_len;
                        seg_last <= w_cur + 8'(burst_len) - 8'd1;
                    end else begin
                        if (mem_wnext && w_cur != w_last) w_cur <= w_cur + 8'd1;
                        if (mem_ack) begin
                            mem_req <= 1'b0;
                            if (seg_last == w_last) begin
                                st_j    <= st_j + 16'd1;
                                st_yacc <= st_yacc + st_ystep;
                                state   <= S_ST_ROW;
                            end
                        end
                    end
                end
                // 描く行を 64 ワードずつのバーストで書く。終わったら次の行 (上下反転ならソースは前の行)
                S_BLIT_WRITE: begin
                    if (!mem_req) begin
                        mem_req  <= 1'b1;
                        mem_we   <= 1'b1;
                        mem_addr <= {draw_base + 13'(y_cur), w_cur};
                        mem_len  <= burst_len;
                        seg_last <= w_cur + 8'(burst_len) - 8'd1;
                    end else begin
                        if (mem_wnext && w_cur != w_last) w_cur <= w_cur + 8'd1;
                        if (mem_ack) begin
                            mem_req <= 1'b0;
                            if (seg_last == w_last) begin
                                if (y_cur == y_last) begin
                                    state <= S_FETCH;
                                end else begin
                                    y_cur     <= y_cur + 8'd1;
                                    b_src     <= flags[2] ? b_src - 21'(b_stride) : b_src + 21'(b_stride);
                                    b_rd_addr <= flags[2] ? b_src - 21'(b_stride) : b_src + 21'(b_stride);
                                    b_rd_left <= src_words;
                                    b_widx    <= '0;
                                    state     <= S_BLIT_READ;
                                end
                            end
                        end
                    end
                end

                // 矩形: 最初に重なりを計算し、1 行の中を 64 ワードずつのバーストで書く
                S_RECT_BURST: begin
                    if (!mem_req) begin
                        if (rw != 0 || rh != 0) begin
                            // 1 回目: 範囲を決める (rw, rh を 0 にして 2 回目以降と区別する)
                            if (rect_empty) begin
                                state <= S_FETCH;
                            end else begin
                                x0_b    <= first_byte(xs[1:0], fmt8);
                                x1_b    <= last_byte(xe[1:0], fmt8);
                                y_cur   <= 8'(ys);
                                y_last  <= 8'(ye);
                                w_first <= word_of(xs, fmt8);
                                w_last  <= word_of(xe, fmt8);
                                w_cur   <= word_of(xs, fmt8);
                            end
                            rw <= 16'd0;
                            rh <= 16'd0;
                        end else begin
                            mem_req  <= 1'b1;
                            mem_we   <= 1'b1;
                            mem_addr <= {(rect_z ? z_base : draw_base) + 13'(y_cur), w_cur};
                            mem_len  <= burst_len;
                            seg_last <= w_cur + 8'(burst_len) - 8'd1;
                        seg_last <= w_cur + 8'(burst_len) - 8'd1;
                        end
                    end else begin
                        if (mem_wnext && w_cur != w_last) w_cur <= w_cur + 8'd1;
                        if (mem_ack) begin
                            mem_req <= 1'b0;
                            if (seg_last == w_last) begin
                                if (y_cur == y_last) begin
                                    state <= S_FETCH;
                                end else begin
                                    y_cur <= y_cur + 8'd1;
                                    w_cur <= w_first;
                                end
                            end
                        end
                    end
                end

                // 入れ替えたあとに fb_scanout が取り込むのを待つ (同じクロックの取り込みは古い値なので数えない)
                S_SWAP_WAIT: begin
                    swap_seen <= 1'b1;
                    if (swap_seen && base_latched) state <= S_FETCH;
                end

                S_UPLOAD_WRITE: begin
                    if (!mem_req) begin
                        mem_req  <= 1'b1;
                        mem_we   <= 1'b1;
                        mem_addr <= up_addr;
                        mem_len  <= 9'd1;
                    end else if (mem_ack) begin
                        mem_req <= 1'b0;
                        up_addr <= up_addr + 21'd1;
                        up_left <= up_left - 24'd1;
                        state   <= S_FETCH;
                        if (up_left == 24'd1) after_fetch <= S_DECODE;
                    end
                end

                // 線: 今のピクセルがクリップ矩形の中なら書き、端に着いたら終わり、でなければ 1 歩進む
                S_LINE_STEP: begin
                    if (in_clip) begin
                        mem_req  <= 1'b1;
                        mem_we   <= 1'b1;
                        mem_addr <= {draw_base + 13'(ly[7:0]), fmt8 ? lx[9:2] : lx[8:1]};
                        mem_len  <= 9'd1;
                        state    <= S_LINE_PLOT;
                    end else begin
                        state <= S_LINE_ADV;
                    end
                end
                S_LINE_PLOT: if (mem_ack) begin
                    mem_req <= 1'b0;
                    state   <= S_LINE_ADV;
                end
                S_LINE_ADV: begin
                    if (lx == ex && ly == ey) begin
                        state <= S_FETCH;
                    end else begin
                        logic signed [19:0] nerr;
                        nerr = err;
                        if (e2 >= 20'(ldy)) begin
                            nerr = nerr + 20'(ldy);
                            lx   <= lsx ? lx - 18'sd1 : lx + 18'sd1;
                        end
                        if (e2 <= 20'(ldx)) begin
                            nerr = nerr + 20'(ldx);
                            ly   <= lsy ? ly - 18'sd1 : ly + 18'sd1;
                        end
                        err   <= nerr;
                        state <= S_LINE_STEP;
                    end
                end
                default: state <= S_FETCH;
            endcase
        end
    end

    // ================================================================ FIFO の書き込み側 (レジスタ)
    always_comb begin
        push      = 1'b0;
        push_word = {wdata, asm_bytes};
        if (we && addr == A_CMD && asm_cnt == 2'd3 && !flush) push = (count != (PTR_W + 1)'(FIFO_WORDS));
    end
    assign flush = we && addr == A_STATUS && wdata[0];

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr   <= '0;
            asm_cnt  <= '0;
            overflow <= 1'b0;
        end else begin
            if (re && addr == A_STATUS) overflow <= 1'b0;
            if (flush) begin
                asm_cnt <= '0;
            end else if (we && addr == A_CMD) begin
                if (asm_cnt == 2'd3) begin
                    if (push) wr_ptr <= wr_ptr + 1'b1;
                    else      overflow <= 1'b1;
                end else begin
                    asm_bytes[8 * asm_cnt +: 8] <= wdata;
                end
                asm_cnt <= asm_cnt + 2'd1;
            end
        end
    end

    // ================================================================ レジスタの読み出し
    logic [15:0] free_words;
    assign free_words = 16'(FIFO_WORDS) - 16'(count);

    logic busy;
    assign busy  = count != 0 || !(state == S_FETCH && after_fetch == S_DECODE);
    assign ready = free_words >= 16'(FIFO_WORDS / 2);

    always_comb begin
        unique case (addr)
            A_STATUS: rdata = {5'b0, overflow, error, busy};
            7'h41:    rdata = free_words[7:0];
            7'h42:    rdata = free_words[15:8];
            7'h44:    rdata = fb_base[7:0];
            7'h45:    rdata = {3'b0, fb_base[12:8]};
            7'h46:    rdata = draw_base[7:0];
            7'h47:    rdata = {3'b0, draw_base[12:8]};
            7'h48:    rdata = bg_color[7:0];
            7'h49:    rdata = bg_color[15:8];
            7'h4A:    rdata = {2'b0, layer_ctrl};
            7'h4C:    rdata = bitmap_key[7:0];
            7'h4D:    rdata = bitmap_key[15:8];
            default:  rdata = 8'h00;
        endcase
    end
endmodule
