// 乗算器の確かめ (G0、rtl/gpu3d/mul_probe.sv): 符号付き 18bit x 18bit を、端の値と乱数で $signed の積と比べる (P も Q も)
`timescale 1ns/1ps
module tb_mul_probe;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic [3:0] addr = '0;
    logic [7:0] wdata = '0, rdata;
    logic       we = 0;
    mul_probe dut (.*);

    task automatic wr(input logic [3:0] a, input logic [7:0] d);
        @(negedge clk); addr = a; wdata = d; we = 1;
        @(negedge clk); we = 0;
    endtask
    task automatic rd(input logic [3:0] a, output logic [7:0] d);
        @(negedge clk); addr = a;
        #1 d = rdata;
    endtask

    int errors = 0;
    task automatic check(input logic signed [17:0] a, input logic signed [17:0] b);
        logic [7:0] d0, d1, d2, d3, d4, e0, e1, e2, e3, e4;
        logic signed [35:0] got_p, got_q, exp;
        wr(4'd0, a[7:0]); wr(4'd1, a[15:8]); wr(4'd2, {6'd0, a[17:16]});
        wr(4'd3, b[7:0]); wr(4'd4, b[15:8]); wr(4'd5, {6'd0, b[17:16]});
        repeat (3) @(negedge clk);
        rd(4'd6, d0); rd(4'd7, d1); rd(4'd8, d2); rd(4'd9, d3); rd(4'd10, d4);
        rd(4'd11, e0); rd(4'd12, e1); rd(4'd13, e2); rd(4'd14, e3); rd(4'd15, e4);
        got_p = {d4[3:0], d3, d2, d1, d0};
        got_q = {e4[3:0], e3, e2, e1, e0};
        exp = a * b;
        if (got_p !== exp || got_q !== exp) begin
            if (errors < 10) $display("  %0d * %0d: P %0d Q %0d, expected %0d", a, b, got_p, got_q, exp);
            errors++;
        end
    endtask

    initial begin
        $dumpfile("build/sim/tb_mul_probe.vcd");
        $dumpvars(0, tb_mul_probe);
        repeat (3) @(negedge clk);
        rst = 0;
        check(18'sd0, 18'sd0);
        check(18'sd1, -18'sd1);
        check(18'sh1FFFF, 18'sh1FFFF);          // 最大 x 最大
        check(-18'sh20000, -18'sh20000);        // 最小 x 最小
        check(-18'sh20000, 18'sh1FFFF);
        for (int i = 0; i < 300; i++) check(18'($urandom), 18'($urandom));
        if (errors == 0) $display("PASS: tb_mul_probe");
        else             $display("FAIL: tb_mul_probe (%0d errors)", errors);
        $finish;
    end
endmodule
