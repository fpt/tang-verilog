// SDRAM の調停: 同時に頼まれたら a が先、ack と rvalid は許可した側にだけ返り、終わったら b に渡る
`timescale 1ns/1ps
module tb_sdram_arb;
    logic        clk = 0, rst = 1;
    logic        a_req = 0, b_req = 0, a_we = 0, b_we = 1;
    logic [20:0] a_addr = 21'h000AAA, b_addr = 21'h000BBB;
    logic [31:0] a_wdata = 32'hAAAA_AAAA, b_wdata = 32'hBBBB_BBBB;
    logic [8:0]  a_len = 9'd3, b_len = 9'd1;
    logic        a_ack, a_rvalid, b_ack, b_rvalid;
    logic        m_req, m_we, m_ack = 0, m_rvalid = 0;
    logic [20:0] m_addr;
    logic [31:0] m_wdata;
    logic [8:0]  m_len;

    sdram_arb dut (.*);

    always #8 clk = ~clk;

    int errors = 0;
    int a_acks = 0, b_acks = 0, a_words = 0, b_words = 0;
    always @(posedge clk) begin
        if (a_ack) a_acks++;
        if (b_ack) b_acks++;
        if (a_rvalid) a_words++;
        if (b_rvalid) b_words++;
    end

    // sdram_ctrl の代わり: m_req が来たら少し待って、len ワード (読み出し) か 1 回 (書き込み) 返して ack
    task automatic serve(output logic [20:0] seen_addr, output logic seen_we);
        int i, n;
        do @(negedge clk); while (!m_req);
        seen_addr = m_addr;
        seen_we = m_we;
        n = m_we ? 0 : int'(m_len);
        repeat (3) @(negedge clk);
        for (i = 0; i < n; i++) begin
            m_rvalid = 1;
            @(negedge clk);
            m_rvalid = 0;
        end
        m_ack = 1;
        @(negedge clk);
        m_ack = 0;
    endtask

    initial begin
        logic [20:0] addr1, addr2;
        logic        we1, we2;
        $dumpfile("build/sim/tb_sdram_arb.vcd");
        $dumpvars(0, tb_sdram_arb);
        repeat (2) @(negedge clk);
        rst = 0;

        // 両方同時に頼む -> a (読み出し 3 ワード) が先
        a_req = 1;
        b_req = 1;
        serve(addr1, we1);
        a_req = 0;           // 利用者は ack を見たら下げる
        serve(addr2, we2);
        b_req = 0;
        repeat (3) @(negedge clk);

        if (addr1 !== 21'h000AAA || we1 !== 1'b0) begin $display("  first grant: addr %h we %b", addr1, we1); errors++; end
        if (addr2 !== 21'h000BBB || we2 !== 1'b1) begin $display("  second grant: addr %h we %b", addr2, we2); errors++; end
        if (a_acks != 1 || b_acks != 1) begin $display("  acks: a %0d b %0d", a_acks, b_acks); errors++; end
        if (a_words != 3 || b_words != 0) begin $display("  rvalid: a %0d b %0d", a_words, b_words); errors++; end
        if (m_req !== 1'b0) begin $display("  m_req still high"); errors++; end

        if (errors == 0) $display("PASS: tb_sdram_arb");
        else             $display("FAIL: tb_sdram_arb (%0d errors)", errors);
        $finish;
    end
endmodule
