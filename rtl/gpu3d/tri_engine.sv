// 三角形のビニング (docs/GPU3D_PLAN.md の G2)。GPU (gpu.sv、GPU3D = 1) から TRI のワード列を受け取り、セットアップして
// SDRAM のパラメータバッファとタイルのリストに置く。描くのは tile_engine (raster3d.sv がまとめる)。規則は tools/harness/raster.py
//
//   TRI: [31:24] 0x20、[23:16] フラグ (bit0 Gouraud、bit1 テクスチャ、bit3 Z)、[15:0] 単色 (RGB565)。続けて頂点ごとに {y, x} (符号付き 12.4)、
//        Gouraud なら {r, g, b} (8bit ずつ、[23:0])、Z なら {z} ([15:0])、テクスチャなら {v, u} (10.6)。push で 1 ワードずつ受け、go でセットアップを始める
//   セットアップ (tri_setup) のあと、描くものがあれば:
//     1. 結果を 32 ワードのレコードとして SDRAM のパラメータバッファ (ワードアドレス 0x20000 + 番号 * 32) に書く:
//        0 {フラグ, 0, 単色}、1 {bx1, bx0}、2 {by1, by0}、3..5 e、6..8 ex、9..11 ey、12..17 s、18..23 gx、24..29 gy
//        (属性は r, g, b, z, u, v)、30 テクスチャの設定 (SET_TEX の先頭ワードの [17:0])、31 テクスチャの base
//     2. 外接矩形が触れるタイル (32 x 32、横 10 x 縦 8、番号 = ty * 10 + tx) ごとに、タイルのリスト
//        (0x40000 + タイル * 1024 + 数) に三角形の番号を足す。タイルごとの数はこのモジュールの RAM (cnt) にあり、tile_engine が cnt_raddr で読む
//   1 シーン 4,096 個、1 タイル 1,024 個を超えた分は足さず、bin_error を 1 クロック出す。bin_clear で数を 0 に戻す (80 クロック)
//   done: 1 つの TRI が終わったとき 1 クロック。empty (描くものがない)・zen・外接矩形 (bx0..by1) は次の go まで保持
//   G1 の即時の描画 (行ごとに SDRAM の Z を読み書き) は G2 でなくした (LUT が足りない)。シーンの外の TRI は、raster3d が
//   1 つだけのシーンとして描く (同じピクセルになる)
module tri_engine (
    input  logic        clk,
    input  logic        rst,
    input  logic        push,
    input  logic [31:0] word,
    input  logic        go,
    output logic        busy,
    output logic        done,
    output logic        empty,
    output logic        zen,                         // この TRI のフラグの Z
    output logic [8:0]  bx0, bx1,
    output logic [7:0]  by0, by1,
    input  logic [8:0]  cx0, cx1,
    input  logic [7:0]  cy0, cy1,
    input  logic [17:0] tex_cfg,                     // 今のテクスチャ (SET_TEX): {形式 [17:16], CLUT のずらし [15:8], 幅の log2 [7:4], 高さの log2 [3:0]}
    input  logic [20:0] tex_base,
    input  logic        bin_clear,
    input  logic [6:0]  cnt_raddr,                   // tile_engine が読むタイルの数 (busy でないとき)
    output logic [10:0] cnt_q,                       // 1 クロック遅れ
    output logic        bin_error,
    output logic [31:0] bin_pairs,                   // 足した (三角形, タイル) の数 (測る用)
    output logic [31:0] cycles,                      // busy のクロック (測る用)
    // SDRAM (sdram_arb の d、raster3d 経由。書くだけ)
    output logic        mem_req,
    output logic        mem_we,
    output logic [20:0] mem_addr,
    output logic [8:0]  mem_len,
    output logic [31:0] mem_wdata,
    output logic [3:0]  mem_wmask,
    input  logic        mem_ack,
    input  logic        mem_wnext
);
    localparam logic [20:0] PARAM_BASE = 21'h020000, LIST_BASE = 21'h040000;
    localparam int SCENE_MAX = 4096, TILE_MAX = 1024;

    // ---- ワード列: 届いた順に頂点の欄に置く (頂点ごとに {y, x}、[色]、[z]、[{v, u}]。使わない欄は 0) ----
    logic        first;                              // 次のワードは先頭 (フラグと単色)
    logic        gour, texd;
    logic [7:0]  rflags;
    logic [15:0] flat;
    logic [1:0]  vi, fld;                            // 次のワードの頂点と欄 (0 {y, x}、1 色、2 z、3 {v, u})
    logic [15:0] vx [0:2];
    logic [15:0] vy [0:2];
    logic [23:0] vc [0:2];
    logic [15:0] vz [0:2];
    logic [31:0] vt [0:2];
    assign gour = rflags[0];
    assign texd = rflags[1];
    assign zen  = rflags[3];
    // 欄 f のあとの欄 (フラグで使うものだけ。最後なら 0 = 次の頂点)
    function automatic logic [1:0] next_fld(input logic [1:0] f, input logic g, input logic z, input logic t);
        if (f == 2'd0 && g) return 2'd1;
        if (f <= 2'd1 && z) return 2'd2;
        if (f <= 2'd2 && t) return 2'd3;
        return 2'd0;
    endfunction

    // ---- セットアップ ----
    logic             su_start, su_done;
    logic [2:0][31:0] su_e;
    logic [2:0][20:0] su_ex, su_ey;
    logic [5:0][31:0] su_s, su_gx, su_gy;
    tri_setup u_setup (
        .clk, .rst, .start(su_start),
        .x0(vx[0]), .y0(vy[0]), .x1(vx[1]), .y1(vy[1]), .x2(vx[2]), .y2(vy[2]),
        .c0(vc[0]), .c1(vc[1]), .c2(vc[2]), .z0(vz[0]), .z1(vz[1]), .z2(vz[2]), .t0(vt[0]), .t1(vt[1]), .t2(vt[2]),
        .cx0, .cx1, .cy0, .cy1,
        .done(su_done), .empty,
        .bx0, .bx1, .by0, .by1, .e(su_e), .ex(su_ex), .ey(su_ey), .s(su_s), .gx(su_gx), .gy(su_gy)
    );

    typedef enum logic [2:0] {E_IDLE, E_SETUP, E_BREC, E_BCNT, E_BAPP, E_BCLR} state_t;
    state_t state;

    // ---- ビニング ----
    logic [12:0] n_tris;                             // このシーンの三角形の数 (レコードの番号)
    logic [3:0]  btx, bty, btx0, btx1, bty1;         // 今のタイル
    logic [6:0]  btile;
    logic [4:0]  ridx;                               // レコードの今のワード
    logic [10:0] cnt [0:127];
    logic [6:0]  cnt_ra, clr_i;
    assign btile  = 7'(bty) * 7'd10 + 7'(btx);
    assign cnt_ra = (state == E_IDLE) ? cnt_raddr : btile;
    always_ff @(posedge clk) begin
        cnt_q <= cnt[cnt_ra];
        if (state == E_BCLR)                            cnt[clr_i] <= '0;
        else if (state == E_BAPP && mem_req && mem_ack) cnt[btile] <= cnt_q + 11'd1;
    end
    // レコードのワード (ridx 番目)。テクスチャの設定は go のときのもの
    logic [31:0] rec_w;
    logic [17:0] tex_cfg_q;
    logic [20:0] tex_base_q;
    always_comb begin
        unique case (ridx)
            5'd0:  rec_w = {rflags, 8'd0, flat};
            5'd1:  rec_w = {7'd0, bx1, 7'd0, bx0};
            5'd2:  rec_w = {8'd0, by1, 8'd0, by0};
            5'd3:  rec_w = su_e[0];
            5'd4:  rec_w = su_e[1];
            5'd5:  rec_w = su_e[2];
            5'd6:  rec_w = 32'(signed'(su_ex[0]));
            5'd7:  rec_w = 32'(signed'(su_ex[1]));
            5'd8:  rec_w = 32'(signed'(su_ex[2]));
            5'd9:  rec_w = 32'(signed'(su_ey[0]));
            5'd10: rec_w = 32'(signed'(su_ey[1]));
            5'd11: rec_w = 32'(signed'(su_ey[2]));
            5'd12: rec_w = su_s[0];
            5'd13: rec_w = su_s[1];
            5'd14: rec_w = su_s[2];
            5'd15: rec_w = su_s[3];
            5'd16: rec_w = su_s[4];
            5'd17: rec_w = su_s[5];
            5'd18: rec_w = su_gx[0];
            5'd19: rec_w = su_gx[1];
            5'd20: rec_w = su_gx[2];
            5'd21: rec_w = su_gx[3];
            5'd22: rec_w = su_gx[4];
            5'd23: rec_w = su_gx[5];
            5'd24: rec_w = su_gy[0];
            5'd25: rec_w = su_gy[1];
            5'd26: rec_w = su_gy[2];
            5'd27: rec_w = su_gy[3];
            5'd28: rec_w = su_gy[4];
            5'd29: rec_w = su_gy[5];
            5'd30: rec_w = {14'd0, tex_cfg_q};
            default: rec_w = {11'd0, tex_base_q};
        endcase
    end
    assign mem_we    = 1'b1;
    assign mem_wmask = 4'hF;
    assign mem_wdata = (state == E_BREC) ? rec_w : {19'd0, n_tris};

    assign busy = state != E_IDLE || go || bin_clear;

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= E_IDLE;
            first     <= 1'b1;
            mem_req   <= 1'b0;
            su_start  <= 1'b0;
            done      <= 1'b0;
            n_tris    <= '0;
            bin_error <= 1'b0;
            bin_pairs <= '0;
            cycles    <= '0;
        end else begin
            su_start  <= 1'b0;
            done      <= 1'b0;
            bin_error <= 1'b0;
            if (push) begin
                if (first) begin
                    rflags <= word[23:16];
                    flat   <= word[15:0];
                    vi     <= '0;
                    fld    <= '0;
                    first  <= 1'b0;
                    for (int i = 0; i < 3; i++) begin vc[i] <= '0; vz[i] <= '0; vt[i] <= '0; end
                end else begin
                    unique case (fld)
                        2'd0:    begin vx[vi] <= word[15:0]; vy[vi] <= word[31:16]; end
                        2'd1:    vc[vi] <= word[23:0];
                        2'd2:    vz[vi] <= word[15:0];
                        default: vt[vi] <= word;
                    endcase
                    fld <= next_fld(fld, gour, zen, texd);
                    if (next_fld(fld, gour, zen, texd) == 2'd0) vi <= vi + 2'd1;
                end
            end
            if (state != E_IDLE) cycles <= cycles + 32'd1;

            unique case (state)
                E_IDLE: if (bin_clear) begin
                    n_tris <= '0;
                    clr_i  <= '0;
                    state  <= E_BCLR;
                end else if (go) begin
                    first      <= 1'b1;
                    tex_cfg_q  <= tex_cfg;
                    tex_base_q <= tex_base;
                    if (n_tris == 13'(SCENE_MAX)) begin
                        bin_error <= 1'b1;               // シーンの上限: 描かない
                        done      <= 1'b1;
                    end else begin
                        su_start <= 1'b1;
                        state    <= E_SETUP;
                    end
                end
                E_BCLR: begin
                    clr_i <= clr_i + 7'd1;
                    if (clr_i == 7'd79) state <= E_IDLE;
                end
                E_SETUP: if (su_done) begin
                    if (empty) begin
                        done  <= 1'b1;
                        state <= E_IDLE;
                    end else begin
                        ridx  <= '0;
                        state <= E_BREC;
                    end
                end
                // レコードを 32 ワードのバーストで書く (データは rec_w、wnext ごとに次のワード)
                E_BREC: begin
                    if (!mem_req) begin
                        mem_req  <= 1'b1;
                        mem_addr <= PARAM_BASE + {3'd0, n_tris[11:0], 5'd0};
                        mem_len  <= 9'd32;
                    end else begin
                        if (mem_wnext) ridx <= ridx + 5'd1;
                        if (mem_ack) begin
                            mem_req <= 1'b0;
                            btx0 <= 4'(bx0 >> 5); btx1 <= 4'(bx1 >> 5);
                            btx  <= 4'(bx0 >> 5);
                            bty  <= 4'(by0 >> 5); bty1 <= 4'(by1 >> 5);
                            state <= E_BCNT;
                        end
                    end
                end
                // タイルの数を読む (cnt_q は次のクロック)
                E_BCNT: state <= E_BAPP;
                E_BAPP: begin
                    if (!mem_req && cnt_q == 11'(TILE_MAX)) bin_error <= 1'b1;     // タイルの上限: このタイルには足さない
                    if (!mem_req && cnt_q != 11'(TILE_MAX)) begin
                        mem_req  <= 1'b1;
                        mem_addr <= LIST_BASE + {4'd0, btile, cnt_q[9:0]};
                        mem_len  <= 9'd1;
                    end else if (!mem_req || mem_ack) begin
                        mem_req <= 1'b0;
                        if (mem_ack) bin_pairs <= bin_pairs + 32'd1;
                        if (btx != btx1) begin
                            btx   <= btx + 4'd1;
                            state <= E_BCNT;
                        end else if (bty != bty1) begin
                            btx   <= btx0;
                            bty   <= bty + 4'd1;
                            state <= E_BCNT;
                        end else begin
                            n_tris <= n_tris + 13'd1;
                            done   <= 1'b1;
                            state  <= E_IDLE;
                        end
                    end
                end
                default: state <= E_IDLE;
            endcase
        end
    end
endmodule
