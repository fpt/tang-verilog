// ビデオタイミング生成 (デフォルト: 640x480 @ 60Hz, ピクセルクロック 25.175MHz)
module video_timing #(
    parameter int H_ACTIVE = 640,
    parameter int H_FP     = 16,
    parameter int H_SYNC   = 96,
    parameter int H_BP     = 48,
    parameter int V_ACTIVE = 480,
    parameter int V_FP     = 10,
    parameter int V_SYNC   = 2,
    parameter int V_BP     = 33
) (
    input  logic        clk,
    input  logic        rst,
    output logic [10:0] x,            // 現在の水平位置 (0 .. H_TOTAL-1)
    output logic [9:0]  y,            // 現在の垂直位置 (0 .. V_TOTAL-1)
    output logic        de,           // 表示期間
    output logic        hsync,        // 負極性
    output logic        vsync,        // 負極性
    output logic        frame_start   // (0,0) で 1 クロック
);
    localparam int H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
    localparam int V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

    always_ff @(posedge clk) begin
        if (rst) begin
            x <= '0;
            y <= '0;
        end else if (x == 11'(H_TOTAL - 1)) begin
            x <= '0;
            y <= (y == 10'(V_TOTAL - 1)) ? '0 : y + 10'd1;
        end else begin
            x <= x + 11'd1;
        end
    end

    assign de          = (x < 11'(H_ACTIVE)) && (y < 10'(V_ACTIVE));
    assign hsync       = !((x >= 11'(H_ACTIVE + H_FP)) && (x < 11'(H_ACTIVE + H_FP + H_SYNC)));
    assign vsync       = !((y >= 10'(V_ACTIVE + V_FP)) && (y < 10'(V_ACTIVE + V_FP + V_SYNC)));
    assign frame_start = (x == '0) && (y == '0);
endmodule
