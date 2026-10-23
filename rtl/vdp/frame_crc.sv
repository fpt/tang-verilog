// 1 フレームの表示ピクセルの CRC-32 (docs/GPU_PLAN.md の M2)
//   DE 中のピクセルを R, G, B の順のバイト列とみなし、標準の CRC-32 (IEEE 802.3、反転入力・反転出力、
//   初期値 0xFFFFFFFF、最後に全ビット反転) を計算する。Python の zlib.crc32(行優先の rgb24 バイト列) と同じ値になる。
//   VBLANK に入ったところで crc にラッチし、crc_toggle を反転する (別クロックからの読み出し用)。
//   frame はリセットからのフレーム番号で、crc と一緒に変わる (どのフレームの CRC かを参照モデルと突き合わせるため)。
module frame_crc (
    input  logic        clk,
    input  logic        rst,
    input  logic        de,
    input  logic [7:0]  r,
    input  logic [7:0]  g,
    input  logic [7:0]  b,
    input  logic        vblank,
    output logic [31:0] crc,          // 直前のフレームの CRC
    output logic [15:0] frame,        // crc を計算したフレームの番号 (リセット後の最初のフレームが 0)
    output logic        crc_toggle    // crc を更新するたびに反転
);
    localparam logic [31:0] POLY = 32'hEDB8_8320;   // 0x04C11DB7 のビット反転

    function automatic logic [31:0] crc_byte(input logic [31:0] c, input logic [7:0] d);
        logic [31:0] x;
        x = c ^ {24'b0, d};
        for (int i = 0; i < 8; i++) x = (x >> 1) ^ (x[0] ? POLY : 32'h0);
        return x;
    endfunction

    logic [31:0] acc;
    logic        vblank_d;

    always_ff @(posedge clk) begin
        vblank_d <= vblank;
        if (rst) begin
            acc        <= 32'hFFFF_FFFF;
            crc        <= '0;
            crc_toggle <= 1'b0;
            frame      <= 16'hFFFF;     // 最初のフレームを 0 にする
        end else if (vblank && !vblank_d) begin
            crc        <= ~acc;
            frame      <= frame + 16'd1;
            crc_toggle <= ~crc_toggle;
            acc        <= 32'hFFFF_FFFF;
        end else if (de) begin
            acc <= crc_byte(crc_byte(crc_byte(acc, r), g), b);
        end
    end
endmodule
