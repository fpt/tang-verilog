// ビデオタイミング: 1 フレームの総クロック数 / 表示ピクセル数 / 同期パルス数を確認
`timescale 1ns/1ps
module tb_video_timing;
    logic        clk = 0, rst = 1;
    logic [10:0] x;
    logic [9:0]  y;
    logic        de, hsync, vsync, frame_start;

    video_timing dut (.*);

    always #20 clk = ~clk;

    int clocks = 0, de_count = 0, hs_pulses = 0, vs_pulses = 0, vs_clocks = 0;
    logic hs_d = 1, vs_d = 1;
    int errors = 0;

    task automatic check(string name, int got, int exp);
        if (got != exp) begin
            $display("  %s: got %0d, expected %0d", name, got, exp);
            errors++;
        end
    endtask

    initial begin
        $dumpfile("build/sim/tb_video_timing.vcd");
        $dumpvars(0, tb_video_timing);
        repeat (2) @(posedge clk);
        rst = 0;
        // 値はすべて negedge でサンプルする
        do @(negedge clk); while (!frame_start);

        // 1 フレーム分カウント
        do begin
            clocks++;
            if (de) de_count++;
            if (hs_d && !hsync) hs_pulses++;
            if (vs_d && !vsync) vs_pulses++;
            if (!vsync) vs_clocks++;
            hs_d = hsync; vs_d = vsync;
            @(negedge clk);
        end while (!frame_start);

        check("clocks/frame", clocks, 800 * 525);
        check("active pixels", de_count, 640 * 480);
        check("hsync pulses", hs_pulses, 525);
        check("vsync pulses", vs_pulses, 1);
        check("vsync width", vs_clocks, 2 * 800);
        if (errors == 0) $display("PASS: tb_video_timing");
        else             $display("FAIL: tb_video_timing (%0d errors)", errors);
        $finish;
    end
endmodule
