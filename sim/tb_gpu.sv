// コマンド GPU: SDRAM の振る舞いモデル相手に、CLEAR (64 ワードずつのバースト)、奇数の端の FILL_RECT (バイトマスク)、
// はみ出しの切り取り、UPLOAD、SWAP (表示が取り込むまで待つ)、知らないコマンド、FIFO の空きとあふれ、
// DRAW_LINE (8 方向・水平・垂直・1 点・画面の外から)、POINT、CLIP (CLEAR には効かない) を確認
`timescale 1ns/1ps
module tb_gpu;
    localparam int SRC_W = 320, SRC_H = 16, FIFO_WORDS = 16;

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

    // ホストと同じく FIFO の空き (GPU_FREE) を見てから送る
    task automatic cmd(input logic [31:0] w);
        logic [7:0] lo, hi;
        do begin
            rd(7'h41, lo); rd(7'h42, hi);
        end while ({hi, lo} == 16'd0);
        wr(7'h30, w[7:0]); wr(7'h30, w[15:8]); wr(7'h30, w[23:16]); wr(7'h30, w[31:24]);
    endtask

    // あふれのテスト用: 空きを見ずに送る
    task automatic cmd_nowait(input logic [31:0] w);
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

    // ---- 線のテスト用: 期待値の 320x16 と、GPU と同じ規則で期待値を描くタスク ----
    logic [15:0] exp_px [0:SRC_H-1][0:SRC_W-1];
    int ecx0 = 0, ecy0 = 0, ecx1 = SRC_W - 1, ecy1 = SRC_H - 1;   // 期待値側のクリップ矩形

    task automatic exp_clear(input logic [15:0] c);
        for (int yy = 0; yy < SRC_H; yy++) for (int xx = 0; xx < SRC_W; xx++) exp_px[yy][xx] = c;
    endtask

    task automatic exp_plot(input int px, input int py, input logic [15:0] c);
        if (px >= ecx0 && px <= ecx1 && py >= ecy0 && py <= ecy1) exp_px[py][px] = c;
    endtask

    // ブレゼンハム (rtl/vdp/gpu.sv と tools/harness/gpu_model.py と同じ): err = dx + dy、e2 = 2 err
    task automatic line(input int x0, input int y0, input int x1, input int y1, input logic [15:0] c);
        int dx, dy, sx, sy, err, e2;
        cmd({8'h06, 8'h00, c}); cmd({16'(y0), 16'(x0)}); cmd({16'(y1), 16'(x1)});
        dx = (x1 > x0) ? x1 - x0 : x0 - x1;
        dy = (y1 > y0) ? y0 - y1 : y1 - y0;
        sx = (x0 < x1) ? 1 : -1;
        sy = (y0 < y1) ? 1 : -1;
        err = dx + dy;
        forever begin
            exp_plot(x0, y0, c);
            if (x0 == x1 && y0 == y1) break;
            e2 = 2 * err;
            if (e2 >= dy) begin err += dy; x0 += sx; end
            if (e2 <= dx) begin err += dx; y0 += sy; end
        end
    endtask

    task automatic point(input int px, input int py, input logic [15:0] c);
        cmd({8'h05, 8'h00, c}); cmd({16'(py), 16'(px)});
        exp_plot(px, py, c);
    endtask

    task automatic fill(input int fx, input int fy, input int fw, input int fh, input logic [15:0] c);
        cmd({8'h02, 8'h00, c}); cmd({16'(fy), 16'(fx)}); cmd({16'(fh), 16'(fw)});
        for (int yy = fy; yy < fy + fh; yy++) for (int xx = fx; xx < fx + fw; xx++) if (xx < SRC_W && yy < SRC_H) exp_plot(xx, yy, c);
    endtask

    task automatic clip(input int x0, input int y0, input int x1, input int y1);
        cmd({8'h07, 24'h0}); cmd({16'(y0), 16'(x0)}); cmd({16'(y1), 16'(x1)});
        ecx0 = x0; ecy0 = y0;
        ecx1 = (x1 > SRC_W - 1) ? SRC_W - 1 : x1;
        ecy1 = (y1 > SRC_H - 1) ? SRC_H - 1 : y1;
    endtask

    task automatic check_all(input string name);
        int bad;
        bad = 0;
        for (int yy = 0; yy < SRC_H; yy++)
            for (int xx = 0; xx < SRC_W; xx++)
                if (pixel(13'd256, xx, yy) !== exp_px[yy][xx]) begin
                    if (bad < 8) $display("  %s (%0d,%0d): got %04h, expected %04h", name, xx, yy, pixel(13'd256, xx, yy), exp_px[yy][xx]);
                    bad++;
                end
        if (bad != 0) begin $display("  %s: %0d pixels differ", name, bad); errors++; end
    endtask

    // 止まったときのための見張り (シミュレーション時間 20ms)
    initial begin
        #20_000_000;
        $display("FAIL: tb_gpu (timeout: GPU state %0d, lx %0d ly %0d, ex %0d ey %0d, FIFO count %0d)",
                 dut.state, dut.lx, dut.ly, dut.ex, dut.ey, dut.count);
        $finish;
    end

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

        // はみ出し: x = 316..(325), y = 14..(20) -> x = 316..319, y = 14..15 だけ。画面の外から始まるものは何もしない
        cmd(32'h0200_5555); cmd({16'd14, 16'd316}); cmd({16'd7, 16'd10});
        cmd(32'h0200_7777); cmd({16'd0, 16'd400}); cmd({16'd2, 16'd2});
        wait_idle();
        for (x = 312; x < SRC_W; x++) check_px("clipped", 13'd256, x, 15, (x >= 316) ? 16'h5555 : 16'h1234);
        check_px("clipped (row 13)", 13'd256, 317, 13, 16'h1234);

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

        // ---- 線・点・クリップ (M6) ----
        // 期待値はテストベンチのブレゼンハムで作り、320x16 の全ピクセルを比べる
        cmd(32'h0100_0000);
        exp_clear(16'h0000);
        line(160, 8, 190, 13, 16'h0001); line(160, 8, 165, 15, 16'h0002);
        line(160, 8, 155, 15, 16'h0003); line(160, 8, 130, 13, 16'h0004);
        line(160, 8, 130, 3, 16'h0005);  line(160, 8, 155, 1, 16'h0006);
        line(160, 8, 165, 1, 16'h0007);  line(160, 8, 190, 3, 16'h0008);
        line(10, 2, 40, 2, 16'h0009);    line(50, 0, 50, 15, 16'h000A);
        line(60, 5, 60, 5, 16'h000B);    line(-20, -3, 340, 20, 16'h000C);
        point(0, 0, 16'h000D); point(319, 15, 16'h000E); point(-1, 3, 16'h000F); point(5, 16, 16'h0010);
        wait_idle();
        check_all("lines");

        // クリップ矩形 (100,2)-(200,10): 線・矩形・点はその中だけ。CLEAR は全体を塗る
        clip(100, 2, 200, 10);
        line(50, 0, 250, 15, 16'h0011);
        fill(90, 0, 30, 16, 16'h0012);
        point(150, 6, 16'h0013); point(99, 6, 16'h0014); point(201, 6, 16'h0015);
        wait_idle();
        check_all("clip");
        cmd(32'h0100_2222);
        exp_clear(16'h2222);
        wait_idle();
        check_all("CLEAR ignores clip");

        // 空のクリップ (x0 > x1) では何も描かない。画面の外の x0 も空
        clip(200, 0, 100, 15);
        point(150, 5, 16'h0016);
        clip(400, 0, 500, 15);
        line(0, 0, 319, 15, 16'h0017);
        clip(0, 0, 319, 239);           // 画面全体に戻す (y1 は画面の下端に丸められる)
        point(1, 1, 16'h0018);
        wait_idle();
        check_all("empty clip");

        // SWAP: 入れ替えて、fb_scanout が取り込むまで (base_latched) 実行中のまま
        cmd(32'h0300_0000);
        repeat (20) @(negedge clk);
        rd(7'h40, d);
        if (!d[0]) begin $display("  SWAP finished before base_latched"); errors++; end
        if (fb_base !== 13'd256) begin $display("  fb_base after SWAP: %0d", fb_base); errors++; end
        rd(7'h46, f0);
        if (f0 != 8'd0) begin $display("  DRAW_BASE after SWAP: %0d", f0); errors++; end

        // 待っているあいだに FIFO をあふれさせる (16 ワード + 2)
        for (x = 0; x < FIFO_WORDS + 2; x++) cmd_nowait(32'h0000_0000);
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
