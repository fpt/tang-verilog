// ラインごとの合成 (docs/EMU_GPU_PLAN.md の E1。M4 の fb_scanout を置き換えた)
//   論理画面 SRC_W x SRC_H を、ライン単位で合成して縦横 2 倍で出す。
//
//   合成: ラインを始めるときにレイヤのレジスタ (背景色・レイヤの有効・ビットマップの透過色と順位・タイル レイヤとスプライトの設定) を
//         取り込み、順位の付いた作業ライン (ピクセルごとに {順位, 色}) に、レイヤごとのパスで書く。
//         1. スプライト (有効なら): sprite_layer が OAM の順に出すピクセル。作業ラインがまだ空 (順位 0) のところだけ書くので、
//            スプライト同士は優先度ビットによらず OAM の前のものが勝つ (メガドラ・SNES と同じ)。順位は優先度ビットで RANK_S_LO / RANK_S_HI
//         2. タイル レイヤ (有効なら): tile_layer が出すピクセル。順位はタイルの優先度ビットで RANK_A_LO / RANK_A_HI
//         3. ビットマップ レイヤ (有効なら): SDRAM のフレームバッファの行をバーストで読む。順位は bitmap_rank (既定 1)。
//            透過色が有効なら、透過色のピクセルは書かない
//         4. 出力: 作業ラインをライン バッファに写し (順位 0 = どのレイヤも書かなかったところは背景色)、作業ラインを空に戻す
//         2 と 3 は「不透明で、順位が今の値より大きいピクセルだけ」書くので、パスの順番によらず順位の高いものが残る (同じ順位なら先のパス)。
//         順位 (3bit): 0 背景色、1 面 B (低)、2 面 A (低)、3 スプライト (低)、4 面 B (高)、5 面 A (高)、6 スプライト (高)。
//         今のタイル レイヤは面 A。面 B は E4 でパスを足す。
//   VRAM (16K ワード x 32bit) とパレット (512 x RGB565) はここに置き、読み出しのポートをスプライトとタイルのパスが順番に使う。
//   レジスタはラインの合成を始めるときに取り込むので、GPU の WAIT_LINE n のあとの REG_WRITE はライン n から効く。
//   そのために、合成を始めるたびに line_start とライン番号 line_num を出す。
//
//   ビットマップ: ソースのライン y はワードアドレス (fb_base + y) * 256 から SRC_W / 2 ワード。
//                 1 ワードに 2 ピクセル (下位 16bit が偶数の x)。RGB565 = {R5, G6, B5}
//   動き方:       ソースのライン n を表示しているあいだ (出力 2 ライン分) に、ライン n+1 を合成して 2 ライン分のライン バッファの
//                 空いているほうに書く。ライン 0 は最後から 2 本目のブランキング ラインで合成する (ほかのラインと同じく出力 2 ライン分の時間がある)。
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
    parameter int V_TOTAL = 525,
    parameter int VRAM_WORDS = 16384
) (
    // --- システムクロック側 ---
    input  logic        clk_sys,
    input  logic        rst_sys,
    input  logic [12:0] fb_base,          // 256 ワード単位。ライン 0 を合成し始めるときに取り込む
    output logic        base_latched,     // fb_base を取り込んだとき 1 クロック
    input  logic [15:0] bg_color,         // 背景色 (RGB565)
    input  logic [3:0]  layer_ctrl,       // bit0: ビットマップ レイヤ有効, bit1: ビットマップの透過色を有効, bit2: タイル レイヤ有効,
                                          // bit3: スプライト有効
    input  logic [15:0] bitmap_key,       // ビットマップの透過色
    input  logic [2:0]  bitmap_rank,      // ビットマップ レイヤの順位 (既定 1)
    input  logic [9:0]  tile_scroll_x,    // タイル レイヤ (tile_layer.sv)
    input  logic [9:0]  tile_scroll_y,
    input  logic [13:0] tile_map_base,
    input  logic [13:0] tile_pat_base,
    input  logic [6:0]  tile_ctrl,
    input  logic [13:0] spr_pat_base,     // スプライト (sprite_layer.sv)
    input  logic [2:0]  spr_bank,
    input  logic [6:0]  spr_line_cols,
    input  logic        vram_we,          // VRAM・パレット・OAM の書き込み (GPU)。OAM は vram_waddr[7:0] と vram_wdata を使う
    input  logic [13:0] vram_waddr,
    input  logic [31:0] vram_wdata,
    input  logic        pal_we,
    input  logic [8:0]  pal_waddr,
    input  logic [15:0] pal_wdata,
    input  logic        oam_we,
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
    localparam int VA_W  = $clog2(VRAM_WORDS);
    localparam logic [2:0] RANK_A_LO = 3'd2, RANK_A_HI = 3'd5, RANK_S_LO = 3'd3, RANK_S_HI = 3'd6;

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
        if (y == 10'(V_TOTAL - 2)) begin
            need = 1'b1;                                   // 最後から 2 本目のブランキング ライン: ライン 0
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
    // 作業ライン: ピクセルごとに {順位 3bit, 色 16bit}。偶数の x と奇数の x を別の BSRAM に置き、1 クロックに 2 ピクセル読み書きできる。
    // 書き込みは「不透明で、順位が今の値より大きいときだけ」。今の値は 1 クロック前に読んでおく (rd_addr を先に出す)
    logic [18:0] wl_even [0:255];
    logic [18:0] wl_odd  [0:255];
    logic [7:0]  wl_rd_addr;
    logic [18:0] wl_q_even, wl_q_odd;
    logic        wl_we_even, wl_we_odd;
    logic [7:0]  wl_wa_even, wl_wa_odd;
    logic [18:0] wl_wd_even, wl_wd_odd;

    always_ff @(posedge clk_sys) begin
        if (wl_we_even) wl_even[wl_wa_even] <= wl_wd_even;
        if (wl_we_odd)  wl_odd[wl_wa_odd]   <= wl_wd_odd;
        wl_q_even <= wl_even[wl_rd_addr];
        wl_q_odd  <= wl_odd[wl_rd_addr];
    end

    typedef enum logic [2:0] {P_IDLE, P_SPRITE, P_TILE, P_ISSUE, P_BITMAP, P_OUT_PRE, P_OUT} phase_t;
    phase_t phase;

    logic [2:0]  req_s;
    logic        busy, pending, mark_pending;
    logic        line_bank;      // 合成しているラインを書くバッファ (ライン番号の偶奇)
    logic [12:0] frame_base;     // このフレームで使う fb_base
    logic [7:0]  widx;           // ビットマップのパスで書くワード
    logic [7:0]  oidx;           // 出力のパスで書くワード
    // このラインのレジスタ (合成を始めるときに取り込む)
    logic [15:0] l_bg, l_key;
    logic        l_key_en, l_bm_en, l_tile_en;
    logic [2:0]  l_bm_rank;
    logic [9:0]  l_sx, l_sy;
    logic [13:0] l_map, l_pat;
    logic [6:0]  l_tctrl;
    logic [13:0] l_spat;
    logic [2:0]  l_sbank;
    logic [6:0]  l_scols;
    logic [20:0] l_addr;         // ビットマップの行のアドレス
    logic        t_start, t_busy;
    logic        t_valid, t_opaque, t_pri;
    logic [7:0]  t_next;
    logic [8:0]  t_x;
    logic [15:0] t_color;
    logic        s_start, s_busy;
    logic        s_valid, s_pri;
    logic [7:0]  s_next;
    logic [8:0]  s_x;
    logic [15:0] s_color;

    assign busy = phase != P_IDLE;

    // VRAM とパレット。読み出しはスプライトのパスのあいだ sprite_layer、それ以外は tile_layer
    logic [31:0] vram [0:VRAM_WORDS-1];
    logic [15:0] pal  [0:511];
    logic [13:0] vram_raddr, t_vram_raddr, s_vram_raddr;
    logic [8:0]  pal_raddr, t_pal_raddr, s_pal_raddr;
    logic [31:0] vram_q;
    logic [15:0] pal_q;
    assign vram_raddr = (phase == P_SPRITE) ? s_vram_raddr : t_vram_raddr;
    assign pal_raddr  = (phase == P_SPRITE) ? s_pal_raddr  : t_pal_raddr;

    always_ff @(posedge clk_sys) begin
        if (vram_we) vram[VA_W'(vram_waddr)] <= vram_wdata;
        vram_q <= vram[VA_W'(vram_raddr)];
    end
    always_ff @(posedge clk_sys) begin
        if (pal_we) pal[pal_waddr] <= pal_wdata;
        pal_q <= pal[pal_raddr];
    end

    sprite_layer #(.SRC_W(SRC_W)) u_sprite (
        .clk(clk_sys), .rst(rst_sys),
        .oam_we, .oam_waddr(vram_waddr[7:0]), .oam_wdata(vram_wdata),
        .vram_raddr(s_vram_raddr), .vram_q, .pal_raddr(s_pal_raddr), .pal_q,
        .start(s_start), .line(line_num), .pat_base(l_spat), .bank(l_sbank), .line_cols(l_scols), .busy(s_busy),
        .next_word(s_next), .px_valid(s_valid), .px_x(s_x), .px_pri(s_pri), .px_color(s_color)
    );

    tile_layer #(.SRC_W(SRC_W)) u_tile (
        .clk(clk_sys), .rst(rst_sys),
        .vram_raddr(t_vram_raddr), .vram_q, .pal_raddr(t_pal_raddr), .pal_q,
        .start(t_start), .line(line_num), .scroll_x(l_sx), .scroll_y(l_sy), .map_base(l_map), .pat_base(l_pat),
        .ctrl(l_tctrl), .busy(t_busy), .next_word(t_next),
        .px_valid(t_valid), .px_x(t_x), .px_opaque(t_opaque), .px_pri(t_pri), .px_color(t_color)
    );

    always_ff @(posedge clk_sys) req_s <= {req_s[1:0], req_toggle};

    // 作業ラインの読み出しアドレス: そのパスで次のクロックに書くところ
    always_comb begin
        unique case (phase)
            P_SPRITE: wl_rd_addr = s_next;
            P_TILE:   wl_rd_addr = t_next;
            P_BITMAP: wl_rd_addr = mem_rvalid ? widx + 8'd1 : widx;
            P_OUT:    wl_rd_addr = oidx + 8'd1;
            default:  wl_rd_addr = 8'd0;
        endcase
    end

    // 作業ラインへの書き込み
    logic [2:0] t_rank, s_rank;
    logic       bm_lo_ok, bm_hi_ok;
    assign t_rank   = t_pri ? RANK_A_HI : RANK_A_LO;
    assign s_rank   = s_pri ? RANK_S_HI : RANK_S_LO;
    assign bm_lo_ok = !(l_key_en && mem_rdata[15:0] == l_key) && l_bm_rank > wl_q_even[18:16];
    assign bm_hi_ok = !(l_key_en && mem_rdata[31:16] == l_key) && l_bm_rank > wl_q_odd[18:16];
    always_comb begin
        wl_we_even = 1'b0; wl_wa_even = widx; wl_wd_even = {l_bm_rank, mem_rdata[15:0]};
        wl_we_odd  = 1'b0; wl_wa_odd  = widx; wl_wd_odd  = {l_bm_rank, mem_rdata[31:16]};
        unique case (phase)
            // スプライト: 空いているところだけ (OAM の前のスプライトが勝つ)。sprite_layer は不透明なピクセルだけ出す
            P_SPRITE: begin
                wl_wa_even = s_x[8:1];  wl_wd_even = {s_rank, s_color};
                wl_wa_odd  = s_x[8:1];  wl_wd_odd  = {s_rank, s_color};
                wl_we_even = s_valid && !s_x[0] && wl_q_even[18:16] == 3'd0;
                wl_we_odd  = s_valid &&  s_x[0] && wl_q_odd[18:16] == 3'd0;
            end
            P_TILE: begin
                wl_wa_even = t_x[8:1];  wl_wd_even = {t_rank, t_color};
                wl_wa_odd  = t_x[8:1];  wl_wd_odd  = {t_rank, t_color};
                wl_we_even = t_valid && !t_x[0] && t_opaque && t_rank > wl_q_even[18:16];
                wl_we_odd  = t_valid &&  t_x[0] && t_opaque && t_rank > wl_q_odd[18:16];
            end
            P_BITMAP: begin
                wl_we_even = mem_rvalid && bm_lo_ok;
                wl_we_odd  = mem_rvalid && bm_hi_ok;
            end
            P_OUT: begin
                // 写したところを空 (順位 0) に戻して、次のラインに備える
                wl_wa_even = oidx; wl_wd_even = '0; wl_we_even = 1'b1;
                wl_wa_odd  = oidx; wl_wd_odd  = '0; wl_we_odd  = 1'b1;
            end
            default: ;
        endcase
    end

    // 出力のパス: 作業ラインをライン バッファに写す。順位 0 (どのレイヤも書かなかった) は背景色
    logic [31:0] out_word;
    assign out_word = {(wl_q_odd[18:16] == 3'd0) ? l_bg : wl_q_odd[15:0],
                       (wl_q_even[18:16] == 3'd0) ? l_bg : wl_q_even[15:0]};
    always_ff @(posedge clk_sys) if (phase == P_OUT) line_buf[{line_bank, oidx}] <= out_word;

    assign mem_len = 9'(WORDS);

    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            phase           <= P_IDLE;
            pending         <= 1'b0;
            mem_req         <= 1'b0;
            underflow_count <= '0;
            frame_base      <= '0;
            base_latched    <= 1'b0;
            line_start      <= 1'b0;
            line_num        <= '0;
            mark_pending    <= 1'b0;
            mark_toggle     <= 1'b0;
            t_start         <= 1'b0;
            s_start         <= 1'b0;
        end else begin
            base_latched <= 1'b0;
            line_start   <= 1'b0;
            t_start      <= 1'b0;
            s_start      <= 1'b0;
            if (mark_req) mark_pending <= 1'b1;

            // 新しい依頼が来たときにまだ合成していたら、表示に間に合っていない
            if (req_s[2] != req_s[1]) begin
                if (busy && underflow_count != 8'hFF) underflow_count <= underflow_count + 8'd1;
                pending <= 1'b1;
            end

            unique case (phase)
                P_IDLE: if (pending || req_s[2] != req_s[1]) begin
                    pending    <= 1'b0;
                    line_bank  <= req_line[0];
                    line_start <= 1'b1;
                    line_num   <= 8'(req_line);
                    l_bg       <= bg_color;
                    l_key      <= bitmap_key;
                    l_key_en   <= layer_ctrl[1];
                    l_bm_en    <= layer_ctrl[0];
                    l_tile_en  <= layer_ctrl[2];
                    l_bm_rank  <= bitmap_rank;
                    l_sx       <= tile_scroll_x;
                    l_sy       <= tile_scroll_y;
                    l_map      <= tile_map_base;
                    l_pat      <= tile_pat_base;
                    l_tctrl    <= tile_ctrl;
                    l_spat     <= spr_pat_base;
                    l_sbank    <= spr_bank;
                    l_scols    <= spr_line_cols;
                    l_addr     <= (req_line == 9'd0) ? {fb_base, 8'b0} : {frame_base + 13'(req_line), 8'b0};
                    widx       <= '0;
                    if (req_line == 9'd0) begin
                        frame_base   <= fb_base;
                        base_latched <= 1'b1;
                        if (mark_pending || mark_req) begin
                            mark_toggle  <= ~mark_toggle;
                            mark_pending <= 1'b0;
                        end
                    end
                    if (layer_ctrl[3]) begin
                        s_start <= 1'b1;
                        phase   <= P_SPRITE;
                    end else if (layer_ctrl[2]) begin
                        t_start <= 1'b1;
                        phase   <= P_TILE;
                    end else begin
                        phase <= P_ISSUE;
                    end
                end
                // s_start / t_start のクロックの busy はまだ 0 (次のクロックから busy)
                P_SPRITE: if (!s_start && !s_busy) begin
                    if (l_tile_en) begin
                        t_start <= 1'b1;
                        phase   <= P_TILE;
                    end else begin
                        phase <= P_ISSUE;
                    end
                end
                P_TILE: if (!t_start && !t_busy) phase <= P_ISSUE;
                P_ISSUE: begin
                    if (l_bm_en) begin
                        mem_req  <= 1'b1;
                        mem_addr <= l_addr;
                        phase    <= P_BITMAP;
                    end else begin
                        phase <= P_OUT_PRE;
                    end
                end
                P_BITMAP: begin
                    if (mem_rvalid) widx <= widx + 8'd1;
                    if (mem_ack) begin
                        mem_req <= 1'b0;
                        phase   <= P_OUT_PRE;
                    end
                end
                // 作業ラインのワード 0 を読むための 1 クロック
                P_OUT_PRE: begin
                    oidx  <= '0;
                    phase <= P_OUT;
                end
                P_OUT: begin
                    oidx <= oidx + 8'd1;
                    if (oidx == 8'(WORDS - 1)) phase <= P_IDLE;
                end
                default: phase <= P_IDLE;
            endcase
        end
    end
endmodule
