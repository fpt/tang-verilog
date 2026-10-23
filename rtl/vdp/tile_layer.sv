// タイル レイヤ 1 面 (docs/EMU_GPU_PLAN.md の E2)。line_compositor が 1 ラインごとに start で動かす
//
//   VRAM:     VRAM_WORDS x 32bit (既定 16K ワード = 64KiB) の BSRAM。GPU の VRAM_WRITE が書く
//   パレット: 512 x RGB565 の BSRAM。GPU の PAL_WRITE が書く
//   タイル:   8x8 ピクセル、4bpp。1 行が 1 ワードで、ピクセル i (左から) は [31-4i -: 4]。タイル t の行 r は pat_base + t*8 + r
//   マップ:   1 エントリ 16bit、1 ワードに 2 つ (下位が偶数の列)。列 c、行 r のエントリは map_base + (r * 幅 + c) / 2。
//             [10:0] タイル番号、[11] 左右反転、[12] 上下反転、[14:13] パレット、[15] 優先度 (E2 では使わない)
//   色:       ピクセルの値 0 は透明 (下のレイヤが見える)。それ以外はパレットの {ctrl[6:4], エントリのパレット, 値}
//   ctrl:     [1:0] マップの幅 (0: 32, 1: 64, 2: 128 タイル)、[3:2] 高さ (0: 32, 1: 64, 2: 128, 3: 28 タイル = SMS)、
//             [6:4] パレットのバンク
//   スクロール: 画面のピクセル (x, line) は、マップのピクセル ((x + scroll_x) mod 幅, (line + scroll_y) mod 高さ)。
//             高さ 28 タイル (224 ピクセル) のときは scroll_y < 224 にする
//
//   動き方: start で、line の 1 ライン分 (SRC_W ピクセル) をタイル ライン バッファに書く。1 タイルごとに
//           マップを読む (1 クロック) -> タイルの行を読む (1 クロック) -> 8 ピクセルを 1 クロックに 1 つ、パレットを引いて書く。
//           1 ラインは約 (3 + 8) x 41 = 450 クロック。終わるまで busy
//   読み出し: rd_addr (ワード = 2 ピクセル) の 1 クロック後に rd_data = {不透明, 色 (奇数の x), 不透明, 色 (偶数の x)}
//
//   スクロールなどの入力は start から busy が落ちるまで変えないこと (line_compositor がラインの開始で取り込んだ値を渡す)。
module tile_layer #(
    parameter int SRC_W      = 320,
    parameter int VRAM_WORDS = 16384
) (
    input  logic        clk,
    input  logic        rst,
    // 書き込み (GPU)
    input  logic        vram_we,
    input  logic [13:0] vram_waddr,
    input  logic [31:0] vram_wdata,
    input  logic        pal_we,
    input  logic [8:0]  pal_waddr,
    input  logic [15:0] pal_wdata,
    // 1 ラインの合成
    input  logic        start,
    input  logic [7:0]  line,
    input  logic [9:0]  scroll_x,
    input  logic [9:0]  scroll_y,
    input  logic [13:0] map_base,
    input  logic [13:0] pat_base,
    input  logic [6:0]  ctrl,
    output logic        busy,
    // タイル ライン バッファの読み出し
    input  logic [7:0]  rd_addr,
    output logic [33:0] rd_data
);
    localparam int VA_W = $clog2(VRAM_WORDS);

    // ================================================================ メモリ
    logic [31:0] vram [0:VRAM_WORDS-1];
    logic [15:0] pal  [0:511];
    logic [16:0] tbuf_even [0:255];      // {不透明, 色}。偶数の x
    logic [16:0] tbuf_odd  [0:255];

    logic [13:0] vram_raddr;
    logic [31:0] vram_q;
    logic [8:0]  pal_raddr;
    logic [15:0] pal_q;

    always_ff @(posedge clk) begin
        if (vram_we) vram[VA_W'(vram_waddr)] <= vram_wdata;
        vram_q <= vram[VA_W'(vram_raddr)];
    end
    always_ff @(posedge clk) begin
        if (pal_we) pal[pal_waddr] <= pal_wdata;
        pal_q <= pal[pal_raddr];
    end

    // 書き込みはパレットを引いた次のクロック
    logic        p_valid, p_opaque;
    logic [8:0]  p_x;
    always_ff @(posedge clk) begin
        if (p_valid && !p_x[0]) tbuf_even[p_x[8:1]] <= {p_opaque, pal_q};
        if (p_valid &&  p_x[0]) tbuf_odd[p_x[8:1]]  <= {p_opaque, pal_q};
    end
    always_ff @(posedge clk) rd_data <= {tbuf_odd[rd_addr], tbuf_even[rd_addr]};

    // ================================================================ ラインの合成
    typedef enum logic [1:0] {T_IDLE, T_MAP, T_PAT, T_EMIT} tstate_t;
    tstate_t state;

    logic [8:0]  x;               // 書く画面の x
    logic [6:0]  col;             // マップの列
    logic [2:0]  px;              // タイルの中の x (反転の前)
    logic [6:0]  row;             // マップの行
    logic [2:0]  fine_y;
    logic [31:0] pat;             // タイルの今の行
    logic        hflip;
    logic [1:0]  pal_sel;
    logic        col_odd;         // 読んだマップのワードのどちらのエントリか
    logic        first;           // T_MAP の 1 クロック目

    // マップの大きさ
    logic [6:0] col_mask;
    always_comb begin
        unique case (ctrl[1:0])
            2'd0:    col_mask = 7'd31;
            2'd1:    col_mask = 7'd63;
            default: col_mask = 7'd127;
        endcase
    end

    // スクロールしたマップの y: 2 のべきの高さはマスク、28 タイルは 224 を最大 2 回引く (line + scroll_y < 240 + 224)
    logic [10:0] vy_sum, vy;
    always_comb begin
        vy_sum = 11'(line) + 11'(scroll_y);
        unique case (ctrl[3:2])
            2'd0: vy = vy_sum & 11'd255;
            2'd1: vy = vy_sum & 11'd511;
            2'd2: vy = vy_sum & 11'd1023;
            default: begin
                vy = vy_sum;
                if (vy >= 11'd224) vy = vy - 11'd224;
                if (vy >= 11'd224) vy = vy - 11'd224;
            end
        endcase
    end

    // マップのエントリの番号 (行 x 幅 + 列) とワードアドレス
    logic [13:0] map_index;
    always_comb begin
        unique case (ctrl[1:0])
            2'd0:    map_index = {2'b0, row, 5'b0} + 14'(col);
            2'd1:    map_index = {1'b0, row, 6'b0} + 14'(col);
            default: map_index = {row, 7'b0} + 14'(col);
        endcase
    end

    logic [14:0] entry;           // 優先度 ([15]) は E2 では使わない
    assign entry = col_odd ? vram_q[30:16] : vram_q[14:0];

    logic [2:0] pi;               // 反転したあとのタイルの中の x
    logic [3:0] nib;
    assign pi  = hflip ? ~px : px;
    assign nib = pat[5'd28 - {pi, 2'b0} +: 4];

    always_comb begin
        vram_raddr = map_base + 14'(map_index >> 1);
        if (state == T_MAP && !first)   // マップのエントリが届いたクロック: タイルの行を読む
            vram_raddr = pat_base + {entry[10:0], entry[12] ? ~fine_y : fine_y};
        pal_raddr = {ctrl[6:4], pal_sel, nib};
    end

    assign busy = state != T_IDLE || p_valid;

    // T_IDLE --start--> (マップを読む) T_MAP -> (タイルの行を読む) T_PAT -> T_EMIT x 8 -> T_MAP ...
    // T_MAP は 2 クロック: 1 クロック目 (first) にマップのアドレスを出し、2 クロック目に届いたエントリからタイルの行のアドレスを出す
    always_ff @(posedge clk) begin
        if (rst) begin
            state   <= T_IDLE;
            p_valid <= 1'b0;
            first   <= 1'b0;
        end else begin
            p_valid <= 1'b0;
            unique case (state)
                T_IDLE: if (start) begin
                    row    <= 7'(vy >> 3);
                    fine_y <= vy[2:0];
                    col    <= 7'(scroll_x >> 3) & col_mask;
                    px     <= scroll_x[2:0];
                    x      <= '0;
                    first  <= 1'b1;
                    state  <= T_MAP;
                end
                T_MAP: begin
                    if (first) begin
                        first   <= 1'b0;
                        col_odd <= col[0];
                    end else begin
                        hflip   <= entry[11];
                        pal_sel <= entry[14:13];
                        state   <= T_PAT;
                    end
                end
                T_PAT: begin
                    pat   <= vram_q;
                    state <= T_EMIT;
                end
                T_EMIT: begin
                    p_valid  <= 1'b1;
                    p_opaque <= nib != 4'd0;
                    p_x      <= x;
                    x        <= x + 9'd1;
                    px       <= px + 3'd1;
                    if (x == 9'(SRC_W - 1)) begin
                        state <= T_IDLE;
                    end else if (px == 3'd7) begin
                        col   <= (col + 7'd1) & col_mask;
                        first <= 1'b1;
                        state <= T_MAP;
                    end
                end
                default: state <= T_IDLE;
            endcase
        end
    end
endmodule
