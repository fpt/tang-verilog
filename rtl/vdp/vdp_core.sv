// VDP コア (雛形)
// 今はカラーバー + 市松模様の背景に、フレームごとに跳ね回る 32x32 の「スプライト」を描くだけ。
// ここにタイルマップ / パターンテーブル / スプライト処理を積み上げていく想定。
module vdp_core (
    input  logic        clk,
    input  logic        rst,
    input  logic [10:0] x,
    input  logic [9:0]  y,
    input  logic        de,
    input  logic        hsync,
    input  logic        vsync,
    input  logic        frame_start,
    // 出力は 1 クロック遅延 (同期信号もそろえて遅延させる)
    output logic [7:0]  r,
    output logic [7:0]  g,
    output logic [7:0]  b,
    output logic        de_o,
    output logic        hsync_o,
    output logic        vsync_o
);
    localparam int SCREEN_W = 640;
    localparam int SCREEN_H = 480;
    localparam int SPR_SIZE = 32;

    // --- スプライト位置の更新 (フレーム先頭で 1 回) ---
    logic [10:0] spr_x;
    logic [9:0]  spr_y;
    logic        spr_dx;  // 1: 右へ
    logic        spr_dy;  // 1: 下へ

    always_ff @(posedge clk) begin
        if (rst) begin
            spr_x  <= 11'd100;
            spr_y  <= 10'd60;
            spr_dx <= 1'b1;
            spr_dy <= 1'b1;
        end else if (frame_start) begin
            if (spr_dx) begin
                if (spr_x >= 11'(SCREEN_W - SPR_SIZE - 4)) spr_dx <= 1'b0;
                spr_x <= spr_x + 11'd4;
            end else begin
                if (spr_x <= 11'd4) spr_dx <= 1'b1;
                spr_x <= spr_x - 11'd4;
            end
            if (spr_dy) begin
                if (spr_y >= 10'(SCREEN_H - SPR_SIZE - 3)) spr_dy <= 1'b0;
                spr_y <= spr_y + 10'd3;
            end else begin
                if (spr_y <= 10'd3) spr_dy <= 1'b1;
                spr_y <= spr_y - 10'd3;
            end
        end
    end

    // --- 背景 ---
    logic [23:0] bg;
    always_comb begin
        if (y < 10'd240) begin
            // 8 色カラーバー (80 ピクセル幅)
            unique case (3'(x / 11'd80))
                3'd0:    bg = 24'hFFFFFF;
                3'd1:    bg = 24'hFFFF00;
                3'd2:    bg = 24'h00FFFF;
                3'd3:    bg = 24'h00FF00;
                3'd4:    bg = 24'hFF00FF;
                3'd5:    bg = 24'hFF0000;
                3'd6:    bg = 24'h0000FF;
                default: bg = 24'h000000;
            endcase
        end else begin
            // 16x16 市松模様
            bg = (x[4] ^ y[4]) ? 24'h303040 : 24'h101018;
        end
    end

    // --- スプライト ---
    logic in_spr;
    assign in_spr = (x >= spr_x) && (x < spr_x + 11'(SPR_SIZE)) &&
                    (y >= spr_y) && (y < spr_y + 10'(SPR_SIZE));

    logic [23:0] color;
    assign color = in_spr ? 24'hFF8000 : bg;

    always_ff @(posedge clk) begin
        {r, g, b} <= de ? color : 24'h000000;
        de_o      <= de;
        hsync_o   <= hsync;
        vsync_o   <= vsync;
    end
endmodule
