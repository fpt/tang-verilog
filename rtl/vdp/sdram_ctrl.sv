// SDR SDRAM コントローラ (GW2AR-18 のパッケージ内 64Mbit: 2M ワード x 32bit、4 バンク x 2048 行 x 256 列)
//
// まずは動かすことを優先した最小構成 (docs/GPU_PLAN.md の M3):
//   - 1 ワードずつ: ACTIVE -> READ/WRITE (オートプリチャージ付き) -> 待ち。バーストは後で
//   - CAS レイテンシ 2、バースト長 1
//   - SDRAM のクロックはこのモジュールのクロックの逆相 (180°) を想定。トップが ODDR で出す
//   - 読み出しデータを取り込む位置は rd_sample (半周期単位) で実行時に変えられる。
//     READ を出したクロックの立ち上がりを 0 として、偶数 h は立ち上がり h/2、奇数 h は立ち下がり (h-1)/2 で取り込む。
//     180° の SDRAM クロックで CL2 なら、データは立ち下がり 1 の tAC 後から立ち下がり 2 の tOH 後まで有効。
//     実機 (Tang Nano 20K, 63MHz) では往復の遅れでこれより遅く、h = 5..7 で 8MiB 全域の BIST に合格、4 以下は不合格だった
//     (harness.py memtest)。7 は SDRAM が出し終えたあとなので、バスが浮いたまま値を保っているだけと考えられる。
//     既定は真ん中の 6 (mem_test の MEM_CFG)
//
// ワードアドレスの割り当て: addr[7:0] = 列, addr[9:8] = バンク, addr[20:10] = 行
// (1 ライン 256 ワードを 1 行に置くと、隣のラインは別のバンクになる)
module sdram_ctrl #(
    parameter int CLK_HZ     = 63_000_000,
    parameter int INIT_US    = 200,      // 電源投入後の待ち
    parameter int REFRESH_NS = 7800      // オートリフレッシュの間隔 (64ms / 8192)
) (
    input  logic        clk,
    input  logic        rst,
    // 利用側: req を ack まで保持する。読み出しは ack と同時に rdata が有効
    input  logic        req,
    input  logic        we,
    input  logic [20:0] addr,
    input  logic [31:0] wdata,
    output logic        ack,
    output logic [31:0] rdata,
    output logic        init_done,
    input  logic [2:0]  rd_sample,      // 読み出しの取り込み位置 (半周期単位、2..7)
    // SDRAM のピン (クロックはトップが出す)
    output logic        sdram_cke,
    output logic        sdram_cs_n,
    output logic        sdram_ras_n,
    output logic        sdram_cas_n,
    output logic        sdram_we_n,
    output logic [1:0]  sdram_ba,
    output logic [10:0] sdram_addr,
    output logic [3:0]  sdram_dqm,
    output logic [31:0] sdram_dq_out,
    output logic        sdram_dq_oe,
    input  logic [31:0] sdram_dq_in
);
    localparam int T_RP  = 2;   // PRECHARGE -> 次のコマンド (18ns 以上)
    localparam int T_RCD = 2;   // ACTIVE -> READ/WRITE (18ns 以上)
    localparam int T_RFC = 6;   // REFRESH -> 次のコマンド (60ns 以上)
    localparam int T_MRD = 2;
    localparam int T_WR  = 2;   // 書き込み -> オートプリチャージ開始
    localparam int INIT_CYCLES   = CLK_HZ / 1_000_000 * INIT_US;
    localparam int REFRESH_CYCLES = CLK_HZ / 1_000_000 * REFRESH_NS / 1000;
    // A10 予約, A9 = 0: バースト書き込み, A8:A7 = 00, A6:A4 = 010: CL2, A3 = 0: シーケンシャル, A2:A0 = 000: BL1
    localparam logic [10:0] MODE = 11'b0_0_00_010_0_000;

    // {cs_n, ras_n, cas_n, we_n}
    localparam logic [3:0] CMD_NOP   = 4'b0111;
    localparam logic [3:0] CMD_ACT   = 4'b0011;
    localparam logic [3:0] CMD_READ  = 4'b0101;
    localparam logic [3:0] CMD_WRITE = 4'b0100;
    localparam logic [3:0] CMD_PRE   = 4'b0010;
    localparam logic [3:0] CMD_REF   = 4'b0001;
    localparam logic [3:0] CMD_MRS   = 4'b0000;

    typedef enum logic [3:0] {
        S_INIT_WAIT, S_INIT_PRE, S_INIT_REF, S_INIT_MRS,
        S_IDLE, S_REF, S_ACT, S_RW, S_READ_WAIT, S_WAIT
    } state_t;
    state_t state;

    logic [3:0]  cmd;
    logic [15:0] timer;          // 汎用の待ちカウンタ
    logic [3:0]  ref_count;      // 初期化中のリフレッシュ回数
    logic [15:0] ref_timer;
    logic        ref_due;
    logic [2:0]  rd_cnt;

    assign {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} = cmd;
    assign sdram_cke = 1'b1;

    // 読み出しデータは両エッジで取り込んでおき、rd_sample で選ぶ
    logic [31:0] dq_pos, dq_neg;
    always_ff @(posedge clk) dq_pos <= sdram_dq_in;
    always_ff @(negedge clk) dq_neg <= sdram_dq_in;

    // リフレッシュの要求
    always_ff @(posedge clk) begin
        if (rst || !init_done) begin
            ref_timer <= '0;
            ref_due   <= 1'b0;
        end else begin
            if (ref_timer == 16'(REFRESH_CYCLES - 1)) begin
                ref_timer <= '0;
                ref_due   <= 1'b1;
            end else begin
                ref_timer <= ref_timer + 16'd1;
            end
            if (state == S_IDLE && ref_due) ref_due <= 1'b0;   // S_REF へ進むときに下ろす
        end
    end

    always_ff @(posedge clk) begin
        cmd         <= CMD_NOP;
        sdram_dq_oe <= 1'b0;
        ack         <= 1'b0;
        if (timer != 0) timer <= timer - 16'd1;

        if (rst) begin
            state      <= S_INIT_WAIT;
            timer      <= 16'(INIT_CYCLES);
            init_done  <= 1'b0;
            sdram_dqm  <= 4'hF;
            sdram_ba   <= '0;
            sdram_addr <= '0;
            ref_count  <= '0;
        end else begin
            unique case (state)
                // --- 初期化: 待ち -> PRECHARGE ALL -> REFRESH x8 -> MODE REGISTER SET ---
                S_INIT_WAIT: if (timer == 0) begin
                    cmd            <= CMD_PRE;
                    sdram_addr[10] <= 1'b1;            // 全バンク
                    timer          <= 16'(T_RP);
                    state          <= S_INIT_PRE;
                end
                S_INIT_PRE: if (timer == 0) begin
                    cmd       <= CMD_REF;
                    timer     <= 16'(T_RFC);
                    ref_count <= 4'd1;
                    state     <= S_INIT_REF;
                end
                S_INIT_REF: if (timer == 0) begin
                    if (ref_count == 4'd8) begin
                        cmd        <= CMD_MRS;
                        sdram_ba   <= 2'b00;
                        sdram_addr <= MODE;
                        timer      <= 16'(T_MRD);
                        state      <= S_INIT_MRS;
                    end else begin
                        cmd       <= CMD_REF;
                        timer     <= 16'(T_RFC);
                        ref_count <= ref_count + 4'd1;
                    end
                end
                S_INIT_MRS: if (timer == 0) begin
                    sdram_dqm <= 4'h0;
                    init_done <= 1'b1;
                    state     <= S_IDLE;
                end

                // --- 通常動作 (全バンクは常にプリチャージ済み) ---
                S_IDLE: begin
                    if (ref_due) begin
                        cmd   <= CMD_REF;
                        timer <= 16'(T_RFC);
                        state <= S_REF;
                    end else if (req) begin
                        cmd        <= CMD_ACT;
                        sdram_ba   <= addr[9:8];
                        sdram_addr <= addr[20:10];
                        timer      <= 16'(T_RCD - 1);
                        state      <= S_ACT;
                    end
                end
                S_REF: if (timer == 0) state <= S_IDLE;
                S_ACT: if (timer == 0) begin
                    sdram_addr <= {1'b1, 2'b00, addr[7:0]};  // A10 = 1: オートプリチャージ
                    if (we) begin
                        cmd          <= CMD_WRITE;
                        sdram_dq_out <= wdata;
                        sdram_dq_oe  <= 1'b1;
                        timer        <= 16'(T_WR + T_RP);
                        ack          <= 1'b1;
                        state        <= S_WAIT;
                    end else begin
                        cmd    <= CMD_READ;
                        rd_cnt <= '0;
                        state  <= S_READ_WAIT;
                    end
                end
                // READ を出した立ち上がりを 0 として、立ち上がり floor(h/2)+1 で取り込んだ値を読む
                S_READ_WAIT: begin
                    rd_cnt <= rd_cnt + 3'd1;
                    if (rd_cnt == 3'(rd_sample[2:1])) begin
                        rdata <= rd_sample[0] ? dq_neg : dq_pos;
                        ack   <= 1'b1;
                        timer <= 16'(T_RP);
                        state <= S_WAIT;
                    end
                end
                S_WAIT: if (timer == 0) state <= S_IDLE;
                default: state <= S_INIT_WAIT;
            endcase
        end
    end
endmodule
