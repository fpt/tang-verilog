// VDP のレジスタ: ID / VERSION / SCRATCH / CONTROL / FRAME_COUNT / STATUS / IRQ / エラーのクリアを確認
`timescale 1ns/1ps
module tb_vdp_regs;
    logic       clk = 0, rst = 1;
    logic [6:0] addr = '0;
    logic [7:0] wdata = '0, rdata, control;
    logic       we = 0, re = 0;
    logic       vblank_async = 0, frame_toggle_async = 0, error_event = 0;
    logic [31:0] crc_async = '0;
    logic       crc_toggle_async = 0;
    logic [7:0] underflow_count = 8'd7;
    logic [12:0] fb_base;
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

        // FRAME_CRC: トグルが変わったら取り込む。0x05 を読んだ時点の値が 0x06..0x08 に残る
        crc_async = 32'h1234_5678;
        #50 crc_toggle_async = 1;
        #100;
        rd_re(7'h05, d); check("FRAME_CRC[7:0]", d, 8'h78);
        crc_async = 32'hAABB_CCDD;          // 次のフレームの CRC が届いても
        #50 crc_toggle_async = 0;
        #100;
        rd(7'h06, d); check("FRAME_CRC[15:8] (snapshot)", d, 8'h56);
        rd(7'h07, d); check("FRAME_CRC[23:16] (snapshot)", d, 8'h34);
        rd(7'h08, d); check("FRAME_CRC[31:24] (snapshot)", d, 8'h12);
        rd_re(7'h05, d); check("FRAME_CRC[7:0] (next frame)", d, 8'hDD);
        rd(7'h08, d); check("FRAME_CRC[31:24] (next frame)", d, 8'hAA);

        // フレームバッファ: UNDERFLOW はそのまま読め、FB_BASE は 13bit
        rd(7'h09, d); check("UNDERFLOW", d, 8'd7);
        wr(7'h0A, 8'h00); wr(7'h0B, 8'hFF);
        rd(7'h0B, d); check("FB_BASE[12:8]", d, 8'h1F);
        if (fb_base !== 13'h1F00) begin $display("  fb_base output: %h", fb_base); errors++; end
        wr(7'h0A, 8'h00); wr(7'h0B, 8'h01);
        if (fb_base !== 13'h0100) begin $display("  fb_base output: %h", fb_base); errors++; end

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
