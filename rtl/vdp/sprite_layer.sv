// スプライト (docs/EMU_GPU_PLAN.md の E3、docs/KESSEL_ON_VDP.md の K2)。line_compositor が 1 ラインごとに start で動かす
//
//   OAM:  128 エントリ x 2 ワードの BSRAM (エントリ n はワード 2n と 2n+1)。GPU の OAM_WRITE が書く
//     ワード 0: [9:0] x (符号付き、画面の左端が 0)、[25:16] y (符号付き)、[27:26] 幅 - 1 (タイル)、[29:28] 高さ - 1 (タイル)、
//               {[10], [30]} セルの並び順、[31] 有効
//     ワード 1: [15:0] マップのエントリと同じ形 ([10:0] 先頭のタイル、[11] 左右反転、[12] 上下反転、[14:13] パレット、[15] 優先度)、
//               [19:16] スプライトごとのバンク (bank[3] = 1 のときだけ使う)
//   大きさ: 幅・高さとも 1〜4 タイル (8〜32 ピクセル)。タイルの形式はタイル レイヤと同じ (8x8、4bpp、ピクセルの値 0 は透明)
//   セルの並び順 (スプライトの中の列 c、行 r のタイル):
//     0: 列優先 (メガドラ)       先頭 + c x 高さ + r
//     1: 16 タイル幅の表 (SNES)  {先頭[10:4] + r, 先頭[3:0] + c} (列は表の行の中で折り返す)
//     2: 行優先 (Kessel の sprn) 先頭 + r x 幅 + c
//     3: 予約 (今は 2 と同じ)
//   反転: 左右反転はタイルの列の順番とタイルの中のピクセルの両方、上下反転はタイルの行の順番とタイルの中の行の両方を逆にする
//   色:   パレットの {bank[2:0], エントリのパレット, ピクセルの値}。bank[3] = 1 なら {0, ワード 1 の [19:16], ピクセルの値} (0..255。
//         8bpp のビットマップ・BLIT4 と同じ番号。エントリのパレット [14:13] は使わない)
//
//   動き方: start で OAM をエントリ 0 から順に 1 クロックに 1 つ調べ、line に掛かる有効なスプライトを見つけたら、
//           その場でタイルの列ごとに タイルの行を読む (1 クロック) -> 受け取る (1 クロック) -> 8 ピクセルを 1 クロックに 1 つ出す。
//           出すのは画面の中 (0 <= x < SRC_W) で不透明なピクセルだけ。並びは OAM の順、1 つのスプライトの中では x の順
//   ラインの上限: line_cols 列 (タイルの列の数。GPU の SPR_LINE_PX / 8)。画面の外の列も数える (メガドラと同じ)。使い切ったら、そのスプライトの残りの列と
//           後ろのエントリは描かない。320 ピクセル = 40 列なら 1 ラインは最大 128 + 40 x 2 + 40 x 10 ≈ 610 クロック
//   出力:   px_valid のクロックに、画面の x = px_x のピクセル {px_pri, px_color}。その 1 クロック前に next_word = x / 2。
//           続けて出す 2 つのピクセルが同じワードの同じ側 (偶奇) になることはない (受け側の 読み‐比較‐書き が追い越されない)
//
//   VRAM とパレットは line_compositor が持ち、読み出しのポートをタイル レイヤと順番に使う (アドレスを出した次のクロックにデータ)。
//   pat_base などの入力は start から busy が落ちるまで変えないこと。
module sprite_layer #(
    parameter int SRC_W = 320
) (
    input  logic        clk,
    input  logic        rst,
    // OAM の書き込み (GPU)
    input  logic        oam_we,
    input  logic [7:0]  oam_waddr,
    input  logic [31:0] oam_wdata,
    // VRAM とパレットの読み出し (1 クロック遅れ)
    output logic [13:0] vram_raddr,
    input  logic [31:0] vram_q,
    output logic [8:0]  pal_raddr,
    input  logic [15:0] pal_q,
    // 1 ラインの合成
    input  logic        start,
    input  logic [7:0]  line,
    input  logic [13:0] pat_base,
    input  logic [3:0]  bank,             // [2:0] バンク (64 色単位)、[3] スプライトごとのバンク (ワード 1 の [19:16]) を使う
    input  logic [6:0]  line_cols,
    output logic        busy,
    // ピクセルの出力
    output logic [7:0]  next_word,
    output logic        px_valid,
    output logic [8:0]  px_x,
    output logic        px_pri,
    output logic [15:0] px_color
);
    // ================================================================ OAM
    logic [31:0] oam [0:255];
    logic [7:0]  oam_raddr;
    logic [31:0] oam_q;

    always_ff @(posedge clk) begin
        if (oam_we) oam[oam_waddr] <= oam_wdata;
        oam_q <= oam[oam_raddr];
    end

    // 出力はパレットを引いた次のクロック
    logic       p_valid, p_pri;
    logic [8:0] p_x;
    assign px_valid = p_valid;
    assign px_x     = p_x;
    assign px_pri   = p_pri;
    assign px_color = pal_q;

    // ================================================================ 走査と描画
    typedef enum logic [2:0] {S_IDLE, S_CHK, S_ATTR, S_COL, S_PAT, S_EMIT, S_NEXT} sstate_t;
    sstate_t state;

    logic [6:0]  idx;             // 調べている OAM のエントリ
    logic [6:0]  cols_left;       // このラインで残っているタイルの列
    // 見つけたスプライト
    logic [10:0] s_x;             // 今のタイルの列の左端 (符号付き)
    logic [1:0]  s_wm1, s_hm1;
    logic [1:0]  s_order;
    logic [4:0]  s_dy;            // スプライトの上端からのライン
    logic [10:0] s_tile;
    logic        s_hflip, s_pri;
    logic [1:0]  s_pal;
    logic [3:0]  s_bank;          // スプライトごとのバンク
    logic [1:0]  s_row;           // 上下反転したあとのタイルの行
    logic [2:0]  s_fine;
    logic [1:0]  col;             // 画面の左から何列目か
    logic [2:0]  k;               // タイルの中のピクセル (画面の左から)
    logic [10:0] cur_x;           // 出すピクセルの画面の x (符号付き)
    logic [31:0] pat;

    // ワード 0 の判定: ライン line がスプライトの縦の範囲に入るか
    logic [10:0] dy;
    logic        hit;
    assign dy  = 11'(line) - 11'(signed'(oam_q[25:16]));
    assign hit = oam_q[31] && dy[10:5] == 6'd0 && dy[4:3] <= oam_q[29:28];

    // ワード 1 から、上下反転を入れたスプライトの中の行
    logic [4:0] ry;
    assign ry = oam_q[12] ? {s_hm1, 3'b111} - s_dy : s_dy;

    // 今の列のタイル番号
    logic [1:0]  sc;              // スプライトの中の列 (左右反転のあと)
    logic [3:0]  col_off;         // 列優先のときの列の先頭のタイル (列 x 高さ)
    logic [3:0]  row_off;         // 行優先のときの行の先頭のタイル (行 x 幅)
    logic [10:0] tile_num;
    assign sc      = s_hflip ? s_wm1 - col : col;
    assign col_off = 4'(sc) * (4'(s_hm1) + 4'd1);
    assign row_off = 4'(s_row) * (4'(s_wm1) + 4'd1);
    always_comb begin
        unique case (s_order)
            2'd0:    tile_num = s_tile + 11'(col_off) + 11'(s_row);
            2'd1:    tile_num = {s_tile[10:4] + 7'(s_row), s_tile[3:0] + 4'(sc)};
            default: tile_num = s_tile + 11'(row_off) + 11'(sc);
        endcase
    end

    logic [2:0] pi;
    logic [3:0] nib;
    logic       on_screen;
    assign pi        = s_hflip ? ~k : k;
    assign nib       = pat[5'd28 - {pi, 2'b0} +: 4];
    assign on_screen = !cur_x[10] && cur_x < 11'(SRC_W);

    always_comb begin
        unique case (state)
            S_CHK:   oam_raddr = hit ? {idx, 1'b1} : {idx + 7'd1, 1'b0};
            S_NEXT:  oam_raddr = {idx + 7'd1, 1'b0};
            S_IDLE:  oam_raddr = 8'd0;
            default: oam_raddr = {idx, 1'b0};
        endcase
        vram_raddr = pat_base + {tile_num, s_fine};
        pal_raddr  = bank[3] ? {1'b0, s_bank, nib} : {bank[2:0], s_pal, nib};
    end

    assign busy      = state != S_IDLE || p_valid;
    assign next_word = cur_x[8:1];

    // S_IDLE --start--> S_CHK (1 クロックに 1 エントリ) --当たり--> S_ATTR -> (S_COL -> S_PAT -> S_EMIT x 8) x 幅 -> S_NEXT -> S_CHK ...
    always_ff @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            p_valid <= 1'b0;
        end else begin
            p_valid <= 1'b0;
            unique case (state)
                S_IDLE: if (start) begin
                    idx       <= '0;
                    cols_left <= line_cols;
                    state     <= S_CHK;
                end
                S_CHK: begin
                    s_x     <= 11'(signed'(oam_q[9:0]));
                    s_wm1   <= oam_q[27:26];
                    s_hm1   <= oam_q[29:28];
                    s_order <= {oam_q[10], oam_q[30]};
                    s_dy    <= dy[4:0];
                    if (hit)                 state <= S_ATTR;
                    else if (idx == 7'd127)  state <= S_IDLE;
                    else                     idx   <= idx + 7'd1;
                end
                S_ATTR: begin
                    s_tile  <= oam_q[10:0];
                    s_hflip <= oam_q[11];
                    s_pal   <= oam_q[14:13];
                    s_bank  <= oam_q[19:16];
                    s_pri   <= oam_q[15];
                    s_row   <= ry[4:3];
                    s_fine  <= ry[2:0];
                    col     <= '0;
                    state   <= S_COL;
                end
                // タイルの行のアドレスを出す (上限を使い切っていたら終わり)
                S_COL: begin
                    if (cols_left == 7'd0) begin
                        state <= S_IDLE;
                    end else begin
                        cols_left <= cols_left - 7'd1;
                        cur_x     <= s_x;
                        state     <= S_PAT;
                    end
                end
                S_PAT: begin
                    pat   <= vram_q;
                    k     <= '0;
                    state <= S_EMIT;
                end
                S_EMIT: begin
                    p_valid <= on_screen && nib != 4'd0;
                    p_x     <= cur_x[8:0];
                    p_pri   <= s_pri;
                    cur_x   <= cur_x + 11'd1;
                    k       <= k + 3'd1;
                    if (k == 3'd7) begin
                        s_x <= s_x + 11'd8;
                        if (col == s_wm1) begin
                            state <= S_NEXT;
                        end else begin
                            col   <= col + 2'd1;
                            state <= S_COL;
                        end
                    end
                end
                S_NEXT: begin
                    if (idx == 7'd127) begin
                        state <= S_IDLE;
                    end else begin
                        idx   <= idx + 7'd1;
                        state <= S_CHK;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
