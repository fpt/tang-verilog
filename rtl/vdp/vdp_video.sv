// タイミング生成 + VDP コアをまとめたもの (ベンダ非依存、シミュレーション可能な範囲)
//   MODE 0: 640x480@60Hz (HDMI/DVI, ピクセルクロック 25.2MHz)
//   MODE 1: 800x480 (40 ピン RGB LCD, ピクセルクロック 33MHz で約 62Hz。
//           タイミングは sipeed/TangNano-20K-example の rgb_lcd/lcd_800_400/cross_bar と同じ)
//   fb_en のときは、テストパターンの代わりに fb_rgb (fb_scanout が x, y の 1 クロック後に出す画素) を出す
module vdp_video #(
    parameter int MODE = 0
) (
    input  logic       clk_pix,
    input  logic       rst,
    input  logic       freeze,       // アニメーション停止 (clk_pix に同期済みであること)
    input  logic       fb_en,        // フレームバッファを表示 (clk_pix に同期済みであること)
    input  logic [23:0] fb_rgb,
    output logic [10:0] x,           // 表示タイミングの位置 (fb_scanout 用)
    output logic [9:0]  y,
    output logic [7:0] r,
    output logic [7:0] g,
    output logic [7:0] b,     // 以下はすべて x, y の 1 クロック後
    output logic       de,
    output logic       hsync,
    output logic       vsync,
    output logic       vblank,       // 表示ライン外 (VBLANK 中)
    output logic       frame_start   // フレーム先頭で 1 クロック
);
    localparam bit LCD      = (MODE == 1);
    localparam int H_ACTIVE = LCD ? 800 : 640;
    localparam int H_FP     = LCD ?  40 :  16;
    localparam int H_SYNC   = LCD ? 128 :  96;
    localparam int H_BP     = LCD ?  88 :  48;
    localparam int V_ACTIVE = 480;
    localparam int V_FP     = LCD ?   1 :  10;
    localparam int V_SYNC   = LCD ?   3 :   2;
    localparam int V_BP     = LCD ?  21 :  33;

    logic        t_de, t_hs, t_vs, t_fs;

    video_timing #(
        .H_ACTIVE(H_ACTIVE), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
        .V_ACTIVE(V_ACTIVE), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP)
    ) u_timing (
        .clk(clk_pix), .rst,
        .x, .y, .de(t_de), .hsync(t_hs), .vsync(t_vs), .frame_start(t_fs)
    );

    logic [7:0] core_r, core_g, core_b;

    assign vblank      = y >= 10'(V_ACTIVE);
    assign frame_start = t_fs;

    vdp_core #(.SCREEN_W(H_ACTIVE), .SCREEN_H(V_ACTIVE)) u_core (
        .clk(clk_pix), .rst,
        .x, .y, .de(t_de), .hsync(t_hs), .vsync(t_vs), .frame_start(t_fs), .freeze,
        .r(core_r), .g(core_g), .b(core_b), .de_o(de), .hsync_o(hsync), .vsync_o(vsync)
    );

    assign {r, g, b} = !fb_en ? {core_r, core_g, core_b} : de ? fb_rgb : 24'h000000;
endmodule
