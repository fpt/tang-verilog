// フレーム CRC: 既知の値 (CRC-32("123456789") = 0xCBF43926) と、2 フレーム目で計算し直されることを確認
`timescale 1ns/1ps
module tb_frame_crc;
    logic        clk = 0, rst = 1;
    logic        de = 0, vblank = 0;
    logic [7:0]  r = 0, g = 0, b = 0;
    logic [31:0] crc;
    logic        crc_toggle;
    logic [15:0] frame;

    frame_crc dut (.*);

    always #20 clk = ~clk;

    int errors = 0;

    // "123", "456", "789" を 3 ピクセルとして流し、VBLANK に入る
    task automatic send_frame(input logic [7:0] first);
        @(negedge clk);
        vblank = 0;
        de = 1; {r, g, b} = {first, "23"};
        @(negedge clk); {r, g, b} = "456";
        @(negedge clk); {r, g, b} = "789";
        @(negedge clk);
        de = 0;
        repeat (3) @(negedge clk);
        vblank = 1;
        repeat (3) @(negedge clk);
    endtask

    initial begin
        logic t0;
        $dumpfile("build/sim/tb_frame_crc.vcd");
        $dumpvars(0, tb_frame_crc);
        repeat (2) @(negedge clk);
        rst = 0;

        t0 = crc_toggle;
        send_frame("1");
        if (crc !== 32'hCBF4_3926) begin $display("  CRC(\"123456789\"): got %08h", crc); errors++; end
        if (crc_toggle === t0) begin $display("  crc_toggle did not change"); errors++; end
        if (frame !== 16'd0) begin $display("  first frame number: %0d", frame); errors++; end

        // 2 フレーム目も同じ内容なら同じ CRC (初期値に戻っている)
        send_frame("1");
        if (crc !== 32'hCBF4_3926) begin $display("  second frame: got %08h", crc); errors++; end
        if (frame !== 16'd1) begin $display("  second frame number: %0d", frame); errors++; end

        // 1 バイト違えば CRC も変わる
        send_frame("0");
        if (crc === 32'hCBF4_3926) begin $display("  CRC did not change for different pixels"); errors++; end

        if (errors == 0) $display("PASS: tb_frame_crc");
        else             $display("FAIL: tb_frame_crc (%0d errors)", errors);
        $finish;
    end
endmodule
