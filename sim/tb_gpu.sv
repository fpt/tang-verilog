// コマンド GPU: SDRAM の振る舞いモデル相手に、CLEAR (64 ワードずつのバースト)、奇数の端の FILL_RECT (バイトマスク)、
// はみ出しの切り取り、UPLOAD、SWAP (表示が取り込むまで待つ)、知らないコマンド、FIFO の空きとあふれ、
// DRAW_LINE (8 方向・水平・垂直・1 点・画面の外から)、POINT、CLIP (CLEAR には効かない)、
// BLIT (偶数 / 奇数の位置、左右・上下反転、透過、画面の外、クリップ、SDRAM の行をまたぐソース)、
// 合成のレジスタ (REG_WRITE)、WAIT_LINE / WAIT_VBLANK (印)、READY、VRAM_WRITE / PAL_WRITE とタイル レイヤのレジスタ (E2)、
//   OAM_WRITE とスプライトのレジスタ (E3) を確認
`timescale 1ns/1ps
module tb_gpu;
    localparam int SRC_W = 320, SRC_H = 16, FIFO_WORDS = 16;

    logic        clk = 0, rst = 1;
    logic [6:0]  addr = '0;
    logic [7:0]  wdata = '0, rdata;
    logic        we = 0, re = 0;
    logic        base_latched = 0;
    logic [12:0] fb_base;
    logic [15:0] bg_color, bitmap_key;
    logic [3:0]  layer_ctrl;
    logic [2:0]  bitmap_rank, spr_bank;
    logic [13:0] spr_pat_base;
    logic [6:0]  spr_line_cols;
    logic        oam_we;
    logic [9:0]  tile_scroll_x, tile_scroll_y;
    logic [13:0] tile_map_base, tile_pat_base, vram_waddr;
    logic [6:0]  tile_ctrl;
    logic        vram_we, pal_we;
    logic [31:0] vram_wdata;
    logic [8:0]  pal_waddr;
    logic [15:0] pal_wdata;
    logic        mark_req, ready;
    logic        line_start = 0;
    logic [7:0]  line_num = 0;

    logic        mem_req, mem_we, mem_ack, mem_wnext, mem_rvalid, init_done;
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
        .mem_req, .mem_we, .mem_addr, .mem_wdata, .mem_wmask, .mem_len, .mem_ack, .mem_wnext, .mem_rvalid,
        .mem_rdata(rdata32),
        .fb_base, .base_latched, .bg_color, .layer_ctrl, .bitmap_key, .bitmap_rank,
        .tile_scroll_x, .tile_scroll_y, .tile_map_base, .tile_pat_base, .tile_ctrl,
        .spr_pat_base, .spr_bank, .spr_line_cols, .oam_we,
        .vram_we, .vram_waddr, .vram_wdata, .pal_we, .pal_waddr, .pal_wdata,
        .mark_req, .line_start, .line_num, .ready
    );

    // VRAM とパレットへの書き込みを記録する
    logic [31:0] vram_tb [0:16383];
    logic [15:0] pal_tb  [0:511];
    logic [31:0] oam_tb  [0:255];
    int          vram_writes = 0, pal_writes = 0, oam_writes = 0;
    always @(posedge clk) begin
        if (vram_we) begin vram_tb[vram_waddr] <= vram_wdata; vram_writes++; end
        if (oam_we)  begin oam_tb[vram_waddr[7:0]] <= vram_wdata; oam_writes++; end
        if (pal_we)  begin pal_tb[pal_waddr]   <= pal_wdata;  pal_writes++;  end
    end

    sdram_ctrl #(.CLK_HZ(63_000_000), .INIT_US(2)) u_ctrl (
        .clk, .rst, .req(mem_req), .we(mem_we), .addr(mem_addr), .wdata(mem_wdata), .wmask(mem_wmask),
        .len(mem_len), .wnext(mem_wnext), .ack(mem_ack), .rvalid(mem_rvalid), .rdata(rdata32), .init_done, .rd_sample(3'd4),
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

    // ---- BLIT 用: ソース画像 2 つ (7x5 と 34x3) ----
    localparam logic [15:0] KEY = 16'hF81F;
    function automatic logic [15:0] src_px(input int which, input int i, input int j);
        logic [15:0] p;
        p = (which == 0) ? 16'(16'h1000 + j * 16 + i) : 16'(16'h2000 + j * 64 + i);
        if (which == 0 && (i + j) % 4 == 0) p = KEY;         // 透過色を混ぜる
        return p;
    endfunction

    task automatic upload_src(input int which, input logic [20:0] a, input int stride, input int w, input int h);
        cmd({8'h04, 24'(stride * h)}); cmd({11'b0, a});
        for (int j = 0; j < h; j++)
            for (int k = 0; k < stride; k++)
                cmd({(2 * k + 1 < w) ? src_px(which, 2 * k + 1, j) : 16'h0, (2 * k < w) ? src_px(which, 2 * k, j) : 16'h0});
    endtask

    task automatic blit(input int which, input logic [20:0] a, input int stride, input int w, input int h,
                        input int bx, input int by, input logic [2:0] fl);
        logic [15:0] p;
        int si, sj;
        cmd({8'h08, 5'b0, fl, KEY}); cmd({11'b0, a}); cmd({16'(h), 16'(w)}); cmd({16'(by), 16'(bx)}); cmd(32'(stride));
        for (int j = 0; j < h; j++)
            for (int i = 0; i < w; i++) begin
                si = fl[1] ? w - 1 - i : i;
                sj = fl[2] ? h - 1 - j : j;
                p = src_px(which, si, sj);
                if (!(fl[0] && p == KEY) && bx + i >= 0 && bx + i < SRC_W && by + j >= 0 && by + j < SRC_H)
                    exp_plot(bx + i, by + j, p);
            end
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

    // +trace で GPU の BLIT の動きを表示する (調べもの用)
    bit trace = 0;
    bit blit_phase = 0;
    initial trace = $test$plusargs("trace");
    int trace_n = 0;
    logic [3:0] prev_state = 0;
    always @(posedge clk) if (trace && blit_phase && dut.state != prev_state && trace_n < 100000) begin
        $display("  [trace] t=%0t state %0d -> %0d op %02h word %08h arg_idx %0d", $time, prev_state, dut.state, dut.op, dut.word, dut.arg_idx);
        trace_n++;
    end
    always @(posedge clk) prev_state <= dut.state;
    always @(posedge clk) if (trace && dut.op == 8'h08 && dut.state != 0) begin
        if (dut.state == 11)
            $display("  [trace] SETUP b_w %0d b_h %0d dx %0d dy %0d bxs %0d bxe %0d bys %0d bye %0d src %h stride %0d flags %b",
                     dut.b_w, dut.b_h, dut.b_dx, dut.b_dy, dut.bxs, dut.bxe, dut.bys, dut.bye, dut.b_src, dut.b_stride, dut.flags);
        if (mem_req && mem_ack) $display("  [trace] state %0d ack addr %h len %0d we %b", dut.state, mem_addr, mem_len, mem_we);
    end

    always @(posedge clk) if (trace && dut.state == 15) $display("  [trace] WAIT_LINE target %0d armed %b mark %b line_start %b line_num %0d op %02h",
                                                     dut.wait_target, dut.wait_armed, dut.wait_mark, line_start, line_num, dut.op);
    always @(posedge clk) if (trace && mark_req) $display("  [trace] mark_req at t=%0t", $time);
    int mark_count_tb = 0, mark_line = -1;
    int prev_line = 0;
    always @(posedge clk) begin
        if (line_start) prev_line <= int'(line_num);
        if (mark_req) begin
            mark_count_tb++;
            mark_line = prev_line;
        end
    end

    // line_compositor の代わり: 40 クロックごとにライン 0..SRC_H-1 の合成の開始を知らせる
    bit lines_on = 0;
    always begin
        repeat (40) @(negedge clk);
        if (lines_on) begin
            line_start = 1;
            @(negedge clk);
            line_start = 0;
            line_num = (line_num == 8'(SRC_H - 1)) ? 8'd0 : line_num + 8'd1;
        end
    end

    // 止まったときのための見張り (シミュレーション時間 20ms)
    initial begin
        #40_000_000;
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

        // ---- BLIT (M7) ----
        // ソース: 7x5 (stride 4 ワード) と、SDRAM の行の境目 (0x20100) をまたぐ 34x3 (stride 17 ワード)。
        // どちらも描く面 (DRAW_BASE 256 = ワードアドレス 0x10000 から) とは別の場所に置く
        blit_phase = 1;
        upload_src(0, 21'h30000, 4, 7, 5);
        upload_src(1, 21'h200FA, 17, 34, 3);
        cmd(32'h0100_0421);
        exp_clear(16'h0421);
        blit(0, 21'h30000, 4, 7, 5, 10, 2, 3'b000);    // 偶数の位置
        wait_idle(); check_all("BLIT 0, 21'h30000, 4, 7, 5, 10, 2, 3'b000");
        blit(0, 21'h30000, 4, 7, 5, 21, 2, 3'b000);    // 奇数の位置
        wait_idle(); check_all("BLIT 0, 21'h30000, 4, 7, 5, 21, 2, 3'b000");
        blit(0, 21'h30000, 4, 7, 5, 40, 2, 3'b010);    // 左右反転
        wait_idle(); check_all("BLIT 0, 21'h30000, 4, 7, 5, 40, 2, 3'b010");
        blit(0, 21'h30000, 4, 7, 5, 60, 2, 3'b100);    // 上下反転
        wait_idle(); check_all("BLIT 0, 21'h30000, 4, 7, 5, 60, 2, 3'b100");
        blit(0, 21'h30000, 4, 7, 5, 81, 3, 3'b110);    // 両方、奇数の位置
        wait_idle(); check_all("BLIT 0, 21'h30000, 4, 7, 5, 81, 3, 3'b110");
        blit(0, 21'h30000, 4, 7, 5, 101, 9, 3'b001);   // 透過
        wait_idle(); check_all("BLIT 0, 21'h30000, 4, 7, 5, 101, 9, 3'b001");
        blit(0, 21'h30000, 4, 7, 5, 111, 9, 3'b111);   // 透過 + 両方
        wait_idle(); check_all("BLIT 0, 21'h30000, 4, 7, 5, 111, 9, 3'b111");
        blit(0, 21'h30000, 4, 7, 5, -3, -2, 3'b000);   // 左上にはみ出す
        wait_idle(); check_all("BLIT 0, 21'h30000, 4, 7, 5, -3, -2, 3'b000");
        blit(0, 21'h30000, 4, 7, 5, 316, 13, 3'b011);  // 右下にはみ出す
        wait_idle(); check_all("BLIT 0, 21'h30000, 4, 7, 5, 316, 13, 3'b011");
        blit(1, 21'h200FA, 17, 34, 3, 150, 1, 3'b000); // 行をまたぐソース
        wait_idle(); check_all("BLIT 1, 21'h200FA, 17, 34, 3, 150, 1, 3'b000");
        blit(1, 21'h200FA, 17, 34, 3, 191, 6, 3'b010);
        wait_idle(); check_all("BLIT 1, 21'h200FA, 17, 34, 3, 191, 6, 3'b010");
        // クリップ: (200,0)-(206,15) の中だけ
        clip(200, 0, 206, 15);
        blit(0, 21'h30000, 4, 7, 5, 197, 4, 3'b000);
        blit(1, 21'h200FA, 17, 34, 3, 190, 11, 3'b110);
        clip(0, 0, 319, 239);
        wait_idle();
        check_all("BLIT with clip");

        // ---- 合成のレジスタと WAIT_LINE / WAIT_VBLANK (E1) ----
        if (bg_color !== 16'h0000 || layer_ctrl !== 4'b0001 || bitmap_key !== 16'h0000) begin
            $display("  layer registers after reset: %04h %b %04h", bg_color, layer_ctrl, bitmap_key); errors++;
        end
        cmd(32'h0900_1234); cmd(32'h0901_0002); cmd(32'h0902_5678);
        wait_idle();
        if (bg_color !== 16'h1234 || layer_ctrl !== 4'b0010 || bitmap_key !== 16'h5678) begin
            $display("  REG_WRITE: %04h %b %04h", bg_color, layer_ctrl, bitmap_key); errors++;
        end
        rd(7'h48, f0); rd(7'h49, f1);
        if ({f1, f0} != 16'h1234) begin $display("  BG_COLOR read back: %04h", {f1, f0}); errors++; end
        wr(7'h4A, 8'h01);
        if (layer_ctrl !== 4'b0001) begin $display("  LAYER_CTRL host write: %b", layer_ctrl); errors++; end
        // WAIT_LINE 5 のあとの REG_WRITE は、ライン 4 の合成が始まったあとで効く
        lines_on = 1;
        cmd(32'h0A00_0005); cmd(32'h0900_7777);
        wait (bg_color == 16'h7777);
        if (line_num != 8'd5) begin $display("  WAIT_LINE 5 released after line %0d", int'(line_num) - 1); errors++; end
        // READY: WAIT_LINE で止まっているあいだに FIFO を 3/4 まで埋めると下がる (16 ワードの半分 = 8 が境目)
        if (!ready) begin $display("  READY low with an empty FIFO"); errors++; end
        cmd(32'h0A00_0002);
        for (x = 0; x < 12; x++) cmd_nowait(32'h0000_0000);
        if (ready) begin $display("  READY high with 12/16 words queued"); errors++; end
        wait_idle();
        if (!ready) begin $display("  READY low after the FIFO drained"); errors++; end
        // WAIT_VBLANK (印付き): 最後のライン (SRC_H-1) の合成が始まったところで mark_req を 1 回出す
        mark_count_tb = 0;
        cmd(32'h0B00_0001);
        wait_idle();
        repeat (2) @(posedge clk);       // mark_req は終わったのと同じクロックで出るので、数え終わるのを待つ
        if (mark_count_tb != 1 || mark_line != SRC_H - 1) begin
            $display("  WAIT_VBLANK mark: %0d pulses, after line %0d", mark_count_tb, mark_line); errors++;
        end
        lines_on = 0;
        cmd(32'h0900_0000);
        wait_idle();

        // ---- タイル レイヤのレジスタ、VRAM_WRITE / PAL_WRITE (E2) ----
        if (tile_scroll_x !== 0 || tile_scroll_y !== 0 || tile_map_base !== 0 || tile_pat_base !== 0 || tile_ctrl !== 0 ||
            bitmap_rank !== 3'd1) begin
            $display("  tile registers after reset"); errors++;
        end
        // 値は各レジスタの幅に切る
        cmd(32'h0901_FFFF); cmd(32'h0903_FC05); cmd(32'h0904_0123); cmd(32'h0905_FFFF); cmd(32'h0906_2000); cmd(32'h0907_00FF);
        wait_idle();
        if (layer_ctrl !== 4'b1111 || tile_scroll_x !== 10'h005 || tile_scroll_y !== 10'h123 || tile_map_base !== 14'h3FFF ||
            tile_pat_base !== 14'h2000 || tile_ctrl !== 7'h7F) begin
            $display("  tile REG_WRITE: %b %h %h %h %h %h", layer_ctrl, tile_scroll_x, tile_scroll_y, tile_map_base,
                     tile_pat_base, tile_ctrl);
            errors++;
        end
        rd(7'h4A, f0);
        if (f0 != 8'h0F) begin $display("  LAYER_CTRL read back: %h", f0); errors++; end
        cmd(32'h0908_FFFE);
        wait_idle();
        if (bitmap_rank !== 3'd6) begin $display("  BITMAP_RANK: %0d", bitmap_rank); errors++; end
        cmd(32'h0908_0001);
        cmd(32'h0901_0001);
        // スプライトのレジスタ (E3)
        if (spr_pat_base !== 0 || spr_bank !== 0 || spr_line_cols !== 7'd40) begin
            $display("  sprite registers after reset: %h %h %0d", spr_pat_base, spr_bank, spr_line_cols); errors++;
        end
        cmd(32'h0909_FFFF); cmd(32'h090A_FFFD); cmd(32'h090B_FC0F);      // 上限 15 ピクセル -> 1 列 (上位の bit は捨てる)
        wait_idle();
        if (spr_pat_base !== 14'h3FFF || spr_bank !== 3'd5 || spr_line_cols !== 7'd1) begin
            $display("  sprite REG_WRITE: %h %h %0d", spr_pat_base, spr_bank, spr_line_cols); errors++;
        end
        cmd(32'h0909_0000); cmd(32'h090A_0000); cmd(32'h090B_0140);
        // OAM_WRITE 3 ワードを 0xFE から (0x00 に折り返す)。VRAM には書かない
        vram_writes = 0; oam_writes = 0;
        cmd(32'h0F00_0003); cmd(32'h0000_00FE); cmd(32'h1111_0001); cmd(32'h2222_0002); cmd(32'h3333_0003);
        cmd(32'h0900_4343);
        wait_idle();
        if (oam_writes != 3 || vram_writes != 0 || oam_tb[254] !== 32'h1111_0001 || oam_tb[255] !== 32'h2222_0002 ||
            oam_tb[0] !== 32'h3333_0003) begin
            $display("  OAM_WRITE: %0d writes (VRAM %0d), %h %h %h", oam_writes, vram_writes, oam_tb[254], oam_tb[255], oam_tb[0]);
            errors++;
        end
        if (bg_color !== 16'h4343) begin $display("  command after OAM_WRITE not run: %h", bg_color); errors++; end
        rd_re(7'h40, d);
        if (d[1]) begin $display("  error after OAM_WRITE"); errors++; end
        // VRAM_WRITE 3 ワードを 0x3FFF から (0x0000 に折り返す)、0 ワード、PAL_WRITE 3 色を 510 から (0 に折り返す)
        vram_writes = 0; pal_writes = 0;
        cmd(32'h0C00_0003); cmd(32'h0000_3FFF); cmd(32'hA0A0_0001); cmd(32'hB0B0_0002); cmd(32'hC0C0_0003);
        cmd(32'h0C00_0000); cmd(32'h0000_0100);
        cmd(32'h0D00_0003); cmd(32'h0000_01FE); cmd(32'h2222_1111); cmd(32'hDEAD_3333);
        cmd(32'h0900_4242);
        wait_idle();
        if (vram_writes != 3 || oam_writes != 3 || vram_tb[16383] !== 32'hA0A0_0001 || vram_tb[0] !== 32'hB0B0_0002 || vram_tb[1] !== 32'hC0C0_0003) begin
            $display("  VRAM_WRITE: %0d writes, %h %h %h", vram_writes, vram_tb[16383], vram_tb[0], vram_tb[1]); errors++;
        end
        if (pal_writes != 3 || pal_tb[510] !== 16'h1111 || pal_tb[511] !== 16'h2222 || pal_tb[0] !== 16'h3333) begin
            $display("  PAL_WRITE: %0d writes, %h %h %h", pal_writes, pal_tb[510], pal_tb[511], pal_tb[0]); errors++;
        end
        if (bg_color !== 16'h4242) begin $display("  command after PAL_WRITE not run: %h", bg_color); errors++; end
        rd_re(7'h40, d);
        if (d[1]) begin $display("  error after VRAM_WRITE / PAL_WRITE"); errors++; end
        // PAL_WRITE の偶数個 (2 ワード = 4 色)
        pal_writes = 0;
        cmd(32'h0D00_0004); cmd(32'h0000_0010); cmd(32'h0B0A_0A0B); cmd(32'h0D0C_0C0D);
        wait_idle();
        repeat (2) @(posedge clk);       // 最後の書き込みは実行が終わった次のクロック
        if (pal_writes != 4 || pal_tb[16] !== 16'h0A0B || pal_tb[17] !== 16'h0B0A || pal_tb[18] !== 16'h0C0D || pal_tb[19] !== 16'h0D0C) begin
            $display("  PAL_WRITE x4: %0d writes %h %h %h %h", pal_writes, pal_tb[16], pal_tb[17], pal_tb[18], pal_tb[19]); errors++;
        end
        cmd(32'h0900_0000);
        wait_idle();

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
