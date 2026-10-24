// 音の出力 (K5a): SDRAM の代わりのメモリ (返すまでの時間は乱数) にリング 16 ワードを置き、ホストの代わりに先回りして書き込みながら、
// I2S を BCLK の立ち上がりで読み戻して比べる
//   - 標本が順番どおり、左 / 右が正しく出る (WS は 1 ビット前に変わる、MSB が先)。リングの折り返し
//   - 書いたものを使い切ると無音になり、UNDERRUN が増える。有効の前は無音で数えない
//   - BCLK の周期 (clk 41 か 42)、1 標本が平均ちょうど clk 1312.5 (= 48kHz)
//   - PCM_RD (レジスタ)、clear で 0 に戻る、pa_en は enable と同じ
//   - PCM_RD の 2 バイトが同じ時点の値: spi_slave と同じく rdata を取り込んだ次のクロックに re を出し、そのクロックで下位から繰り上がっても上位がずれない
`timescale 1ns/1ps
module tb_audio_out;
    logic clk = 0, rst = 1;
    always #7.936 clk = ~clk;        // 63MHz

    logic        enable = 0, clear = 0;
    logic [12:0] base = 13'h0010;
    logic [3:0]  size_log2 = 4'd4;
    logic [15:0] wr = '0;
    logic [3:0]  addr = '0;
    logic        re = 0;
    logic [7:0]  rdata;
    logic        mem_req, mem_ack = 0, mem_rvalid = 0;
    logic [20:0] mem_addr;
    logic [31:0] mem_rdata = '0;
    logic        bck, ws, din, pa_en;

    audio_out dut (.*);

    // SDRAM の代わり: 2〜60 クロック待って 1 ワード返す
    logic [31:0] ram [0:15];
    int          bad_addr = 0;
    always begin
        @(negedge clk);
        if (mem_req && !mem_ack) begin
            if (mem_addr[20:4] != {base, 4'b0}) bad_addr++;          // {base, 8'b0} + 0..15
            repeat ($urandom_range(2, 60)) @(negedge clk);
            mem_rvalid = 1; mem_rdata = ram[mem_addr[3:0]];
            @(negedge clk);
            mem_rvalid = 0; mem_ack = 1;
            @(negedge clk);
            mem_ack = 0;
        end
    end

    function automatic logic [31:0] sample(input int k);
        return {16'(k * 977 + 3), 16'(k * 31337 + 1)};
    endfunction

    // ホストの代わり: 先回りの量が 12 より少なければ 1 標本書く (N 個まで)
    localparam int N = 100;
    bit host_on = 0;
    int host_n = 0;
    always @(negedge clk) begin
        if (host_on && host_n < N && 16'(host_n) - dut.rd < 16'd12) begin
            ram[host_n % 16] = sample(host_n);
            host_n++;
            wr = 16'(host_n);
        end
    end

    // I2S を読む: 立ち上がりで din を拾う。WS が 1 -> 0 になった立ち上がり (右の LSB) で 1 標本ぶん (32 ビット) がそろう
    logic [31:0] sh = '0;
    logic        last_ws = 1;
    logic [31:0] got [0:511];
    int          got_n = 0, edges = 0, last_rise = 0, min_p = 1000, max_p = 0, cyc = 0;
    int          frame_start_cyc [0:511];
    always @(posedge clk) cyc++;
    always @(posedge bck) begin
        logic [31:0] s;
        s = {sh[30:0], din};
        sh <= s;
        if (edges > 2) begin
            if (cyc - last_rise < min_p) min_p = cyc - last_rise;
            if (cyc - last_rise > max_p) max_p = cyc - last_rise;
        end
        last_rise = cyc;
        edges++;
        if (last_ws && !ws && got_n < 512) begin
            got[got_n] = {s[15:0], s[31:16]};          // {右, 左}
            frame_start_cyc[got_n] = cyc;
            got_n++;
        end
        last_ws <= ws;
    end

    int errors = 0;
    task automatic read_reg(input logic [3:0] a, output logic [7:0] d);
        @(negedge clk); addr = a; re = 1;
        #1 d = rdata;
        @(negedge clk); re = 0;
    endtask

    initial begin
        int first, k, zeros_before, n0;
        logic [7:0] lo, hi, ur;
        $dumpfile("build/sim/tb_audio_out.vcd");
        $dumpvars(0, tb_audio_out);
        repeat (4) @(negedge clk);
        rst = 0;

        // 有効の前: 無音、数えない、アンプは切れている
        wait (got_n >= 4);
        if (dut.underrun != 0 || pa_en !== 0) begin $display("  before enable: underrun %0d pa_en %b", dut.underrun, pa_en); errors++; end
        // 先に 12 標本書いてから有効にする
        host_on = 1;
        wait (host_n == 12);
        n0 = got_n;
        @(negedge clk) enable = 1;
        wait (host_n == N);
        wait (dut.rd == 16'(N));
        repeat (3 * 1313) @(negedge clk);     // 使い切ったあと 3 標本ぶん
        if (pa_en !== 1) begin $display("  pa_en low while enabled"); errors++; end

        // 出てきた列: 有効にしてからの無音 (最初の 1 つまで) → sample(0..N-1) → 無音
        first = -1;
        for (k = n0; k < got_n; k++) if (got[k] != 0) begin first = k; break; end
        zeros_before = first - n0;
        if (first < 0 || zeros_before > 2) begin $display("  first sample at %0d (enabled at %0d)", first, n0); errors++; end
        for (k = 0; k < N; k++)
            if (got[first + k] !== sample(k)) begin
                if (errors < 10) $display("  sample %0d: got %h expected %h", k, got[first + k], sample(k));
                errors++;
            end
        for (k = first + N; k < got_n; k++) if (got[k] != 0) begin $display("  not silent after the data ran out (%0d)", k); errors++; break; end
        if (int'(dut.underrun) < got_n - (first + N) - 1 || int'(dut.underrun) > got_n - (first + N) + 2 + zeros_before) begin
            $display("  underrun %0d for %0d silent frames (+%0d before)", dut.underrun, got_n - (first + N), zeros_before); errors++;
        end
        // 時間: BCLK の周期は 41 か 42、64 標本で clk ちょうど 84,000 (= 1312.5 x 64)
        if (min_p < 41 || max_p > 42) begin $display("  BCLK period %0d..%0d clk", min_p, max_p); errors++; end
        if (frame_start_cyc[first + 64] - frame_start_cyc[first] != 84000) begin
            $display("  64 frames took %0d clk (expected 84000)", frame_start_cyc[first + 64] - frame_start_cyc[first]); errors++;
        end
        if (bad_addr != 0) begin $display("  %0d reads outside the ring", bad_addr); errors++; end

        // レジスタ: PCM_RD = N、UNDERRUN
        read_reg(4'd0, lo); read_reg(4'd1, hi); read_reg(4'd2, ur);
        if ({hi, lo} != 16'(N) || ur != dut.underrun) begin $display("  registers: PCM_RD %0d UNDERRUN %0d", {hi, lo}, ur); errors++; end
        // PCM_RD を spi_slave の順で読む: rdata (下位) を取り込むクロック → 次のクロックに re → 上位。
        // 取り込みと re のあいだで rd が 0x12FF -> 0x1300 に繰り上がっても、0x12FF が読めること
        @(negedge clk); force dut.rd = 16'h12FF; addr = 4'd0;
        #1 lo = rdata;                                   // 次の立ち上がりで取り込む値
        @(negedge clk); force dut.rd = 16'h1300; re = 1;
        @(negedge clk); re = 0; addr = 4'd1;
        #1 hi = rdata;
        release dut.rd;
        if ({hi, lo} != 16'h12FF) begin $display("  torn PCM_RD read across a carry: %h", {hi, lo}); errors++; end
        // clear
        @(negedge clk) clear = 1;
        @(negedge clk) clear = 0;
        if (dut.rd != 0 || dut.underrun != 0) begin $display("  clear: rd %0d underrun %0d", dut.rd, dut.underrun); errors++; end
        enable = 0;

        $display("  %0d frames, first sample after %0d silent frames, BCLK %0d..%0d clk", got_n, zeros_before, min_p, max_p);
        if (errors == 0) $display("PASS: tb_audio_out");
        else             $display("FAIL: tb_audio_out (%0d errors)", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL: tb_audio_out (timeout, rd %0d)", dut.rd);
        $finish;
    end
endmodule
