// 符号付き 36 x 18 の乗算 (G1、rtl/gpu3d/smul36x18.sv): 端の値と乱数を毎クロック入れ、3 クロック後の結果とタグを $signed の積と比べる
`timescale 1ns/1ps
module tb_smul36x18;
    logic clk = 0;
    always #5 clk = ~clk;

    logic               in_valid = 0, out_valid;
    logic signed [35:0] a = '0;
    logic signed [17:0] b = '0;
    logic [7:0]         in_tag = '0, out_tag;
    logic signed [53:0] p;
    smul36x18 #(.TAG_W(8)) dut (.*);

    logic signed [53:0] exp_q [$];
    logic [7:0]         tag_q [$];
    int errors = 0, checked = 0;
    always @(posedge clk) begin
        if (out_valid) begin
            logic signed [53:0] e;
            logic [7:0] t;
            e = exp_q.pop_front();
            t = tag_q.pop_front();
            checked++;
            if (p !== e || out_tag !== t) begin
                if (errors < 10) $display("  got %0d (tag %0d), expected %0d (tag %0d)", p, out_tag, e, t);
                errors++;
            end
        end
    end

    task automatic put(input logic signed [35:0] x, input logic signed [17:0] y);
        @(negedge clk);
        in_valid = 1; a = x; b = y; in_tag = 8'(checked + exp_q.size());
        exp_q.push_back(54'(x) * 54'(y));
        tag_q.push_back(in_tag);
    endtask

    initial begin
        $dumpfile("build/sim/tb_smul36x18.vcd");
        $dumpvars(0, tb_smul36x18);
        put(0, 0); put(1, -1); put(-1, -1); put(36'sh7FFFFFFFF, 18'sh1FFFF); put(-36'sh800000000, -18'sh20000);
        put(-36'sh800000000, 18'sh1FFFF); put(36'sh7FFFFFFFF, -18'sh20000); put(36'sh000020000, -18'sd3);
        for (int i = 0; i < 2000; i++) put({$urandom, $urandom} >> (i % 30), 18'($urandom) >>> (i % 7));
        @(negedge clk) in_valid = 0;
        repeat (6) @(negedge clk);
        if (checked != 2008 || exp_q.size() != 0) begin $display("  checked %0d, left %0d", checked, exp_q.size()); errors++; end
        if (errors == 0) $display("PASS: tb_smul36x18");
        else             $display("FAIL: tb_smul36x18 (%0d errors)", errors);
        $finish;
    end
endmodule
