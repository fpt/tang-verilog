// フレームバッファの表示 (docs/GPU_PLAN.md の M4)
//   SDRAM の SRC_W x SRC_H (RGB565) を縦横 2 倍にして出す。
//
//   メモリ配置: ソースのライン y はワードアドレス (fb_base + y) * 256 から SRC_W / 2 ワード。
//               1 ワードに 2 ピクセル (下位 16bit が偶数の x、上位が奇数の x)。RGB565 = {R5, G6, B5}
//   動き方:     ソースのライン n を表示しているあいだ (出力 2 ライン分) に、ライン n+1 を SDRAM からバーストで読み、
//               2 ライン分のライン バッファ (BSRAM) の空いているほうに書く。ライン 0 は最後のブランキング ラインで頼む。
//               表示が始まるときに読み込みが終わっていなかったら underflow_count を 1 増やす。
//   fb_base:    ライン 0 を読み始めるときにだけ取り込み、そのフレームの間は変えない (途中で変えても上下で面が混ざらない)。
//               取り込んだクロックで base_latched を 1 クロック出す (GPU の SWAP が「表示に反映された」を知るため)。
//
//   クロック: ピクセル側 (clk_pix) が「次のライン」をトグルで頼み、システム側 (clk_sys) が SDRAM から読む。
//            頼むライン番号はトグルの前に確定し、次に頼むまで (出力 2 ライン以上) 変わらない。
module fb_scanout #(
    parameter int SRC_W   = 320,
    parameter int SRC_H   = 240,
    parameter int V_TOTAL = 525
) (
    // --- システムクロック側 ---
    input  logic        clk_sys,
    input  logic        rst_sys,
    input  logic [12:0] fb_base,          // 256 ワード単位。ライン 0 を読み始めるときに取り込む
    output logic        base_latched,     // fb_base を取り込んだとき 1 クロック
    output logic        mem_req,
    output logic [20:0] mem_addr,
    output logic [8:0]  mem_len,
    input  logic        mem_ack,
    input  logic        mem_rvalid,
    input  logic [31:0] mem_rdata,
    output logic [7:0]  underflow_count,  // 飽和する
    // --- ピクセルクロック側 ---
    input  logic        clk_pix,
    input  logic        rst_pix,
    input  logic        enable,           // clk_pix に同期済み
    input  logic [10:0] x,                // 表示タイミング (video_timing の x, y)
    input  logic [9:0]  y,
    output logic [23:0] rgb               // x, y の 1 クロック後に有効
);
    localparam int WORDS = SRC_W / 2;

    // --- ライン バッファ (2 ライン x 256 ワード)。書き込みは clk_sys、読み出しは clk_pix ---
    logic [31:0] line_buf [0:511];

    // ================================================================ ピクセル側
    logic [8:0]  req_line;
    logic        req_toggle;
    logic        need;
    logic [8:0]  next_line;

    always_comb begin
        need      = 1'b0;
        next_line = '0;
        if (y == 10'(V_TOTAL - 1)) begin
            need = 1'b1;                                   // 最後のブランキング ライン: ライン 0
        end else if (y < 10'(2 * SRC_H - 2) && !y[0]) begin
            need      = 1'b1;                              // ライン n の 1 本目: ライン n+1
            next_line = 9'(y >> 1) + 9'd1;
        end
    end

    always_ff @(posedge clk_pix) begin
        if (rst_pix) begin
            req_toggle <= 1'b0;
            req_line   <= '0;
        end else if (enable && x == 11'd0 && need) begin
            req_line   <= next_line;
            req_toggle <= ~req_toggle;
        end
    end

    logic [31:0] word;
    logic        upper;
    always_ff @(posedge clk_pix) begin
        word  <= line_buf[{y[1], x[9:2]}];   // ソースのライン y>>1 の偶奇でバッファを選ぶ
        upper <= x[1];
    end

    logic [15:0] p;
    assign p   = upper ? word[31:16] : word[15:0];
    assign rgb = {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};

    // ================================================================ システム側
    logic [2:0]  req_s;
    logic        busy, pending;
    logic        line_bank;      // 読んでいるラインを書くバッファ (ライン番号の偶奇)
    logic [12:0] frame_base;     // このフレームで使う fb_base
    logic [7:0]  widx;

    always_ff @(posedge clk_sys) req_s <= {req_s[1:0], req_toggle};

    // BSRAM にするため、書き込みはリセットのない別のブロックで
    always_ff @(posedge clk_sys) if (mem_rvalid) line_buf[{line_bank, widx}] <= mem_rdata;

    assign mem_len = 9'(WORDS);

    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            busy            <= 1'b0;
            pending         <= 1'b0;
            mem_req         <= 1'b0;
            underflow_count <= '0;
            frame_base      <= '0;
            base_latched    <= 1'b0;
        end else begin
            base_latched <= 1'b0;
            // 新しい依頼が来たときにまだ読んでいたら、表示に間に合っていない
            if (req_s[2] != req_s[1]) begin
                if (busy && underflow_count != 8'hFF) underflow_count <= underflow_count + 8'd1;
                pending <= 1'b1;
            end

            if (!busy && (pending || req_s[2] != req_s[1])) begin
                pending  <= 1'b0;
                busy     <= 1'b1;
                line_bank <= req_line[0];
                mem_req  <= 1'b1;
                if (req_line == 9'd0) begin
                    frame_base   <= fb_base;
                    base_latched <= 1'b1;
                    mem_addr     <= {fb_base, 8'b0};
                end else begin
                    mem_addr <= {frame_base + 13'(req_line), 8'b0};
                end
                widx     <= '0;
            end

            if (mem_rvalid) widx <= widx + 8'd1;
            if (mem_ack) begin
                mem_req <= 1'b0;
                busy    <= 1'b0;
            end
        end
    end
endmodule
