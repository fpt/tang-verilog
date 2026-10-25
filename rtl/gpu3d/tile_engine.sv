// TBDR のタイルのパス (docs/GPU3D_PLAN.md の G2・G3)。END_SCENE で、tri_engine がビニングしたシーンをタイル (32 x 32、横 10 x 縦 8) ごとに描く
//
//   タイルの範囲 (rtx0..rtx1 x rty0..rty1) を 1 タイルずつ:
//     1. タイルバッファ (色 1,024 x 16bit、Z 1,024 x 16bit、オンチップ) を用意する: clear_color なら色 ccol、そうでなければ描く面から読む。
//        clear_z なら Z = 0xFFFF、そうでなければ Z バッファ (Z_BASE) から読む (どちらも 1 行 16 ワードのバーストを 32 行。一番下のタイルは 16 行)
//     2. タイルのリスト (tri_engine の数 cnt と、SDRAM の 0x40000 + タイル * 1024 からの番号) を 64 個ずつ読み、投入順に:
//        レコード (0x20000 + 番号 * 32 から 32 ワード) を読む → 外接矩形とタイルの重なりの左上での辺の値と属性 (r, g, b, z, u, v) を
//        s + gx * dx + gy * dy で作る (乗算 18 回。dx, dy は外接矩形の左上からのピクセル数。即時モードの足し算と同じ値になる) →
//        重なりを 1 クロックに 1 ピクセル (下の 4 段)。辺の判定、Z (z < タイルの Z) はオンチップ、色と z をタイルバッファに書く
//     3. タイルの色を描く面に書く (write_z なら Z も Z バッファに)。書いたワードのタイルバッファは、clear なら次のタイルの値に戻す
//   ピクセルの 4 段 (G3):
//     A  辺の判定、属性、テクセルの座標とワードアドレス、テクスチャのキャッシュのタグを見る。外れなら A を止めて 1 行 (8 ワード) を読む
//     B  キャッシュのワードからテクセルを取り出す (16bpp はそのまま、8 / 4bpp は CLUT を引く)
//     C  テクセルの色が決まる。タイルの Z を読む
//     D  透明 (テクセルの色 0)、変調 (Gouraud なら頂点の色を掛ける、128 = 1 倍)、Z を比べてタイルバッファに書く
//   テクスチャのキャッシュ: 直接写像、16 行 x 8 ワード (BSRAM 1 個)。タグは 14bit (ワードアドレスの [20:7])。シーン (タイルのパス) の始めに空にする
//   規則は tools/harness/raster.py (即時モードと同じピクセル)。タイルのリストに入れなかった三角形 (上限を超えた分) はそのタイルでは描かない
//   数え (測る用、32bit で回る): 段階ごとのクロック (準備、リストとレコードの読み出し、乗算、走査、書き出し)、走査・描いたピクセル、
//   テクセルを引いた数 (中のピクセル)、キャッシュの外れ、外れで止まったクロック
module tile_engine (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [3:0]  rtx0, rtx1,                   // 描くタイルの範囲 (シーンは 0..9 x 0..7、シーンの外の TRI は外接矩形のタイル)
    input  logic [3:0]  rty0, rty1,
    input  logic        clear_color,
    input  logic        clear_z,
    input  logic        write_z,
    input  logic [15:0] ccol,
    input  logic [12:0] draw_base,
    input  logic [12:0] z_base,
    output logic        busy,
    // CLUT の書き込み (CLUT_WRITE)
    input  logic        clut_we,
    input  logic [7:0]  clut_waddr,
    input  logic [15:0] clut_wdata,
    // タイルの三角形の数 (tri_engine の cnt、1 クロック遅れ)
    output logic [6:0]  cnt_raddr,
    input  logic [10:0] cnt_q,
    // SDRAM
    output logic        mem_req,
    output logic        mem_we,
    output logic [20:0] mem_addr,
    output logic [8:0]  mem_len,
    output logic [31:0] mem_wdata,
    output logic [3:0]  mem_wmask,
    input  logic        mem_ack,
    input  logic        mem_wnext,
    input  logic        mem_rvalid,
    input  logic [31:0] mem_rdata,
    output logic [31:0] c_prep, c_fetch, c_mul, c_walk, c_out,
    output logic [31:0] walked, drawn,
    output logic [31:0] tex_looks, tex_miss, c_tex
);
    localparam logic [20:0] PARAM_BASE = 21'h020000, LIST_BASE = 21'h040000;

    typedef enum logic [4:0] {
        T_IDLE, T_SWEEP, T_TILE, T_LOADC, T_LOADZ, T_CNT, T_CNT2, T_LFETCH, T_ENTRY, T_ENTRY2, T_REC, T_MUL, T_MULW,
        T_ROW, T_WALK, T_TFILL, T_DRAIN, T_DRAIN2, T_NEXTENT, T_OUTC, T_OUTZ, T_NEXTTILE
    } state_t;
    state_t state;

    // ---- タイル ----
    logic [3:0]  tx, ty;
    logic [6:0]  tile;
    logic [5:0]  rows;                                // 32 (一番下は 16)
    logic [4:0]  r;                                   // 今の行 (準備と書き出し)
    logic [3:0]  w_cur;                               // 行の中のワード
    logic [3:0]  w_rd;
    logic [8:0]  sw_i;                                // T_SWEEP の番号
    assign tile = 7'(ty) * 7'd10 + 7'(tx);
    assign cnt_raddr = tile;

    // ---- タイルバッファ (偶数の x と奇数の x を別に。番号は {行, x / 2}) ----
    logic [15:0] cb_e [0:511];
    logic [15:0] cb_o [0:511];
    logic [15:0] zb_e [0:511];
    logic [15:0] zb_o [0:511];
    logic [8:0]  rd_idx, wr_idx;
    logic [15:0] cq_e, cq_o, zq_e, zq_o;

    // ---- リスト ----
    logic [11:0] lbuf [0:63];
    logic [11:0] lq;
    logic [10:0] n, li;                               // このタイルの数、読み終えた数
    logic [6:0]  chunk, k;                            // 読んだ塊の数、その中の番号
    logic [5:0]  lw;                                  // 塊を読むときの書く位置
    logic [11:0] idx;

    // ---- レコード ----
    logic               gour, texd, zen;              // レコードのフラグ (bit0 Gouraud、bit1 テクスチャ、bit3 Z)
    logic [15:0]        rflat;
    logic [8:0]         rbx0, rbx1;
    logic [7:0]         rby0, rby1;
    logic signed [31:0] re  [0:2];
    logic signed [20:0] rex [0:2];
    logic signed [20:0] rey [0:2];
    logic [31:0]        rs  [0:5];
    logic [31:0]        rgx [0:5];
    logic [31:0]        rgy [0:5];
    logic [1:0]         tfmt;                         // テクスチャ: 0 16bpp、1 8bpp、2 4bpp
    logic [7:0]         tclut;
    logic [3:0]         twl, thl;
    logic [20:0]        tbase;
    logic [4:0]         ridx;

    // 外接矩形とタイルの重なり
    logic [8:0] ox0, ox1, tx0p, tx1p;
    logic [7:0] oy0, oy1, ty0p, ty1p;
    assign tx0p = {tx, 5'd0};
    assign tx1p = {tx, 5'd31};
    assign ty0p = {ty[2:0], 5'd0};
    assign ty1p = {ty[2:0], 5'd31};
    assign ox0 = (rbx0 > tx0p) ? rbx0 : tx0p;
    assign ox1 = (rbx1 < tx1p) ? rbx1 : tx1p;
    assign oy0 = (rby0 > ty0p) ? rby0 : ty0p;
    assign oy1 = (rby1 < ty1p) ? rby1 : ty1p;

    // ---- 乗算 (重なりの左上の値) ----
    logic               m_in_v, m_out_v;
    logic signed [35:0] m_a;
    logic signed [17:0] m_b;
    logic [4:0]         m_in_tag, m_out_tag;          // {組の 1 つ目, 置き場所 (0..2 辺、3..8 属性)}
    logic signed [31:0] m_p;                          // 積の下位 32bit (値は 32bit で回る)
    logic [4:0]         mk;                           // 出した乗算の数 (0..17)
    logic [4:0]         mdone;
    logic [31:0]        macc;                         // 乗算の結果を足していく (組ごと)
    smul36x18 #(.TAG_W(5), .P_W(32)) u_mul (
        .clk, .in_valid(m_in_v), .a(m_a), .b(m_b), .in_tag(m_in_tag),
        .out_valid(m_out_v), .p(m_p), .out_tag(m_out_tag)
    );
    logic [8:0] dxp;
    logic [7:0] dyp;
    assign dxp = ox0 - rbx0;
    assign dyp = oy0 - rby0;
    always_comb begin
        int d;
        m_in_v = state == T_MUL;
        d = int'(mk) / 2;
        m_in_tag = {!mk[0], 4'(d)};
        m_b = mk[0] ? 18'({10'd0, dyp}) : 18'({9'd0, dxp});
        if (d < 3) m_a = mk[0] ? 36'(rey[d]) : 36'(rex[d]);
        else       m_a = mk[0] ? 36'(signed'(rgy[d - 3])) : 36'(signed'(rgx[d - 3]));
    end

    // ---- 走査 (A 段) ----
    logic [8:0]         x;
    logic [7:0]         y;
    logic signed [31:0] er [0:2];
    logic signed [31:0] ec [0:2];
    logic [31:0]        ar [0:5];
    logic [31:0]        ac [0:5];
    logic               p_in;
    logic [15:0]        pz, pcol;
    logic [7:0]         pr8, pg8, pb8;
    function automatic logic [15:0] clampv(input logic [31:0] acc, input logic [15:0] mx);
        logic signed [19:0] v;
        v = 20'(signed'(acc) >>> 12);
        if (v < 0) return 16'd0;
        if (v > signed'({4'b0, mx})) return mx;
        return 16'(v);
    endfunction
    always_comb begin
        p_in = ec[0] >= 0 && ec[1] >= 0 && ec[2] >= 0;
        pz   = clampv(ac[3], 16'hFFFF);
        pr8  = 8'(clampv(ac[0], 16'd255));
        pg8  = 8'(clampv(ac[1], 16'd255));
        pb8  = 8'(clampv(ac[2], 16'd255));
        pcol = gour ? {pr8[7:3], pg8[7:2], pb8[7:3]} : rflat;
    end

    // テクセル: tu = (acc_u >>> 18) & (幅 - 1)、ワードアドレス = base + (tv << (幅の log2 - s)) + (tu >> s)
    logic [7:0]  tu, tv, umask, vmask;
    logic [1:0]  tsh;
    logic [20:0] taddr;
    logic [3:0]  tline;
    logic [13:0] ttag;
    logic        t_hit, t_need;
    assign umask = 8'((9'd1 << twl) - 9'd1);
    assign vmask = 8'((9'd1 << thl) - 9'd1);
    assign tu    = ac[4][25:18] & umask;
    assign tv    = ac[5][25:18] & vmask;
    assign tsh   = (tfmt == 2'd0) ? 2'd1 : (tfmt == 2'd1) ? 2'd2 : 2'd3;
    assign taddr = tbase + 21'(16'(tv) << (twl - 4'(tsh))) + 21'(tu >> tsh);
    assign tline = taddr[6:3];
    assign ttag  = taddr[20:7];

    // テクスチャのキャッシュ (直接写像 16 行 x 8 ワード。タグは FF なので、LUT が足りるように 16 行にした)
    logic [31:0] tcache [0:127];
    logic [13:0] ttags [0:15];
    logic [15:0] tvalid;
    logic [31:0] tq;
    logic [6:0]  tc_raddr;
    logic [2:0]  tf_w;                                // 埋めているワード
    logic [3:0]  tf_line;
    logic [13:0] tf_tag;
    assign t_hit    = tvalid[tline] && ttags[tline] == ttag;
    assign t_need   = state == T_WALK && texd && p_in;
    assign tc_raddr = {tline, taddr[2:0]};

    // CLUT
    logic [15:0] clut [0:255];
    logic [15:0] clq;
    logic [7:0]  cl_raddr;

    // ---- B 段: テクセルのワードが届く ----
    logic        b_v, b_in, b_odd, b_txd;
    logic [8:0]  b_idx;
    logic [15:0] b_z, b_col;
    logic [23:0] b_rgb;
    logic [2:0]  b_sub;                               // ワードの中のテクセルの位置 (tu の下位)
    logic [15:0] b_t16;                               // 16bpp のテクセル
    always_comb begin
        logic [7:0] v8;
        logic [3:0] v4;
        b_t16 = b_sub[0] ? tq[31:16] : tq[15:0];
        v8 = tq[{b_sub[1:0], 3'b0} +: 8];
        v4 = tq[5'd28 - {b_sub, 2'b0} +: 4];
        cl_raddr = ((tfmt == 2'd1) ? v8 : {4'd0, v4}) + tclut;
    end
    // ---- C 段: テクセルの色が決まる、タイルの Z を読む ----
    logic        c_v, c_in, c_odd, c_txd;
    logic [8:0]  c_idx;
    logic [15:0] c_z, c_col, c_t16;
    logic [23:0] c_rgb;
    // ---- D 段: 透明、変調、Z ----
    logic        d_v, d_in, d_odd, d_txd;
    logic [8:0]  d_idx;
    logic [15:0] d_z, d_col, d_tex565;
    logic [23:0] d_rgb;
    logic        d_pass;
    logic [15:0] d_out;
    // 小さい符号なしの乗算 (a x b、6bit x 8bit) をシフトと加算で。`*` だと yosys が DSP (MULT9X9) に置き、MULT18X18 と混ざると
    // nextpnr が配置できなかった (G3)
    function automatic logic [13:0] umul6x8(input logic [5:0] a, input logic [7:0] b);
        logic [13:0] p;
        p = '0;
        for (int i = 0; i < 6; i++) if (a[i]) p = p + (14'(b) << i);
        return p;
    endfunction
    function automatic logic [15:0] modulate(input logic [15:0] t, input logic [23:0] c);
        logic [5:0] mr, mb;
        logic [6:0] mg;
        mr = 6'(umul6x8({1'b0, t[15:11]}, c[23:16]) >> 7);
        mg = 7'(umul6x8(t[10:5], c[15:8]) >> 7);
        mb = 6'(umul6x8({1'b0, t[4:0]}, c[7:0]) >> 7);
        return {mr[5] ? 5'd31 : mr[4:0], mg[6] ? 6'd63 : mg[5:0], mb[5] ? 5'd31 : mb[4:0]};
    endfunction
    always_comb begin
        d_out  = d_txd ? (gour ? modulate(d_tex565, d_rgb) : d_tex565) : d_col;
        d_pass = d_v && d_in && !(d_txd && d_tex565 == 16'd0) && (!zen || d_z < (d_odd ? zq_o : zq_e));
    end

    // タイルバッファの読み出しの番号: 走査は C 段のピクセル、準備と書き出しは {行, ワード}
    logic [4:0] lx, ly;
    assign lx = 5'(x - tx0p);
    assign ly = 5'(y - ty0p);
    assign w_rd = ((state == T_OUTC || state == T_OUTZ) && mem_wnext) ? w_cur + 4'd1 : w_cur;
    assign rd_idx = c_v ? c_idx : {r, w_rd};
    assign wr_idx = {r, w_cur};

    always_ff @(posedge clk) begin
        cq_e <= cb_e[rd_idx];
        cq_o <= cb_o[rd_idx];
        zq_e <= zb_e[rd_idx];
        zq_o <= zb_o[rd_idx];
        lq   <= lbuf[k[5:0]];
        tq   <= tcache[tc_raddr];
        clq  <= clut[cl_raddr];
        if (clut_we) clut[clut_waddr] <= clut_wdata;
        if (state == T_TFILL && mem_req && mem_rvalid) tcache[{tf_line, tf_w}] <= mem_rdata;
        if (state == T_LFETCH && mem_req && mem_rvalid) lbuf[lw] <= mem_rdata[11:0];
        // 色
        if (state == T_SWEEP) begin
            cb_e[sw_i] <= ccol; cb_o[sw_i] <= ccol;
        end else if (state == T_LOADC && mem_req && mem_rvalid) begin
            cb_e[wr_idx] <= mem_rdata[15:0]; cb_o[wr_idx] <= mem_rdata[31:16];
        end else if (state == T_OUTC && mem_wnext && clear_color) begin
            cb_e[wr_idx] <= ccol; cb_o[wr_idx] <= ccol;
        end else if (d_pass) begin
            if (d_odd) cb_o[d_idx] <= d_out;
            else       cb_e[d_idx] <= d_out;
        end
        // Z
        if (state == T_SWEEP) begin
            zb_e[sw_i] <= 16'hFFFF; zb_o[sw_i] <= 16'hFFFF;
        end else if (state == T_LOADZ && mem_req && mem_rvalid) begin
            zb_e[wr_idx] <= mem_rdata[15:0]; zb_o[wr_idx] <= mem_rdata[31:16];
        end else if (((state == T_OUTZ) || (state == T_OUTC && !write_z)) && mem_wnext && clear_z) begin
            zb_e[wr_idx] <= 16'hFFFF; zb_o[wr_idx] <= 16'hFFFF;
        end else if (d_pass && zen) begin
            if (d_odd) zb_o[d_idx] <= d_z;
            else       zb_e[d_idx] <= d_z;
        end
    end

    assign mem_wmask = 4'hF;
    assign mem_wdata = (state == T_OUTZ) ? {zq_o, zq_e} : {cq_o, cq_e};
    assign busy = state != T_IDLE || start;

    always_ff @(posedge clk) begin
        if (rst) begin
            state   <= T_IDLE;
            mem_req <= 1'b0;
            mem_we  <= 1'b0;
            b_v <= 1'b0; c_v <= 1'b0; d_v <= 1'b0;
            tvalid  <= '0;
            {c_prep, c_fetch, c_mul, c_walk, c_out, walked, drawn, tex_looks, tex_miss, c_tex} <= '0;
        end else begin
            if (d_pass) drawn <= drawn + 32'd1;
            unique case (state)
                T_SWEEP, T_TILE, T_LOADC, T_LOADZ:                         c_prep  <= c_prep + 32'd1;
                T_CNT, T_CNT2, T_LFETCH, T_ENTRY, T_ENTRY2, T_REC, T_NEXTENT: c_fetch <= c_fetch + 32'd1;
                T_MUL, T_MULW:                                             c_mul   <= c_mul + 32'd1;
                T_ROW, T_WALK, T_DRAIN, T_DRAIN2:                          c_walk  <= c_walk + 32'd1;
                T_TFILL:                                                   c_tex   <= c_tex + 32'd1;
                T_OUTC, T_OUTZ, T_NEXTTILE:                                c_out   <= c_out + 32'd1;
                default: ;
            endcase

            // B → C → D (いつも進む。A が止まっているあいだは空が流れる)
            c_v <= b_v; c_in <= b_in; c_odd <= b_odd; c_txd <= b_txd; c_idx <= b_idx;
            c_z <= b_z; c_col <= b_col; c_rgb <= b_rgb; c_t16 <= b_t16;
            d_v <= c_v; d_in <= c_in; d_odd <= c_odd; d_txd <= c_txd; d_idx <= c_idx;
            d_z <= c_z; d_col <= c_col; d_rgb <= c_rgb;
            d_tex565 <= (tfmt == 2'd0) ? c_t16 : clq;
            b_v <= 1'b0;

            // 乗算の結果を足す (辺の値と属性。どちらも 32bit で回る)
            if (m_out_v) begin
                // 置き場所ごとの 2 つの積は続けて出るので、加算器 1 つで: 1 つ目は e / s に、2 つ目はその和に足す
                logic [3:0]  dd;
                logic [31:0] val;
                dd  = m_out_tag[3:0];
                val = (m_out_tag[4] ? ((dd < 4'd3) ? 32'(re[2'(dd)]) : rs[3'(dd - 4'd3)]) : macc) + m_p;
                macc <= val;
                if (dd < 4'd3) er[2'(dd)] <= signed'(val);
                else           ar[3'(dd - 4'd3)] <= val;
                mdone <= mdone + 5'd1;
            end

            unique case (state)
                T_IDLE: if (start) begin
                    tx <= rtx0; ty <= rty0;
                    sw_i   <= '0;
                    tvalid <= '0;                       // テクスチャはシーンのあいだに書き換えられているかもしれない
                    state  <= T_SWEEP;
                end
                // タイルバッファを消す (シーンの最初だけ。あとは書き出しのときに次のタイルの値に戻す)
                T_SWEEP: begin
                    sw_i <= sw_i + 9'd1;
                    if (sw_i == 9'd511) state <= T_TILE;
                end
                T_TILE: begin
                    rows  <= (ty == 4'd7) ? 6'd16 : 6'd32;
                    r     <= '0;
                    w_cur <= '0;
                    if (!clear_color)  state <= T_LOADC;
                    else if (!clear_z) state <= T_LOADZ;
                    else               state <= T_CNT;
                end
                // 描く面 / Z バッファの行をタイルバッファに読む (1 行 16 ワード)
                T_LOADC, T_LOADZ: begin
                    if (!mem_req) begin
                        mem_req  <= 1'b1;
                        mem_we   <= 1'b0;
                        mem_addr <= {((state == T_LOADZ) ? z_base : draw_base) + 13'({ty[2:0], r}), tx, 4'd0};
                        mem_len  <= 9'd16;
                        w_cur    <= '0;
                    end else begin
                        if (mem_rvalid) w_cur <= w_cur + 4'd1;
                        if (mem_ack) begin
                            mem_req <= 1'b0;
                            if (6'(r) == rows - 6'd1) begin
                                r <= '0;
                                if (state == T_LOADC && !clear_z) state <= T_LOADZ;
                                else                              state <= T_CNT;
                            end else begin
                                r <= r + 5'd1;
                            end
                        end
                    end
                end
                T_CNT: state <= T_CNT2;                     // cnt_q は次のクロック
                T_CNT2: begin
                    n     <= cnt_q;
                    li    <= '0;
                    state <= T_LFETCH;
                end
                // リストを 64 個までの塊で読む
                T_LFETCH: begin
                    if (!mem_req) begin
                        if (li == n) begin
                            r <= '0; w_cur <= '0;
                            state <= T_OUTC;
                        end else begin
                            chunk    <= (n - li > 11'd64) ? 7'd64 : 7'(n - li);
                            mem_req  <= 1'b1;
                            mem_we   <= 1'b0;
                            mem_addr <= LIST_BASE + {4'd0, tile, li[9:0]};
                            mem_len  <= (n - li > 11'd64) ? 9'd64 : 9'(n - li);
                            lw       <= '0;
                        end
                    end else begin
                        if (mem_rvalid) lw <= lw + 6'd1;
                        if (mem_ack) begin
                            mem_req <= 1'b0;
                            k       <= '0;
                            state   <= T_ENTRY;
                        end
                    end
                end
                T_ENTRY: state <= T_ENTRY2;                 // lq は次のクロック
                T_ENTRY2: begin
                    idx   <= lq;
                    ridx  <= '0;
                    state <= T_REC;
                end
                T_REC: begin
                    if (!mem_req) begin
                        mem_req  <= 1'b1;
                        mem_we   <= 1'b0;
                        mem_addr <= PARAM_BASE + {4'd0, idx, 5'd0};
                        mem_len  <= 9'd32;
                    end else begin
                        if (mem_rvalid) begin
                            ridx <= ridx + 5'd1;
                            if (ridx == 5'd0) begin
                                gour <= mem_rdata[24]; texd <= mem_rdata[25]; zen <= mem_rdata[27]; rflat <= mem_rdata[15:0];
                            end else if (ridx == 5'd1) begin
                                rbx0 <= mem_rdata[8:0]; rbx1 <= mem_rdata[24:16];
                            end else if (ridx == 5'd2) begin
                                rby0 <= mem_rdata[7:0]; rby1 <= mem_rdata[23:16];
                            end else if (ridx < 5'd6)  re[2'(ridx - 5'd3)]  <= signed'(mem_rdata);
                            else if (ridx < 5'd9)  rex[2'(ridx - 5'd6)] <= mem_rdata[20:0];
                            else if (ridx < 5'd12) rey[2'(ridx - 5'd9)] <= mem_rdata[20:0];
                            else if (ridx < 5'd18) rs[3'(ridx - 5'd12)]  <= mem_rdata;
                            else if (ridx < 5'd24) rgx[3'(ridx - 5'd18)] <= mem_rdata;
                            else if (ridx < 5'd30) rgy[3'(ridx - 5'd24)] <= mem_rdata;
                            else if (ridx == 5'd30) begin
                                tfmt <= mem_rdata[17:16]; tclut <= mem_rdata[15:8]; twl <= mem_rdata[7:4]; thl <= mem_rdata[3:0];
                            end else begin
                                tbase <= mem_rdata[20:0];
                            end
                        end
                        if (mem_ack) begin
                            mem_req <= 1'b0;
                            mk      <= '0;
                            mdone   <= '0;
                            state   <= T_MUL;
                        end
                    end
                end
                // 重なりの左上: er = e + ex dx + ey dy、ar = s + gx dx + gy dy (乗算 18 回を足していく)
                T_MUL: begin
                    mk <= mk + 5'd1;
                    if (mk == 5'd17) state <= T_MULW;
                end
                T_MULW: if (mdone == 5'd18 || (mdone == 5'd17 && m_out_v)) begin
                    y     <= oy0;
                    state <= T_ROW;
                end
                T_ROW: begin
                    for (int i = 0; i < 3; i++) ec[i] <= er[i];
                    for (int j = 0; j < 6; j++) ac[j] <= ar[j];
                    x     <= ox0;
                    state <= T_WALK;
                end
                // 1 クロックに 1 ピクセル (A 段)。テクスチャのキャッシュが外れたら、その行を読んでからこのピクセルをやり直す
                T_WALK: begin
                    if (t_need && !t_hit) begin
                        tex_miss <= tex_miss + 32'd1;
                        tf_line  <= tline;
                        tf_tag   <= ttag;
                        tf_w     <= '0;
                        mem_req  <= 1'b1;
                        mem_we   <= 1'b0;
                        mem_addr <= {taddr[20:3], 3'd0};
                        mem_len  <= 9'd8;
                        state    <= T_TFILL;
                    end else begin
                        if (t_need) tex_looks <= tex_looks + 32'd1;
                        b_v    <= 1'b1;
                        b_idx  <= {ly, lx[4:1]};
                        b_odd  <= lx[0];
                        b_in   <= p_in;
                        b_txd  <= texd;
                        b_z    <= pz;
                        b_col  <= pcol;
                        b_rgb  <= {pr8, pg8, pb8};
                        b_sub  <= tu[2:0];
                        walked <= walked + 32'd1;
                        for (int i = 0; i < 3; i++) ec[i] <= ec[i] + 32'(rex[i]);
                        for (int j = 0; j < 6; j++) ac[j] <= ac[j] + rgx[j];
                        x <= x + 9'd1;
                        if (x == ox1) state <= T_DRAIN;
                    end
                end
                T_TFILL: begin
                    if (mem_rvalid) tf_w <= tf_w + 3'd1;
                    if (mem_ack) begin
                        mem_req          <= 1'b0;
                        ttags[tf_line]   <= tf_tag;
                        tvalid[tf_line]  <= 1'b1;
                        state            <= T_WALK;
                    end
                end
                T_DRAIN: begin
                    for (int i = 0; i < 3; i++) er[i] <= er[i] + 32'(rey[i]);
                    for (int j = 0; j < 6; j++) ar[j] <= ar[j] + rgy[j];
                    state <= T_DRAIN2;
                end
                T_DRAIN2: begin
                    if (y == oy1) begin
                        state <= T_NEXTENT;
                    end else begin
                        y     <= y + 8'd1;
                        state <= T_ROW;
                    end
                end
                T_NEXTENT: begin
                    if (7'(k) + 7'd1 == chunk) begin
                        li    <= li + 11'(chunk);
                        state <= T_LFETCH;
                    end else begin
                        k     <= k + 7'd1;
                        state <= T_ENTRY;
                    end
                end
                // タイルの色 (と Z) を書く。1 行 16 ワード (走査の最後のピクセルが書き終わってから。D 段は 3 クロック後)
                T_OUTC, T_OUTZ: begin
                    if (!mem_req) begin
                        if (!b_v && !c_v && !d_v) begin
                            mem_req  <= 1'b1;
                            mem_we   <= 1'b1;
                            mem_addr <= {((state == T_OUTZ) ? z_base : draw_base) + 13'({ty[2:0], r}), tx, 4'd0};
                            mem_len  <= 9'd16;
                        end
                    end else begin
                        if (mem_wnext) w_cur <= w_cur + 4'd1;
                        if (mem_ack) begin
                            mem_req <= 1'b0;
                            w_cur   <= '0;
                            if (6'(r) == rows - 6'd1) begin
                                r <= '0;
                                if (state == T_OUTC && write_z) state <= T_OUTZ;
                                else                            state <= T_NEXTTILE;
                            end else begin
                                r <= r + 5'd1;
                            end
                        end
                    end
                end
                T_NEXTTILE: begin
                    if (tx == rtx1) begin
                        tx <= rtx0;
                        if (ty == rty1) state <= T_IDLE;
                        else begin ty <= ty + 4'd1; state <= T_TILE; end
                    end else begin
                        tx    <= tx + 4'd1;
                        state <= T_TILE;
                    end
                end
                default: state <= T_IDLE;
            endcase
        end
    end
endmodule
