// ラインごとの合成 (docs/EMU_GPU_PLAN.md の E1。M4 の fb_scanout を置き換えた)
//   論理画面 SRC_W x SRC_H を、ライン単位で合成して縦横 2 倍で出す。
//
//   合成: ラインを始めるときにレイヤのレジスタ (背景色・レイヤの有効・ビットマップの透過色) を取り込み、
//         - ビットマップ レイヤが有効なら、SDRAM のフレームバッファの行をバーストで読み、透過色のピクセル (透過色が有効なとき) を背景色に
//           置き換えて書く
//         - 無効なら背景色で埋める
//         タイル レイヤやスプライトは、このあと (E2, E3) で合成のパスを足していく。
//   レジスタはラインの合成を始めるときに取り込むので、GPU の WAIT_LINE n のあとの REG_WRITE はライン n から効く。
//   そのために、合成を始めるたびに line_start とライン番号 line_num を出す。
//
//   ビットマップ: ソースのライン y はワードアドレス (fb_base + y) * 256 から SRC_W / 2 ワード。
//                 1 ワードに 2 ピクセル (下位 16bit が偶数の x)。RGB565 = {R5, G6, B5}
//   動き方:       ソースのライン n を表示しているあいだ (出力 2 ライン分) に、ライン n+1 を合成して 2 ライン分のライン バッファの
//                 空いているほうに書く。ライン 0 は最後のブランキング ラインで合成する。
//                 表示が始まるときに合成が終わっていなかったら underflow_count を 1 増やす。
//   fb_base:      ライン 0 を合成し始めるときにだけ取り込み、そのフレームの間は変えない。取り込んだクロックで base_latched を出す。
//   印:           mark_req を受けると、次にライン 0 から合成するフレームに印を付ける (mark_toggle を反転)。
//                 frame_crc がそのフレームの CRC を MARK_CRC に残す。ラインごとにレジスタを変えたフレームを比べるため。
//
//   クロック: ピクセル側 (clk_pix) が「次のライン」をトグルで頼み、システム側 (clk_sys) が合成する。
//            頼むライン番号はトグルの前に確定し、次に頼むまで (出力 2 ライン以上) 変わらない。
//            表示 (vdp_video の fb_en) にかかわらず、映像のタイミングが動いていれば合成し続ける (WAIT_LINE が止まらないように)。
module line_compositor #(
    parameter int SRC_W   = 320,
    parameter int SRC_H   = 240,
    parameter int V_TOTAL = 525
) (
    // --- システムクロック側 ---
    input  logic        clk_sys,
    input  logic        rst_sys,
    input  logic [12:0] fb_base,          // 256 ワード単位。ライン 0 を合成し始めるときに取り込む
    output logic        base_latched,     // fb_base を取り込んだとき 1 クロック
    input  logic [15:0] bg_color,         // 背景色 (RGB565)
    input  logic [1:0]  layer_ctrl,       // bit0: ビットマップ レイヤ有効, bit1: ビットマップの透過色を有効
    input  logic [15:0] bitmap_key,       // ビットマップの透過色
    input  logic        mark_req,         // 次のフレームに印を付ける (1 クロック)
    output logic        mark_toggle,      // 印を付けたフレームの合成を始めるたびに反転
    output logic        line_start,       // ラインの合成を始めたとき 1 クロック
    output logic [7:0]  line_num,         // 合成しているライン (line_start のあいだ有効、次まで保持)
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
        end else if (x == 11'd0 && need) begin
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
    logic        busy, pending, filling, mark_pending;
    logic        line_bank;      // 合成しているラインを書くバッファ (ライン番号の偶奇)
    logic [12:0] frame_base;     // このフレームで使う fb_base
    logic [7:0]  widx;
    // このラインのレジスタ (合成を始めるときに取り込む)
    logic [15:0] l_bg, l_key;
    logic        l_key_en;

    always_ff @(posedge clk_sys) req_s <= {req_s[1:0], req_toggle};

    // ビットマップのピクセルを、透過色なら背景色に置き換える
    function automatic logic [15:0] pick(input logic [15:0] px, input logic [15:0] bg, input logic [15:0] key,
                                         input logic key_en);
        return (key_en && px == key) ? bg : px;
    endfunction

    // BSRAM にするため、書き込みはリセットのない別のブロックで
    logic        wr_en;
    logic [31:0] wr_data;
    assign wr_en   = filling || (busy && mem_rvalid);
    assign wr_data = filling ? {l_bg, l_bg}
                             : {pick(mem_rdata[31:16], l_bg, l_key, l_key_en), pick(mem_rdata[15:0], l_bg, l_key, l_key_en)};
    always_ff @(posedge clk_sys) if (wr_en) line_buf[{line_bank, widx}] <= wr_data;

    assign mem_len = 9'(WORDS);

    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            busy            <= 1'b0;
            pending         <= 1'b0;
            filling         <= 1'b0;
            mem_req         <= 1'b0;
            underflow_count <= '0;
            frame_base      <= '0;
            base_latched    <= 1'b0;
            line_start      <= 1'b0;
            line_num        <= '0;
            mark_pending    <= 1'b0;
            mark_toggle     <= 1'b0;
        end else begin
            base_latched <= 1'b0;
            line_start   <= 1'b0;
            if (mark_req) mark_pending <= 1'b1;

            // 新しい依頼が来たときにまだ合成していたら、表示に間に合っていない
            if (req_s[2] != req_s[1]) begin
                if (busy && underflow_count != 8'hFF) underflow_count <= underflow_count + 8'd1;
                pending <= 1'b1;
            end

            if (!busy && (pending || req_s[2] != req_s[1])) begin
                pending    <= 1'b0;
                busy       <= 1'b1;
                line_bank  <= req_line[0];
                line_start <= 1'b1;
                line_num   <= 8'(req_line);
                l_bg       <= bg_color;
                l_key      <= bitmap_key;
                l_key_en   <= layer_ctrl[1];
                widx       <= '0;
                if (req_line == 9'd0) begin
                    frame_base   <= fb_base;
                    base_latched <= 1'b1;
                    if (mark_pending || mark_req) begin
                        mark_toggle  <= ~mark_toggle;
                        mark_pending <= 1'b0;
                    end
                end
                if (layer_ctrl[0]) begin
                    mem_req  <= 1'b1;
                    mem_addr <= (req_line == 9'd0) ? {fb_base, 8'b0} : {frame_base + 13'(req_line), 8'b0};
                end else begin
                    filling <= 1'b1;
                end
            end

            // 背景色で埋める (ビットマップ レイヤが無効のとき)
            if (filling) begin
                widx <= widx + 8'd1;
                if (widx == 8'(WORDS - 1)) begin
                    filling <= 1'b0;
                    busy    <= 1'b0;
                end
            end

            if (mem_rvalid) widx <= widx + 8'd1;
            if (mem_ack) begin
                mem_req <= 1'b0;
                busy    <= 1'b0;
            end
        end
    end
endmodule
