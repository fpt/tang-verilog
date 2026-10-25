// 符号付き 36bit x 符号付き 18bit = 54bit の乗算 (docs/GPU3D_PLAN.md の G1、三角形のセットアップ用)
//
//   G0 で、DSP (MULT18X18) の符号付きの乗算はオープンソースのツールの組み合わせでは実機で符号なしになると分かったので、
//   DSP には符号なしの 18 x 18 だけをさせ、符号は LUT で直す:
//     A = Ah * 2^18 + Al (Al は符号なし 18bit、Ah は符号付き 18bit)
//     Ah * B = uAh * uB - (Ah < 0 ? uB << 18 : 0) - (B < 0 ? uAh << 18 : 0)    (36bit で回る。|Ah * B| < 2^35 なので正しい)
//     Al * B = uAl * uB - (B < 0 ? uAl << 18 : 0)                              (同じ)
//     P = (Ah * B) << 18 + Al * B
//   1 クロックに 1 つ入れられる。結果は入れてから 3 クロック後 (in_valid → out_valid)。tag は結果と一緒に出てくる。
//   P_W を小さくすると積の下位 P_W ビットだけ出す (2 の補数で回った値)
module smul36x18 #(
    parameter int TAG_W = 8,
    parameter int P_W   = 54
) (
    input  logic               clk,
    input  logic               in_valid,
    input  logic signed [35:0] a,
    input  logic signed [17:0] b,
    input  logic [TAG_W-1:0]   in_tag,
    output logic               out_valid,
    output logic signed [P_W-1:0] p,
    output logic [TAG_W-1:0]   out_tag
);
    // 1 段目: 入力
    logic [17:0]      ah1, al1, b1;
    logic             v1;
    logic [TAG_W-1:0] t1;
    always_ff @(posedge clk) begin
        v1  <= in_valid;
        t1  <= in_tag;
        ah1 <= a[35:18];
        al1 <= a[17:0];
        b1  <= b;
    end

    // 2 段目: 符号なしの積 2 つ (DSP)
    logic [35:0]      ph2, pl2;
    logic [17:0]      ah2, al2, b2;
    logic             v2;
    logic [TAG_W-1:0] t2;
    always_ff @(posedge clk) begin
        v2  <= v1;
        t2  <= t1;
        ph2 <= ah1 * b1;
        pl2 <= al1 * b1;
        ah2 <= ah1;
        al2 <= al1;
        b2  <= b1;
    end

    // 3 段目: 符号の補正と足し合わせ
    logic [35:0] hb, lb;
    assign hb = ph2 - {ah2[17] ? b2 : 18'd0, 18'd0} - {b2[17] ? ah2 : 18'd0, 18'd0};
    assign lb = pl2 - {b2[17] ? al2 : 18'd0, 18'd0};
    always_ff @(posedge clk) begin
        out_valid <= v2;
        out_tag   <= t2;
        p         <= P_W'((54'(signed'(hb)) <<< 18) + 54'(signed'(lb)));
    end
endmodule
