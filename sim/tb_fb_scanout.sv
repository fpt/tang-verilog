// フレームバッファの表示: 小さい画面 (ソース 8x4 -> 出力 16x8) で、全ピクセルが 2 倍に引き伸ばされて出ること、
// メモリが遅すぎると UNDERFLOW を数えることを確認
`timescale 1ns/1ps
module tb_fb_scanout;
    localparam int SRC_W = 8, SRC_H = 4;
    localparam int H_ACTIVE = 2 * SRC_W, H_FP = 2, H_SYNC = 2, H_BP = 2;   // 1 ライン 22 クロック
    localparam int V_ACTIVE = 2 * SRC_H, V_FP = 1, V_SYNC = 1, V_BP = 1;   // 11 ライン
    localparam int V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;
    localparam logic [12:0] BASE = 13'd3;

    logic clk_sys = 0, clk_pix = 0, rst = 1;
    always #3 clk_sys = ~clk_sys;     // システムクロックのほうが速い (実機は 63MHz と 25.2MHz)
    always #10 clk_pix = ~clk_pix;

    logic [10:0] x;
    logic [9:0]  y;
    logic        de, hsync, vsync, frame_start;
    video_timing #(
        .H_ACTIVE(H_ACTIVE), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
        .V_ACTIVE(V_ACTIVE), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP)
    ) u_timing (.clk(clk_pix), .rst, .x, .y, .de, .hsync, .vsync, .frame_start);

    logic        mem_req, mem_ack = 0, mem_rvalid = 0;
    logic [20:0] mem_addr;
    logic [8:0]  mem_len;
    logic [31:0] mem_rdata = '0;
    logic [7:0]  underflow_count;
    logic [23:0] rgb;
    logic        enable = 0;

    fb_scanout #(.SRC_W(SRC_W), .SRC_H(SRC_H), .V_TOTAL(V_TOTAL)) dut (
        .clk_sys, .rst_sys(rst), .fb_base(BASE),
        .mem_req, .mem_addr, .mem_len, .mem_ack, .mem_rvalid, .mem_rdata, .underflow_count,
        .clk_pix, .rst_pix(rst), .enable, .x, .y, .rgb
    );

    // ソース画像のピクセル (RGB565) と、それを 8bit に広げた値
    function automatic logic [15:0] pixel(input int px, input int py);
        return 16'((py * 8 + px) * 16'h0841 ^ (py << 13) ^ (px << 2));
    endfunction
    function automatic logic [23:0] expand(input logic [15:0] p);
        return {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};
    endfunction

    int errors = 0;

    // SDRAM の代わり: (fb_base + line) * 256 から len ワード。latency クロック待ってから返す
    int latency = 4;
    int requests = 0;
    always begin
        int line, i;
        @(negedge clk_sys);
        if (mem_req && !mem_ack) begin
            requests++;
            line = int'(mem_addr >> 8) - int'(BASE);
            if (mem_addr[7:0] != 0 || mem_len != 9'(SRC_W / 2) || line < 0 || line >= SRC_H) begin
                $display("  bad request: addr %h len %0d", mem_addr, mem_len);
                errors++;
            end
            repeat (latency) @(negedge clk_sys);
            for (i = 0; i < SRC_W / 2; i++) begin
                mem_rvalid = 1;
                mem_rdata  = {pixel(2 * i + 1, line), pixel(2 * i, line)};
                @(negedge clk_sys);
            end
            mem_rvalid = 0;
            mem_ack = 1;
            @(negedge clk_sys);
            mem_ack = 0;
        end
    end

    int checked = 0;

    // 出力は x, y の 1 クロック後
    logic [10:0] x_d;
    logic [9:0]  y_d;
    logic        de_d;
    bit          check_on = 0;
    always @(posedge clk_pix) begin
        if (check_on && de_d) begin
            checked++;
            if (rgb !== expand(pixel(int'(x_d) / 2, int'(y_d) / 2))) begin
                if (errors < 10) $display("  (%0d,%0d): got %06h, expected %06h", x_d, y_d, rgb,
                                          expand(pixel(int'(x_d) / 2, int'(y_d) / 2)));
                errors++;
            end
        end
        x_d  <= x;
        y_d  <= y;
        de_d <= de;
    end

    initial begin
        $dumpfile("build/sim/tb_fb_scanout.vcd");
        $dumpvars(0, tb_fb_scanout);
        repeat (3) @(negedge clk_pix);
        rst = 0;
        enable = 1;

        // 最初のフレームはライン 0 を読む前に始まるので、2 フレーム目から全ピクセルを比べる
        @(posedge frame_start);
        @(posedge frame_start);
        check_on = 1;
        @(posedge frame_start);
        @(posedge frame_start);
        check_on = 0;
        if (checked != 2 * H_ACTIVE * V_ACTIVE) begin $display("  checked %0d pixels", checked); errors++; end
        if (underflow_count != 0) begin $display("  unexpected underflow: %0d", underflow_count); errors++; end
        if (requests < 2 * SRC_H) begin $display("  only %0d line requests", requests); errors++; end

        // メモリが出力 2 ライン分 (22 x 2 x 20ns = 880ns) より遅いと間に合わず、UNDERFLOW が増える
        latency = 200;
        @(posedge frame_start);
        @(posedge frame_start);
        if (underflow_count == 0) begin $display("  slow memory did not cause underflow"); errors++; end

        if (errors == 0) $display("PASS: tb_fb_scanout");
        else             $display("FAIL: tb_fb_scanout (%0d errors)", errors);
        $finish;
    end
endmodule
