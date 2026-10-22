// SPI スレーブ: 書き込み / 読み出しのバースト、同期バイト、フレームエラーを 1 / 8 / 10MHz で確認
`timescale 1ns/1ps
module tb_spi_slave;
    logic       clk = 0, rst = 1;
    logic       sck = 0, copi = 0, cs = 0;
    logic       cipo;
    logic [6:0] reg_addr;
    logic [7:0] reg_wdata, reg_rdata;
    logic       reg_we, reg_re, frame_error;

    spi_slave dut (.*);

    always #7.936 clk = ~clk;   // 63MHz

    // レジスタの代わりの 128 バイトのメモリ
    logic [7:0] mem [0:127];
    always_ff @(posedge clk) if (reg_we) mem[reg_addr] <= reg_wdata;
    assign reg_rdata = mem[reg_addr];

    int errors = 0, frame_errors = 0;
    always @(posedge clk) if (frame_error) frame_errors++;

    real half = 500.0;          // SCK の半周期 [ns]

    // mode 0: SCK が Low の間に COPI を変え、立ち上がりで CIPO をサンプルする
    task automatic xfer_byte(input logic [7:0] tx, output logic [7:0] rx);
        int i;
        rx = 8'h00;
        for (i = 7; i >= 0; i--) begin
            copi = tx[i];
            #(half);
            sck = 1;
            rx = {rx[6:0], cipo};
            #(half);
            sck = 0;
        end
    endtask

    function automatic logic [7:0] pattern(input logic [7:0] seed, input int k);
        pattern = seed + 8'(k * 37);
    endfunction

    task automatic write_burst(input logic [6:0] a, input int n, input logic [7:0] seed);
        logic [7:0] rx;
        int k;
        cs = 1;
        #(half);
        xfer_byte({1'b0, a}, rx);
        if (rx !== 8'hA5) begin
            $display("  write sync byte: got %02h (half=%0.1f)", rx, half);
            errors++;
        end
        for (k = 0; k < n; k++) xfer_byte(pattern(seed, k), rx);
        #(half);
        cs = 0;
        #(4 * half + 100);
    endtask

    task automatic read_check(input logic [6:0] a, input int n, input logic [7:0] seed, input int offset);
        logic [7:0] rx;
        int k;
        cs = 1;
        #(half);
        xfer_byte({1'b1, a}, rx);
        if (rx !== 8'hA5) begin
            $display("  read sync byte: got %02h (half=%0.1f)", rx, half);
            errors++;
        end
        for (k = 0; k < n; k++) begin
            xfer_byte(8'h00, rx);
            if (rx !== pattern(seed, k + offset)) begin
                $display("  read %02h+%0d: got %02h, expected %02h (half=%0.1f)", a, k, rx, pattern(seed, k + offset), half);
                errors++;
            end
        end
        #(half);
        cs = 0;
        #(4 * half + 100);
    endtask

    task automatic run_speed(input real h, input logic [7:0] seed);
        half = h;
        write_burst(7'h10, 8, seed);
        read_check(7'h10, 8, seed, 0);
        read_check(7'h13, 3, seed, 3);       // 途中から読む
        write_burst(7'h7D, 1, seed ^ 8'hFF); // 1 バイトだけ
        read_check(7'h7D, 1, seed ^ 8'hFF, 0);
    endtask

    initial begin
        int i;
        logic [7:0] rx;
        $dumpfile("build/sim/tb_spi_slave.vcd");
        $dumpvars(0, tb_spi_slave);
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (4) @(posedge clk);

        run_speed(500.0, 8'h11);   // 1MHz
        run_speed(62.5, 8'h52);    // 8MHz
        run_speed(50.0, 8'hC3);    // 10MHz

        if (frame_errors != 0) begin
            $display("  unexpected frame errors: %0d", frame_errors);
            errors++;
        end

        // バイトの途中で CS を下げるとフレームエラー、書き込みは起きない
        half = 500.0;
        mem[7'h20] = 8'h77;
        cs = 1;
        #(half);
        xfer_byte({1'b0, 7'h20}, rx);
        for (i = 0; i < 4; i++) begin
            copi = 1'b1;
            #(half);
            sck = 1;
            #(half);
            sck = 0;
        end
        #(half);
        cs = 0;
        #(1000);
        if (frame_errors != 1) begin
            $display("  frame errors after a partial byte: got %0d, expected 1", frame_errors);
            errors++;
        end
        if (mem[7'h20] !== 8'h77) begin
            $display("  partial byte was written: %02h", mem[7'h20]);
            errors++;
        end

        // CS が Low の間、CIPO は Low
        if (cipo !== 1'b0) begin
            $display("  CIPO is not low while CS is low");
            errors++;
        end

        if (errors == 0) $display("PASS: tb_spi_slave");
        else             $display("FAIL: tb_spi_slave (%0d errors)", errors);
        $finish;
    end
endmodule
