// 三角形のセットアップ (docs/GPU3D_PLAN.md の 3.4 節、G1)。計算の規則は tools/harness/raster.py が正 (同じ整数の計算)
//
//   入力: 頂点 3 つ (x, y は符号付き 12.4、色 {r, g, b} 8bit ずつ、z 16bit)、クリップ矩形 (ピクセル、両端を含む)
//   出力 (done のクロックから次の start まで保持):
//     empty      描くものがない (面積 0、外接矩形とクリップ矩形が重ならない)
//     bx0..by1   走査する外接矩形 (ピクセル、両端を含む)
//     e[i]       辺 i の関数の、外接矩形の左上のピクセルの中心での値 (上左の規則の -1 込み)。中は全部 >= 0
//     ex[i], ey[i]  辺 i の関数の、1 ピクセル右 / 1 行下での増分
//     s[k], gx[k], gy[k]  属性 k (0 r, 1 g, 2 b, 3 z) の左上での値と、1 ピクセル右 / 1 行下での増分 (固定小数点 12bit)
//   計算: 乗算は smul36x18 (符号なしの DSP + 符号の補正) を 1 クロックに 1 つ。順番は
//     面積 (2) → 向きを揃える (負なら v1 と v2 を入れ替える) → 外接矩形 → 辺の値 (6) と属性の分子 Nx, Ny (16)、並行して
//     面積の逆数の仮数 m (17 回の引き戻し除算) → 増分 gx, gy (8、(N * m) >> n を 32bit で飽和) → 左上の値 s (8)
//   約 60 クロック
module tri_setup (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [15:0] x0, y0, x1, y1, x2, y2,     // 符号付き 12.4
    input  logic [23:0] c0, c1, c2,                 // {r, g, b}
    input  logic [15:0] z0, z1, z2,
    input  logic [8:0]  cx0, cx1,
    input  logic [7:0]  cy0, cy1,
    output logic        done,                       // 1 クロック
    output logic        empty,
    output logic [8:0]  bx0, bx1,
    output logic [7:0]  by0, by1,
    output logic [2:0][31:0] e,
    output logic [2:0][20:0] ex, ey,
    output logic [3:0][31:0] s, gx, gy
);
    // ---- 頂点 (向きを揃えたあと) ----
    logic signed [15:0] vx [0:2];
    logic signed [15:0] vy [0:2];
    logic        [15:0] va [0:3][0:2];             // 属性 k の頂点 i の値

    // ---- 乗算器 ----
    logic               m_in_v, m_out_v;
    logic signed [35:0] m_a;
    logic signed [17:0] m_b;
    logic [7:0]         m_in_tag, m_out_tag;        // {first, neg, dest[5:0]}
    logic signed [53:0] m_p;
    smul36x18 #(.TAG_W(8)) u_mul (
        .clk, .in_valid(m_in_v), .a(m_a), .b(m_b), .in_tag(m_in_tag),
        .out_valid(m_out_v), .p(m_p), .out_tag(m_out_tag)
    );

    // 結果の置き場所 (dest): 0 面積、1..3 辺、4..7 Nx、8..11 Ny、12..15 gx、16..19 gy、20..23 T (左上の値の途中)
    localparam logic [5:0] D_AREA = 6'd0, D_E = 6'd1, D_NX = 6'd4, D_NY = 6'd8, D_GX = 6'd12, D_GY = 6'd16, D_T = 6'd20;
    logic signed [31:0] area;
    logic signed [35:0] nx [0:3];
    logic signed [35:0] ny [0:3];
    logic signed [53:0] acc;                         // 同じ置き場所への 1〜2 回の乗算を足していく (置き場所ごとの乗算は続けて出る)
    logic        [2:0]  bias;                        // 辺 i が上左でなければ 1 (値に -1)

    typedef enum logic [3:0] {S_IDLE, S_AREA, S_AREA_W, S_ORIENT, S_BBOX, S_BBOX2, S_BBOX3, S_OPS1, S_OPS2, S_OPS3, S_DRAIN, S_FINAL} state_t;
    state_t state, after_drain;
    logic [4:0] k;                                   // 今のフェーズで出す乗算の番号

    // 左上のピクセルの中心 (1/16 ピクセル)
    logic signed [15:0] sx, sy;
    assign sx = 16'(signed'({1'b0, bx0}) * 16 + 8);
    assign sy = 16'(signed'({1'b0, by0}) * 16 + 8);

    // 辺 i: a → b (e0: v1→v2、e1: v2→v0、e2: v0→v1)
    function automatic int ea(input int i); return (i + 1) % 3; endfunction
    function automatic int eb(input int i); return (i + 2) % 3; endfunction
    logic signed [16:0] edx [0:2];
    logic signed [16:0] edy [0:2];
    always_comb begin
        for (int i = 0; i < 3; i++) begin
            edx[i] = 17'(vx[eb(i)]) - 17'(vx[ea(i)]);
            edy[i] = 17'(vy[eb(i)]) - 17'(vy[ea(i)]);
        end
    end

    // 属性の差 d1 = a1 - a0、d2 = a2 - a0 (17bit)
    logic signed [16:0] d1 [0:3];
    logic signed [16:0] d2 [0:3];
    always_comb begin
        for (int j = 0; j < 4; j++) begin
            d1[j] = 17'({1'b0, va[j][1]}) - 17'({1'b0, va[j][0]});
            d2[j] = 17'({1'b0, va[j][2]}) - 17'({1'b0, va[j][0]});
        end
    end

    // 面積の逆数の仮数: m = ((1 << (n + 16)) - 1) // area。area を最上位 (bit 30) まで寄せて (an = area << kk)、
    // (2^47 - 2^kk) / an を 17 回の引き戻し除算で (余りの初期値は上位 31bit。an より小さい)
    logic [4:0]  nbits, nb;                          // area のビット長 (nb は S_BBOX で取っておいたもの)
    logic signed [12:0] qx0, qx1, qy0, qy1;          // 外接矩形 (クリップの前 / 後)
    logic [31:0] an;
    logic [30:0] rem;
    logic [47:0] dvd;
    logic [16:0] mq;
    logic [4:0]  dcnt;
    logic        dbusy;
    always_comb begin
        nbits = 5'd0;
        for (int i = 0; i < 31; i++) if (area[i]) nbits = 5'(i + 1);
    end

    // 増分: (P >>> n) を 32bit で飽和
    function automatic logic [31:0] shsat(input logic signed [53:0] v, input logic [4:0] sh);
        logic signed [53:0] t;
        t = v >>> sh;
        if (t > 54'sh7FFFFFFF)       return 32'h7FFFFFFF;
        else if (t < -54'sh80000000) return 32'h80000000;
        else                         return 32'(t);
    endfunction
    function automatic logic [31:0] sat32(input logic signed [53:0] v);
        if (v > 54'sh7FFFFFFF)       return 32'h7FFFFFFF;
        else if (v < -54'sh80000000) return 32'h80000000;
        else                         return 32'(v);
    endfunction

    // ---- このクロックに出す乗算 ----
    always_comb begin
        int i, j;
        m_in_v = 1'b0; m_a = '0; m_b = '0; m_in_tag = '0;
        i = 0; j = 0;
        unique case (state)
            S_AREA: begin
                // (x1 - x0)(y2 - y0) - (y1 - y0)(x2 - x0)
                m_in_v = 1'b1;
                if (k == 5'd0) begin
                    m_a = 36'(17'(vx[1]) - 17'(vx[0])); m_b = 18'(17'(vy[2]) - 17'(vy[0])); m_in_tag = {1'b1, 1'b0, D_AREA};
                end else begin
                    m_a = 36'(17'(vy[1]) - 17'(vy[0])); m_b = 18'(17'(vx[2]) - 17'(vx[0])); m_in_tag = {1'b0, 1'b1, D_AREA};
                end
            end
            S_OPS1: begin
                m_in_v = 1'b1;
                if (k < 5'd6) begin
                    // 辺 i: dx (sy - ya) - dy (sx - xa)
                    i = int'(k) / 2;
                    if (!k[0]) begin m_a = 36'(edx[i]); m_b = 18'(17'(sy) - 17'(vy[ea(i)])); m_in_tag = {1'b1, 1'b0, 6'(D_E + i)}; end
                    else       begin m_a = 36'(edy[i]); m_b = 18'(17'(sx) - 17'(vx[ea(i)])); m_in_tag = {1'b0, 1'b1, 6'(D_E + i)}; end
                end else begin
                    // 属性 j: Nx = d1 (y2 - y0) + d2 (y0 - y1)、Ny = d1 (x0 - x2) + d2 (x1 - x0)
                    j = (int'(k) - 6) / 4;
                    unique case (2'(int'(k) - 6))
                        2'd0: begin m_a = 36'(d1[j]); m_b = 18'(17'(vy[2]) - 17'(vy[0])); m_in_tag = {1'b1, 1'b0, 6'(D_NX + j)}; end
                        2'd1: begin m_a = 36'(d2[j]); m_b = 18'(17'(vy[0]) - 17'(vy[1])); m_in_tag = {1'b0, 1'b0, 6'(D_NX + j)}; end
                        2'd2: begin m_a = 36'(d1[j]); m_b = 18'(17'(vx[0]) - 17'(vx[2])); m_in_tag = {1'b1, 1'b0, 6'(D_NY + j)}; end
                        default: begin m_a = 36'(d2[j]); m_b = 18'(17'(vx[1]) - 17'(vx[0])); m_in_tag = {1'b0, 1'b0, 6'(D_NY + j)}; end
                    endcase
                end
            end
            S_OPS2: begin
                // gx = (Nx * m) >> n、gy = (Ny * m) >> n
                m_in_v = 1'b1;
                j = int'(k) / 2;
                m_b = 18'({1'b0, mq});
                if (!k[0]) begin m_a = nx[j]; m_in_tag = {1'b1, 1'b0, 6'(D_GX + j)}; end
                else       begin m_a = ny[j]; m_in_tag = {1'b1, 1'b0, 6'(D_GY + j)}; end
            end
            S_OPS3: begin
                // T = gx (sx - x0) + gy (sy - y0)
                m_in_v = 1'b1;
                j = int'(k) / 2;
                if (!k[0]) begin m_a = 36'(signed'(gx[j])); m_b = 18'(17'(sx) - 17'(vx[0])); m_in_tag = {1'b1, 1'b0, 6'(D_T + j)}; end
                else       begin m_a = 36'(signed'(gy[j])); m_b = 18'(17'(sy) - 17'(vy[0])); m_in_tag = {1'b0, 1'b0, 6'(D_T + j)}; end
            end
            default: ;
        endcase
    end

    // 乗算の数 (フェーズごと)
    logic [4:0] k_last;
    always_comb begin
        unique case (state)
            S_AREA:  k_last = 5'd1;
            S_OPS1:  k_last = 5'd21;
            default: k_last = 5'd7;
        endcase
    end

    // ---- 結果を置く ----
    logic [5:0]         r_dest;
    logic               r_first, r_neg;
    assign {r_first, r_neg, r_dest} = m_out_tag;
    logic [1:0]         ri, ri_e;                      // 置き場所の中の番号 (辺は 1..3 → 0..2)
    assign ri   = r_dest[1:0];
    assign ri_e = r_dest[1:0] - 2'd1;
    logic [2:0]         pend;                        // 乗算器の中にある数 (0..3)

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            dbusy <= 1'b0;
            pend  <= '0;
        end else begin
            done <= 1'b0;
            pend <= pend + 3'(m_in_v) - 3'(m_out_v);

            // 乗算の結果: val = (最初なら初期値、でなければ acc) ± 積。置き場所に val (増分は (積 >>> n) を飽和、左上の値は
            // sat32((a0 << 12) + (T >>> 4))) を入れる。加算器は 1 つ
            if (m_out_v) begin
                logic signed [53:0] base, val;
                base = r_first ? ((r_dest >= D_E && r_dest < D_NX && bias[ri_e]) ? -54'sd1 : 54'sd0) : acc;
                val  = r_neg ? base - m_p : base + m_p;
                acc <= val;
                unique case (r_dest)
                    D_AREA:                     area   <= 32'(val);
                    6'd1, 6'd2, 6'd3:           e[ri_e] <= 32'(val);
                    6'd4, 6'd5, 6'd6, 6'd7:     nx[ri] <= 36'(val);
                    6'd8, 6'd9, 6'd10, 6'd11:   ny[ri] <= 36'(val);
                    6'd12, 6'd13, 6'd14, 6'd15: gx[ri] <= shsat(m_p, nb);
                    6'd16, 6'd17, 6'd18, 6'd19: gy[ri] <= shsat(m_p, nb);
                    default:                    s[ri]  <= sat32(signed'(54'({va[ri][0], 12'd0})) + (val >>> 4));
                endcase
            end

            // 面積の逆数 (S_BBOX で始める)
            if (dbusy) begin
                logic [31:0] r2;
                r2 = {rem[30:0], dvd[{1'b0, dcnt}]};
                if (r2 >= an) begin rem <= 31'(r2 - an); mq <= {mq[15:0], 1'b1}; end
                else          begin rem <= 31'(r2);      mq <= {mq[15:0], 1'b0}; end
                if (dcnt == 5'd0) dbusy <= 1'b0;
                else              dcnt <= dcnt - 5'd1;
            end

            unique case (state)
                S_IDLE: if (start) begin
                    vx[0] <= x0; vx[1] <= x1; vx[2] <= x2;
                    vy[0] <= y0; vy[1] <= y1; vy[2] <= y2;
                    va[0][0] <= {8'd0, c0[23:16]}; va[0][1] <= {8'd0, c1[23:16]}; va[0][2] <= {8'd0, c2[23:16]};
                    va[1][0] <= {8'd0, c0[15:8]};  va[1][1] <= {8'd0, c1[15:8]};  va[1][2] <= {8'd0, c2[15:8]};
                    va[2][0] <= {8'd0, c0[7:0]};   va[2][1] <= {8'd0, c1[7:0]};   va[2][2] <= {8'd0, c2[7:0]};
                    va[3][0] <= z0;                va[3][1] <= z1;                va[3][2] <= z2;
                    k     <= '0;
                    state <= S_AREA;
                end
                S_AREA: begin
                    k <= k + 5'd1;
                    if (k == k_last) state <= S_AREA_W;
                end
                S_AREA_W: if (pend == 3'd0 && !m_out_v) state <= S_ORIENT;
                S_ORIENT: begin
                    if (area == 32'sd0) begin
                        empty <= 1'b1;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        if (area < 0) begin
                            vx[1] <= vx[2]; vx[2] <= vx[1];
                            vy[1] <= vy[2]; vy[2] <= vy[1];
                            for (int j = 0; j < 4; j++) begin va[j][1] <= va[j][2]; va[j][2] <= va[j][1]; end
                            area <= -area;
                        end
                        state <= S_BBOX;
                    end
                end
                // 外接矩形 (ピクセル): (min + 7) >>> 4 .. (max - 8) >>> 4 をクリップ矩形と重ねる。上左の規則。
                // 3 クロックに分ける (1 クロックにすると clk_sys の 63MHz にほとんど余裕がなかった)
                S_BBOX: begin
                    logic signed [15:0] mnx, mxx, mny, mxy;
                    mnx = vx[0]; mxx = vx[0]; mny = vy[0]; mxy = vy[0];
                    for (int i = 1; i < 3; i++) begin
                        if (vx[i] < mnx) mnx = vx[i];
                        if (vx[i] > mxx) mxx = vx[i];
                        if (vy[i] < mny) mny = vy[i];
                        if (vy[i] > mxy) mxy = vy[i];
                    end
                    qx0 <= 13'((17'(mnx) + 17'sd7) >>> 4);
                    qx1 <= 13'((17'(mxx) - 17'sd8) >>> 4);
                    qy0 <= 13'((17'(mny) + 17'sd7) >>> 4);
                    qy1 <= 13'((17'(mxy) - 17'sd8) >>> 4);
                    nb  <= nbits;
                    for (int i = 0; i < 3; i++) begin
                        bias[i] <= !(edy[i] < 0 || (edy[i] == 0 && edx[i] > 0));
                        ex[i]   <= 21'(-(edy[i] * 17'sd16));
                        ey[i]   <= 21'(edx[i] * 17'sd16);
                    end
                    state <= S_BBOX2;
                end
                S_BBOX2: begin
                    if (qx0 < signed'({4'b0, cx0})) qx0 <= signed'({4'b0, cx0});
                    if (qx1 > signed'({4'b0, cx1})) qx1 <= signed'({4'b0, cx1});
                    if (qy0 < signed'({5'b0, cy0})) qy0 <= signed'({5'b0, cy0});
                    if (qy1 > signed'({5'b0, cy1})) qy1 <= signed'({5'b0, cy1});
                    // 除算の準備: kk = 31 - n、an = area << kk、被除数 2^47 - 2^kk
                    an    <= 32'(area) << (5'd31 - nb);
                    dvd   <= (48'd1 << 47) - (48'd1 << (5'd31 - nb));
                    rem   <= 31'(((48'd1 << 47) - (48'd1 << (5'd31 - nb))) >> 17);
                    state <= S_BBOX3;
                end
                S_BBOX3: begin
                    if (qx0 > qx1 || qy0 > qy1) begin
                        empty <= 1'b1;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        empty <= 1'b0;
                        bx0 <= 9'(qx0); bx1 <= 9'(qx1);
                        by0 <= 8'(qy0); by1 <= 8'(qy1);
                        dcnt  <= 5'd16;
                        dbusy <= 1'b1;
                        mq    <= '0;
                        k     <= '0;
                        state <= S_OPS1;
                    end
                end
                S_OPS1, S_OPS2, S_OPS3: begin
                    k <= k + 5'd1;
                    if (k == k_last) begin
                        // (Icarus Verilog は enum の三項演算子の代入を受け付けないので if で書く)
                        if (state == S_OPS1)      after_drain <= S_OPS2;
                        else if (state == S_OPS2) after_drain <= S_OPS3;
                        else                      after_drain <= S_FINAL;
                        state <= S_DRAIN;
                    end
                end
                // 乗算器が空になるのを待つ (S_OPS2 の前は除算も)
                S_DRAIN: if (pend == 3'd0 && !m_out_v && !(after_drain == S_OPS2 && dbusy)) begin
                    k     <= '0;
                    state <= after_drain;
                end
                S_FINAL: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
