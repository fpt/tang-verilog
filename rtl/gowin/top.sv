// Tang Nano 20K トップ
//   27MHz -> rPLL 126MHz (シリアル) -> CLKDIV /5 -> 25.2MHz (ピクセル)
//   27MHz -> 2 つ目の rPLL 63MHz (システム: SPI スレーブ・レジスタ・SDRAM)
//                              + CLKOUTP (同じ 63MHz を位相だけずらしたもの) -> SDRAM のクロック
//   ハーネス (docs/HARNESS.md, harness/pins.json) の線もここで出す
//   パッケージ内 SDRAM は 63MHz で動かし、SDRAM のクロックは CLKOUTP を ODDR で反転して出す。
//   位相 (PSDA、1/16 周期 = 約 1ns 刻み) は MEM_CLK レジスタで実行時に変えられる。PSDA = 0 で以前と同じ逆相 (180°)
//   GPU3D = 1 (make TARGET=gpu3d): VDP を外した 3D GPU のビットストリーム (docs/GPU3D_PLAN.md)。line_compositor の代わりに
//   fb_line (ビットマップ RGB565 + 背景色・透過色だけ) で表示し、音はない (アンプは切る)。0x50..0x5F は MUL_PROBE なら mul_probe (DSP の確かめ)。
//   VERSION の bit7 が 1 になる
module top #(
    parameter int GPU3D = 0,
    parameter int MUL_PROBE = 0          // 3D GPU で 0x50 に mul_probe (DSP の確かめ、G0) を入れる (make TARGET=gpu3d MUL_PROBE=1)
) (
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
    inout  wire  [31:0] IO_sdram_dq,
    // 基板の音のアンプ (MAX98357A、I2S)。K5a
    output logic        hp_bck,
    output logic        hp_ws,
    output logic        hp_din,
    output logic        pa_en
);
    // --- クロック生成 ---
    logic clk_ser, clk_pix, clk_sys, clk_sdram, pll_lock, pll_sys_lock;
    logic [3:0] sdram_psda, sdram_dutyda;   // mem_test の MEM_CLK から

    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(2),     // /3
        .FBDIV_SEL(13),   // x14  -> 126MHz
        .ODIV_SEL(4),     // VCO = 504MHz
        .DEVICE("GW2AR-18C")
    ) u_pll (
        .CLKIN(clk),
        .CLKOUT(clk_ser),
        .LOCK(pll_lock),
        .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0),
        .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );

    // システムクロックと SDRAM のクロック (位相を実行時に変える)
    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(2),     // /3
        .FBDIV_SEL(6),    // x7  -> 63MHz
        .ODIV_SEL(8),     // VCO = 504MHz
        .DYN_DA_EN("true"),
        .DEVICE("GW2AR-18C")
    ) u_pll_sys (
        .CLKIN(clk),
        .CLKOUT(clk_sys),
        .CLKOUTP(clk_sdram),
        .LOCK(pll_sys_lock),
        .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0),
        .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(sdram_psda), .DUTYDA(sdram_dutyda), .FDLY(4'b0)
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
    always_ff @(posedge clk_sys or negedge pll_sys_lock) begin
        if (!pll_sys_lock) rst_sys_sync <= '1;
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
    logic [15:0] frame_crc_frame;
    logic [31:0] held_crc;
    logic [7:0]  mark_count;
    logic        mark_toggle;        // line_compositor (clk_sys) -> frame_crc
    frame_crc u_crc (
        .clk(clk_pix), .rst, .de, .r, .g, .b, .vblank,
        .crc(frame_crc_value), .frame(frame_crc_frame), .crc_toggle(frame_crc_toggle),
        .mark_toggle_async(mark_toggle), .held_crc, .mark_count
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
    logic [7:0] reg_wdata, reg_rdata, vdp_rdata, mem_rdata, gpu_rdata;
    logic       reg_we, reg_re, spi_frame_error;

    logic [12:0] fb_base;            // gpu -> line_compositor
    logic        base_latched;       // line_compositor -> gpu
    logic [7:0]  underflow_count;    // line_compositor -> vdp_regs

    // IRQ ピン: 既定は VBLANK (CONTROL.IRQ_EN)、CONTROL bit4 で READY (GPU の FIFO が半分以上空いている)
    logic irq_vblank, gpu_ready;
    assign vdp_irq = control[4] ? gpu_ready : irq_vblank;

    // 0x10..0x2F は SDRAM のテスト (mem_test)、0x30..0x4F は GPU、それ以外は vdp_regs
    // 0x50..0x5F は音 (audio_out、読み出しだけ)
    logic sel_mem, sel_gpu, sel_audio;
    logic [7:0] audio_rdata;
    assign sel_mem   = reg_addr >= 7'h10 && reg_addr <= 7'h2F;
    assign sel_gpu   = reg_addr >= 7'h30 && reg_addr <= 7'h4F;
    assign sel_audio = reg_addr >= 7'h50 && reg_addr <= 7'h5F;
    assign reg_rdata = sel_mem ? mem_rdata : sel_gpu ? gpu_rdata : sel_audio ? audio_rdata : vdp_rdata;

    spi_slave u_spi (
        .clk(clk_sys), .rst(rst_sys),
        .sck(spi_sck), .copi(spi_copi), .cs(spi_cs), .cipo(spi_cipo),
        .reg_addr, .reg_wdata, .reg_we, .reg_re, .reg_rdata,
        .frame_error(spi_frame_error)
    );

    vdp_regs #(.VERSION(GPU3D != 0 ? 8'h81 : 8'h01)) u_regs (
        .clk(clk_sys), .rst(rst_sys),
        .addr(reg_addr), .wdata(reg_wdata), .we(reg_we && !sel_mem && !sel_gpu && !sel_audio), .re(reg_re && !sel_mem && !sel_gpu && !sel_audio),
        .rdata(vdp_rdata),
        .vblank_async(vblank), .frame_toggle_async(heartbeat),
        .crc_async(frame_crc_value), .crc_frame_async(frame_crc_frame), .crc_toggle_async(frame_crc_toggle),
        .held_crc_async(held_crc), .mark_count_async(mark_count),
        .error_event(spi_frame_error),
        .underflow_count,
        .control, .irq(irq_vblank), .error(error_out)
    );

    // --- パッケージ内 SDRAM ---
    // 利用者: a = フレームバッファの表示 (最優先), b = GPU の描画, c = メモリテスト
    logic        mem_req, mem_we, mem_ack, mem_rvalid, mem_wnext, mem_init_done, sdram_dq_oe;
    logic [20:0] mem_addr;
    logic [31:0] mem_wdata, mem_rdata32, sdram_dq_out;
    logic [3:0]  mem_wmask;
    logic [8:0]  mem_len;
    logic [2:0]  rd_sample;

    logic        fb_req, fb_ack, fb_rvalid;
    logic [20:0] fb_addr;
    logic [8:0]  fb_len;

    logic        g_req, g_we, g_ack, g_wnext, g_rvalid;
    logic [20:0] g_addr;
    logic [31:0] g_wdata;
    logic [3:0]  g_wmask;
    logic [8:0]  g_len;

    logic        t_req, t_we, t_ack, t_rvalid;
    logic [20:0] t_addr;
    logic [31:0] t_wdata;
    logic [3:0]  t_wmask;
    logic [8:0]  t_len;

    // 合成のレジスタと、ラインの合成の開始 (WAIT_LINE 用)・フレームの印
    logic [15:0] bg_color, bitmap_key;
    logic [2:0]  bitmap_rank;
    logic        bitmap_fmt;
    logic [5:0]  layer_ctrl;
    logic        light_we;
    logic        xreg_we;           // E7 のレジスタ (gpu -> line_compositor)
    logic [4:0]  xreg_idx;
    logic [15:0] xreg_data;
    logic [9:0]  tileb_scroll_x, tileb_scroll_y;
    logic [13:0] tileb_map_base, tileb_pat_base, win_map_base, hs_base;
    logic [7:0]  tileb_ctrl;
    logic [5:0]  win_h, win_v;
    logic [1:0]  hs_mode;
    // タイル レイヤのレジスタと、VRAM / パレットの書き込み (gpu -> line_compositor)
    logic [9:0]  tile_scroll_x, tile_scroll_y;
    logic [13:0] tile_map_base, tile_pat_base, vram_waddr;
    logic [7:0]  tile_ctrl;
    logic [13:0] spr_pat_base;
    logic [3:0]  spr_bank;
    logic [6:0]  spr_line_cols;
    logic        oam_we;
    logic        vram_we, pal_we;
    logic [31:0] vram_wdata;
    logic [8:0]  pal_waddr;
    logic [15:0] pal_wdata;
    logic        mark_req, line_start;
    logic [7:0]  line_num;

    if (GPU3D != 0) begin : g_fb
        // 3D GPU: ビットマップだけの表示。gpu の面・スプライト・VRAM などの出力はつながず、合成で消える
        fb_line u_fb (
            .clk_sys, .rst_sys, .fb_base, .base_latched,
            .bg_color, .layer_ctrl(layer_ctrl[1:0]), .bitmap_key, .mark_req, .mark_toggle, .line_start, .line_num,
            .mem_req(fb_req), .mem_addr(fb_addr), .mem_len(fb_len), .mem_ack(fb_ack),
            .mem_rvalid(fb_rvalid), .mem_rdata(mem_rdata32), .underflow_count,
            .clk_pix, .rst_pix(rst), .x(vx), .y(vy), .rgb(fb_rgb)
        );
    end else begin : g_comp
        line_compositor u_comp (
            .clk_sys, .rst_sys, .fb_base, .base_latched,
            .bg_color, .layer_ctrl, .bitmap_key, .bitmap_rank, .bitmap_fmt, .mark_req, .mark_toggle, .line_start, .line_num,
            .tile_scroll_x, .tile_scroll_y, .tile_map_base, .tile_pat_base, .tile_ctrl,
            .spr_pat_base, .spr_bank, .spr_line_cols, .oam_we, .light_we, .xreg_we, .xreg_idx, .xreg_data,
            .tileb_scroll_x, .tileb_scroll_y, .tileb_map_base, .tileb_pat_base, .tileb_ctrl, .win_h, .win_v, .win_map_base, .hs_mode, .hs_base,
            .vram_we, .vram_waddr, .vram_wdata, .pal_we, .pal_waddr, .pal_wdata,
            .mem_req(fb_req), .mem_addr(fb_addr), .mem_len(fb_len), .mem_ack(fb_ack),
            .mem_rvalid(fb_rvalid), .mem_rdata(mem_rdata32), .underflow_count,
            .clk_pix, .rst_pix(rst), .x(vx), .y(vy), .rgb(fb_rgb)
        );
    end

    // 音のレジスタ (gpu -> audio_out)
    logic        audio_en, audio_clear;
    logic [12:0] pcm_base;
    logic [3:0]  pcm_size;
    logic [15:0] pcm_wr;

    // 3D GPU (GPU3D): gpu -> tri_engine
    logic        t3_push, t3_go, t3_busy, t3_error;
    logic [31:0] t3_word;
    logic [12:0] draw_base, z_base;
    logic [8:0]  clip_x0, clip_x1;
    logic [7:0]  clip_y0, clip_y1;

    gpu #(.GPU3D(GPU3D)) u_gpu (
        .clk(clk_sys), .rst(rst_sys),
        .addr(reg_addr), .wdata(reg_wdata), .we(reg_we && sel_gpu), .re(reg_re && sel_gpu), .rdata(gpu_rdata),
        .mem_req(g_req), .mem_we(g_we), .mem_addr(g_addr), .mem_wdata(g_wdata), .mem_wmask(g_wmask),
        .mem_len(g_len), .mem_ack(g_ack), .mem_wnext(g_wnext), .mem_rvalid(g_rvalid), .mem_rdata(mem_rdata32),
        .fb_base, .base_latched,
        .bg_color, .layer_ctrl, .bitmap_key, .bitmap_rank, .bitmap_fmt, .mark_req, .line_start, .line_num, .ready(gpu_ready),
        .tile_scroll_x, .tile_scroll_y, .tile_map_base, .tile_pat_base, .tile_ctrl,
        .spr_pat_base, .spr_bank, .spr_line_cols, .oam_we, .light_we, .xreg_we, .xreg_idx, .xreg_data,
        .tileb_scroll_x, .tileb_scroll_y, .tileb_map_base, .tileb_pat_base, .tileb_ctrl, .win_h, .win_v, .win_map_base, .hs_mode, .hs_base,
        .vram_we, .vram_waddr, .vram_wdata, .pal_we, .pal_waddr, .pal_wdata,
        .audio_en, .audio_clear, .pcm_base, .pcm_size, .pcm_wr,
        .t3_push, .t3_word, .t3_go, .t3_busy, .t3_error, .draw_base_o(draw_base), .z_base, .clip_x0, .clip_x1, .clip_y0, .clip_y1
    );

    // アービタの d: VDP は音 (PCM のリング -> I2S、読み出しだけ)、3D GPU は三角形の描画 (tri_engine)
    logic        p_req, p_we, p_ack, p_rvalid, p_wnext;
    logic [20:0] p_addr;
    logic [31:0] p_wdata;
    logic [3:0]  p_wmask;
    logic [8:0]  p_len;
    if (GPU3D != 0) begin : g_no_audio
        // 音はない。0x50..0x5F の窓は、MUL_PROBE なら乗算器の確かめ (mul_probe、G0)
        assign {hp_bck, hp_ws, hp_din, pa_en} = 4'b0000;
        if (MUL_PROBE != 0) begin : g_mul
            mul_probe u_mul (
                .clk(clk_sys), .rst(rst_sys),
                .addr(reg_addr[3:0]), .wdata(reg_wdata), .we(reg_we && sel_audio), .rdata(audio_rdata)
            );
        end else begin : g_no_mul
            assign audio_rdata = 8'h00;
        end
        raster3d u_r3d (
            .clk(clk_sys), .rst(rst_sys),
            .push(t3_push), .word(t3_word), .go(t3_go), .busy(t3_busy), .error(t3_error),
            .draw_base, .z_base, .cx0(clip_x0), .cx1(clip_x1), .cy0(clip_y0), .cy1(clip_y1),
            .mem_req(p_req), .mem_we(p_we), .mem_addr(p_addr), .mem_len(p_len), .mem_wdata(p_wdata), .mem_wmask(p_wmask),
            .mem_ack(p_ack), .mem_wnext(p_wnext), .mem_rvalid(p_rvalid), .mem_rdata(mem_rdata32),
            .st_bin(), .st_pairs(), .st_prep(), .st_fetch(), .st_mul(), .st_walk(), .st_out(), .st_walked(), .st_drawn()
        );
    end else begin : g_audio
        assign {p_we, p_wdata, p_wmask, p_len} = {1'b0, 32'h0, 4'h0, 9'd1};
        assign {t3_busy, t3_error} = 2'b00;
        audio_out u_audio (
            .clk(clk_sys), .rst(rst_sys),
            .enable(audio_en), .clear(audio_clear), .base(pcm_base), .size_log2(pcm_size), .wr(pcm_wr),
            .addr(reg_addr[3:0]), .re(reg_re && sel_audio), .rdata(audio_rdata),
            .mem_req(p_req), .mem_addr(p_addr), .mem_ack(p_ack), .mem_rvalid(p_rvalid), .mem_rdata(mem_rdata32),
            .bck(hp_bck), .ws(hp_ws), .din(hp_din), .pa_en
        );
    end

    mem_test u_mem_test (
        .clk(clk_sys), .rst(rst_sys),
        .addr(reg_addr), .wdata(reg_wdata), .we(reg_we && sel_mem), .rdata(mem_rdata),
        .mem_req(t_req), .mem_we(t_we), .mem_addr(t_addr), .mem_wdata(t_wdata), .mem_wmask(t_wmask),
        .mem_len(t_len), .mem_ack(t_ack), .mem_rvalid(t_rvalid), .mem_rdata(mem_rdata32), .mem_init_done, .rd_sample,
        .clk_phase(sdram_psda), .clk_duty(sdram_dutyda)
    );

    sdram_arb u_arb (
        .clk(clk_sys), .rst(rst_sys),
        .a_req(fb_req), .a_we(1'b0), .a_addr(fb_addr), .a_wdata(32'h0), .a_wmask(4'h0), .a_len(fb_len),
        .a_ack(fb_ack), .a_rvalid(fb_rvalid), .a_wnext(),
        .b_req(g_req), .b_we(g_we), .b_addr(g_addr), .b_wdata(g_wdata), .b_wmask(g_wmask), .b_len(g_len),
        .b_ack(g_ack), .b_rvalid(g_rvalid), .b_wnext(g_wnext),
        .c_req(t_req), .c_we(t_we), .c_addr(t_addr), .c_wdata(t_wdata), .c_wmask(t_wmask), .c_len(t_len),
        .c_ack(t_ack), .c_rvalid(t_rvalid), .c_wnext(),
        .d_req(p_req), .d_we(p_we), .d_addr(p_addr), .d_wdata(p_wdata), .d_wmask(p_wmask), .d_len(p_len),
        .d_ack(p_ack), .d_rvalid(p_rvalid), .d_wnext(p_wnext),
        .m_req(mem_req), .m_we(mem_we), .m_addr(mem_addr), .m_wdata(mem_wdata), .m_wmask(mem_wmask), .m_len(mem_len),
        .m_ack(mem_ack), .m_rvalid(mem_rvalid), .m_wnext(mem_wnext)
    );

    sdram_ctrl #(.CLK_HZ(63_000_000)) u_sdram (
        .clk(clk_sys), .rst(rst_sys),
        .req(mem_req), .we(mem_we), .addr(mem_addr), .wdata(mem_wdata), .wmask(mem_wmask), .len(mem_len),
        .wnext(mem_wnext), .ack(mem_ack), .rvalid(mem_rvalid), .rdata(mem_rdata32),
        .init_done(mem_init_done), .rd_sample,
        .sdram_cke(O_sdram_cke), .sdram_cs_n(O_sdram_cs_n), .sdram_ras_n(O_sdram_ras_n),
        .sdram_cas_n(O_sdram_cas_n), .sdram_we_n(O_sdram_wen_n), .sdram_ba(O_sdram_ba),
        .sdram_addr(O_sdram_addr), .sdram_dqm(O_sdram_dqm),
        .sdram_dq_out, .sdram_dq_oe, .sdram_dq_in(IO_sdram_dq)
    );
    assign IO_sdram_dq = sdram_dq_oe ? sdram_dq_out : 'z;

    // SDRAM のクロック: 立ち上がりで 0、立ち下がりで 1 を出す = clk_sys の逆相
    ODDR u_sdram_clk (
        .D0(1'b0), .D1(1'b1), .TX(1'b0), .CLK(clk_sdram), .Q0(O_sdram_clk), .Q1()
    );

    // --- 動作確認用 LED (約 1.5Hz で流れる) ---
    logic [24:0] div;
    always_ff @(posedge clk_pix) div <= div + 25'd1;
    assign led = btn_s2 ? 6'b000000 : ~(6'b1 << (div[24:22] % 3'd6));  // S2 押下で全点灯
endmodule
