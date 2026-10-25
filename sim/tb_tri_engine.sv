// 三角形のビニング (G2、rtl/gpu3d/tri_engine.sv): SDRAM の代わりのメモリ (返すまでの時間は乱数) で
//   - レコード (パラメータバッファの 24 ワード) の先頭 3 ワード (フラグと単色、外接矩形) が合う
//   - 外接矩形が触れるタイルだけ、そのリストに番号が足され、数 (cnt) が増える。足した組の数 (bin_pairs)
//   - 1 タイル 1,024 個を超えた分と、1 シーン 4,096 個を超えた分は足さず bin_error を出す。bin_clear で数が 0 に戻る
//   - 面積 0 は empty で何もしない
`timescale 1ns/1ps
module tb_tri_engine;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic        push = 0, go = 0, busy, done, empty, zen, bin_clear = 0, bin_error;
    logic [31:0] word = '0;
    logic [8:0]  bx0, bx1;
    logic [7:0]  by0, by1;
    logic [8:0]  cx0 = 0, cx1 = 319;
    logic [7:0]  cy0 = 0, cy1 = 239;
    logic [6:0]  cnt_raddr = '0;
    logic [10:0] cnt_q;
    logic [31:0] bin_pairs, cycles;
    logic        mem_req, mem_we, mem_ack = 0;
    logic [20:0] mem_addr;
    logic [8:0]  mem_len;
    logic [31:0] mem_wdata;
    logic [3:0]  mem_wmask;
    logic        wn = 0;
    logic        mem_wnext;
    assign mem_wnext = wn;
    tri_engine dut (.*);

    // SDRAM の代わり (書くだけ)
    logic [31:0] mem [0:524287];
    always begin
        @(negedge clk);
        if (mem_req && !mem_ack) begin
            int n;
            logic [20:0] a;
            n = int'(mem_len);
            a = mem_addr;
            repeat ($urandom_range(1, 8)) @(negedge clk);
            for (int i = 0; i < n; i++) begin
                wn = 1;
                @(posedge clk);
                mem[int'(a) + i] = mem_wdata;
                @(negedge clk);
                wn = 0;
            end
            mem_ack = 1;
            @(negedge clk);
            mem_ack = 0;
        end
    end

    int errors = 0, err_pulses = 0;
    always @(posedge clk) if (bin_error) err_pulses++;

    // 単色の三角形 (ピクセルの座標)
    task automatic tri_px(input int x0, input int y0, input int x1, input int y1, input int x2, input int y2, input logic [15:0] c);
        @(negedge clk); push = 1; word = {8'h20, 8'h00, c};
        @(negedge clk); word = {16'(y0 * 16), 16'(x0 * 16)};
        @(negedge clk); word = {16'(y1 * 16), 16'(x1 * 16)};
        @(negedge clk); word = {16'(y2 * 16), 16'(x2 * 16)};
        @(negedge clk); push = 0; go = 1;
        @(negedge clk); go = 0;
        while (busy) @(negedge clk);
    endtask
    task automatic clear_bins;
        @(negedge clk) bin_clear = 1;
        @(negedge clk) bin_clear = 0;
        while (busy) @(negedge clk);
    endtask
    function automatic int count_of(input int t);
        return int'(dut.cnt[t]);
    endfunction

    initial begin
        $dumpfile("build/sim/tb_tri_engine.vcd");
        $dumpvars(0, tb_tri_engine);
        repeat (3) @(negedge clk);
        rst = 0;
        clear_bins();

        // 三角形 0: (10,10)-(100,10)-(10,80) → 外接矩形 10..99 x 10..79 → タイル tx 0..3, ty 0..2 (12 組)
        tri_px(10, 10, 100, 10, 10, 80, 16'h1234);
        if (mem[21'h020000] !== 32'h0000_1234 || mem[21'h020001] !== {7'd0, 9'd99, 7'd0, 9'd10} ||
            mem[21'h020002] !== {8'd0, 8'd79, 8'd0, 8'd10}) begin
            $display("  record 0: %h %h %h", mem[21'h020000], mem[21'h020001], mem[21'h020002]); errors++;
        end
        // 三角形 1: タイル 33 (tx 3, ty 3) の中だけ
        tri_px(100, 100, 120, 100, 100, 120, 16'h5678);
        // 面積 0
        tri_px(50, 50, 60, 60, 70, 70, 16'h9999);
        if (!empty) begin $display("  degenerate not empty"); errors++; end
        if (bin_pairs != 13) begin $display("  pairs %0d (expected 13)", bin_pairs); errors++; end
        for (int t = 0; t < 80; t++) begin
            int e;
            e = (t % 10 <= 3 && t / 10 <= 2) ? 1 : 0;
            if (t == 33) e = 1;
            if (count_of(t) != e) begin $display("  tile %0d: count %0d (expected %0d)", t, count_of(t), e); errors++; end
        end
        if (mem[21'h040000 + 33 * 1024] !== 32'd1 || mem[21'h040000 + 12 * 1024] !== 32'd0) begin
            $display("  list entries: %h %h", mem[21'h040000 + 33 * 1024], mem[21'h040000 + 12 * 1024]); errors++;
        end
        // cnt_raddr から読める (止まっているとき)
        cnt_raddr = 7'd33;
        @(negedge clk); @(negedge clk);
        if (cnt_q != 11'd1) begin $display("  cnt_q %0d", cnt_q); errors++; end

        // タイルの上限: タイル 0 に 1,030 個 → 足すのは 1,024 (今 1 個あるので 1,024 個目を超える 7 個が error)
        err_pulses = 0;
        for (int n = 0; n < 1030; n++) tri_px(1, 1, 4, 1, 1, 4, 16'h0001);
        repeat (2) @(negedge clk);                       // 最後の bin_error は busy が落ちるクロックに出る
        if (count_of(0) != 1024 || err_pulses != 7) begin
            $display("  tile overflow: count %0d, %0d errors (expected 1024, 7)", count_of(0), err_pulses); errors++;
        end
        // シーンの上限: 消してから 4,097 個 → 最後の 1 つが error
        clear_bins();
        err_pulses = 0;
        for (int n = 0; n < 4097; n++)                 // 80 タイルに散らす (1 タイル 52 個ほど)
            tri_px((n % 10) * 32 + 2, (n / 10 % 8) * 32 + 2, (n % 10) * 32 + 5, (n / 10 % 8) * 32 + 2, (n % 10) * 32 + 2, (n / 10 % 8) * 32 + 5, 16'h0002);
        repeat (2) @(negedge clk);
        if (err_pulses != 1 || dut.n_tris != 13'd4096) begin
            $display("  scene limit: %0d errors, %0d triangles", err_pulses, dut.n_tris); errors++;
        end
        clear_bins();
        if (count_of(66) != 0 || dut.n_tris != 0) begin $display("  bin_clear: %0d %0d", count_of(66), dut.n_tris); errors++; end

        $display("  %0d pairs, %0d cycles", bin_pairs, cycles);
        if (errors == 0) $display("PASS: tb_tri_engine");
        else             $display("FAIL: tb_tri_engine (%0d errors)", errors);
        $finish;
    end

    initial begin
        #2_000_000_000;
        $display("FAIL: tb_tri_engine (timeout)");
        $finish;
    end
endmodule
