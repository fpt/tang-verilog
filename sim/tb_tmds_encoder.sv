// TMDS エンコーダ: デコードして元データに戻ること、DC バランスが保たれることを確認
`timescale 1ns/1ps
module tb_tmds_encoder;
    logic       clk = 0, rst = 1;
    logic [7:0] data;
    logic [1:0] ctrl;
    logic       de;
    logic [9:0] tmds;

    tmds_encoder dut (.*);

    always #5 clk = ~clk;

    function automatic logic [7:0] decode(input logic [9:0] s);
        logic [7:0] d, o;
        d = s[9] ? ~s[7:0] : s[7:0];
        o[0] = d[0];
        for (int i = 1; i < 8; i++) o[i] = s[8] ? (d[i] ^ d[i-1]) : ~(d[i] ^ d[i-1]);
        return o;
    endfunction

    int errors = 0;
    int disparity = 0;
    logic [7:0] exp_q[$];
    logic       exp_de_q[$];
    logic [7:0] e;
    logic       ed;

    initial begin
        $dumpfile("build/sim/tb_tmds_encoder.vcd");
        $dumpvars(0, tb_tmds_encoder);
        data = 0; ctrl = 0; de = 0;
        repeat (2) @(posedge clk);
        rst = 0;

        for (int n = 0; n < 20000; n++) begin
            @(negedge clk);
            de   = (n % 100) < 80;
            data = $urandom;
            ctrl = $urandom;
            exp_q.push_back(data);
            exp_de_q.push_back(de);
        end
        @(negedge clk);
        if (errors == 0) $display("PASS: tb_tmds_encoder");
        else             $display("FAIL: tb_tmds_encoder (%0d errors)", errors);
        $finish;
    end

    // 出力は 1 クロック遅れ
    always @(posedge clk) begin
        #1;
        if (!rst && exp_q.size() > 0) begin
            e  = exp_q.pop_front();
            ed = exp_de_q.pop_front();
            if (ed) begin
                if (decode(tmds) !== e) begin
                    errors++;
                    if (errors < 10) $display("mismatch: exp=%02h got=%02h sym=%b", e, decode(tmds), tmds);
                end
                disparity += 2 * $countones(tmds) - 10;
                if (disparity > 10 || disparity < -10) begin
                    errors++;
                    if (errors < 10) $display("disparity out of range: %0d", disparity);
                end
            end else begin
                disparity = 0;
            end
        end
    end
endmodule
