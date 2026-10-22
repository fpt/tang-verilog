// ハーネスの配線テスト用トップ (docs/HARNESS.md, harness/firmware と対で使う)
//   通常: FPGA -> RP2 の各線を、それぞれ違う周波数 (27MHz / 2^(N+1)) でトグルさせる
//   エコー: RP2 -> FPGA の線のどれかが High の間は、その 4 本を決まった線にそのまま折り返す
//     SCK -> CIPO, COPI -> IRQ, CS -> VSYNC, RESET -> HEARTBEAT (ERROR と LED は 0)
//   RP2 -> FPGA の線は FPGA 側でもプルダウンし、FPGA は絶対に駆動しない (入力専用)
module top_harness_probe (
    input  logic       clk,          // 27MHz
    input  logic       spi_sck,
    input  logic       spi_copi,
    input  logic       spi_cs,
    input  logic       rst_in,
    output logic       spi_cipo,
    output logic       vdp_irq,
    output logic       vsync_out,
    output logic       heartbeat,
    output logic       error_out,
    output logic [5:0] led
);
    logic [20:0] cnt = '0;
    always_ff @(posedge clk) cnt <= cnt + 21'd1;

    logic echo;
    assign echo = spi_sck | spi_copi | spi_cs | rst_in;

    // 周波数は harness/firmware/src/main.c の PROBE_BITS と合わせる
    assign spi_cipo  = echo ? spi_sck  : cnt[10];   // 13.2kHz
    assign vdp_irq   = echo ? spi_copi : cnt[11];   // 6.6kHz
    assign vsync_out = echo ? spi_cs   : cnt[12];   // 3.3kHz
    assign heartbeat = echo ? rst_in   : cnt[13];   // 1.6kHz
    assign error_out = echo ? 1'b0     : cnt[14];   // 824Hz
    assign led       = echo ? 6'b0     : cnt[20:15]; // 412Hz .. 12.9Hz (LED5 は目でも点滅が見える)
endmodule
