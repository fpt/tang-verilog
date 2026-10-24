// SDRAM の調停: 4 つ同時に頼まれたら a -> d -> b -> c の順。ack / rvalid / wnext は許可した利用者にだけ返る
`timescale 1ns/1ps
module tb_sdram_arb;
    logic        clk = 0, rst = 1;
    logic        a_req = 0, b_req = 0, c_req = 0;
    logic        a_we = 0, b_we = 1, c_we = 1;
    logic [20:0] a_addr = 21'h000AAA, b_addr = 21'h000BBB, c_addr = 21'h000CCC;
    logic [31:0] a_wdata = 32'hAAAA_AAAA, b_wdata = 32'hBBBB_BBBB, c_wdata = 32'hCCCC_CCCC;
    logic [3:0]  a_wmask = 4'h1, b_wmask = 4'h2, c_wmask = 4'h4;
    logic [8:0]  a_len = 9'd3, b_len = 9'd2, c_len = 9'd1;
    logic        a_ack, a_rvalid, a_wnext, b_ack, b_rvalid, b_wnext, c_ack, c_rvalid, c_wnext;
    logic        d_req = 0, d_ack, d_rvalid;
    logic [20:0] d_addr = 21'h000DDD;
    logic [8:0]  d_len = 9'd1;
    logic        m_req, m_we, m_ack = 0, m_rvalid = 0, m_wnext = 0;
    logic [20:0] m_addr;
    logic [31:0] m_wdata;
    logic [3:0]  m_wmask;
    logic [8:0]  m_len;

    sdram_arb dut (.*);

    always #8 clk = ~clk;

    int errors = 0;
    int acks [4] = '{0, 0, 0, 0};
    int rvalids [4] = '{0, 0, 0, 0};
    int wnexts [3] = '{0, 0, 0};
    always @(posedge clk) begin
        if (a_ack) acks[0]++;
        if (b_ack) acks[1]++;
        if (c_ack) acks[2]++;
        if (a_rvalid) rvalids[0]++;
        if (b_rvalid) rvalids[1]++;
        if (c_rvalid) rvalids[2]++;
        if (d_ack) acks[3]++;
        if (d_rvalid) rvalids[3]++;
        if (a_wnext) wnexts[0]++;
        if (b_wnext) wnexts[1]++;
        if (c_wnext) wnexts[2]++;
    end

    // sdram_ctrl の代わり: 読み出しなら len 回 rvalid、書き込みなら len 回 wnext を出してから ack
    task automatic serve(output logic [20:0] seen_addr, output logic [3:0] seen_mask);
        int i, n;
        do @(negedge clk); while (!m_req);
        seen_addr = m_addr;
        seen_mask = m_wmask;
        n = int'(m_len);
        repeat (2) @(negedge clk);
        for (i = 0; i < n; i++) begin
            if (m_we) m_wnext = 1;
            else      m_rvalid = 1;
            @(negedge clk);
            m_wnext = 0;
            m_rvalid = 0;
        end
        m_ack = 1;
        @(negedge clk);
        m_ack = 0;
    endtask

    initial begin
        logic [20:0] addr [4];
        logic [3:0]  mask [4];
        $dumpfile("build/sim/tb_sdram_arb.vcd");
        $dumpvars(0, tb_sdram_arb);
        repeat (2) @(negedge clk);
        rst = 0;

        a_req = 1; b_req = 1; c_req = 1; d_req = 1;
        serve(addr[0], mask[0]); a_req = 0;    // 利用者は ack を見たら下げる
        serve(addr[3], mask[3]); d_req = 0;
        serve(addr[1], mask[1]); b_req = 0;
        serve(addr[2], mask[2]); c_req = 0;
        repeat (3) @(negedge clk);

        if (addr[0] !== 21'h000AAA || addr[3] !== 21'h000DDD || addr[1] !== 21'h000BBB || addr[2] !== 21'h000CCC) begin
            $display("  grant order: %h %h %h %h", addr[0], addr[3], addr[1], addr[2]); errors++;
        end
        if (acks[3] != 1 || rvalids[3] != 1) begin $display("  d: %0d acks, %0d rvalid", acks[3], rvalids[3]); errors++; end
        if (mask[1] !== 4'h2 || mask[2] !== 4'h4) begin $display("  wmask routing: %h %h", mask[1], mask[2]); errors++; end
        if (acks[0] != 1 || acks[1] != 1 || acks[2] != 1) begin $display("  acks: %0d %0d %0d", acks[0], acks[1], acks[2]); errors++; end
        if (rvalids[0] != 3 || rvalids[1] != 0 || rvalids[2] != 0) begin $display("  rvalid: %0d %0d %0d", rvalids[0], rvalids[1], rvalids[2]); errors++; end
        if (wnexts[0] != 0 || wnexts[1] != 2 || wnexts[2] != 1) begin $display("  wnext: %0d %0d %0d", wnexts[0], wnexts[1], wnexts[2]); errors++; end
        if (m_req !== 1'b0) begin $display("  m_req still high"); errors++; end

        if (errors == 0) $display("PASS: tb_sdram_arb");
        else             $display("FAIL: tb_sdram_arb (%0d errors)", errors);
        $finish;
    end
endmodule
