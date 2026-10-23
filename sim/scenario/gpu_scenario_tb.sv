// シナリオをシステム全体の RTL で走らせる (docs/GPU_PLAN.md の M5、「3 通りの比較」の Verilator の分)
//   gpu + sdram_arb + sdram_ctrl + SDRAM の振る舞いモデル + fb_scanout + vdp_video + frame_crc。SPI は通さず、レジスタバスを直接叩く。
//   入力 (gpu_model.py export が作る):
//     +cmds=<file>    1 行 1 ワード (16 進) のコマンド列
//     +checks=<file>  1 行 1 つ、check の位置 (そこまでに送るワード数、10 進)
//     +out=<dir>      check ごとに crc_<i>.txt (FRAME_CRC、CRC_FRAME、UNDERFLOW、表示の読み出しの最大待ち) と frame_<i>.ppm を書く
//   check では、GPU が空になったあと 2 フレーム待ち、その次のフレームの CRC を記録する (実機の harness.py scenario と同じ)。
//   実行は make scenario (Verilator) だけ。640x480 のフレームを何枚も回すので Icarus では遅すぎる。
`timescale 1ns/1ps
module gpu_scenario_tb;
    logic clk_sys = 0, clk_pix = 0, rst = 1;
    always #7.936 clk_sys = ~clk_sys;    // 63MHz
    always #19.841 clk_pix = ~clk_pix;   // 25.2MHz

    // --- レジスタバス (gpu だけ) ---
    logic [6:0] addr = '0;
    logic [7:0] wdata = '0, rdata;
    logic       we = 0, re = 0;

    // --- 映像 ---
    logic [10:0] vx;
    logic [9:0]  vy;
    logic [7:0]  r, g, b;
    logic        de, hsync, vsync, vblank, frame_start;
    logic [23:0] fb_rgb;
    vdp_video u_video (
        .clk_pix, .rst, .freeze(1'b0), .fb_en(1'b1), .fb_rgb, .x(vx), .y(vy),
        .r, .g, .b, .de, .hsync, .vsync, .vblank, .frame_start
    );

    logic [31:0] crc;
    logic [15:0] crc_frame;
    logic        crc_toggle;
    frame_crc u_crc (.clk(clk_pix), .rst, .de, .r, .g, .b, .vblank, .crc, .frame(crc_frame), .crc_toggle);

    // --- SDRAM まわり ---
    logic [12:0] fb_base;
    logic        base_latched;
    logic [7:0]  underflow_count;

    logic        fb_req, fb_ack, fb_rvalid;
    logic [20:0] fb_addr;
    logic [8:0]  fb_len;
    logic        g_req, g_we, g_ack, g_wnext, g_rvalid;
    logic [20:0] g_addr;
    logic [31:0] g_wdata;
    logic [3:0]  g_wmask;
    logic [8:0]  g_len;
    logic        m_req, m_we, m_ack, m_rvalid, m_wnext, init_done;
    logic [20:0] m_addr;
    logic [31:0] m_wdata, m_rdata;
    logic [3:0]  m_wmask;
    logic [8:0]  m_len;

    fb_scanout u_fb (
        .clk_sys, .rst_sys(rst), .fb_base, .base_latched,
        .mem_req(fb_req), .mem_addr(fb_addr), .mem_len(fb_len), .mem_ack(fb_ack),
        .mem_rvalid(fb_rvalid), .mem_rdata(m_rdata), .underflow_count,
        .clk_pix, .rst_pix(rst), .enable(1'b1), .x(vx), .y(vy), .rgb(fb_rgb)
    );

    gpu u_gpu (
        .clk(clk_sys), .rst, .addr, .wdata, .we, .re, .rdata,
        .mem_req(g_req), .mem_we(g_we), .mem_addr(g_addr), .mem_wdata(g_wdata), .mem_wmask(g_wmask),
        .mem_len(g_len), .mem_ack(g_ack), .mem_wnext(g_wnext), .mem_rvalid(g_rvalid), .mem_rdata(m_rdata),
        .fb_base, .base_latched
    );

    sdram_arb u_arb (
        .clk(clk_sys), .rst,
        .a_req(fb_req), .a_we(1'b0), .a_addr(fb_addr), .a_wdata(32'h0), .a_wmask(4'h0), .a_len(fb_len),
        .a_ack(fb_ack), .a_rvalid(fb_rvalid), .a_wnext(),
        .b_req(g_req), .b_we(g_we), .b_addr(g_addr), .b_wdata(g_wdata), .b_wmask(g_wmask), .b_len(g_len),
        .b_ack(g_ack), .b_rvalid(g_rvalid), .b_wnext(g_wnext),
        .c_req(1'b0), .c_we(1'b0), .c_addr(21'h0), .c_wdata(32'h0), .c_wmask(4'h0), .c_len(9'd1),
        .c_ack(), .c_rvalid(), .c_wnext(),
        .m_req, .m_we, .m_addr, .m_wdata, .m_wmask, .m_len, .m_ack, .m_rvalid, .m_wnext
    );

    logic        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
    logic [1:0]  ba;
    logic [10:0] sa;
    logic [3:0]  dqm;
    logic [31:0] dq_out;
    wire  [31:0] dq;
    assign dq = dq_oe ? dq_out : 'z;

    sdram_ctrl #(.CLK_HZ(63_000_000), .INIT_US(2)) u_ctrl (
        .clk(clk_sys), .rst, .req(m_req), .we(m_we), .addr(m_addr), .wdata(m_wdata), .wmask(m_wmask), .len(m_len),
        .wnext(m_wnext), .ack(m_ack), .rvalid(m_rvalid), .rdata(m_rdata), .init_done, .rd_sample(3'd4),
        .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n), .sdram_we_n(we_n),
        .sdram_ba(ba), .sdram_addr(sa), .sdram_dqm(dqm), .sdram_dq_out(dq_out), .sdram_dq_oe(dq_oe), .sdram_dq_in(dq)
    );

    sdram_model model (.clk(~clk_sys), .cke, .cs_n, .ras_n, .cas_n, .we_n, .ba, .addr(sa), .dqm, .dq);

    // 表示のライン読み出しの待ち時間 (要求から ack まで、clk_sys のクロック数) の最大。締め切りは出力 2 ライン = 63.5us = 4000 クロック
    int fetch_cycles = 0, max_fetch_cycles = 0;
    always @(posedge clk_sys) begin
        if (fb_req && !fb_ack) fetch_cycles++;
        else begin
            if (fetch_cycles > max_fetch_cycles) max_fetch_cycles = fetch_cycles;
            fetch_cycles = 0;
        end
    end

    // --- バスの操作 ---
    task automatic wr(input logic [6:0] a, input logic [7:0] d);
        @(negedge clk_sys);
        addr = a; wdata = d; we = 1;
        @(negedge clk_sys);
        we = 0;
    endtask

    task automatic rd(input logic [6:0] a, output logic [7:0] d);
        @(negedge clk_sys);
        addr = a;
        #1 d = rdata;
    endtask

    task automatic send_word(input logic [31:0] w);
        logic [7:0] lo, hi;
        do begin
            rd(7'h41, lo); rd(7'h42, hi);
        end while ({hi, lo} == 16'd0);
        wr(7'h30, w[7:0]); wr(7'h30, w[15:8]); wr(7'h30, w[23:16]); wr(7'h30, w[31:24]);
    endtask

    task automatic wait_idle;
        logic [7:0] s;
        do rd(7'h40, s); while (s[0]);
    endtask

    // 次の CRC の更新 (frame_crc がフレームを確定させる) を待つ
    task automatic wait_crc;
        logic t;
        t = crc_toggle;
        wait (crc_toggle != t);
    endtask

    // 次のフレームの画素を集めて PPM に書く (frame_crc と同じ範囲: DE 中の画素)
    logic [7:0] frame_buf [0:640*480*3-1];
    task automatic capture_frame(input string path);
        int n, fd;
        n = 0;
        @(posedge frame_start);
        while (n < 640 * 480) begin
            @(posedge clk_pix);
            if (de) begin
                frame_buf[3 * n] = r; frame_buf[3 * n + 1] = g; frame_buf[3 * n + 2] = b;
                n++;
            end
        end
        fd = $fopen(path, "wb");
        $fwrite(fd, "P6\n640 480\n255\n");
        for (int i = 0; i < 640 * 480 * 3; i++) $fwrite(fd, "%c", frame_buf[i]);
        $fclose(fd);
    endtask

    logic [31:0] cmds [0:1048575];
    int          checks [0:255];

    initial begin
        string cmds_path, checks_path, out;
        int n_words, n_checks, fd, sent, i, k, code;
        if (!$value$plusargs("cmds=%s", cmds_path) || !$value$plusargs("checks=%s", checks_path) ||
            !$value$plusargs("out=%s", out)) begin
            $display("FAIL: gpu_scenario_tb needs +cmds= +checks= +out=");
            $finish;
        end
        // ワード数と check の数は最初の行に書いてある
        fd = $fopen(cmds_path, "r");
        code = $fscanf(fd, "%d\n", n_words);
        for (i = 0; i < n_words; i++) code = $fscanf(fd, "%h\n", cmds[i]);
        $fclose(fd);
        fd = $fopen(checks_path, "r");
        code = $fscanf(fd, "%d\n", n_checks);
        for (i = 0; i < n_checks; i++) code = $fscanf(fd, "%d\n", checks[i]);
        $fclose(fd);

        repeat (4) @(posedge clk_sys);
        rst = 0;
        wait (init_done);

        sent = 0;
        for (k = 0; k < n_checks; k++) begin
            while (sent < checks[k]) begin
                send_word(cmds[sent]);
                sent++;
            end
            wait_idle();
            wait_crc(); wait_crc();
            capture_frame($sformatf("%s/frame_%0d.ppm", out, k));
            wait_crc();    // capture_frame で集めたフレームの CRC
            fd = $fopen($sformatf("%s/crc_%0d.txt", out, k), "w");
            $fwrite(fd, "%08h %0d %0d %0d\n", crc, crc_frame, underflow_count, max_fetch_cycles);
            $fclose(fd);
            $display("check %0d: crc %08h frame %0d underflow %0d max_fetch_cycles %0d", k, crc, crc_frame,
                     underflow_count, max_fetch_cycles);
        end
        if (model.violations != 0) $display("FAIL: SDRAM model timing violations: %0d", model.violations);
        $display("DONE: gpu_scenario_tb");
        $finish;
    end
endmodule
