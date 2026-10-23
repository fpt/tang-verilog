// SDRAM の BIST とレジスタ経由の読み書き: 小さい範囲で合格すること、取り込み位置が悪いと不合格になること
`timescale 1ns/1ps
module tb_mem_test;
    logic        clk = 0, rst = 1;
    logic [6:0]  addr = '0;
    logic [7:0]  wdata = '0, rdata;
    logic        we = 0;

    logic        mem_req, mem_we, mem_ack, init_done;
    logic [20:0] mem_addr;
    logic [31:0] mem_wdata, mem_rdata;
    logic [2:0]  rd_sample;
    logic [8:0]  mem_len;
    logic        mem_rvalid;

    logic        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
    logic [1:0]  ba;
    logic [10:0] sa;
    logic [3:0]  dqm;
    logic [31:0] dq_out;
    wire  [31:0] dq;
    assign dq = dq_oe ? dq_out : 'z;

    mem_test dut (
        .clk, .rst, .addr, .wdata, .we, .rdata,
        .mem_req, .mem_we, .mem_addr, .mem_wdata, .mem_len, .mem_ack, .mem_rvalid, .mem_rdata, .mem_init_done(init_done), .rd_sample, .clk_phase(), .clk_duty()
    );

    sdram_ctrl #(.CLK_HZ(63_000_000), .INIT_US(2)) u_ctrl (
        .clk, .rst, .req(mem_req), .we(mem_we), .addr(mem_addr), .wdata(mem_wdata), .len(mem_len), .ack(mem_ack), .rvalid(mem_rvalid),
        .rdata(mem_rdata), .init_done, .rd_sample,
        .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n), .sdram_we_n(we_n),
        .sdram_ba(ba), .sdram_addr(sa), .sdram_dqm(dqm), .sdram_dq_out(dq_out), .sdram_dq_oe(dq_oe),
        .sdram_dq_in(dq)
    );

    sdram_model model (
        .clk(~clk), .cke, .cs_n, .ras_n, .cas_n, .we_n, .ba, .addr(sa), .dqm, .dq
    );

    always #7.936 clk = ~clk;

    int errors = 0;

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

    task automatic rd32(input logic [6:0] a, output logic [31:0] v);
        logic [7:0] b0, b1, b2, b3;
        rd(a, b0); rd(a + 7'd1, b1); rd(a + 7'd2, b2); rd(a + 7'd3, b3);
        v = {b3, b2, b1, b0};
    endtask

    task automatic wait_idle;
        logic [7:0] s;
        do rd(7'h12, s); while (s[1]);
    endtask

    task automatic bist(input logic [2:0] h, input logic [4:0] size, output logic [7:0] status, output logic [31:0] errs);
        wr(7'h11, {5'b0, h});
        wr(7'h13, {3'b0, size});
        wr(7'h14, 8'h3C);
        wr(7'h10, 8'd1);
        wait_idle();
        rd(7'h12, status);
        rd32(7'h18, errs);
    endtask

    initial begin
        logic [7:0]  s;
        logic [31:0] v;
        $dumpfile("build/sim/tb_mem_test.vcd");
        $dumpvars(0, tb_mem_test);
        repeat (4) @(posedge clk);
        rst = 0;
        do rd(7'h12, s); while (!s[0]);

        // 1024 ワード、取り込み位置 4 で合格
        bist(3'd4, 5'd10, s, v);
        if (s[3:2] != 2'b11 || v != 0) begin $display("  BIST h=4: status %02h, errors %0d", s, v); errors++; end

        // 取り込み位置 6 では全部不一致 (2 周 x 1024 ワード)、最初の不一致はアドレス 0
        bist(3'd6, 5'd10, s, v);
        if (s[3:2] != 2'b01 || v != 2048) begin $display("  BIST h=6: status %02h, errors %0d", s, v); errors++; end
        rd32(7'h1C, v);
        if (v != 0) begin $display("  BIST h=6: first fail address %0h", v); errors++; end

        // レジスタ経由の 1 ワード書き込みと読み出し (アドレスは自動で進む)
        wr(7'h11, 8'd4);
        wr(7'h28, 8'h45); wr(7'h29, 8'h23); wr(7'h2A, 8'h01); wr(7'h2B, 8'h00);
        wr(7'h2C, 8'hEF); wr(7'h2D, 8'hBE); wr(7'h2E, 8'hAD); wr(7'h2F, 8'hDE);
        wr(7'h10, 8'd3);
        wait_idle();
        rd32(7'h28, v);
        if (v != 32'h0001_2346) begin $display("  MEM_ADDR after write: %0h", v); errors++; end
        wr(7'h28, 8'h45);
        wr(7'h2C, 8'h00); wr(7'h2D, 8'h00); wr(7'h2E, 8'h00); wr(7'h2F, 8'h00);
        wr(7'h10, 8'd2);
        wait_idle();
        rd32(7'h2C, v);
        if (v != 32'hDEAD_BEEF) begin $display("  MEM_DATA after read: %0h", v); errors++; end

        // アップロード用のポート: MEM_ADDR = 0x200 から 8 バイト (2 ワード) 流し込み、1 ワードずつ読んで確かめる
        wr(7'h28, 8'h00); wr(7'h29, 8'h02); wr(7'h2A, 8'h00); wr(7'h2B, 8'h00);
        wr(7'h30, 8'h11); wr(7'h30, 8'h22); wr(7'h30, 8'h33); wr(7'h30, 8'h44);
        wr(7'h30, 8'h55); wr(7'h30, 8'h66); wr(7'h30, 8'h77); wr(7'h30, 8'h88);
        wait_idle();
        rd32(7'h28, v);
        if (v != 32'h0000_0202) begin $display("  MEM_ADDR after port: %0h", v); errors++; end
        wr(7'h28, 8'h00); wr(7'h29, 8'h02);
        wr(7'h10, 8'd2); wait_idle(); rd32(7'h2C, v);
        if (v != 32'h4433_2211) begin $display("  port word 0: %0h", v); errors++; end
        wr(7'h10, 8'd2); wait_idle(); rd32(7'h2C, v);
        if (v != 32'h8877_6655) begin $display("  port word 1: %0h", v); errors++; end
        rd(7'h12, s);
        if (s[4]) begin $display("  port overflow flagged"); errors++; end

        if (model.violations != 0) begin $display("  model timing violations: %0d", model.violations); errors++; end
        if (errors == 0) $display("PASS: tb_mem_test");
        else             $display("FAIL: tb_mem_test (%0d errors)", errors);
        $finish;
    end
endmodule
