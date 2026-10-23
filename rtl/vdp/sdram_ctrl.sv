// SDR SDRAM コントローラ (GW2AR-18 のパッケージ内 64Mbit: 2M ワード x 32bit、4 バンク x 2048 行 x 256 列)
//
// 最小構成 (docs/GPU_PLAN.md の M3、M4 で読み出しのバースト、M5 で書き込みのバーストを追加):
//   - 書き込みは同じ行の中で len ワード: ACTIVE -> WRITE を毎クロック (最後だけオートプリチャージ付き) -> 待ち。
//     ワードごとに wmask (1 = そのバイトを書く) を DQM に出すので、ピクセル単位で書き飛ばせる
//   - 読み出しは同じ行の中で len ワード: ACTIVE -> READ を毎クロック (最後だけオートプリチャージ付き) -> データを待つ
//   - CAS レイテンシ 2、バースト長 1
//   - SDRAM のクロックはこのモジュールのクロックの逆相 (180°) を想定。トップが ODDR で出す
//   - 読み出しデータを取り込む位置は rd_sample (半周期単位) で実行時に変えられる。
//     読み出しの途中で変わると受け取ったワードの数がずれて ack が出なくなるので、待機中 (S_IDLE) にだけ取り込む。
//     READ を出したクロックの立ち上がりを 0 として、偶数 h は立ち上がり h/2、奇数 h は立ち下がり (h-1)/2 で取り込む。
//     180° の SDRAM クロックで CL2 なら、データは立ち下がり 1 の tAC 後から立ち下がり 2 の tOH 後まで有効。
//     実機 (Tang Nano 20K, 63MHz) では往復の遅れでこれより遅く、バースト読み出しで正しく読めるのは h = 5 だけ
//     (4 と 6 はフレームごとに値が揺れ、7 はいつも次のワードを読む)。1 ワードずつの読み出しなら 5..7 で読めるが、
//     6, 7 は SDRAM が出し終えたあとも浮いたバスが値を保っているだけ。既定は 5 (mem_test の MEM_CFG)
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
    // 利用側: req と we / addr / len を ack まで保持する。
    // 書き込みは wnext が 1 のクロックの立ち上がりで wdata / wmask を 1 ワード使うので、利用側は同じ立ち上がりで次のワードに進める。
    // 最後のワードを使ったところで ack。
    // 読み出しは 1 ワードごとに rvalid と rdata が出て、最後のワードのあとに ack。ack のときの rdata は最後のワード
    input  logic        req,
    input  logic        we,
    input  logic [20:0] addr,
    input  logic [31:0] wdata,
    input  logic [3:0]  wmask,          // 書くバイト (1 = 書く)。DQM はこの反転
    input  logic [8:0]  len,            // ワード数 (1..256)。addr[7:0] + len が 256 を超えないこと (行をまたがない)
    output logic        wnext,          // この立ち上がりで wdata / wmask を使う (組み合わせ回路)
    output logic        ack,
    output logic        rvalid,
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
        S_IDLE, S_REF, S_ACT, S_WRITE, S_READ, S_READ_DRAIN, S_WAIT
    } state_t;
    state_t state;

    logic [3:0]  cmd;
    logic [15:0] timer;          // 汎用の待ちカウンタ
    logic [3:0]  ref_count;      // 初期化中のリフレッシュ回数
    logic [15:0] ref_timer;
    logic        ref_due;
    logic [7:0]  col;            // 次に READ する列
    logic [8:0]  issued, received;
    logic [3:0]  rd_pipe;        // READ を出してからの経過 (rs[2:1] 番目で取り込む)
    logic [2:0]  rs;             // 使っている取り込み位置 (rd_sample を S_IDLE で取り込んだもの)
    logic        rd_push;

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

    // READ を出したら rd_pipe に 1 を入れる。READ を出した立ち上がりを 0 として、立ち上がり floor(h/2)+1 で
    // rd_pipe[floor(h/2)] が 1 になっているので、そこで取り込んだ値 (dq_pos か dq_neg) を読む
    assign rd_push = (state == S_ACT && timer == 0 && !we) || state == S_READ;
    assign wnext   = (state == S_ACT && timer == 0 && we) || state == S_WRITE;

    always_ff @(posedge clk) begin
        cmd         <= CMD_NOP;
        sdram_dq_oe <= 1'b0;
        ack         <= 1'b0;
        rvalid      <= 1'b0;
        if (init_done) sdram_dqm <= 4'h0;     // 書き込みのクロック以外はマスクしない
        if (timer != 0) timer <= timer - 16'd1;

        rd_pipe <= rst ? '0 : {rd_pipe[2:0], rd_push && !rst};
        if (rst || state == S_IDLE) rs <= rd_sample;
        if (!rst && rd_pipe[rs[2:1]]) begin
            rdata    <= rs[0] ? dq_neg : dq_pos;
            rvalid   <= 1'b1;
            received <= received + 9'd1;
        end

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
                    if (we) begin
                        // 最後の WRITE だけ A10 = 1 (オートプリチャージ)
                        cmd          <= CMD_WRITE;
                        sdram_addr   <= {len == 9'd1, 2'b00, addr[7:0]};
                        sdram_dq_out <= wdata;
                        sdram_dq_oe  <= 1'b1;
                        sdram_dqm    <= ~wmask;
                        col          <= addr[7:0] + 8'd1;
                        issued       <= 9'd1;
                        if (len == 9'd1) begin
                            timer <= 16'(T_WR + T_RP);
                            ack   <= 1'b1;
                            state <= S_WAIT;
                        end else begin
                            state <= S_WRITE;
                        end
                    end else begin
                        // 最後の READ だけ A10 = 1 (オートプリチャージ)
                        cmd        <= CMD_READ;
                        sdram_addr <= {len == 9'd1, 2'b00, addr[7:0]};
                        col        <= addr[7:0] + 8'd1;
                        issued     <= 9'd1;
                        received   <= '0;
                        if (len == 9'd1) state <= S_READ_DRAIN;
                        else             state <= S_READ;
                    end
                end
                S_WRITE: begin
                    cmd          <= CMD_WRITE;
                    sdram_addr   <= {issued == len - 9'd1, 2'b00, col};
                    sdram_dq_out <= wdata;
                    sdram_dq_oe  <= 1'b1;
                    sdram_dqm    <= ~wmask;
                    col          <= col + 8'd1;
                    issued       <= issued + 9'd1;
                    if (issued == len - 9'd1) begin
                        timer <= 16'(T_WR + T_RP);
                        ack   <= 1'b1;
                        state <= S_WAIT;
                    end
                end
                S_READ: begin
                    cmd        <= CMD_READ;
                    sdram_addr <= {issued == len - 9'd1, 2'b00, col};
                    col        <= col + 8'd1;
                    issued     <= issued + 9'd1;
                    if (issued == len - 9'd1) state <= S_READ_DRAIN;
                end
                S_READ_DRAIN: if (received == len) begin
                    ack   <= 1'b1;
                    timer <= 16'(T_RP);
                    state <= S_WAIT;
                end
                S_WAIT: if (timer == 0) state <= S_IDLE;
                default: state <= S_INIT_WAIT;
            endcase
        end
    end
endmodule
