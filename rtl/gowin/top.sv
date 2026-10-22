// Tang Nano 20K トップ
//   27MHz -> rPLL 126MHz (シリアル) -> CLKDIV /5 -> 25.2MHz (ピクセル)
//                                   -> rPLL CLKOUTD /2 -> 63MHz (システム: SPI スレーブとレジスタ)
//   ハーネス (docs/HARNESS.md, harness/pins.json) の線もここで出す
//   パッケージ内 SDRAM は 63MHz で動かし、SDRAM のクロックは逆相 (ODDR) で出す
module top (
    input  logic       clk,          // 27MHz
    input  logic       btn_s1,       // リセット (押下で 1)
    input  logic       btn_s2,
    output logic [5:0] led,          // 負論理
    output logic       tmds_clk_p,
    output logic       tmds_clk_n,
    output logic [2:0] tmds_d_p,
    output logic [2:0] tmds_d_n,
    // ハーネス (RP2 -> FPGA は入力専用、正論理)
    input  logic       spi_sck,
    input  logic       spi_copi,
    input  logic       spi_cs,
    input  logic       rst_in,
    output logic       spi_cipo,
    output logic       vdp_irq,
    output logic       vsync_out,
    output logic       heartbeat,
    output logic       error_out,
    // パッケージ内 SDRAM
    output logic        O_sdram_clk,
    output logic        O_sdram_cke,
    output logic        O_sdram_cs_n,
    output logic        O_sdram_ras_n,
    output logic        O_sdram_cas_n,
    output logic        O_sdram_wen_n,
    output logic [1:0]  O_sdram_ba,
    output logic [10:0] O_sdram_addr,
    output logic [3:0]  O_sdram_dqm,
    inout  wire  [31:0] IO_sdram_dq
);
    // --- クロック生成 ---
    logic clk_ser, clk_pix, clk_sys, pll_lock;

    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(2),     // /3
        .FBDIV_SEL(13),   // x14  -> 126MHz
        .ODIV_SEL(4),     // VCO = 504MHz
        .DYN_SDIV_SEL(2), // CLKOUTD = 126MHz / 2 = 63MHz
        .DEVICE("GW2AR-18C")
    ) u_pll (
        .CLKIN(clk),
        .CLKOUT(clk_ser),
        .LOCK(pll_lock),
        .CLKOUTP(), .CLKOUTD(clk_sys), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0),
        .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );

    CLKDIV #(.DIV_MODE("5")) u_clkdiv (
        .HCLKIN(clk_ser),
        .RESETN(pll_lock),
        .CALIB(1'b0),
        .CLKOUT(clk_pix)
    );

    // --- リセット同期化 (S1 または RP2 の RESET) ---
    logic rst_req;
    assign rst_req = btn_s1 || rst_in;

    logic [3:0] rst_sync = '1;
    always_ff @(posedge clk_pix or negedge pll_lock) begin
        if (!pll_lock) rst_sync <= '1;
        else           rst_sync <= {rst_sync[2:0], rst_req};
    end
    logic rst;
    assign rst = rst_sync[3];

    logic [3:0] rst_sys_sync = '1;
    always_ff @(posedge clk_sys or negedge pll_lock) begin
        if (!pll_lock) rst_sys_sync <= '1;
        else           rst_sys_sync <= {rst_sys_sync[2:0], rst_req};
    end
    logic rst_sys;
    assign rst_sys = rst_sys_sync[3];

    // --- 映像 ---
    logic [7:0] r, g, b;
    logic de, hsync, vsync, vblank, frame_start;
    logic [7:0] control;

    // CONTROL のアニメーション停止 (clk_sys) をピクセルクロックへ
    // CONTROL のフレームバッファ表示 (bit3) も同じく
    logic [1:0] freeze_s, fb_en_s;
    always_ff @(posedge clk_pix) begin
        freeze_s <= {freeze_s[0], control[1]};
        fb_en_s  <= {fb_en_s[0], control[3]};
    end

    logic [10:0] vx;
    logic [9:0]  vy;
    logic [23:0] fb_rgb;

    vdp_video u_video (
        .clk_pix, .rst, .freeze(freeze_s[1]), .fb_en(fb_en_s[1]), .fb_rgb, .x(vx), .y(vy),
        .r, .g, .b, .de, .hsync, .vsync, .vblank, .frame_start
    );

    // 表示ピクセルの CRC (FRAME_CRC レジスタ)
    logic [31:0] frame_crc_value;
    logic        frame_crc_toggle;
    frame_crc u_crc (
        .clk(clk_pix), .rst, .de, .r, .g, .b, .vblank,
        .crc(frame_crc_value), .crc_toggle(frame_crc_toggle)
    );

    dvi_tx u_dvi (
        .clk_pix, .clk_ser, .rst,
        .r, .g, .b, .de, .hsync, .vsync,
        .tmds_clk_p, .tmds_clk_n, .tmds_d_p, .tmds_d_n
    );

    // --- ハーネスの観測線 ---
    // HEARTBEAT はフレームごとにトグル (30Hz)。リセット中は止まる
    always_ff @(posedge clk_pix) begin
        if (rst)              heartbeat <= 1'b0;
        else if (frame_start) heartbeat <= ~heartbeat;
    end
    assign vsync_out = !vsync;   // 正論理 (同期パルス中 High)

    // --- SPI スレーブとレジスタ (システムクロック) ---
    logic [6:0] reg_addr;
    logic [7:0] reg_wdata, reg_rdata, vdp_rdata, mem_rdata;
    logic       reg_we, reg_re, spi_frame_error;

    logic [12:0] fb_base;            // vdp_regs -> fb_scanout
    logic [7:0]  underflow_count;    // fb_scanout -> vdp_regs

    // 0x10..0x3F は SDRAM のテストとアップロード (mem_test)、それ以外は vdp_regs
    logic sel_mem;
    assign sel_mem   = reg_addr >= 7'h10 && reg_addr <= 7'h3F;
    assign reg_rdata = sel_mem ? mem_rdata : vdp_rdata;

    spi_slave u_spi (
        .clk(clk_sys), .rst(rst_sys),
        .sck(spi_sck), .copi(spi_copi), .cs(spi_cs), .cipo(spi_cipo),
        .reg_addr, .reg_wdata, .reg_we, .reg_re, .reg_rdata,
        .frame_error(spi_frame_error)
    );

    vdp_regs u_regs (
        .clk(clk_sys), .rst(rst_sys),
        .addr(reg_addr), .wdata(reg_wdata), .we(reg_we && !sel_mem), .re(reg_re && !sel_mem), .rdata(vdp_rdata),
        .vblank_async(vblank), .frame_toggle_async(heartbeat),
        .crc_async(frame_crc_value), .crc_toggle_async(frame_crc_toggle),
        .error_event(spi_frame_error),
        .underflow_count, .fb_base,
        .control, .irq(vdp_irq), .error(error_out)
    );

    // --- パッケージ内 SDRAM ---
    // 利用者: a = フレームバッファの表示 (優先), b = メモリテストとアップロード
    logic        mem_req, mem_we, mem_ack, mem_rvalid, mem_init_done, sdram_dq_oe;
    logic [20:0] mem_addr;
    logic [31:0] mem_wdata, mem_rdata32, sdram_dq_out;
    logic [8:0]  mem_len;
    logic [2:0]  rd_sample;

    logic        fb_req, fb_ack, fb_rvalid;
    logic [20:0] fb_addr;
    logic [8:0]  fb_len;

    logic        t_req, t_we, t_ack, t_rvalid;
    logic [20:0] t_addr;
    logic [31:0] t_wdata;
    logic [8:0]  t_len;

    fb_scanout u_fb (
        .clk_sys, .rst_sys, .fb_base,
        .mem_req(fb_req), .mem_addr(fb_addr), .mem_len(fb_len), .mem_ack(fb_ack),
        .mem_rvalid(fb_rvalid), .mem_rdata(mem_rdata32), .underflow_count,
        .clk_pix, .rst_pix(rst), .enable(fb_en_s[1]), .x(vx), .y(vy), .rgb(fb_rgb)
    );

    mem_test u_mem_test (
        .clk(clk_sys), .rst(rst_sys),
        .addr(reg_addr), .wdata(reg_wdata), .we(reg_we && sel_mem), .rdata(mem_rdata),
        .mem_req(t_req), .mem_we(t_we), .mem_addr(t_addr), .mem_wdata(t_wdata), .mem_len(t_len),
        .mem_ack(t_ack), .mem_rvalid(t_rvalid), .mem_rdata(mem_rdata32), .mem_init_done, .rd_sample
    );

    sdram_arb u_arb (
        .clk(clk_sys), .rst(rst_sys),
        .a_req(fb_req), .a_we(1'b0), .a_addr(fb_addr), .a_wdata(32'h0), .a_len(fb_len),
        .a_ack(fb_ack), .a_rvalid(fb_rvalid),
        .b_req(t_req), .b_we(t_we), .b_addr(t_addr), .b_wdata(t_wdata), .b_len(t_len),
        .b_ack(t_ack), .b_rvalid(t_rvalid),
        .m_req(mem_req), .m_we(mem_we), .m_addr(mem_addr), .m_wdata(mem_wdata), .m_len(mem_len),
        .m_ack(mem_ack), .m_rvalid(mem_rvalid)
    );

    sdram_ctrl #(.CLK_HZ(63_000_000)) u_sdram (
        .clk(clk_sys), .rst(rst_sys),
        .req(mem_req), .we(mem_we), .addr(mem_addr), .wdata(mem_wdata), .len(mem_len),
        .ack(mem_ack), .rvalid(mem_rvalid), .rdata(mem_rdata32),
        .init_done(mem_init_done), .rd_sample,
        .sdram_cke(O_sdram_cke), .sdram_cs_n(O_sdram_cs_n), .sdram_ras_n(O_sdram_ras_n),
        .sdram_cas_n(O_sdram_cas_n), .sdram_we_n(O_sdram_wen_n), .sdram_ba(O_sdram_ba),
        .sdram_addr(O_sdram_addr), .sdram_dqm(O_sdram_dqm),
        .sdram_dq_out, .sdram_dq_oe, .sdram_dq_in(IO_sdram_dq)
    );
    assign IO_sdram_dq = sdram_dq_oe ? sdram_dq_out : 'z;

    // SDRAM のクロック: 立ち上がりで 0、立ち下がりで 1 を出す = clk_sys の逆相
    ODDR u_sdram_clk (
        .D0(1'b0), .D1(1'b1), .TX(1'b0), .CLK(clk_sys), .Q0(O_sdram_clk), .Q1()
    );

    // --- 動作確認用 LED (約 1.5Hz で流れる) ---
    logic [24:0] div;
    always_ff @(posedge clk_pix) div <= div + 25'd1;
    assign led = btn_s2 ? 6'b000000 : ~(6'b1 << (div[24:22] % 3'd6));  // S2 押下で全点灯
endmodule
