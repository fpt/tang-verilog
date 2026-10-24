// 音の出力 (docs/KESSEL_ON_VDP.md の K5a)。SDRAM の PCM のリングを読み、I2S で出す (Tang Nano 20K の MAX98357A)
//
//   標本化: 48kHz、ステレオ 16bit (2 の補数)。BCLK = 32 fs = 1.536MHz (1 フレーム 32 ビット、左 16 + 右 16)。
//           clk (63MHz) から、累算器 (CLK_DIV_N / CLK_DIV_D ずつ足す) で BCLK の半周期を作る。63MHz x 128 / 2625 = 3.072MHz の半周期で、
//           clk_pix (25.2MHz) と同じ PLL から作った clk なので、映像の 1 フレーム (60Hz) にちょうど 800 標本 (ずれていかない)
//   I2S:    データは BCLK の立ち下がりで変え、立ち上がりで DAC が拾う。MSB が先。WS は 0 が左で、データの MSB の 1 ビット前に変わる (標準の I2S)
//   リング: SDRAM のワードアドレス {base, 8'b0} から 1 << size_log2 ワード。1 ワード = 1 標本 {右 [31:16], 左 [15:0]}。
//           rd (再生した標本の数) と wr (ホストが書いた標本の数) は 16bit で数え、リングの中の位置はその下位ビット。rd != wr ならデータがある
//   動き方: 次の標本を 1 つ先読みしておく (nxt)。1 フレームの始め (ビット 0 の立ち下がり) に nxt を出す標本にし、rd を 1 進める。
//           nxt がなければ無音 (0) を出し、underrun を 1 増やす (有効のあいだだけ。飽和する)。nxt が空で rd != wr なら SDRAM を 1 ワード読む
//   有効 (enable): 0 のあいだは無音を出し、rd を進めず、pa_en (アンプの有効) を 0 にする。clear で rd・underrun・先読みを空に戻す
//   レジスタ (読み出しだけ、0x50..0x5F の窓の中の番号): 0 PCM_RD 下位 (読むと上位を取っておく)、1 PCM_RD 上位、2 UNDERRUN
module audio_out #(
    parameter int CLK_DIV_N = 128,      // BCLK の半周期 = clk x CLK_DIV_D / CLK_DIV_N
    parameter int CLK_DIV_D = 2625
) (
    input  logic        clk,
    input  logic        rst,
    // 設定 (GPU の REG_WRITE)
    input  logic        enable,
    input  logic        clear,          // 1 クロック
    input  logic [12:0] base,           // 256 ワード単位
    input  logic [3:0]  size_log2,
    input  logic [15:0] wr,
    // レジスタの読み出し
    input  logic [3:0]  addr,
    input  logic        re,
    output logic [7:0]  rdata,
    // SDRAM (sdram_arb 経由、1 ワードの読み出し)
    output logic        mem_req,
    output logic [20:0] mem_addr,
    input  logic        mem_ack,
    input  logic        mem_rvalid,
    input  logic [31:0] mem_rdata,
    // I2S
    output logic        bck,
    output logic        ws,
    output logic        din,
    output logic        pa_en
);
    localparam int ACC_W = $clog2(CLK_DIV_D + CLK_DIV_N);

    logic [15:0] rd;
    logic [7:0]  underrun;
    logic [31:0] nxt, cur;
    logic        nxt_valid;
    logic        stale;         // 読んでいる途中に clear が来た (読んだワードは捨てる)
    logic [ACC_W-1:0] acc;
    logic [4:0]  bit_idx;       // 今出しているビット (0..15 左、16..31 右)
    logic [15:0] mask;
    logic        fall;          // このクロックで BCLK が立ち下がる

    assign mask  = (16'd1 << size_log2) - 16'd1;
    assign fall  = acc + ACC_W'(CLK_DIV_N) >= ACC_W'(CLK_DIV_D) && bck;
    assign pa_en = enable;

    always_ff @(posedge clk) begin
        if (rst) begin
            acc       <= '0;
            bck       <= 1'b0;
            ws        <= 1'b0;
            din       <= 1'b0;
            bit_idx   <= 5'd31;
            cur       <= '0;
            rd        <= '0;
            underrun  <= '0;
            nxt_valid <= 1'b0;
            mem_req   <= 1'b0;
            stale     <= 1'b0;
        end else begin
            // BCLK の半周期
            if (acc + ACC_W'(CLK_DIV_N) >= ACC_W'(CLK_DIV_D)) begin
                acc <= acc + ACC_W'(CLK_DIV_N) - ACC_W'(CLK_DIV_D);
                bck <= ~bck;
            end else begin
                acc <= acc + ACC_W'(CLK_DIV_N);
            end

            // 立ち下がりで次のビットを出す。ビット 0 (左の MSB) の立ち下がりで次の標本に替える
            if (fall) begin
                logic [4:0]  b;
                logic [31:0] s;
                b = bit_idx + 5'd1;
                s = cur;
                if (b == 5'd0) begin
                    s = '0;
                    if (enable) begin
                        if (nxt_valid) begin
                            s         = nxt;
                            nxt_valid <= 1'b0;
                            rd        <= rd + 16'd1;
                        end else if (underrun != 8'hFF) begin
                            underrun <= underrun + 8'd1;
                        end
                    end
                    cur <= s;
                end
                bit_idx <= b;
                din     <= b[4] ? s[31 - 32'(b[3:0])] : s[15 - 32'(b[3:0])];
                ws      <= (b + 5'd1) >= 5'd16;           // 次のビットの声道 (1 ビット前に変わる)
            end

            // 先読み: 空いていてデータがあれば 1 ワード読む
            if (!mem_req) begin
                if (enable && !nxt_valid && rd != wr && !clear) begin
                    mem_req  <= 1'b1;
                    mem_addr <= {base, 8'b0} + 21'(rd & mask);
                end
            end else begin
                if (mem_rvalid) nxt <= mem_rdata;
                if (mem_ack) begin
                    mem_req   <= 1'b0;
                    nxt_valid <= !stale;
                    stale     <= 1'b0;
                end
            end

            if (clear) begin
                rd        <= '0;
                underrun  <= '0;
                nxt_valid <= 1'b0;
                if (mem_req && !mem_ack) stale <= 1'b1;
            end
        end
    end

    // PCM_RD は下位を読んだときの値の上位を取っておく (2 バイトが同じ時点の値になる)。spi_slave は rdata を取り込んだ次のクロックに re を出すので、
    // 1 クロック前の rd の上位 (rd_hi_d) を取る (re のクロックの rd を取ると、その 1 クロックで下位から繰り上がったときに 256 ずれる)
    logic [7:0]  rd_hi_d;
    logic [7:0]  rd_hi_held;
    always_ff @(posedge clk) begin
        rd_hi_d <= rd[15:8];
        if (re && addr == 4'd0) rd_hi_held <= rd_hi_d;
    end
    always_comb begin
        unique case (addr)
            4'd0:    rdata = rd[7:0];
            4'd1:    rdata = rd_hi_held;
            4'd2:    rdata = underrun;
            default: rdata = 8'h00;
        endcase
    end
endmodule
