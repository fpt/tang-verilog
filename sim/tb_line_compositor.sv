// ラインごとの合成: 小さい画面 (ソース 8x4 -> 出力 16x8) で確かめる
//   - ビットマップ レイヤ: 全ピクセルが 2 倍に引き伸ばされて出る。fb_base はフレームの途中で変えても次のフレームから
//   - ビットマップ レイヤを切ると背景色、透過色を有効にすると透過色のピクセルが背景色になる
//   - レジスタはラインの合成を始めるときに取り込む (line_start ごとに背景色を変えると、ラインごとに違う色になる)
//   - line_start / line_num が毎フレーム 0..H-1 の順に出る。mark_req で次のライン 0 のときだけ mark_toggle が変わる
//   - メモリが遅すぎると UNDERFLOW を数える
`timescale 1ns/1ps
module tb_line_compositor;
    localparam int SRC_W = 8, SRC_H = 4;
    localparam int H_ACTIVE = 2 * SRC_W, H_FP = 2, H_SYNC = 2, H_BP = 2;   // 1 ライン 22 クロック
    localparam int V_ACTIVE = 2 * SRC_H, V_FP = 1, V_SYNC = 1, V_BP = 1;   // 11 ライン
    localparam int V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;
    localparam logic [12:0] BASE = 13'd3;
    localparam logic [12:0] OTHER = 13'd40;

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

    line_compositor #(.SRC_W(SRC_W), .SRC_H(SRC_H), .V_TOTAL(V_TOTAL)) dut (
        .clk_sys, .rst_sys(rst), .fb_base, .base_latched, .bg_color, .layer_ctrl, .bitmap_key,
        .mark_req, .mark_toggle, .line_start, .line_num,
        .mem_req, .mem_addr, .mem_len, .mem_ack, .mem_rvalid, .mem_rdata, .underflow_count,
        .clk_pix, .rst_pix(rst), .x, .y, .rgb
    );

    // ソース画像のピクセル (RGB565) と、それを 8bit に広げた値
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
    int requests = 0;
    int latches = 0;
    always begin
        int line, i;
        @(negedge clk_sys);
        if (mem_req && !mem_ack) begin
            requests++;
            line = int'(mem_addr >> 8) - int'(BASE);
            if (mem_addr >= 21'(int'(OTHER) << 8)) line = int'(mem_addr >> 8) - int'(OTHER) + 100;   // もう 1 つの面
            // リセット直後、最初にライン 0 で fb_base を取り込むまではフレームの面が決まっていないので見ない
            if (latches > 0 && (mem_addr[7:0] != 0 || mem_len != 9'(SRC_W / 2) || line < 0 || (line >= SRC_H && line < 100))) begin
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

    // line_start の順番: 前のラインの次 (最後の次は 0) であること
    int other_reqs = 0, line_events = 0, mark_flips = 0, line_order_errors = 0;
    int last_line = -1;
    logic req_d = 0, mark_d = 0;
    bit   per_line_bg = 0;
    always @(posedge clk_sys) begin
        if (base_latched) latches++;
        if (mem_req && !req_d && mem_addr >= 21'(int'(OTHER) << 8)) other_reqs++;   // 新しい要求だけ数える
        req_d <= mem_req;
        if (line_start) begin
            line_events++;
            if (last_line >= 0 && int'(line_num) != (last_line + 1) % SRC_H) line_order_errors++;
            last_line = int'(line_num);
            // ラインごとに背景色を変える: line_num の合成が始まったので、次のラインの色にしておく
            if (per_line_bg) bg_color <= line_color((int'(line_num) + 1) % SRC_H);
        end
        if (mark_toggle != mark_d) begin
            mark_flips++;
            if (!(line_start && line_num == 0)) begin
                $display("  mark_toggle changed outside line 0"); errors++;
            end
        end
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
        @(posedge frame_start);       // 設定を変えたあとの最初のフレームは見ない
        checked = 0;
        check_on = 1;
        repeat (frames) @(posedge frame_start);
        check_on = 0;
        if (checked != frames * H_ACTIVE * V_ACTIVE) begin $display("  mode %0d: checked %0d pixels", m, checked); errors++; end
    endtask

    initial begin
        int flips0;
        $dumpfile("build/sim/tb_line_compositor.vcd");
        $dumpvars(0, tb_line_compositor);
        repeat (3) @(negedge clk_pix);
        rst = 0;

        // ビットマップ レイヤ (既定)
        check_frames(0, 2);
        if (underflow_count != 0) begin $display("  unexpected underflow: %0d", underflow_count); errors++; end
        if (requests < 2 * SRC_H) begin $display("  only %0d line requests", requests); errors++; end

        // fb_base をフレームの途中 (ライン 3 の表示中) で変えても、そのフレームの残りは前の面のまま。次のフレームのライン 0 から新しい面
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

        // ビットマップの透過色: ピクセル (1,1) と同じ色のところが背景色になる
        key_px = pixel(1, 1);
        bitmap_key = key_px;
        bg_color = 16'hABCD;
        layer_ctrl = 2'b11;
        check_frames(2, 2);
        layer_ctrl = 2'b01;

        // line_start の順番と、印 (次のライン 0 で 1 回だけ)
        if (line_order_errors != 0) begin $display("  line_start out of order: %0d", line_order_errors); errors++; end
        if (line_events < 8 * SRC_H) begin $display("  only %0d line_start", line_events); errors++; end
        flips0 = mark_flips;
        @(negedge clk_sys); mark_req = 1; @(negedge clk_sys); mark_req = 0;
        repeat (3) @(posedge frame_start);
        if (mark_flips - flips0 != 1) begin $display("  mark flips after one mark_req: %0d", mark_flips - flips0); errors++; end

        // メモリが出力 2 ライン分 (22 x 2 x 20ns = 880ns) より遅いと間に合わず、UNDERFLOW が増える
        latency = 200;
        @(posedge frame_start);
        @(posedge frame_start);
        if (underflow_count == 0) begin $display("  slow memory did not cause underflow"); errors++; end

        if (errors == 0) $display("PASS: tb_line_compositor");
        else             $display("FAIL: tb_line_compositor (%0d errors)", errors);
        $finish;
    end
endmodule
