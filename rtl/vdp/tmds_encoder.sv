// DVI 1.0 準拠 TMDS エンコーダ (8b/10b, DC バランス付き)
// 出力 tmds[0] から先に送出する。
module tmds_encoder (
    input  logic       clk,
    input  logic       rst,
    input  logic [7:0] data,
    input  logic [1:0] ctrl,   // {C1, C0}
    input  logic       de,
    output logic [9:0] tmds
);
    function automatic logic [3:0] popcount8(input logic [7:0] v);
        logic [3:0] n;
        n = '0;
        for (int i = 0; i < 8; i++) n = n + 4'(v[i]);
        return n;
    endfunction

    // --- Stage 1: 遷移最小化 ---
    logic [3:0] n1_d;
    logic       use_xnor;
    logic [8:0] q_m;

    always_comb begin
        n1_d     = popcount8(data);
        use_xnor = (n1_d > 4'd4) || (n1_d == 4'd4 && data[0] == 1'b0);
        q_m[0]   = data[0];
        for (int i = 1; i < 8; i++)
            q_m[i] = use_xnor ? ~(q_m[i-1] ^ data[i]) : (q_m[i-1] ^ data[i]);
        q_m[8] = ~use_xnor;
    end

    // --- Stage 2: DC バランス ---
    logic signed [4:0] cnt;   // ランニングディスパリティ (1 の数 - 0 の数)
    logic signed [4:0] diff;  // q_m[7:0] の (1 の数 - 0 の数)

    always_comb diff = $signed({1'b0, popcount8(q_m[7:0])}) * 5'sd2 - 5'sd8;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt  <= '0;
            tmds <= 10'b1101010100;
        end else if (!de) begin
            cnt <= '0;
            unique case (ctrl)
                2'b00: tmds <= 10'b1101010100;
                2'b01: tmds <= 10'b0010101011;
                2'b10: tmds <= 10'b0101010100;
                2'b11: tmds <= 10'b1010101011;
            endcase
        end else if (cnt == 0 || diff == 0) begin
            tmds <= {~q_m[8], q_m[8], q_m[8] ? q_m[7:0] : ~q_m[7:0]};
            cnt  <= q_m[8] ? cnt + diff : cnt - diff;
        end else if ((cnt > 0 && diff > 0) || (cnt < 0 && diff < 0)) begin
            tmds <= {1'b1, q_m[8], ~q_m[7:0]};
            cnt  <= cnt + (q_m[8] ? 5'sd2 : 5'sd0) - diff;
        end else begin
            tmds <= {1'b0, q_m[8], q_m[7:0]};
            cnt  <= cnt - (q_m[8] ? 5'sd0 : 5'sd2) + diff;
        end
    end
endmodule
