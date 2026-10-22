// SDRAM コントローラ: 振る舞いモデル相手に、初期化・ランダムな読み書き・リフレッシュ・取り込み位置を確認
//   モデルのデータは立ち下がり 1 の T_AC (5.4ns) 後から立ち下がり 2 の T_OH (2.5ns) 後まで有効なので、
//   取り込み位置 h = 4 (立ち上がり 2) と 5 (立ち下がり 2) は読めて、3 と 6 は読めないはず
`timescale 1ns/1ps
module tb_sdram_ctrl;
    logic        clk = 0, rst = 1;
    logic        req = 0, we = 0, ack, init_done, rvalid;
    logic [8:0]  len = 9'd1;
    logic [20:0] addr = '0;
    logic [31:0] wdata = '0, rdata;
    logic [2:0]  rd_sample = 3'd4;

    logic        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
    logic [1:0]  ba;
    logic [10:0] sa;
    logic [3:0]  dqm;
    logic [31:0] dq_out;
    wire  [31:0] dq;
    assign dq = dq_oe ? dq_out : 'z;

    sdram_ctrl #(.CLK_HZ(63_000_000), .INIT_US(2)) dut (
        .clk, .rst, .req, .we, .addr, .wdata, .len, .ack, .rvalid, .rdata, .init_done, .rd_sample,
        .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n), .sdram_we_n(we_n),
        .sdram_ba(ba), .sdram_addr(sa), .sdram_dqm(dqm), .sdram_dq_out(dq_out), .sdram_dq_oe(dq_oe),
        .sdram_dq_in(dq)
    );

    // SDRAM のクロックは逆相 (実機ではトップの ODDR)
    sdram_model model (
        .clk(~clk), .cke, .cs_n, .ras_n, .cas_n, .we_n, .ba, .addr(sa), .dqm, .dq
    );

    always #7.936 clk = ~clk;   // 63MHz

    int errors = 0;

    task automatic access(input logic w, input logic [20:0] a, input logic [31:0] d, output logic [31:0] q);
        @(negedge clk);
        req = 1;
        we = w;
        addr = a;
        wdata = d;
        do @(posedge clk); while (!ack);
        q = rdata;
        @(negedge clk);
        req = 0;
    endtask

    localparam int N = 64;
    logic [20:0] addrs [N];
    logic [31:0] datas [N];

    // 書いて、取り込み位置 h で読み、不一致の数を返す
    task automatic run(input logic [2:0] h, output int mismatches);
        logic [31:0] q;
        int i;
        mismatches = 0;
        rd_sample = h;
        for (i = 0; i < N; i++) access(1'b1, addrs[i], datas[i] ^ {29'b0, h}, q);
        for (i = 0; i < N; i++) begin
            access(1'b0, addrs[i], '0, q);
            if (q !== (datas[i] ^ {29'b0, h})) mismatches++;
        end
    endtask

    initial begin
        int m, i;
        $dumpfile("build/sim/tb_sdram_ctrl.vcd");
        $dumpvars(0, tb_sdram_ctrl);

        // 端 (0 と最大) と、バンク・行・列がばらけるアドレス
        for (i = 0; i < N; i++) begin
            addrs[i] = 21'((i * 32'h0002_5A3B + 32'h0001_0101 * i * i) & 32'h1F_FFFF);
            datas[i] = 32'hA5A5_0000 ^ (32'h0101_0101 * i) ^ (32'h8000_0001 << (i % 31));
        end
        addrs[0] = 21'h00_0000;
        addrs[1] = 21'h1F_FFFF;

        repeat (4) @(posedge clk);
        rst = 0;
        wait (init_done);

        run(3'd4, m);
        if (m != 0) begin $display("  rd_sample=4: %0d mismatches", m); errors++; end
        run(3'd5, m);
        if (m != 0) begin $display("  rd_sample=5: %0d mismatches", m); errors++; end
        run(3'd3, m);
        if (m != N) begin $display("  rd_sample=3: expected all %0d to fail, got %0d", N, m); errors++; end
        run(3'd6, m);
        if (m != N) begin $display("  rd_sample=6: expected all %0d to fail, got %0d", N, m); errors++; end

        // バースト読み出し: 1 行 (列 0x10 から 160 ワード) を書いて、len = 160 で一度に読む
        rd_sample = 3'd4;
        begin
            logic [31:0] q;
            int got;
            for (i = 0; i < 160; i++) access(1'b1, 21'h0A_C10 + 21'(i), 32'h5000_0000 + 32'(i * 7), q);
            @(negedge clk);
            req = 1; we = 0; addr = 21'h0A_C10; len = 9'd160;
            got = 0;
            do begin
                @(negedge clk);   // rvalid と rdata はどちらもクロックの途中で見る
                if (rvalid) begin
                    if (rdata !== 32'h5000_0000 + 32'(got * 7)) begin
                        if (errors < 10) $display("  burst word %0d: got %08h", got, rdata);
                        errors++;
                    end
                    got++;
                end
            end while (!ack);
            req = 0; len = 9'd1;
            if (got != 160) begin $display("  burst: %0d words (expected 160)", got); errors++; end
        end

        // 60us 放置してリフレッシュが続いていることを確かめ、もう一度読む
        rd_sample = 3'd4;
        #60000;
        run(3'd4, m);
        if (m != 0) begin $display("  after idle: %0d mismatches", m); errors++; end
        if (model.refreshes < 8 + 7) begin $display("  too few refreshes: %0d", model.refreshes); errors++; end
        if (model.violations != 0) begin $display("  model timing violations: %0d", model.violations); errors++; end

        if (errors == 0) $display("PASS: tb_sdram_ctrl");
        else             $display("FAIL: tb_sdram_ctrl (%0d errors)", errors);
        $finish;
    end
endmodule
