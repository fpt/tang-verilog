// DVI 送信部 (Gowin GW2A 用: OSER10 + TLVDS_OBUF)
// clk_ser は clk_pix の 5 倍 (DDR で 10 ビット送出)
module dvi_tx (
    input  logic       clk_pix,
    input  logic       clk_ser,
    input  logic       rst,
    input  logic [7:0] r,
    input  logic [7:0] g,
    input  logic [7:0] b,
    input  logic       de,
    input  logic       hsync,
    input  logic       vsync,
    output logic       tmds_clk_p,
    output logic       tmds_clk_n,
    output logic [2:0] tmds_d_p,
    output logic [2:0] tmds_d_n
);
    logic [9:0] sym [4];  // 0:B 1:G 2:R 3:CLK

    tmds_encoder u_enc_b (.clk(clk_pix), .rst, .data(b), .ctrl({vsync, hsync}), .de, .tmds(sym[0]));
    tmds_encoder u_enc_g (.clk(clk_pix), .rst, .data(g), .ctrl(2'b00),          .de, .tmds(sym[1]));
    tmds_encoder u_enc_r (.clk(clk_pix), .rst, .data(r), .ctrl(2'b00),          .de, .tmds(sym[2]));
    assign sym[3] = 10'b0000011111;

    logic [3:0] ser;

    for (genvar i = 0; i < 4; i++) begin : g_ser
        OSER10 u_oser (
            .Q(ser[i]),
            .D0(sym[i][0]), .D1(sym[i][1]), .D2(sym[i][2]), .D3(sym[i][3]), .D4(sym[i][4]),
            .D5(sym[i][5]), .D6(sym[i][6]), .D7(sym[i][7]), .D8(sym[i][8]), .D9(sym[i][9]),
            .PCLK(clk_pix),
            .FCLK(clk_ser),
            .RESET(rst)
        );
    end

    TLVDS_OBUF u_obuf_clk (.I(ser[3]), .O(tmds_clk_p), .OB(tmds_clk_n));
    for (genvar i = 0; i < 3; i++) begin : g_obuf
        TLVDS_OBUF u_obuf (.I(ser[i]), .O(tmds_d_p[i]), .OB(tmds_d_n[i]));
    end
endmodule
