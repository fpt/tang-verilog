// VDP のレジスタ: ID / VERSION / SCRATCH / CONTROL / FRAME_COUNT / STATUS / IRQ / エラーのクリアを確認
`timescale 1ns/1ps
module tb_vdp_regs;
    logic       clk = 0, rst = 1;
    logic [6:0] addr = '0;
    logic [7:0] wdata = '0, rdata, control;
    logic       we = 0, re = 0;
    logic       vblank_async = 0, frame_toggle_async = 0, error_event = 0;
    logic       irq, error;

    vdp_regs #(.VERSION(8'h01)) dut (.*);

    always #8 clk = ~clk;

    int errors = 0;

    task automatic check(input string name, input logic [7:0] got, input logic [7:0] exp);
        if (got !== exp) begin
            $display("  %s: got %02h, expected %02h", name, got, exp);
            errors++;
        end
    endtask

    task automatic wr(input logic [6:0] a, input logic [7:0] d);
        @(negedge clk);
        addr = a;
        wdata = d;
        we = 1;
        @(negedge clk);
        we = 0;
    endtask

    task automatic rd(input logic [6:0] a, output logic [7:0] d);
        @(negedge clk);
        addr = a;
        #1 d = rdata;
    endtask

    // SPI スレーブと同じく、読み出した値を取り込むときに re を 1 クロック出す
    task automatic rd_re(input logic [6:0] a, output logic [7:0] d);
        @(negedge clk);
        addr = a;
        re = 1;
        #1 d = rdata;
        @(negedge clk);
        re = 0;
    endtask

    initial begin
        logic [7:0] d;
        int i;
        $dumpfile("build/sim/tb_vdp_regs.vcd");
        $dumpvars(0, tb_vdp_regs);
        repeat (3) @(posedge clk);
        rst = 0;

        rd(7'h7E, d); check("ID", d, 8'h5A);
        rd(7'h7F, d); check("VERSION", d, 8'h01);
        rd(7'h7D, d); check("SCRATCH after reset", d, 8'h00);
        wr(7'h7D, 8'h3C);
        rd(7'h7D, d); check("SCRATCH", d, 8'h3C);
        rd(7'h40, d); check("unmapped", d, 8'h00);

        // フレームカウンタ (ピクセルクロック側のトグルを数える)
        for (i = 0; i < 3; i++) begin
            #100 frame_toggle_async = ~frame_toggle_async;
        end
        #100;
        rd(7'h04, d); check("FRAME_COUNT", d, 8'd3);

        // VBLANK と IRQ
        rd(7'h00, d); check("STATUS (not vblank)", d, 8'h00);
        vblank_async = 1;
        #100;
        rd(7'h00, d); check("STATUS (vblank)", d, 8'h01);
        check("IRQ while disabled", {7'b0, irq}, 8'h00);
        wr(7'h01, 8'h04);
        rd(7'h01, d); check("CONTROL", d, 8'h04);
        #1 check("IRQ while enabled in vblank", {7'b0, irq}, 8'h01);
        vblank_async = 0;
        #100;
        check("IRQ after vblank", {7'b0, irq}, 8'h00);

        // エラーはラッチされ、STATUS を読むとクリア
        @(negedge clk);
        error_event = 1;
        @(negedge clk);
        error_event = 0;
        check("ERROR pin", {7'b0, error}, 8'h01);
        rd(7'h00, d); check("STATUS (error, no re)", d, 8'h02);
        rd(7'h00, d); check("STATUS still latched", d, 8'h02);
        rd_re(7'h00, d); check("STATUS read with re", d, 8'h02);
        rd(7'h00, d); check("STATUS after clear", d, 8'h00);
        check("ERROR pin after clear", {7'b0, error}, 8'h00);

        // リセットでレジスタが戻る
        @(negedge clk);
        rst = 1;
        @(negedge clk);
        rst = 0;
        rd(7'h7D, d); check("SCRATCH after second reset", d, 8'h00);
        rd(7'h01, d); check("CONTROL after second reset", d, 8'h00);

        if (errors == 0) $display("PASS: tb_vdp_regs");
        else             $display("FAIL: tb_vdp_regs (%0d errors)", errors);
        $finish;
    end
endmodule
