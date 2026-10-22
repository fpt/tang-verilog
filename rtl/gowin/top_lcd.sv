// Tang Nano 20K + 40 ピン RGB LCD (800x480) トップ
//   27MHz -> rPLL 33MHz (ピクセル)。HDMI 版 (top.sv) と同じテストパターンを 800x480 で出す
//   クロックとタイミングは sipeed/TangNano-20K-example の rgb_lcd/lcd_800_400/cross_bar と同じ
module top_lcd (
    input  logic       clk,          // 27MHz
    input  logic       btn_s1,       // リセット (押下で 1)
    input  logic       btn_s2,
    output logic [5:0] led,          // 負論理
    output logic       lcd_clk,
    output logic       lcd_hsync,    // 負極性
    output logic       lcd_vsync,    // 負極性
    output logic       lcd_de,
    output logic [4:0] lcd_r,
    output logic [5:0] lcd_g,
    output logic [4:0] lcd_b,
    output logic       lcd_bl        // バックライト駆動回路のイネーブル (1 で点灯)
);
    // --- クロック生成 ---
    logic clk_pix, pll_lock;

    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(8),     // /9
        .FBDIV_SEL(10),   // x11 -> 33MHz
        .ODIV_SEL(16),    // VCO = 528MHz
        .DEVICE("GW2AR-18C")
    ) u_pll (
        .CLKIN(clk),
        .CLKOUT(clk_pix),
        .LOCK(pll_lock),
        .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0),
        .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
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

    vdp_video #(.MODE(1)) u_video (
        .clk_pix, .rst, .freeze(1'b0), .fb_en(1'b0), .fb_rgb(24'h0), .x(), .y(), .r, .g, .b,
        .de(lcd_de), .hsync(lcd_hsync), .vsync(lcd_vsync), .vblank(), .frame_start()
    );

    // RGB565 に切り詰める。データは clk_pix の立ち上がりで変わり、パネルは立ち下がりで取り込む
    assign lcd_r   = r[7:3];
    assign lcd_g   = g[7:2];
    assign lcd_b   = b[7:3];
    assign lcd_clk = clk_pix;
    assign lcd_bl  = 1'b1;

    // --- 動作確認用 LED (約 1Hz で流れる) ---
    logic [24:0] div;
    always_ff @(posedge clk_pix) div <= div + 25'd1;
    assign led = btn_s2 ? 6'b000000 : ~(6'b1 << (div[24:22] % 3'd6));  // S2 押下で全点灯
endmodule
