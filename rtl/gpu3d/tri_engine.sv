// 三角形の即時描画 (docs/GPU3D_PLAN.md の G1)。GPU (gpu.sv、GPU3D = 1) から TRI のワード列を受け取り、描く面 (RGB565) と
// SDRAM の Z バッファに描く。規則は tools/harness/raster.py が正
//
//   TRI: [31:24] 0x20、[23:16] フラグ (bit0 Gouraud、bit3 Z)、[15:0] 単色 (RGB565)。続けて頂点ごとに {y, x} (符号付き 12.4)、
//        Gouraud なら {r, g, b} (8bit ずつ、[23:0])、Z なら {z} ([15:0])。push で 1 ワードずつ受け、go でセットアップを始める
//   描き方: tri_setup のあと、外接矩形を 1 行ずつ:
//     1. Z なら Z バッファのその行 (外接矩形の範囲のワード) を読む (64 ワードまでのバースト)
//     2. 1 クロックに 1 ピクセル: 辺の関数がどれも >= 0 なら中。z < Z バッファ (Z のとき) なら通る。通ったピクセルの色と z を行バッファに置く
//     3. 通ったピクセルの範囲のワードを、描く面に書く (ピクセルごとのマスク)。Z なら Z バッファにも
//   Z バッファ: SDRAM のワードアドレス (z_base + y) * 256 + x / 2 の 16bit (下位が偶数の x)。フレームバッファと同じ並び
//   数え: walked (走査したピクセル)、drawn (書いたピクセル)、cycles (busy のクロック) は 32bit で回る (測る用)
module tri_engine (
    input  logic        clk,
    input  logic        rst,
    input  logic        push,
    input  logic [31:0] word,
    input  logic        go,
    output logic        busy,
    input  logic [12:0] draw_base,
    input  logic [12:0] z_base,
    input  logic [8:0]  cx0, cx1,
    input  logic [7:0]  cy0, cy1,
    // SDRAM (sdram_arb の d)
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
    output logic [31:0] walked,
    output logic [31:0] drawn,
    output logic [31:0] cycles
);
    localparam int MAX_BURST = 64;

    // ---- ワード列 ----
    logic [31:0] w [0:9];
    logic [3:0]  wcnt;
    logic        gour, zen;
    logic [15:0] flat;
    assign gour = w[0][16];
    assign zen  = w[0][19];
    assign flat = w[0][15:0];

    // 頂点 i のワード: 1 + i * (1 + Gouraud + Z) から {y, x}、[色]、[z]
    logic [15:0] vx [0:2];
    logic [15:0] vy [0:2];
    logic [23:0] vc [0:2];
    logic [15:0] vz [0:2];
    always_comb begin
        for (int i = 0; i < 3; i++) begin
            int b;
            b = 1 + i * (1 + int'(gour) + int'(zen));
            vx[i] = w[b][15:0];
            vy[i] = w[b][31:16];
            vc[i] = gour ? w[b + 1][23:0] : 24'd0;
            vz[i] = zen ? w[b + 1 + int'(gour)][15:0] : 16'd0;
        end
    end

    // ---- セットアップ ----
    logic             su_start, su_done, su_empty;
    logic [8:0]       bx0, bx1;
    logic [7:0]       by0, by1;
    logic [2:0][31:0] su_e;
    logic [2:0][20:0] su_ex, su_ey;
    logic [3:0][31:0] su_s, su_gx, su_gy;
    tri_setup u_setup (
        .clk, .rst, .start(su_start),
        .x0(vx[0]), .y0(vy[0]), .x1(vx[1]), .y1(vy[1]), .x2(vx[2]), .y2(vy[2]),
        .c0(vc[0]), .c1(vc[1]), .c2(vc[2]), .z0(vz[0]), .z1(vz[1]), .z2(vz[2]),
        .cx0, .cx1, .cy0, .cy1,
        .done(su_done), .empty(su_empty),
        .bx0, .bx1, .by0, .by1, .e(su_e), .ex(su_ex), .ey(su_ey), .s(su_s), .gx(su_gx), .gy(su_gy)
    );

    // ---- 走査の状態 ----
    typedef enum logic [3:0] {E_IDLE, E_SETUP, E_ROW, E_ZREAD, E_WALK, E_DRAIN, E_WALK_END, E_CWRITE, E_ZWRITE, E_NEXT} state_t;
    state_t state;
    logic [7:0]         y;
    logic [8:0]         x;
    logic signed [31:0] er [0:2];                    // 行の始めの辺の値
    logic signed [31:0] ec [0:2];                    // 今のピクセル
    logic [31:0]        ar [0:3];                    // 行の始めの属性
    logic [31:0]        ac [0:3];

    // 今のピクセルの値
    logic        p_in;
    logic [15:0] pz, pcol;
    function automatic logic [15:0] clampv(input logic [31:0] acc, input logic [15:0] mx);
        logic signed [19:0] v;
        v = 20'(signed'(acc) >>> 12);
        if (v < 0) return 16'd0;
        if (v > signed'({4'b0, mx})) return mx;
        return 16'(v);
    endfunction
    // 色 (0..255) を RGB565 の 5bit / 6bit に切り捨て
    function automatic logic [4:0] c5(input logic [31:0] acc);
        return 5'(clampv(acc, 16'd255) >> 3);
    endfunction
    function automatic logic [5:0] c6(input logic [31:0] acc);
        return 6'(clampv(acc, 16'd255) >> 2);
    endfunction
    always_comb begin
        p_in = ec[0] >= 0 && ec[1] >= 0 && ec[2] >= 0;
        pz   = clampv(ac[3], 16'hFFFF);
        pcol = gour ? {c5(ac[0]), c6(ac[1]), c5(ac[2])} : flat;
    end

    // ---- 行バッファ (偶数の x と奇数の x を別に。番号は x / 2) ----
    logic [15:0] zrow_e [0:159];
    logic [15:0] zrow_o [0:159];
    logic [16:0] crow_e [0:159];                     // {通った, 色}
    logic [16:0] crow_o [0:159];
    logic [15:0] zq_e, zq_o;
    logic [16:0] cq_e, cq_o;
    logic [7:0]  zr_idx, br_idx;                     // 走査で読む番号、書き出しで読む番号

    // 2 段目 (1 クロック遅れ): Z を比べて行バッファに置く
    logic        b_v, b_in;
    logic [8:0]  b_x;
    logic [15:0] b_z, b_col;
    logic        b_pass;
    logic [15:0] b_zq;
    assign b_zq   = b_x[0] ? zq_o : zq_e;
    assign b_pass = b_v && b_in && (!zen || b_z < b_zq);

    // 書き出しの範囲 (通ったピクセルの最初と最後)
    logic        any;
    logic [8:0]  px_first, px_last;
    logic [7:0]  w_first, w_last, w_cur, w_rd;
    logic [8:0]  burst_len;
    logic [7:0]  seg_last;                           // 今のバーストの最後のワード (行の終わりは ack でこれを見る。ack は最後のワードの次のクロック)
    assign burst_len = (9'(w_last) - 9'(w_cur) + 9'd1 > 9'(MAX_BURST)) ? 9'(MAX_BURST) : 9'(w_last) - 9'(w_cur) + 9'd1;
    assign w_rd = ((state == E_CWRITE || state == E_ZWRITE) && mem_wnext) ? w_cur + 8'd1 : w_cur;
    assign zr_idx = (state == E_WALK) ? x[8:1] : w_rd;
    assign br_idx = w_rd;

    always_ff @(posedge clk) begin
        // Z の行: SDRAM から (E_ZREAD)、走査で通ったピクセル (2 段目)
        if (state == E_ZREAD && mem_rvalid) begin
            zrow_e[w_cur] <= mem_rdata[15:0];
            zrow_o[w_cur] <= mem_rdata[31:16];
        end else if (b_v && b_pass) begin
            if (b_x[0]) zrow_o[b_x[8:1]] <= b_z;
            else        zrow_e[b_x[8:1]] <= b_z;
        end
        if (b_v) begin
            if (b_x[0]) crow_o[b_x[8:1]] <= {b_pass, b_col};
            else        crow_e[b_x[8:1]] <= {b_pass, b_col};
        end
        zq_e <= zrow_e[zr_idx];
        zq_o <= zrow_o[zr_idx];
        cq_e <= crow_e[br_idx];
        cq_o <= crow_o[br_idx];
    end

    // 書くワードのマスク: 通ったピクセルで、外接矩形の中 (端のワードのもう片方のピクセルは今の行で走査していない)
    logic [1:0] okp;
    always_comb begin
        okp[0] = cq_e[16] && {w_cur, 1'b0} >= bx0 && {w_cur, 1'b0} <= bx1;
        okp[1] = cq_o[16] && {w_cur, 1'b1} >= bx0 && {w_cur, 1'b1} <= bx1;
    end
    assign mem_wmask = {{2{okp[1]}}, {2{okp[0]}}};
    assign mem_wdata = (state == E_ZWRITE) ? {zq_o, zq_e} : {cq_o[15:0], cq_e[15:0]};

    assign busy = state != E_IDLE || go;

    always_ff @(posedge clk) begin
        if (rst) begin
            state   <= E_IDLE;
            wcnt    <= '0;
            mem_req <= 1'b0;
            mem_we  <= 1'b0;
            b_v     <= 1'b0;
            su_start <= 1'b0;
            walked  <= '0;
            drawn   <= '0;
            cycles  <= '0;
        end else begin
            su_start <= 1'b0;
            b_v      <= 1'b0;
            if (push) begin
                w[wcnt] <= word;
                wcnt    <= wcnt + 4'd1;
            end
            if (state != E_IDLE) cycles <= cycles + 32'd1;

            // 2 段目
            if (b_v && b_pass) begin
                drawn <= drawn + 32'd1;
                if (!any || b_x < px_first) px_first <= b_x;
                if (!any || b_x > px_last)  px_last  <= b_x;
                any <= 1'b1;
            end

            unique case (state)
                E_IDLE: if (go) begin
                    wcnt     <= '0;
                    su_start <= 1'b1;
                    state    <= E_SETUP;
                end
                E_SETUP: if (su_done) begin
                    if (su_empty) begin
                        state <= E_IDLE;
                    end else begin
                        y <= by0;
                        for (int i = 0; i < 3; i++) er[i] <= signed'(su_e[i]);
                        for (int k = 0; k < 4; k++) ar[k] <= su_s[k];
                        state <= E_ROW;
                    end
                end
                E_ROW: begin
                    for (int i = 0; i < 3; i++) ec[i] <= er[i];
                    for (int k = 0; k < 4; k++) ac[k] <= ar[k];
                    x       <= bx0;
                    any     <= 1'b0;
                    w_first <= bx0[8:1];
                    w_last  <= bx1[8:1];
                    w_cur   <= bx0[8:1];
                    // (Icarus Verilog は enum の三項演算子の代入を受け付けないので if で書く)
                    if (zen) state <= E_ZREAD;
                    else     state <= E_WALK;
                end
                // Z の行を読む
                E_ZREAD: begin
                    if (!mem_req) begin
                        mem_req  <= 1'b1;
                        mem_we   <= 1'b0;
                        mem_addr <= {z_base + 13'(y), w_cur};
                        mem_len  <= burst_len;
                        seg_last <= w_cur + 8'(burst_len) - 8'd1;
                    end else begin
                        if (mem_rvalid && w_cur != w_last) w_cur <= w_cur + 8'd1;
                        if (mem_ack) begin
                            mem_req <= 1'b0;
                            if (seg_last == w_last) state <= E_WALK;
                        end
                    end
                end
                // 1 クロックに 1 ピクセル (1 段目: 値を出して Z を読む)
                E_WALK: begin
                    b_v   <= 1'b1;
                    b_x   <= x;
                    b_in  <= p_in;
                    b_z   <= pz;
                    b_col <= pcol;
                    walked <= walked + 32'd1;
                    for (int i = 0; i < 3; i++) ec[i] <= ec[i] + 32'(signed'(su_ex[i]));
                    for (int k = 0; k < 4; k++) ac[k] <= ac[k] + su_gx[k];
                    x <= x + 9'd1;
                    if (x == bx1) state <= E_DRAIN;
                end
                E_DRAIN: state <= E_WALK_END;           // 2 段目が最後のピクセルを置くクロック
                E_WALK_END: begin
                    // 2 段目が最後のピクセルを置いたあと: 書き出しの範囲
                    w_first <= px_first[8:1];
                    w_last  <= px_last[8:1];
                    w_cur   <= px_first[8:1];
                    if (any) state <= E_CWRITE;
                    else     state <= E_NEXT;
                end
                E_CWRITE, E_ZWRITE: begin
                    if (!mem_req) begin
                        mem_req  <= 1'b1;
                        mem_we   <= 1'b1;
                        mem_addr <= {((state == E_ZWRITE) ? z_base : draw_base) + 13'(y), w_cur};
                        mem_len  <= burst_len;
                        seg_last <= w_cur + 8'(burst_len) - 8'd1;
                    end else begin
                        if (mem_wnext && w_cur != w_last) w_cur <= w_cur + 8'd1;
                        if (mem_ack) begin
                            mem_req <= 1'b0;
                            if (seg_last == w_last) begin
                                if (state == E_CWRITE && zen) begin
                                    w_cur <= w_first;
                                    state <= E_ZWRITE;
                                end else begin
                                    state <= E_NEXT;
                                end
                            end
                        end
                    end
                end
                E_NEXT: begin
                    for (int i = 0; i < 3; i++) er[i] <= er[i] + 32'(signed'(su_ey[i]));
                    for (int k = 0; k < 4; k++) ar[k] <= ar[k] + su_gy[k];
                    y <= y + 8'd1;
                    if (y == by1) state <= E_IDLE;
                    else          state <= E_ROW;
                end
                default: state <= E_IDLE;
            endcase
        end
    end
endmodule
