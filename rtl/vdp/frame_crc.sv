// 1 フレームの表示ピクセルの CRC-32 (docs/GPU_PLAN.md の M2)
//   DE 中のピクセルを R, G, B の順のバイト列とみなし、標準の CRC-32 (IEEE 802.3、反転入力・反転出力、
//   初期値 0xFFFFFFFF、最後に全ビット反転) を計算する。Python の zlib.crc32(行優先の rgb24 バイト列) と同じ値になる。
//   VBLANK に入ったところで crc にラッチし、crc_toggle を反転する (別クロックからの読み出し用)。
//   frame はリセットからのフレーム番号で、crc と一緒に変わる (どのフレームの CRC かを参照モデルと突き合わせるため)。
//   印: mark_toggle_async (line_compositor、システムクロック側) が変わってから最初に始まったフレームの CRC を held_crc に残し、
//       mark_count を 1 増やす。GPU の WAIT_VBLANK (印付き) のあと、ラインごとにレジスタを変えたフレームを比べるため。
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
    input  logic        mark_toggle_async,
    output logic [31:0] held_crc,     // 印を付けたフレームの CRC
    output logic [7:0]  mark_count,   // held_crc を更新するたびに 1 増える
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
    logic [1:0]  mark_s;
    logic        mark_seen, armed;   // armed: 今のフレームに印が付いている

    always_ff @(posedge clk) mark_s <= {mark_s[0], mark_toggle_async};

    always_ff @(posedge clk) begin
        vblank_d <= vblank;
        if (rst) begin
            acc        <= 32'hFFFF_FFFF;
            crc        <= '0;
            crc_toggle <= 1'b0;
            frame      <= 16'hFFFF;     // 最初のフレームを 0 にする
            held_crc   <= '0;
            mark_count <= '0;
            mark_seen  <= 1'b0;
            armed      <= 1'b0;
        end else if (vblank && !vblank_d) begin
            crc        <= ~acc;
            frame      <= frame + 16'd1;
            crc_toggle <= ~crc_toggle;
            acc        <= 32'hFFFF_FFFF;
            if (armed) begin
                held_crc   <= ~acc;
                mark_count <= mark_count + 8'd1;
                armed      <= 1'b0;
            end
        end else if (de) begin
            acc <= crc_byte(crc_byte(crc_byte(acc, r), g), b);
        end
        // フレームの先頭 (VBLANK が終わったところ): 印が変わっていたら、このフレームに印を付ける。
        // 画素の積算とは別に判定する (同じクロックに画素があっても落とさないように)
        if (!rst && !vblank && vblank_d) begin
            armed     <= mark_s[1] != mark_seen;
            mark_seen <= mark_s[1];
        end
    end
endmodule
