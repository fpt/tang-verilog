// VDP のレジスタ (docs/GPU_PLAN.md の M1)。レジスタバスと同じシステムクロックで動く
//
//   0x00 STATUS      R  bit0: VBLANK 中, bit1: エラー (SPI のフレームエラーなど。読むとクリア)
//   0x01 CONTROL     RW bit1: アニメーション停止 (スプライトをリセット位置に止める。比較用), bit2: IRQ 許可 (IRQ = VBLANK 中),
//                       bit3: 合成した画面 (line_compositor) を表示 (0 ならテストパターン),
//                       bit4: IRQ ピンを READY (GPU のコマンド FIFO が半分以上空いている) にする。bit0 は予約 (表示 ON)
//   0x02 MARK_COUNT  R  印を付けたフレームの CRC (MARK_CRC) を更新するたびに 1 増える
//   0x04 FRAME_COUNT R  フレームカウンタの下位 8bit
//   0x05 FRAME_CRC   R  直前のフレームの CRC-32 (32bit、リトルエンディアン、0x05..0x08)。frame_crc.sv
//                       0x05 を読んだ時点の値を 0x06..0x08 用に取っておくので、0x05 から続けて読めば 4 バイトが同じフレームの値になる
//   0x09 UNDERFLOW   R  表示に間に合わなかったライン数 (fb_scanout、飽和する)
//   0x0A CRC_FRAME   R  FRAME_CRC がどのフレームの値か (リセット後のフレーム番号、16bit、0x0A..0x0B)。
//                       FRAME_CRC と同じく 0x05 を読んだ時点の値 (先に 0x05..0x08 を読み、そのあとで読む)
//   0x0C MARK_CRC    R  印を付けたフレーム (GPU の WAIT_VBLANK、印付き) の CRC-32 (32bit、0x0C..0x0F)。frame_crc.sv
//   (表示するフレームバッファの先頭 FB_BASE は M5 で gpu.sv の 0x44 へ移した)
//   0x7C RECONFIG    W  0xA5 を書くと FPGA を再コンフィグする (トップが RECONFIG_N を Low にする。フラッシュの multiboot で次のビットストリームへ。
//                       docs/GPU3D_PLAN.md の G6 の前)。ほかの値は何もしない
//   0x7D SCRATCH     RW 書いた値がそのまま読める (SPI リンクの確認用)
//   0x7E ID          R  0x5A
//   0x7F VERSION     R  RTL の版
//
// vblank / frame_toggle / crc はピクセルクロック側の信号なので、ここで同期化する。
module vdp_regs #(
    parameter logic [7:0] VERSION = 8'h01
) (
    input  logic       clk,
    input  logic       rst,
    input  logic [6:0] addr,
    input  logic [7:0] wdata,
    input  logic       we,
    input  logic       re,             // addr の値を読み出したとき 1 クロック
    output logic [7:0] rdata,
    input  logic       vblank_async,   // VBLANK 中 (ピクセルクロック側)
    input  logic       frame_toggle_async,  // フレームごとにトグル (ピクセルクロック側)
    input  logic [31:0] crc_async,     // フレームの CRC (ピクセルクロック側、crc_toggle が変わるまで変化しない)
    input  logic [15:0] crc_frame_async,   // その CRC のフレーム番号 (同上)
    input  logic       crc_toggle_async,
    input  logic [31:0] held_crc_async,    // 印を付けたフレームの CRC (ピクセルクロック側、mark_count と一緒に変わる)
    input  logic [7:0] mark_count_async,
    input  logic       error_event,    // エラーを 1 クロック (このクロック側)
    input  logic [7:0] underflow_count,
    output logic [7:0] control,
    output logic       irq,
    output logic       error,
    output logic       reconfig_req    // RECONFIG に 0xA5 を書いたとき 1 クロック
);
    localparam logic [6:0] A_STATUS      = 7'h00;
    localparam logic [6:0] A_CONTROL     = 7'h01;
    localparam logic [6:0] A_FRAME_COUNT = 7'h04;
    localparam logic [6:0] A_FRAME_CRC   = 7'h05;   // 0x05..0x08
    localparam logic [6:0] A_RECONFIG    = 7'h7C;
    localparam logic [6:0] A_SCRATCH     = 7'h7D;
    localparam logic [6:0] A_ID          = 7'h7E;
    localparam logic [6:0] A_VERSION     = 7'h7F;
    localparam logic [7:0] ID            = 8'h5A;

    // --- ピクセルクロック側からの同期化 ---
    logic [1:0] vblank_s;
    logic [2:0] frame_s, crc_s, mark_s;
    always_ff @(posedge clk) begin
        vblank_s <= {vblank_s[0], vblank_async};
        frame_s  <= {frame_s[1:0], frame_toggle_async};
        crc_s    <= {crc_s[1:0], crc_toggle_async};
        mark_s   <= {mark_s[1:0], mark_count_async[0]};
    end

    // 印の CRC: mark_count の最下位ビットが変わったら (= 更新されたら)、CRC と回数を取り込む
    logic [31:0] mark_crc;
    logic [7:0]  mark_count;
    always_ff @(posedge clk) begin
        if (rst) begin
            mark_count <= '0;
        end else if (mark_s[2] != mark_s[1]) begin
            mark_crc   <= held_crc_async;
            mark_count <= mark_count_async;
        end
    end

    // crc_async はトグルより前に確定し、次のトグルまで変わらないので、トグルの変化を見てから取り込めばよい
    logic [31:0] crc;
    logic [15:0] crc_frame, crc_frame_snap;
    logic [31:8] crc_snap;     // 0x05 (下位バイト) はその場で返すので、残りの 3 バイトだけ取っておく
    // spi_slave は rdata (0x05) を取り込んだ次のクロックに re を出すので、1 クロック前の値 (_d) を取っておく
    // (re のクロックの値を取ると、そのクロックで crc が替わったとき下位だけ前のフレームになる)
    logic [31:8] crc_d;
    logic [15:0] crc_frame_d;
    always_ff @(posedge clk) begin
        if (crc_s[2] != crc_s[1]) begin
            crc       <= crc_async;
            crc_frame <= crc_frame_async;
        end
        crc_d       <= crc[31:8];
        crc_frame_d <= crc_frame;
        if (re && addr == A_FRAME_CRC) begin
            crc_snap       <= crc_d;
            crc_frame_snap <= crc_frame_d;
        end
    end
    logic vblank;
    assign vblank = vblank_s[1];

    logic [7:0] scratch, frame_count;

    assign reconfig_req = we && addr == A_RECONFIG && wdata == 8'hA5;

    always_ff @(posedge clk) begin
        if (rst) begin
            control     <= '0;
            scratch     <= '0;
            frame_count <= '0;
            error       <= 1'b0;
        end else begin
            if (frame_s[2] != frame_s[1]) frame_count <= frame_count + 8'd1;

            if (error_event)                   error <= 1'b1;
            else if (re && addr == A_STATUS)   error <= 1'b0;

            if (we) begin
                unique case (addr)
                    A_CONTROL: control <= wdata;
                    A_SCRATCH: scratch <= wdata;
                    default:   ;
                endcase
            end
        end
    end

    always_comb begin
        unique case (addr)
            A_STATUS:      rdata = {6'b0, error, vblank};
            A_CONTROL:     rdata = control;
            A_FRAME_COUNT: rdata = frame_count;
            A_FRAME_CRC:   rdata = crc[7:0];
            7'h06:         rdata = crc_snap[15:8];
            7'h07:         rdata = crc_snap[23:16];
            7'h08:         rdata = crc_snap[31:24];
            7'h09:         rdata = underflow_count;
            7'h02:         rdata = mark_count;
            7'h0C:         rdata = mark_crc[7:0];
            7'h0D:         rdata = mark_crc[15:8];
            7'h0E:         rdata = mark_crc[23:16];
            7'h0F:         rdata = mark_crc[31:24];
            7'h0A:         rdata = crc_frame_snap[7:0];
            7'h0B:         rdata = crc_frame_snap[15:8];
            A_SCRATCH:     rdata = scratch;
            A_ID:          rdata = ID;
            A_VERSION:     rdata = VERSION;
            default:       rdata = 8'h00;
        endcase
    end

    assign irq = control[2] && vblank;
endmodule
