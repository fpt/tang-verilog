// コマンド GPU (docs/GPU_PLAN.md の M5, M6)。コマンド FIFO から 32bit ワードのコマンドを読み、SDRAM のフレームバッファに描く
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
//   それ以外        エラーを立て、1 ワードのコマンドとして読み飛ばす
//
// 1 ワードに 2 ピクセル (下位 16bit が偶数の x)。矩形の端が奇数の x で始まる / 終わるときや、線と点の 1 ピクセルは、
// SDRAM のバイトマスク (DQM) で片方のピクセルだけを書く (読み‐修正‐書きはしない)。矩形の書き込みは 1 行の中で 64 ワードずつのバースト。
module gpu #(
    parameter int SRC_W = 320,
    parameter int SRC_H = 240,
    parameter int FIFO_WORDS = 512
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
    // 表示
    output logic [12:0] fb_base,
    input  logic        base_latched     // fb_scanout が fb_base を取り込んだとき 1 クロック
);
    localparam int PTR_W = $clog2(FIFO_WORDS);
    localparam int MAX_BURST = 64;
    localparam logic [6:0] A_CMD    = 7'h30;
    localparam logic [6:0] A_STATUS = 7'h40;

    localparam logic [7:0] OP_NOP = 8'h00, OP_CLEAR = 8'h01, OP_FILL_RECT = 8'h02, OP_SWAP = 8'h03, OP_UPLOAD = 8'h04,
                           OP_POINT = 8'h05, OP_DRAW_LINE = 8'h06, OP_CLIP = 8'h07;

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
    typedef enum logic [3:0] {
        S_FETCH, S_FETCH_WAIT, S_DECODE, S_ARG, S_EXEC, S_RECT_BURST, S_SWAP_WAIT,
        S_UPLOAD_WRITE, S_LINE_STEP, S_LINE_PLOT, S_LINE_ADV
    } state_t;
    state_t state, after_fetch;

    logic [31:0] word;
    logic [7:0]  op;
    logic [31:0] arg0, arg1;
    logic        arg_idx, last_arg;        // 何個目の引数を読んでいるか、それが最後か
    logic        error, overflow, swap_seen;
    logic [12:0] draw_base;
    logic [15:0] color;
    logic [23:0] up_left;
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

    logic        x0_odd, x1_odd;           // 塗る範囲の最初 / 最後 (含む) のピクセルの x が奇数か
    logic [7:0]  y_cur, y_last;
    logic [7:0]  w_first, w_last, w_cur;   // ワード単位

    // バーストの中の今のワードのマスク: 最初のワードは x0 が奇数なら上位 (奇数のピクセル) だけ、最後のワードは x1 が偶数なら下位だけ
    logic [3:0] cur_mask;
    always_comb begin
        cur_mask = 4'hF;
        if (w_cur == w_first && x0_odd)  cur_mask = cur_mask & 4'b1100;
        if (w_cur == w_last  && !x1_odd) cur_mask = cur_mask & 4'b0011;
    end

    logic [8:0] burst_len;
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

    assign mem_wmask = (state == S_RECT_BURST) ? cur_mask :
                       (state == S_LINE_PLOT)  ? (lx[0] ? 4'b1100 : 4'b0011) : 4'hF;
    assign mem_wdata = (state == S_RECT_BURST || state == S_LINE_PLOT) ? {color, color} : word;

    assign pop = (state == S_FETCH && count != 0 && !flush);

    // 引数の数 (先頭ワードのあとに続くワード。UPLOAD は先頭のアドレスだけ数え、データは S_UPLOAD_WRITE で読む)
    function automatic logic [1:0] nargs(input logic [7:0] o);
        unique case (o)
            OP_FILL_RECT, OP_DRAW_LINE, OP_CLIP: return 2'd2;
            OP_UPLOAD, OP_POINT:                 return 2'd1;
            default:                             return 2'd0;
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
        end else begin
            if (flush) rd_ptr <= wr_ptr;
            if (re && addr == A_STATUS) error <= 1'b0;

            // 表示用レジスタはホストからも書ける
            if (we) begin
                unique case (addr)
                    7'h44: fb_base[7:0]    <= wdata;
                    7'h45: fb_base[12:8]   <= wdata[4:0];
                    7'h46: draw_base[7:0]  <= wdata;
                    7'h47: draw_base[12:8] <= wdata[4:0];
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
                    color   <= word[15:0];
                    up_left <= word[23:0];
                    arg_idx <= 1'b0;
                    if (nargs(word[31:24]) != 2'd0) begin
                        last_arg    <= nargs(word[31:24]) == 2'd1;
                        state       <= S_FETCH;
                        after_fetch <= S_ARG;
                    end else begin
                        state <= S_EXEC;
                    end
                end
                S_ARG: begin
                    if (!arg_idx) arg0 <= word;
                    else          arg1 <= word;
                    arg_idx <= 1'b1;
                    if (last_arg) begin
                        state       <= S_EXEC;
                        after_fetch <= S_DECODE;
                    end else begin
                        last_arg <= 1'b1;
                        state    <= S_FETCH;
                    end
                end

                S_EXEC: begin
                    state <= S_FETCH;          // 下で上書きしなければ次のコマンドへ
                    unique case (op)
                        OP_NOP: ;
                        OP_CLEAR: begin
                            rx <= 16'd0; ry <= 16'd0; rw <= 16'(SRC_W); rh <= 16'(SRC_H);
                            bx0 <= 9'd0; bx1 <= 9'(SRC_W - 1); by0 <= 8'd0; by1 <= 8'(SRC_H - 1);
                            state <= S_RECT_BURST;
                        end
                        OP_FILL_RECT: begin
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
                        default: error <= 1'b1;
                    endcase
                end

                // 矩形: 最初に重なりを計算し、1 行の中を 64 ワードずつのバーストで書く
                S_RECT_BURST: begin
                    if (!mem_req) begin
                        if (rw != 0 || rh != 0) begin
                            // 1 回目: 範囲を決める (rw, rh を 0 にして 2 回目以降と区別する)
                            if (rect_empty) begin
                                state <= S_FETCH;
                            end else begin
                                x0_odd  <= xs[0];
                                x1_odd  <= xe[0];
                                y_cur   <= 8'(ys);
                                y_last  <= 8'(ye);
                                w_first <= 8'(xs >> 1);
                                w_last  <= 8'(xe >> 1);
                                w_cur   <= 8'(xs >> 1);
                            end
                            rw <= 16'd0;
                            rh <= 16'd0;
                        end else begin
                            mem_req  <= 1'b1;
                            mem_we   <= 1'b1;
                            mem_addr <= {draw_base + 13'(y_cur), w_cur};
                            mem_len  <= burst_len;
                        end
                    end else begin
                        if (mem_wnext && w_cur != w_last) w_cur <= w_cur + 8'd1;
                        if (mem_ack) begin
                            mem_req <= 1'b0;
                            if (w_cur == w_last) begin
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
                        mem_addr <= {draw_base + 13'(ly[7:0]), lx[8:1]};
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
    assign busy = count != 0 || !(state == S_FETCH && after_fetch == S_DECODE);

    always_comb begin
        unique case (addr)
            A_STATUS: rdata = {5'b0, overflow, error, busy};
            7'h41:    rdata = free_words[7:0];
            7'h42:    rdata = free_words[15:8];
            7'h44:    rdata = fb_base[7:0];
            7'h45:    rdata = {3'b0, fb_base[12:8]};
            7'h46:    rdata = draw_base[7:0];
            7'h47:    rdata = {3'b0, draw_base[12:8]};
            default:  rdata = 8'h00;
        endcase
    end
endmodule
