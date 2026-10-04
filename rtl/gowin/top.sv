// Tang Nano 20K トップ
//   27MHz -> rPLL 126MHz (シリアル) -> CLKDIV /5 -> 25.2MHz (ピクセル)
module top (
    input  logic       clk,          // 27MHz
    input  logic       btn_s1,       // リセット (押下で 1)
    input  logic       btn_s2,
    output logic [5:0] led,          // 負論理
    output logic       tmds_clk_p,
    output logic       tmds_clk_n,
    output logic [2:0] tmds_d_p,
    output logic [2:0] tmds_d_n
);
    // --- クロック生成 ---
    logic clk_ser, clk_pix, pll_lock;

    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(2),     // /3
        .FBDIV_SEL(13),   // x14  -> 126MHz
        .ODIV_SEL(4),     // VCO = 504MHz
        .DEVICE("GW2AR-18C")
    ) u_pll (
        .CLKIN(clk),
        .CLKOUT(clk_ser),
        .LOCK(pll_lock),
        .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0),
        .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );

    CLKDIV #(.DIV_MODE("5")) u_clkdiv (
        .HCLKIN(clk_ser),
        .RESETN(pll_lock),
        .CALIB(1'b0),
        .CLKOUT(clk_pix)
    );

    // --- リセット同期化 ---
    logic [3:0] rst_sync = '1;
    always_ff @(posedge clk_pix or negedge pll_lock) begin
        if (!pll_lock) rst_sync <= '1;
        else           rst_sync <= {rst_sync[2:0], btn_s1};
    end
    logic rst;
    assign rst = rst_sync[3];

    // --- 映像 ---
    logic [7:0] r, g, b;
    logic de, hsync, vsync;

    vdp_video u_video (.clk_pix, .rst, .r, .g, .b, .de, .hsync, .vsync);

    dvi_tx u_dvi (
        .clk_pix, .clk_ser, .rst,
        .r, .g, .b, .de, .hsync, .vsync,
        .tmds_clk_p, .tmds_clk_n, .tmds_d_p, .tmds_d_n
    );

    // --- 動作確認用 LED (約 1.5Hz で流れる) ---
    logic [24:0] div;
    always_ff @(posedge clk_pix) div <= div + 25'd1;
    assign led = btn_s2 ? 6'b000000 : ~(6'b1 << (div[24:22] % 3'd6));  // S2 押下で全点灯
endmodule
