// コマンド GPU: SDRAM の振る舞いモデル相手に、CLEAR (64 ワードずつのバースト)、奇数の端の FILL_RECT (バイトマスク)、
// はみ出しの切り取り、UPLOAD、SWAP (表示が取り込むまで待つ)、知らないコマンド、FIFO の空きとあふれを確認
`timescale 1ns/1ps
module tb_gpu;
    localparam int SRC_W = 320, SRC_H = 4, FIFO_WORDS = 16;

    logic        clk = 0, rst = 1;
    logic [6:0]  addr = '0;
    logic [7:0]  wdata = '0, rdata;
    logic        we = 0, re = 0;
    logic        base_latched = 0;
    logic [12:0] fb_base;

    logic        mem_req, mem_we, mem_ack, mem_wnext, init_done;
    logic [20:0] mem_addr;
    logic [31:0] mem_wdata, rdata32;
    logic [3:0]  mem_wmask;
    logic [8:0]  mem_len;

    logic        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
    logic [1:0]  ba;
    logic [10:0] sa;
    logic [3:0]  dqm;
    logic [31:0] dq_out;
    wire  [31:0] dq;
    assign dq = dq_oe ? dq_out : 'z;

    gpu #(.SRC_W(SRC_W), .SRC_H(SRC_H), .FIFO_WORDS(FIFO_WORDS)) dut (
        .clk, .rst, .addr, .wdata, .we, .re, .rdata,
        .mem_req, .mem_we, .mem_addr, .mem_wdata, .mem_wmask, .mem_len, .mem_ack, .mem_wnext,
        .fb_base, .base_latched
    );

    sdram_ctrl #(.CLK_HZ(63_000_000), .INIT_US(2)) u_ctrl (
        .clk, .rst, .req(mem_req), .we(mem_we), .addr(mem_addr), .wdata(mem_wdata), .wmask(mem_wmask),
        .len(mem_len), .wnext(mem_wnext), .ack(mem_ack), .rvalid(), .rdata(rdata32), .init_done, .rd_sample(3'd4),
        .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n), .sdram_we_n(we_n),
        .sdram_ba(ba), .sdram_addr(sa), .sdram_dqm(dqm), .sdram_dq_out(dq_out), .sdram_dq_oe(dq_oe),
        .sdram_dq_in(dq)
    );

    sdram_model model (.clk(~clk), .cke, .cs_n, .ras_n, .cas_n, .we_n, .ba, .addr(sa), .dqm, .dq);

    always #7.936 clk = ~clk;

    int errors = 0;

    task automatic wr(input logic [6:0] a, input logic [7:0] d);
        @(negedge clk);
        addr = a; wdata = d; we = 1;
        @(negedge clk);
        we = 0;
    endtask

    task automatic rd(input logic [6:0] a, output logic [7:0] d);
        @(negedge clk);
        addr = a;
        #1 d = rdata;
    endtask

    task automatic rd_re(input logic [6:0] a, output logic [7:0] d);
        @(negedge clk);
        addr = a; re = 1;
        #1 d = rdata;
        @(negedge clk);
        re = 0;
    endtask

    task automatic cmd(input logic [31:0] w);
        wr(7'h30, w[7:0]); wr(7'h30, w[15:8]); wr(7'h30, w[23:16]); wr(7'h30, w[31:24]);
    endtask

    task automatic wait_idle;
        logic [7:0] s;
        do rd(7'h40, s); while (s[0]);
    endtask

    // SDRAM のワードアドレス -> モデルの配列の添字 ({バンク, 行, 列})
    function automatic logic [31:0] mem_word(input logic [20:0] a);
        return model.mem[{a[9:8], a[20:10], a[7:0]}];
    endfunction

    // 描く面 (draw_base) のピクセル (x, y)
    function automatic logic [15:0] pixel(input logic [12:0] base, input int x, input int y);
        logic [31:0] w;
        w = mem_word({base + 13'(y), 8'(x / 2)});
        return (x % 2) ? w[31:16] : w[15:0];
    endfunction

    task automatic check_px(input string name, input logic [12:0] base, input int x, input int y, input logic [15:0] exp);
        logic [15:0] got;
        got = pixel(base, x, y);
        if (got !== exp) begin
            if (errors < 20) $display("  %s (%0d,%0d): got %04h, expected %04h", name, x, y, got, exp);
            errors++;
        end
    endtask

    initial begin
        logic [7:0] d, f0, f1;
        int x, y;
        $dumpfile("build/sim/tb_gpu.vcd");
        $dumpvars(0, tb_gpu);
        repeat (4) @(posedge clk);
        rst = 0;
        wait (init_done);

        rd(7'h41, f0); rd(7'h42, f1);
        if ({f1, f0} != 16'(FIFO_WORDS)) begin $display("  initial free: %0d", {f1, f0}); errors++; end
        rd(7'h46, f0); rd(7'h47, f1);
        if ({f1, f0} != 16'd256) begin $display("  initial DRAW_BASE: %0d", {f1, f0}); errors++; end

        // CLEAR: 1 行 160 ワード = 64 + 64 + 32 のバースト
        cmd(32'h0100_1234);
        wait_idle();
        for (y = 0; y < SRC_H; y++) for (x = 0; x < SRC_W; x++) check_px("CLEAR", 13'd256, x, y, 16'h1234);

        // FILL_RECT: x = 3..8 (奇数で始まり偶数で終わる), y = 1..2
        cmd(32'h0200_ABCD); cmd({16'd1, 16'd3}); cmd({16'd2, 16'd6});
        wait_idle();
        for (y = 0; y < SRC_H; y++)
            for (x = 0; x < 12; x++)
                check_px("FILL_RECT", 13'd256, x, y, (y >= 1 && y <= 2 && x >= 3 && x <= 8) ? 16'hABCD : 16'h1234);

        // はみ出し: x = 316..(325), y = 3..(9) -> x = 316..319, y = 3 だけ。画面の外から始まるものは何もしない
        cmd(32'h0200_5555); cmd({16'd3, 16'd316}); cmd({16'd7, 16'd10});
        cmd(32'h0200_7777); cmd({16'd0, 16'd400}); cmd({16'd2, 16'd2});
        wait_idle();
        for (x = 312; x < SRC_W; x++) check_px("clipped", 13'd256, x, 3, (x >= 316) ? 16'h5555 : 16'h1234);
        check_px("clipped (row 2)", 13'd256, 317, 2, 16'h1234);

        // UPLOAD: ワードアドレス 0x12345 から 3 ワード
        cmd(32'h0400_0003); cmd(32'h0001_2345); cmd(32'hDEAD_0001); cmd(32'hDEAD_0002); cmd(32'hDEAD_0003);
        wait_idle();
        for (x = 0; x < 3; x++)
            if (mem_word(21'h12345 + 21'(x)) !== 32'hDEAD_0001 + 32'(x)) begin
                $display("  UPLOAD word %0d: %08h", x, mem_word(21'h12345 + 21'(x))); errors++;
            end

        // 知らないコマンド: エラーが立ち、STATUS を読むと消える。後続は普通に実行される
        cmd(32'h7F00_0000);
        cmd(32'h0100_0F0F);
        wait_idle();
        rd_re(7'h40, d);
        if (!d[1]) begin $display("  unknown command did not set error"); errors++; end
        rd(7'h40, d);
        if (d[1]) begin $display("  error not cleared by reading STATUS"); errors++; end
        check_px("CLEAR after unknown", 13'd256, 5, 0, 16'h0F0F);

        // SWAP: 入れ替えて、fb_scanout が取り込むまで (base_latched) 実行中のまま
        cmd(32'h0300_0000);
        repeat (20) @(negedge clk);
        rd(7'h40, d);
        if (!d[0]) begin $display("  SWAP finished before base_latched"); errors++; end
        if (fb_base !== 13'd256) begin $display("  fb_base after SWAP: %0d", fb_base); errors++; end
        rd(7'h46, f0);
        if (f0 != 8'd0) begin $display("  DRAW_BASE after SWAP: %0d", f0); errors++; end

        // 待っているあいだに FIFO をあふれさせる (16 ワード + 2)
        for (x = 0; x < FIFO_WORDS + 2; x++) cmd(32'h0000_0000);
        rd(7'h41, f0);
        if (f0 != 8'd0) begin $display("  free while full: %0d", f0); errors++; end
        rd_re(7'h40, d);
        if (!d[2]) begin $display("  overflow not flagged"); errors++; end

        @(negedge clk); base_latched = 1; @(negedge clk); base_latched = 0;
        wait_idle();
        rd(7'h41, f0);
        if (f0 != 8'(FIFO_WORDS)) begin $display("  free after drain: %0d", f0); errors++; end

        // 入れ替えたあとの描く面 (0) に描ける
        cmd(32'h0200_4321); cmd({16'd0, 16'd0}); cmd({16'd1, 16'd1});
        wait_idle();
        check_px("draw to new DRAW_BASE", 13'd0, 0, 0, 16'h4321);

        if (model.violations != 0) begin $display("  model timing violations: %0d", model.violations); errors++; end
        if (errors == 0) $display("PASS: tb_gpu");
        else             $display("FAIL: tb_gpu (%0d errors)", errors);
        $finish;
    end
endmodule
