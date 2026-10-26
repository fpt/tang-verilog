// 3D GPU の描画部 (docs/GPU3D_PLAN.md の G1・G2)。gpu.sv (GPU3D = 1) からコマンドのワード列を受け、tri_engine (ビニング) と
// tile_engine (タイルのパス) を動かす。SDRAM は 1 つの口 (sdram_arb の d) を、動いているほうに渡す
//
//   0x20 TRI          シーンの中ならビニングする (描くのは END_SCENE)。シーンの外なら、その 1 つだけのシーンとして描く:
//                     数を消してビニングし、外接矩形のタイルだけを、面を読んで (Z なら Z も読んで書き戻して) 描く。G1 の即時モードと同じピクセル
//   0x25 BEGIN_SCENE  シーンを始める。[23:16] フラグ: bit0 描く面を [15:0] の色で消す (でなければ今の面の上に)、
//                     bit1 Z を 0xFFFF から (でなければ Z バッファから読む)、bit2 最後の Z を Z バッファに書き戻す
//   0x26 END_SCENE    シーンをタイルごとに描く (終わるまで busy。そのあとのコマンドは描き終わった面に効く)
//   0x21 SET_TEX      今のテクスチャ。[17:16] 形式 (0 16bpp、1 8bpp、2 4bpp)、[15:8] CLUT のずらし、[7:4] 幅の log2 (3..8)、[3:0] 高さの log2 (0..8)。
//                     次のワードに base (SDRAM のワードアドレス)。そのあとの TRI のレコードに入る
//   0x28 CLUT_WRITE   [23:16] 最初の番号、[8:0] 色の数 n。続けて (n + 1) / 2 ワード (1 ワードに 2 色、下位が先)。すぐ効く (シーンの中でも、
//                     描くのは END_SCENE なので、シーンの中で書き換えるとそのシーン全部に効く)
//   シーンの上限 (4,096 個、1 タイル 1,024 個) を超えると error を 1 クロック出す (gpu.sv の GPU_STATUS のエラー)
//   push は 2 クロック以上あけて出す (CLUT_WRITE の 1 ワードの上位の色を次のクロックに書くため。gpu.sv は 3 クロックごと)
module raster3d (
    input  logic        clk,
    input  logic        rst,
    input  logic        push,
    input  logic [31:0] word,
    input  logic        go,
    output logic        busy,
    output logic        error,
    input  logic [12:0] draw_base,
    input  logic [12:0] z_base,
    input  logic [8:0]  cx0, cx1,
    input  logic [7:0]  cy0, cy1,
    output logic        mem_req,
    output logic        mem_we,
    output logic [20:0] mem_addr,
    output logic [8:0]  mem_len,
    output logic [31:0] mem_wdata,
    output logic [3:0]  mem_wmask,
    input  logic        mem_ack,
    input  logic        mem_wnext,
    input  logic        mem_rvalid,
    input  logic [31:0] mem_rdata,
    // 測る用 (32bit で回る)
    output logic [31:0] st_bin, st_pairs,
    output logic [31:0] st_prep, st_fetch, st_mul, st_walk, st_out, st_walked, st_drawn,
    output logic [31:0] st_tlook, st_tmiss, st_tstall
);
    localparam logic [7:0] OP_TRI = 8'h20, OP_SET_TEX = 8'h21, OP_BEGIN = 8'h25, OP_END = 8'h26, OP_CLUT = 8'h28;

    // 先頭ワード (コマンドの種類とシーンのフラグ)
    logic [7:0]  hdr_op;
    logic [2:0]  hdr_fl;
    logic [15:0] hdr_col;
    logic [17:0] hdr_lo;                              // 先頭ワードの [17:0] (SET_TEX の設定)
    logic        hdr_seen;
    logic [7:0]  op_now;
    assign op_now = hdr_seen ? hdr_op : word[31:24];

    logic        scene;
    logic [2:0]  sflags;                              // タイルのパスのフラグ {write_z, clear_z, clear_color}
    logic [15:0] scol;
    logic [3:0]  rtx0, rtx1, rty0, rty1;

    // シーンの外の TRI: 数を消す → ビニング → 外接矩形のタイルを描く
    typedef enum logic [2:0] {R_IDLE, R_CLR, R_BIN, R_BINW, R_TILES} rstate_t;
    rstate_t rs;

    logic        t_push, t_go, t_busy, t_done, t_empty, t_zen, bin_clear, bin_error;
    logic [8:0]  t_bx0, t_bx1;
    logic [7:0]  t_by0, t_by1;
    logic        k_start, k_busy;
    logic [6:0]  cnt_raddr;
    logic [10:0] cnt_q;
    logic        t_req, t_we, k_req, k_we;
    logic [20:0] t_addr, k_addr;
    logic [8:0]  t_len, k_len;
    logic [31:0] t_wdata, k_wdata;
    logic [3:0]  t_wmask, k_wmask;
    logic        go_imm;                              // シーンの外の TRI の go (数を消したあとに出す)
    logic [17:0] tex_cfg;                             // 今のテクスチャ (SET_TEX)
    logic [20:0] tex_base, tex_base_n;
    logic        clut_we, cl_hi;
    logic [7:0]  clut_waddr, cl_idx;
    logic [15:0] clut_wdata, cl_hold;
    logic [8:0]  cl_left;
    assign t_push = push && op_now == OP_TRI;
    assign t_go   = (go && op_now == OP_TRI && scene) || go_imm;

    tri_engine u_tri (
        .clk, .rst, .push(t_push), .word, .go(t_go), .busy(t_busy), .done(t_done), .empty(t_empty), .zen(t_zen),
        .bx0(t_bx0), .bx1(t_bx1), .by0(t_by0), .by1(t_by1), .cx0, .cx1, .cy0, .cy1, .tex_cfg, .tex_base,
        .bin_clear, .cnt_raddr, .cnt_q, .bin_error, .bin_pairs(st_pairs), .cycles(st_bin),
        .mem_req(t_req), .mem_we(t_we), .mem_addr(t_addr), .mem_len(t_len), .mem_wdata(t_wdata), .mem_wmask(t_wmask),
        .mem_ack(mem_ack && !k_busy), .mem_wnext(mem_wnext && !k_busy)
    );

    tile_engine u_tile (
        .clk, .rst, .start(k_start), .rtx0, .rtx1, .rty0, .rty1,
        .clear_color(sflags[0]), .clear_z(sflags[1]), .write_z(sflags[2]), .ccol(scol),
        .draw_base, .z_base, .busy(k_busy), .clut_we, .clut_waddr, .clut_wdata, .cnt_raddr, .cnt_q,
        .mem_req(k_req), .mem_we(k_we), .mem_addr(k_addr), .mem_len(k_len), .mem_wdata(k_wdata), .mem_wmask(k_wmask),
        .mem_ack(mem_ack && k_busy), .mem_wnext(mem_wnext && k_busy), .mem_rvalid(mem_rvalid && k_busy), .mem_rdata,
        .c_prep(st_prep), .c_fetch(st_fetch), .c_mul(st_mul), .c_walk(st_walk), .c_out(st_out),
        .walked(st_walked), .drawn(st_drawn), .tex_looks(st_tlook), .tex_miss(st_tmiss), .c_tex(st_tstall)
    );

    // SDRAM: タイルのパスのあいだは tile_engine、それ以外は tri_engine (同時には動かない)
    always_comb begin
        if (k_busy) {mem_req, mem_we, mem_addr, mem_len, mem_wdata, mem_wmask} = {k_req, k_we, k_addr, k_len, k_wdata, k_wmask};
        else        {mem_req, mem_we, mem_addr, mem_len, mem_wdata, mem_wmask} = {t_req, t_we, t_addr, t_len, t_wdata, t_wmask};
    end

    assign busy  = t_busy || k_busy || bin_clear || k_start || rs != R_IDLE;
    assign error = bin_error;

    always_ff @(posedge clk) begin
        if (rst) begin
            hdr_seen  <= 1'b0;
            scene     <= 1'b0;
            sflags    <= '0;
            bin_clear <= 1'b0;
            k_start   <= 1'b0;
            go_imm    <= 1'b0;
            rs        <= R_IDLE;
            tex_cfg   <= {2'd0, 8'd0, 4'd3, 4'd3};
            tex_base  <= '0;
            clut_we   <= 1'b0;
            cl_hi     <= 1'b0;
            cl_left   <= '0;
        end else begin
            bin_clear <= 1'b0;
            k_start   <= 1'b0;
            go_imm    <= 1'b0;
            if (push && !hdr_seen) begin
                hdr_op   <= word[31:24];
                hdr_fl   <= word[18:16];
                hdr_col  <= word[15:0];
                hdr_lo   <= word[17:0];
                hdr_seen <= 1'b1;
                // CLUT_WRITE: 書く番号と数
                cl_idx  <= word[23:16];
                cl_left <= word[8:0];
            end
            // SET_TEX の 2 ワード目 (base)、CLUT_WRITE のデータ (1 ワードに 2 色: 下位をこのクロック、上位を次のクロックに書く)
            clut_we  <= 1'b0;
            if (cl_hi) begin
                clut_we    <= cl_left != 9'd0;
                clut_waddr <= cl_idx;
                clut_wdata <= cl_hold;
                cl_idx     <= cl_idx + 8'd1;
                cl_left    <= (cl_left != 9'd0) ? cl_left - 9'd1 : 9'd0;
                cl_hi      <= 1'b0;
            end
            if (push && hdr_seen) begin
                if (hdr_op == OP_SET_TEX) tex_base_n <= word[20:0];
                if (hdr_op == OP_CLUT && cl_left != 9'd0) begin
                    clut_we    <= 1'b1;
                    clut_waddr <= cl_idx;
                    clut_wdata <= word[15:0];
                    cl_hold    <= word[31:16];
                    cl_idx     <= cl_idx + 8'd1;
                    cl_left    <= cl_left - 9'd1;
                    cl_hi      <= 1'b1;
                end
            end
            if (go) begin
                hdr_seen <= 1'b0;
                if (op_now == OP_SET_TEX) begin
                    // 2 ワード目は go と同じクロックに届く (gpu.sv は最後のワードと go を一緒に出す)
                    tex_cfg  <= hdr_lo;
                    tex_base <= push ? word[20:0] : tex_base_n;
                end else if (op_now == OP_BEGIN) begin
                    scene     <= 1'b1;
                    sflags    <= hdr_seen ? hdr_fl : word[18:16];
                    scol      <= hdr_seen ? hdr_col : word[15:0];
                    bin_clear <= 1'b1;
                end else if (op_now == OP_END) begin
                    if (scene) begin
                        rtx0 <= 4'd0; rtx1 <= 4'd9; rty0 <= 4'd0; rty1 <= 4'd7;
                        k_start <= 1'b1;
                    end
                    scene <= 1'b0;
                end else if (op_now == OP_TRI && !scene) begin
                    bin_clear <= 1'b1;
                    rs        <= R_CLR;
                end
            end
            unique case (rs)
                R_CLR: if (!t_busy && !bin_clear) begin
                    go_imm <= 1'b1;
                    rs     <= R_BIN;
                end
                R_BIN: rs <= R_BINW;                     // go_imm のクロック
                R_BINW: if (t_done) begin
                    if (t_empty) begin
                        rs <= R_IDLE;
                    end else begin
                        // 面を読み、Z の三角形なら Z も読んで書き戻す (Z なしなら Z は使わない)
                        sflags  <= t_zen ? 3'b100 : 3'b010;
                        rtx0 <= 4'(t_bx0 >> 5); rtx1 <= 4'(t_bx1 >> 5);
                        rty0 <= 4'(t_by0 >> 5); rty1 <= 4'(t_by1 >> 5);
                        k_start <= 1'b1;
                        rs      <= R_TILES;
                    end
                end
                R_TILES: if (!k_start && !k_busy) rs <= R_IDLE;
                default: ;
            endcase
        end
    end
endmodule
