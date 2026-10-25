// 乗算器の確かめ (docs/GPU3D_PLAN.md の G0)。オープンソースのツール (yosys の synth_gowin → nextpnr-himbaechel → gowin_pack) が
// Gowin の DSP (MULT18X18) に置いた乗算が、実機で正しく動くかをホストから確かめる
//
//   レジスタ (0x50..0x5F の窓の中の番号。複数バイトはリトルエンディアン):
//     0..2   W  A (符号付き 18bit)。2 の [1:0] が上位
//     3..5   W  B (符号付き 18bit)
//     6..10  R  P = A * B を符号付きの乗算で (yosys は MULT18X18 の ASIGN / BSIGN を 1 にする)。10 の [3:0] が上位
//     11..15 R  Q = A * B を「符号なしの乗算 + 符号の補正」で (DSP は符号なし、補正は LUT の引き算 2 つ)
//   書いてから 3 クロックで有効。乗算は 2 段のレジスタを挟む (入力と出力)
//   G0 の実機の結果: P は負の値で間違う (ASIGN / BSIGN が効かず、符号なしで掛けたものになる)、Q は正しい
module mul_probe (
    input  logic       clk,
    input  logic       rst,
    input  logic [3:0] addr,
    input  logic [7:0] wdata,
    input  logic       we,
    output logic [7:0] rdata
);
    logic signed [17:0] a, b, a_q, b_q;
    logic signed [35:0] p;
    logic        [35:0] pu, q;
    logic        [17:0] ua, ub;
    logic               sa, sb;

    assign ua = a_q;
    assign ub = b_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            a <= '0;
            b <= '0;
        end else if (we) begin
            unique case (addr)
                4'd0: a[7:0]   <= wdata;
                4'd1: a[15:8]  <= wdata;
                4'd2: a[17:16] <= wdata[1:0];
                4'd3: b[7:0]   <= wdata;
                4'd4: b[15:8]  <= wdata;
                4'd5: b[17:16] <= wdata[1:0];
                default: ;
            endcase
        end
        a_q <= a;
        b_q <= b;
        p   <= a_q * b_q;
        pu  <= ua * ub;
        sa  <= a_q[17];
        sb  <= b_q[17];
    end
    // 符号付き = 符号なしの積 - (A が負なら B << 18) - (B が負なら A << 18)  (36bit で回る)
    logic [17:0] ua_d, ub_d;
    always_ff @(posedge clk) begin
        ua_d <= ua;
        ub_d <= ub;
    end
    assign q = pu - {sa ? ub_d : 18'd0, 18'd0} - {sb ? ua_d : 18'd0, 18'd0};

    always_comb begin
        unique case (addr)
            4'd6:    rdata = p[7:0];
            4'd7:    rdata = p[15:8];
            4'd8:    rdata = p[23:16];
            4'd9:    rdata = p[31:24];
            4'd10:   rdata = {4'b0, p[35:32]};
            4'd11:   rdata = q[7:0];
            4'd12:   rdata = q[15:8];
            4'd13:   rdata = q[23:16];
            4'd14:   rdata = q[31:24];
            4'd15:   rdata = {4'b0, q[35:32]};
            default: rdata = 8'h00;
        endcase
    end
endmodule
