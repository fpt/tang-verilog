// VDP のレジスタ (docs/GPU_PLAN.md の M1)。レジスタバスと同じシステムクロックで動く
//
//   0x00 STATUS      R  bit0: VBLANK 中, bit1: エラー (SPI のフレームエラーなど。読むとクリア)
//   0x01 CONTROL     RW bit2: IRQ 許可 (IRQ = VBLANK 中)。bit0, bit1 は予約 (表示 ON, アニメーション停止)
//   0x04 FRAME_COUNT R  フレームカウンタの下位 8bit
//   0x7D SCRATCH     RW 書いた値がそのまま読める (SPI リンクの確認用)
//   0x7E ID          R  0x5A
//   0x7F VERSION     R  RTL の版
//
// vblank と frame_toggle はピクセルクロック側の信号なので、ここで同期化する。
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
    input  logic       error_event,    // エラーを 1 クロック (このクロック側)
    output logic [7:0] control,
    output logic       irq,
    output logic       error
);
    localparam logic [6:0] A_STATUS      = 7'h00;
    localparam logic [6:0] A_CONTROL     = 7'h01;
    localparam logic [6:0] A_FRAME_COUNT = 7'h04;
    localparam logic [6:0] A_SCRATCH     = 7'h7D;
    localparam logic [6:0] A_ID          = 7'h7E;
    localparam logic [6:0] A_VERSION     = 7'h7F;
    localparam logic [7:0] ID            = 8'h5A;

    // --- ピクセルクロック側からの同期化 ---
    logic [1:0] vblank_s;
    logic [2:0] frame_s;
    always_ff @(posedge clk) begin
        vblank_s <= {vblank_s[0], vblank_async};
        frame_s  <= {frame_s[1:0], frame_toggle_async};
    end
    logic vblank;
    assign vblank = vblank_s[1];

    logic [7:0] scratch, frame_count;

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
            A_SCRATCH:     rdata = scratch;
            A_ID:          rdata = ID;
            A_VERSION:     rdata = VERSION;
            default:       rdata = 8'h00;
        endcase
    end

    assign irq = control[2] && vblank;
endmodule
