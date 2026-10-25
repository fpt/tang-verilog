// フレームバッファの表示 (docs/GPU3D_PLAN.md の G0)。3D GPU のビットストリームで、VDP の line_compositor の代わりに使う
//
//   line_compositor のビットマップ レイヤ (RGB565) と背景色・透過色だけを残したもの。面・スプライト・8bpp・ライトマップ・Mode 7 はない。
//   ラインの頼み方 (ピクセル側のトグル)、line_start / line_num、fb_base の取り込み (base_latched)、印 (mark_toggle)、UNDERFLOW の数え方は
//   line_compositor と同じなので、GPU の WAIT_LINE / WAIT_VBLANK / SWAP はそのまま動き、同じコマンド列から同じ画 (CRC) が出る
//
//   合成: ラインを始めるときに bg_color / layer_ctrl / bitmap_key を取り込む。ビットマップが有効 (layer_ctrl[0]) なら
//         SDRAM のワードアドレス (fb_base + ライン) * 256 から SRC_W / 2 ワードを読み、届いたワードをそのままライン バッファに書く
//         (透過色が有効 (layer_ctrl[1]) なら、透過色のピクセルは背景色)。無効なら背景色で埋める
//   クロック: ピクセル側 (clk_pix) が「次のライン」をトグルで頼み、システム側 (clk_sys) が合成する (line_compositor と同じ)
module fb_line #(
    parameter int SRC_W   = 320,
    parameter int SRC_H   = 240,
    parameter int V_TOTAL = 525
) (
    // --- システムクロック側 ---
    input  logic        clk_sys,
    input  logic        rst_sys,
    input  logic [12:0] fb_base,          // 256 ワード単位。ライン 0 を合成し始めるときに取り込む
    output logic        base_latched,     // fb_base を取り込んだとき 1 クロック
    input  logic [15:0] bg_color,
    input  logic [1:0]  layer_ctrl,       // bit0: ビットマップ有効, bit1: 透過色を有効
    input  logic [15:0] bitmap_key,
    input  logic        mark_req,         // 次のフレームに印を付ける (1 クロック)
    output logic        mark_toggle,      // 印を付けたフレームの合成を始めるたびに反転
    output logic        line_start,       // ラインの合成を始めたとき 1 クロック
    output logic [7:0]  line_num,
    output logic        mem_req,
    output logic [20:0] mem_addr,
    output logic [8:0]  mem_len,
    input  logic        mem_ack,
    input  logic        mem_rvalid,
    input  logic [31:0] mem_rdata,
    output logic [7:0]  underflow_count,  // 飽和する
    // --- ピクセルクロック側 ---
    input  logic        clk_pix,
    input  logic        rst_pix,
    input  logic [10:0] x,
    input  logic [9:0]  y,
    output logic [23:0] rgb               // x, y の 1 クロック後に有効
);
    localparam int WORDS = SRC_W / 2;

    // --- ライン バッファ (2 ライン x 256 ワード)。書き込みは clk_sys、読み出しは clk_pix ---
    logic [31:0] line_buf [0:511];

    // ================================================================ ピクセル側 (line_compositor と同じ)
    logic [8:0]  req_line;
    logic        req_toggle;
    logic        need;
    logic [8:0]  next_line;

    always_comb begin
        need      = 1'b0;
        next_line = '0;
        if (y == 10'(V_TOTAL - 2)) begin
            need = 1'b1;                                   // 最後から 2 本目のブランキング ライン: ライン 0
        end else if (y < 10'(2 * SRC_H - 2) && !y[0]) begin
            need      = 1'b1;                              // ライン n の 1 本目: ライン n+1
            next_line = 9'(y >> 1) + 9'd1;
        end
    end

    always_ff @(posedge clk_pix) begin
        if (rst_pix) begin
            req_toggle <= 1'b0;
            req_line   <= '0;
        end else if (x == 11'd0 && need) begin
            req_line   <= next_line;
            req_toggle <= ~req_toggle;
        end
    end

    logic [31:0] word;
    logic        upper;
    always_ff @(posedge clk_pix) begin
        word  <= line_buf[{y[1], x[9:2]}];
        upper <= x[1];
    end

    logic [15:0] p;
    assign p   = upper ? word[31:16] : word[15:0];
    assign rgb = {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};

    // ================================================================ システム側
    typedef enum logic [1:0] {P_IDLE, P_ISSUE, P_BITMAP, P_FILL} phase_t;
    phase_t phase;

    logic [2:0]  req_s;
    logic        pending, mark_pending;
    logic        line_bank;
    logic [12:0] frame_base;
    logic [7:0]  widx;
    logic [15:0] l_bg, l_key;
    logic        l_key_en, l_bm_en;
    logic [20:0] l_addr;

    always_ff @(posedge clk_sys) req_s <= {req_s[1:0], req_toggle};

    // 届いたワードの 2 ピクセル (透過色は背景色に)
    logic [15:0] lo, hi;
    assign lo = (l_key_en && mem_rdata[15:0] == l_key) ? l_bg : mem_rdata[15:0];
    assign hi = (l_key_en && mem_rdata[31:16] == l_key) ? l_bg : mem_rdata[31:16];
    always_ff @(posedge clk_sys) begin
        if (phase == P_BITMAP && mem_rvalid) line_buf[{line_bank, widx}] <= {hi, lo};
        if (phase == P_FILL)                 line_buf[{line_bank, widx}] <= {l_bg, l_bg};
    end

    assign mem_len = 9'(WORDS);

    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            phase           <= P_IDLE;
            pending         <= 1'b0;
            mem_req         <= 1'b0;
            underflow_count <= '0;
            frame_base      <= '0;
            base_latched    <= 1'b0;
            line_start      <= 1'b0;
            line_num        <= '0;
            mark_pending    <= 1'b0;
            mark_toggle     <= 1'b0;
        end else begin
            base_latched <= 1'b0;
            line_start   <= 1'b0;
            if (mark_req) mark_pending <= 1'b1;

            // 新しい依頼が来たときにまだ合成していたら、表示に間に合っていない
            if (req_s[2] != req_s[1]) begin
                if (phase != P_IDLE && underflow_count != 8'hFF) underflow_count <= underflow_count + 8'd1;
                pending <= 1'b1;
            end

            unique case (phase)
                P_IDLE: if (pending || req_s[2] != req_s[1]) begin
                    pending    <= 1'b0;
                    line_bank  <= req_line[0];
                    line_start <= 1'b1;
                    line_num   <= 8'(req_line);
                    l_bg       <= bg_color;
                    l_key      <= bitmap_key;
                    l_key_en   <= layer_ctrl[1];
                    l_bm_en    <= layer_ctrl[0];
                    l_addr     <= (req_line == 9'd0) ? {fb_base, 8'b0} : {frame_base + 13'(req_line), 8'b0};
                    widx       <= '0;
                    if (req_line == 9'd0) begin
                        frame_base   <= fb_base;
                        base_latched <= 1'b1;
                        if (mark_pending || mark_req) begin
                            mark_toggle  <= ~mark_toggle;
                            mark_pending <= 1'b0;
                        end
                    end
                    phase <= P_ISSUE;
                end
                P_ISSUE: begin
                    if (l_bm_en) begin
                        mem_req  <= 1'b1;
                        mem_addr <= l_addr;
                        phase    <= P_BITMAP;
                    end else begin
                        phase <= P_FILL;
                    end
                end
                P_BITMAP: begin
                    if (mem_rvalid) widx <= widx + 8'd1;
                    if (mem_ack) begin
                        mem_req <= 1'b0;
                        phase   <= P_IDLE;
                    end
                end
                P_FILL: begin
                    widx <= widx + 8'd1;
                    if (widx == 8'(WORDS - 1)) phase <= P_IDLE;
                end
                default: phase <= P_IDLE;
            endcase
        end
    end
endmodule
