// フレームバッファの表示 (G0、rtl/gpu3d/fb_line.sv): 小さい画面 (ソース 8x4 -> 出力 16x8) で確かめる
//   - ビットマップ: 全ピクセルが 2 倍に引き伸ばされて出る。fb_base はフレームの途中で変えても次のフレームから
//   - ビットマップを切ると背景色 (ラインの合成を始めるときに取り込むので、line_start ごとに変えるとラインごとに違う色)
//   - 透過色を有効にすると、透過色のピクセルが背景色
//   - line_start / line_num が毎フレーム 0..H-1 の順に出る。mark_req で次のライン 0 のときだけ mark_toggle が変わる
//   - メモリが遅すぎると UNDERFLOW を数える
`timescale 1ns/1ps
module tb_fb_line;
    localparam int SRC_W = 8, SRC_H = 4;
    localparam int H_ACTIVE = 2 * SRC_W, H_FP = 2, H_SYNC = 2, H_BP = 20;
    localparam int V_ACTIVE = 2 * SRC_H, V_FP = 1, V_SYNC = 1, V_BP = 1;
    localparam int V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;
    localparam logic [12:0] BASE = 13'd3;
    localparam logic [12:0] OTHER = 13'd40;

    logic clk_sys = 0, clk_pix = 0, rst = 1;
    always #3 clk_sys = ~clk_sys;
    always #10 clk_pix = ~clk_pix;

    logic [10:0] x;
    logic [9:0]  y;
    logic        de, hsync, vsync, frame_start;
    video_timing #(
        .H_ACTIVE(H_ACTIVE), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
        .V_ACTIVE(V_ACTIVE), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP)
    ) u_timing (.clk(clk_pix), .rst, .x, .y, .de, .hsync, .vsync, .frame_start);

    logic [12:0] fb_base = BASE;
    logic        base_latched;
    logic [15:0] bg_color = 16'h0000, bitmap_key = 16'h0000;
    logic [1:0]  layer_ctrl = 2'b01;
    logic        mark_req = 0, mark_toggle, line_start;
    logic [7:0]  line_num;
    logic        mem_req, mem_ack = 0, mem_rvalid = 0;
    logic [20:0] mem_addr;
    logic [8:0]  mem_len;
    logic [31:0] mem_rdata = '0;
    logic [7:0]  underflow_count;
    logic [23:0] rgb;

    fb_line #(.SRC_W(SRC_W), .SRC_H(SRC_H), .V_TOTAL(V_TOTAL)) dut (
        .clk_sys, .rst_sys(rst), .fb_base, .base_latched, .bg_color, .layer_ctrl, .bitmap_key,
        .mark_req, .mark_toggle, .line_start, .line_num,
        .mem_req, .mem_addr, .mem_len, .mem_ack, .mem_rvalid, .mem_rdata, .underflow_count,
        .clk_pix, .rst_pix(rst), .x, .y, .rgb
    );

    function automatic logic [15:0] pixel(input int px, input int py);
        return 16'((py * 8 + px) * 16'h0841 ^ (py << 13) ^ (px << 2));
    endfunction
    function automatic logic [23:0] expand(input logic [15:0] p);
        return {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};
    endfunction
    function automatic logic [15:0] line_color(input int n);
        return 16'(16'h1111 * (n + 1));
    endfunction

    int errors = 0;

    // SDRAM の代わり: (fb_base + line) * 256 から len ワード。latency クロック待ってから返す
    int latency = 4;
    int requests = 0, other_reqs = 0, latches = 0;
    always begin
        int line, i;
        @(negedge clk_sys);
        if (mem_req && !mem_ack) begin
            requests++;
            line = int'(mem_addr >> 8) - int'(BASE);
            if (mem_addr >= 21'(int'(OTHER) << 8)) begin
                line = int'(mem_addr >> 8) - int'(OTHER) + 100;
                other_reqs++;
            end
            if (latches > 0 && (mem_addr[7:0] != 0 || mem_len != 9'(SRC_W / 2) || line < 0 || (line >= SRC_H && line < 100))) begin
                $display("  bad request: addr %h len %0d", mem_addr, mem_len);
                errors++;
            end
            repeat (latency) @(negedge clk_sys);
            for (i = 0; i < int'(mem_len); i++) begin
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
    always @(posedge clk_sys) if (base_latched) latches++;

    // line_start の順番、ラインごとの背景色、印
    int  expect_line = -1, line_order_errors = 0, line_events = 0, mark_flips = 0;
    bit  per_line_bg = 0;
    logic mark_d = 0;
    always @(posedge clk_sys) begin
        if (line_start) begin
            if (expect_line >= 0 && int'(line_num) != expect_line) line_order_errors++;   // リセット直後の最初のラインは途中から
            expect_line = (int'(line_num) + 1) % SRC_H;
            line_events++;
            if (per_line_bg) bg_color <= line_color((int'(line_num) + 1) % SRC_H);
        end
        if (mark_toggle != mark_d) mark_flips++;
        mark_d <= mark_toggle;
    end

    // 出力は x, y の 1 クロック後。mode: 0 = ビットマップ、1 = 背景色だけ (ラインごと)、2 = 透過色あり
    logic [10:0] x_d;
    logic [9:0]  y_d;
    logic        de_d;
    bit          check_on = 0;
    int          mode = 0, checked = 0;
    logic [15:0] key_px;
    always @(posedge clk_pix) begin
        if (check_on && de_d) begin
            logic [15:0] e;
            int sx, sy;
            sx = int'(x_d) / 2;
            sy = int'(y_d) / 2;
            unique case (mode)
                0: e = pixel(sx, sy);
                1: e = line_color(sy);
                default: e = (pixel(sx, sy) == key_px) ? 16'hABCD : pixel(sx, sy);
            endcase
            checked++;
            if (rgb !== expand(e)) begin
                if (errors < 10) $display("  mode %0d (%0d,%0d): got %06h, expected %06h", mode, x_d, y_d, rgb, expand(e));
                errors++;
            end
        end
        x_d  <= x;
        y_d  <= y;
        de_d <= de;
    end

    task automatic check_frames(input int m, input int frames);
        mode = m;
        @(posedge frame_start);
        @(posedge frame_start);
        checked = 0;
        check_on = 1;
        repeat (frames) @(posedge frame_start);
        check_on = 0;
        if (checked != frames * H_ACTIVE * V_ACTIVE) begin $display("  mode %0d: checked %0d pixels", m, checked); errors++; end
    endtask

    initial begin
        int flips0;
        $dumpfile("build/sim/tb_fb_line.vcd");
        $dumpvars(0, tb_fb_line);
        repeat (3) @(negedge clk_pix);
        rst = 0;

        check_frames(0, 2);
        if (underflow_count != 0) begin $display("  unexpected underflow: %0d", underflow_count); errors++; end
        if (requests < 2 * SRC_H) begin $display("  only %0d line requests", requests); errors++; end

        // fb_base をフレームの途中で変えても、そのフレームの残りは前の面のまま
        other_reqs = 0;
        wait (y == 10'd3);
        fb_base = OTHER;
        wait (y == 10'(V_ACTIVE));
        if (other_reqs != 0) begin $display("  fb_base changed mid-frame: %0d requests to the other plane", other_reqs); errors++; end
        @(posedge frame_start);
        @(posedge frame_start);
        if (other_reqs < SRC_H) begin $display("  new plane not used after the frame: %0d requests", other_reqs); errors++; end
        fb_base = BASE;

        // ビットマップを切り、ラインごとに背景色を変える
        layer_ctrl = 2'b00;
        per_line_bg = 1;
        check_frames(1, 2);
        per_line_bg = 0;

        // 透過色
        key_px = pixel(1, 1);
        bitmap_key = key_px;
        bg_color = 16'hABCD;
        layer_ctrl = 2'b11;
        check_frames(2, 2);
        layer_ctrl = 2'b01;

        if (line_order_errors != 0) begin $display("  line_start out of order: %0d", line_order_errors); errors++; end
        flips0 = mark_flips;
        @(negedge clk_sys); mark_req = 1; @(negedge clk_sys); mark_req = 0;
        repeat (3) @(posedge frame_start);
        if (mark_flips - flips0 != 1) begin $display("  mark flips after one mark_req: %0d", mark_flips - flips0); errors++; end

        if (underflow_count != 0) begin $display("  underflow before the slow-memory test: %0d", underflow_count); errors++; end
        latency = 400;
        @(posedge frame_start);
        @(posedge frame_start);
        if (underflow_count == 0) begin $display("  slow memory did not cause underflow"); errors++; end

        if (errors == 0) $display("PASS: tb_fb_line");
        else             $display("FAIL: tb_fb_line (%0d errors)", errors);
        $finish;
    end
endmodule
