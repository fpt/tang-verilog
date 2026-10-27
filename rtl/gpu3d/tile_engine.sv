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
//   ピクセルの段 (G3・G4):
//     A  辺の判定、属性、テクセルの座標とワードアドレス、テクスチャのキャッシュのタグを見る。外れなら A を止めて 1 行 (8 ワード) を読む
//     B  キャッシュのワードからテクセルを取り出す (16bpp はそのまま、8 / 4bpp は CLUT を引く)
//     C  テクセルの色が決まる。タイルの Z を読む
//     D  透明 (テクセルの色 0)、Z を比べる、変調 (Gouraud なら頂点の色を掛ける、128 = 1 倍) の部分積
//     E  変調の部分積を足して飽和。タイルの色を読む (半透明で混ぜる相手)
//     F  Z を書く (半透明は書かない)。半透明なら色を混ぜる (flags [5:4]: 平均、加算、減算、1/4 加算)
//     G  色をタイルバッファに書く (書くデータは FF から)
//   半透明 (G4) は投入順に描く。シーンの外の TRI は描く面のタイルを読んでから描くので、即時でも描く面と混ざる
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
    // タイルの三角形の数 (tri_engine の cnt、cnt_raddr の 2 クロック後)
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
    // 書き出しの先読み: タイルバッファの読み出しの番号は FF から直接 (DP の BSRAM の B ポートのアドレスは nextpnr が
    // タイミングを見ないので、論理を挟まない)。番号を 1 段 FF に置くので、読んだワードは 2 クロック後に出る。3 ワードの FIFO に入れ、mem_wnext で出す
    logic [3:0]  ra;                                  // 次に読むワード
    logic [4:0]  o_issued;                            // この行で読んだワード数
    logic        o_qv1, o_qv;                         // 1 / 2 クロック前に読んだ (o_qv のとき cq / zq に出ている)
    logic [1:0]  o_cnt;                               // FIFO の数 (0..3)
    logic [31:0] o_f0, o_f1, o_f2;
    logic        o_pop, o_issue;
    logic [31:0] o_word;
    logic [8:0]  sw_i;                                // T_SWEEP の番号
    assign tile = 7'(ty) * 7'd10 + 7'(tx);
    assign cnt_raddr = tile;

    // ---- タイルバッファ (偶数の x と奇数の x を別に。番号は {行, x / 2}) ----
    logic [15:0] cb_e [0:511];
    logic [15:0] cb_o [0:511];
    logic [15:0] zb_e [0:511];
    logic [15:0] zb_o [0:511];
    logic [8:0]  zr_q, cr_q, wr_idx;                   // Z の読み出し、色の読み出し (どちらも FF)、準備と書き出しの書き込み
    // 書き込みも FF から (1 クロック遅れて書く): 色と Z の、偶数 / 奇数の書く印、番号、データ
    logic        cw_e, cw_o, zw_e, zw_o;
    logic [8:0]  cw_a, zw_a;
    logic [15:0] cw_de, cw_do, zw_de, zw_do;
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
    logic               semi;                         // bit2 半透明 (G4)
    logic [1:0]         bmode;                        // [5:4] 半透明の式
    logic [15:0]        rflat;
    logic [8:0]         rbx0, rbx1;
    logic [7:0]         rby0, rby1;
    logic signed [20:0] rex [0:2];
    logic signed [20:0] rey [0:2];
    logic [31:0]        rgx [0:5];
    logic [31:0]        rgy [0:5];
    logic [1:0]         tfmt;                         // テクスチャ: 0 16bpp、1 8bpp、2 4bpp
    logic [7:0]         tclut;
    logic [7:0]         umask, vmask;                 // 幅 - 1、高さ - 1
    logic [1:0]         tsh;                          // 1 ワードのテクセル数の log2 (16bpp 1、8bpp 2、4bpp 3)
    logic [3:0]         tvs;                          // 1 行のワード数の log2 (幅の log2 - tsh)
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
    logic               mph;                          // 乗算を出すのは 2 クロックに 1 回 (smul36x18)
    logic [31:0]        macc;                         // 乗算の結果を足していく (組ごと)
    smul36x18 #(.TAG_W(5), .P_W(32)) u_mul (
        .clk, .rst, .in_valid(m_in_v), .a(m_a), .b(m_b), .in_tag(m_in_tag),
        .out_valid(m_out_v), .p(m_p), .out_tag(m_out_tag)
    );
    logic [8:0] dxp;
    logic [7:0] dyp;
    assign dxp = ox0 - rbx0;
    assign dyp = oy0 - rby0;
    always_comb begin
        int d;
        m_in_v = state == T_MUL && !mph;
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

    // テクセル: tu = (acc_u >>> 18) & (幅 - 1)、ワードアドレス = base | (tv << (幅の log2 - s)) | (tu >> s)
    // (base はテクスチャのワード数の倍数。足し算にすると桁上げがキャッシュの判定まで続いて 63MHz に届かなかった)
    // ワードアドレスは FF (taddr): 次のクロックに A 段にいるピクセルの u, v (ac の更新と同じ値) から 1 クロック前に作る。
    // キャッシュの判定、埋める行の番地とタグ、キャッシュの読み出しの番地がどれも同じ FF から出る (G5: 組み合わせのワードアドレスから
    // 同じクロックに mem_addr・tf_line・tf_tag を取っていたら、配置によって 1 行がほかの行のデータで埋まった。nextpnr の報告では間に合っていた)
    logic [2:0]  tu;
    logic [20:0] taddr;
    logic [3:0]  tline;
    logic [13:0] ttag;
    logic        t_hit, t_need;
    logic [31:0] acu_n, acv_n;
    logic [7:0]  tu_n, tv_n;
    assign tu    = ac[4][20:18] & umask[2:0];           // ワードの中のテクセルの位置 (B 段)
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
    assign tc_raddr = taddr[6:0];
    always_comb begin
        if (state == T_ROW) begin
            acu_n = ar[4]; acv_n = ar[5];
        end else if (state == T_WALK && !(t_need && !t_hit)) begin
            acu_n = ac[4] + rgx[4]; acv_n = ac[5] + rgx[5];
        end else begin
            acu_n = ac[4]; acv_n = ac[5];
        end
    end
    assign tu_n = acu_n[25:18] & umask;
    assign tv_n = acv_n[25:18] & vmask;
    always_ff @(posedge clk) taddr <= tbase | 21'(16'(tv_n) << tvs) | 21'(tu_n >> tsh);

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
    logic [7:0]  c_cla;                               // CLUT の番号 (FF から直接 CLUT を読む)
    logic [23:0] c_rgb;
    // ---- D 段: 透明、変調、Z ----
    logic        d_v, d_in, d_odd, d_txd;
    logic [8:0]  d_idx;
    logic [15:0] d_z, d_col, d_t16, d_tex565;
    logic [23:0] d_rgb;
    logic        d_pass;
    logic        d_mod;                               // 変調する
    logic [15:0] d_raw;                               // 変調しないときの色
    logic [10:0] d_plo [0:2];                         // 変調の部分積: テクセルの色 (6bit) の下位 3bit x 頂点の色 (8bit)
    logic [10:0] d_phi [0:2];                         //               上位 3bit x 頂点の色
    // ---- E 段: 部分積を足して飽和 (変調を 2 段に分けた。6bit x 8bit を 1 クロックで足すと実機で緑のビットが化けた。
    //            nextpnr の報告では間に合っていた) ----
    logic        e_v, e_zw, e_odd, e_mod;
    logic [8:0]  e_idx;
    logic [15:0] e_z, e_raw, e_out;
    logic [10:0] e_plo [0:2];
    logic [10:0] e_phi [0:2];
    // ---- F 段: Z を書く、半透明なら混ぜる ----
    logic        f_v, f_zw, f_odd;
    logic [8:0]  f_idx;
    logic [15:0] f_out, f_z, f_bg;
    // ---- G 段: 色を書く ----
    logic        g_v, g_odd;
    logic [8:0]  g_idx;
    logic [15:0] g_out;
    // 半透明 (raster.py の blend): 成分ごとに 0 平均 (B + F) >> 1、1 加算、2 減算、3 B + F / 4 (加算と減算は飽和)
    function automatic logic [15:0] blend565(input logic [1:0] m, input logic [15:0] b, input logic [15:0] f);
        logic [5:0]  bc, fc, fq, mx;
        logic [6:0]  sum;
        logic [15:0] o;
        o = '0;
        for (int i = 0; i < 3; i++) begin
            bc  = (i == 1) ? b[10:5] : (i == 0) ? {1'b0, b[15:11]} : {1'b0, b[4:0]};
            fc  = (i == 1) ? f[10:5] : (i == 0) ? {1'b0, f[15:11]} : {1'b0, f[4:0]};
            mx  = (i == 1) ? 6'd63 : 6'd31;
            fq  = (m == 2'd3) ? {2'b0, fc[5:2]} : fc;
            sum = 7'(bc) + 7'(fq);
            if (m == 2'd0)      sum = sum >> 1;
            else if (m == 2'd2) sum = (bc < fc) ? 7'd0 : 7'(bc - fc);
            else if (sum > 7'(mx)) sum = 7'(mx);
            if (i == 0)      o[15:11] = sum[4:0];
            else if (i == 1) o[10:5]  = sum[5:0];
            else             o[4:0]   = sum[4:0];
        end
        return o;
    endfunction
    // 小さい符号なしの乗算 (a x b、3bit x 8bit) をシフトと加算で。`*` だと yosys が DSP (MULT9X9) に置き、MULT18X18 と混ざると
    // nextpnr が配置できなかった (G3)
    function automatic logic [10:0] umul3x8(input logic [2:0] a, input logic [7:0] b);
        logic [10:0] p;
        p = '0;
        for (int i = 0; i < 3; i++) if (a[i]) p = p + (11'(b) << i);
        return p;
    endfunction
    assign d_tex565 = (tfmt == 2'd0) ? d_t16 : clq;
    always_comb begin
        logic [5:0] tc [0:2];
        tc[0] = {1'b0, d_tex565[15:11]};
        tc[1] = d_tex565[10:5];
        tc[2] = {1'b0, d_tex565[4:0]};
        for (int i = 0; i < 3; i++) begin
            d_plo[i] = umul3x8(tc[i][2:0], d_rgb[23 - 8 * i -: 8]);
            d_phi[i] = umul3x8(tc[i][5:3], d_rgb[23 - 8 * i -: 8]);
        end
        d_mod  = d_txd && gour;
        d_raw  = d_txd ? d_tex565 : d_col;
        d_pass = d_v && d_in && !(d_txd && d_tex565 == 16'd0) && (!zen || d_z < (d_odd ? zq_o : zq_e));
    end
    // (PS1 と同じく 128 = 1 倍): min(最大, (テクセル x 頂点の色) >> 7)、テクセル x 頂点の色 = 下位の部分積 + (上位の部分積 << 3)
    always_comb begin
        logic [6:0] m [0:2];
        for (int i = 0; i < 3; i++) m[i] = 7'((14'(e_plo[i]) + (14'(e_phi[i]) << 3)) >> 7);
        e_out = e_mod ? {m[0][6:5] != 2'd0 ? 5'd31 : m[0][4:0], m[1][6] ? 6'd63 : m[1][5:0], m[2][6:5] != 2'd0 ? 5'd31 : m[2][4:0]}
                      : e_raw;
    end

    // タイルバッファの読み出しの番号: 走査は C 段のピクセル、準備と書き出しは {行, ワード}
    logic [4:0] lx, ly;
    assign lx = 5'(x - tx0p);
    assign ly = 5'(y - ty0p);
    assign f_bg   = f_odd ? cq_o : cq_e;
    assign o_word  = (state == T_OUTZ) ? {zq_o, zq_e} : {cq_o, cq_e};
    assign o_pop   = mem_req && mem_wnext && (state == T_OUTC || state == T_OUTZ);
    // 走査の最後のピクセルが書き終わってから (書き込みと同じ番地を先に読まないように。書き込みは 1 クロック遅れるが、読み出しの番号も
    // 1 クロック遅れるので順は変わらない)。FIFO + 読んでいる分が 3 を超えないように
    assign o_issue = (state == T_OUTC || state == T_OUTZ) && !mem_ack && !b_v && !c_v && !d_v && !e_v && !f_v && !g_v && o_issued != 5'd16 &&
                     3'(o_cnt) + 3'(o_qv) + 3'(o_qv1) - 3'(o_pop) <= 3'd2;
    assign wr_idx = {r, w_cur};

    always_ff @(posedge clk) begin
        // 読み出しの番号: Z は次に C 段に入るピクセル、色は次に E 段に入るピクセル (半透明で混ぜる相手)、どちらもなければ書き出しの {行, ワード}
        zr_q <= b_v    ? b_idx : {r, ra};
        cr_q <= d_pass ? d_idx : {r, ra};
        cq_e <= cb_e[cr_q];
        cq_o <= cb_o[cr_q];
        zq_e <= zb_e[zr_q];
        zq_o <= zb_o[zr_q];
        lq   <= lbuf[k[5:0]];
        tq   <= tcache[tc_raddr];
        clq  <= clut[c_cla];
        if (clut_we) clut[clut_waddr] <= clut_wdata;
        if (state == T_TFILL && mem_req && mem_rvalid) tcache[{tf_line, tf_w}] <= mem_rdata;
        if (state == T_LFETCH && mem_req && mem_rvalid) lbuf[lw] <= mem_rdata[11:0];
        // 色 (書く印・番号・データを FF に置いて、次のクロックに書く)
        cw_e <= 1'b0; cw_o <= 1'b0;
        if (state == T_SWEEP) begin
            cw_e <= 1'b1; cw_o <= 1'b1; cw_a <= sw_i; cw_de <= ccol; cw_do <= ccol;
        end else if (state == T_LOADC && mem_req && mem_rvalid) begin
            cw_e <= 1'b1; cw_o <= 1'b1; cw_a <= wr_idx; cw_de <= mem_rdata[15:0]; cw_do <= mem_rdata[31:16];
        end else if (state == T_OUTC && mem_wnext && clear_color) begin
            cw_e <= 1'b1; cw_o <= 1'b1; cw_a <= wr_idx; cw_de <= ccol; cw_do <= ccol;
        end else if (g_v) begin
            cw_e <= !g_odd; cw_o <= g_odd; cw_a <= g_idx; cw_de <= g_out; cw_do <= g_out;
        end
        if (cw_e) cb_e[cw_a] <= cw_de;
        if (cw_o) cb_o[cw_a] <= cw_do;
        // Z
        zw_e <= 1'b0; zw_o <= 1'b0;
        if (state == T_SWEEP) begin
            zw_e <= 1'b1; zw_o <= 1'b1; zw_a <= sw_i; zw_de <= 16'hFFFF; zw_do <= 16'hFFFF;
        end else if (state == T_LOADZ && mem_req && mem_rvalid) begin
            zw_e <= 1'b1; zw_o <= 1'b1; zw_a <= wr_idx; zw_de <= mem_rdata[15:0]; zw_do <= mem_rdata[31:16];
        end else if (((state == T_OUTZ) || (state == T_OUTC && !write_z)) && mem_wnext && clear_z) begin
            zw_e <= 1'b1; zw_o <= 1'b1; zw_a <= wr_idx; zw_de <= 16'hFFFF; zw_do <= 16'hFFFF;
        end else if (f_zw) begin
            zw_e <= !f_odd; zw_o <= f_odd; zw_a <= f_idx; zw_de <= f_z; zw_do <= f_z;
        end
        if (zw_e) zb_e[zw_a] <= zw_de;
        if (zw_o) zb_o[zw_a] <= zw_do;
    end

    assign mem_wmask = 4'hF;
    assign mem_wdata = o_f0;
    assign busy = state != T_IDLE || start;

    // 書き出しの FIFO (行ごとに空から。mem_ack のクロックとほかの状態では空にする)
    always_ff @(posedge clk) begin
        if (rst || !(state == T_OUTC || state == T_OUTZ) || mem_ack) begin
            ra <= '0; o_issued <= '0; o_qv1 <= 1'b0; o_qv <= 1'b0; o_cnt <= '0;
        end else begin
            o_qv1 <= o_issue;
            o_qv  <= o_qv1;
            if (o_issue) begin ra <= ra + 4'd1; o_issued <= o_issued + 5'd1; end
            // 出す (先頭を詰める) → 入れる (詰めたあとの末尾に。同じ場所への代入はあとのものが勝つ)
            if (o_pop) begin o_f0 <= o_f1; o_f1 <= o_f2; end
            if (o_qv) begin
                unique case (2'(o_cnt - 2'(o_pop)))
                    2'd0:    o_f0 <= o_word;
                    2'd1:    o_f1 <= o_word;
                    default: o_f2 <= o_word;
                endcase
            end
            o_cnt <= 2'(o_cnt + 2'(o_qv) - 2'(o_pop));
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state   <= T_IDLE;
            mem_req <= 1'b0;
            mem_we  <= 1'b0;
            b_v <= 1'b0; c_v <= 1'b0; d_v <= 1'b0; e_v <= 1'b0; e_zw <= 1'b0; f_v <= 1'b0; f_zw <= 1'b0; g_v <= 1'b0;
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

            // B → C → D → E → F → G (いつも進む。A が止まっているあいだは空が流れる)
            c_v <= b_v; c_in <= b_in; c_odd <= b_odd; c_txd <= b_txd; c_idx <= b_idx;
            c_z <= b_z; c_col <= b_col; c_rgb <= b_rgb; c_t16 <= b_t16; c_cla <= cl_raddr;
            d_v <= c_v; d_in <= c_in; d_odd <= c_odd; d_txd <= c_txd; d_idx <= c_idx;
            e_v <= d_pass; e_zw <= d_pass && zen && !semi; e_odd <= d_odd; e_idx <= d_idx; e_z <= d_z;
            e_mod <= d_mod; e_raw <= d_raw;
            for (int i = 0; i < 3; i++) begin e_plo[i] <= d_plo[i]; e_phi[i] <= d_phi[i]; end   // (Icarus Verilog は配列ごとの代入を通さない)
            f_v <= e_v; f_zw <= e_zw; f_odd <= e_odd; f_idx <= e_idx; f_z <= e_z; f_out <= e_out;
            g_v <= f_v; g_odd <= f_odd; g_idx <= f_idx; g_out <= semi ? blend565(bmode, f_bg, f_out) : f_out;
            d_z <= c_z; d_col <= c_col; d_rgb <= c_rgb;
            d_t16 <= c_t16;
            b_v <= 1'b0;

            // 乗算の結果を足す (辺の値と属性。どちらも 32bit で回る)
            if (m_out_v) begin
                // 置き場所ごとの 2 つの積は続けて出るので、加算器 1 つで: 1 つ目はレコードの e / s (er / ar に読んである) に、2 つ目はその和に足す
                logic [3:0]  dd;
                logic [31:0] val;
                dd  = m_out_tag[3:0];
                val = (m_out_tag[4] ? ((dd < 4'd3) ? 32'(er[2'(dd)]) : ar[3'(dd - 4'd3)]) : macc) + m_p;
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
                T_CNT: state <= T_CNT2;                     // cnt_q は tile の 2 クロック後 (T_TILE で tile が決まっている)
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
                                semi <= mem_rdata[26]; bmode <= mem_rdata[29:28];
                            end else if (ridx == 5'd1) begin
                                rbx0 <= mem_rdata[8:0]; rbx1 <= mem_rdata[24:16];
                            end else if (ridx == 5'd2) begin
                                rby0 <= mem_rdata[7:0]; rby1 <= mem_rdata[23:16];
                            end else if (ridx < 5'd6)  er[2'(ridx - 5'd3)]  <= signed'(mem_rdata);   // 左上の値 (乗算の和を足していく)
                            else if (ridx < 5'd9)  rex[2'(ridx - 5'd6)] <= mem_rdata[20:0];
                            else if (ridx < 5'd12) rey[2'(ridx - 5'd9)] <= mem_rdata[20:0];
                            else if (ridx < 5'd18) ar[3'(ridx - 5'd12)]  <= mem_rdata;
                            else if (ridx < 5'd24) rgx[3'(ridx - 5'd18)] <= mem_rdata;
                            else if (ridx < 5'd30) rgy[3'(ridx - 5'd24)] <= mem_rdata;
                            else if (ridx == 5'd30) begin
                                logic [1:0] sh;
                                sh     = (mem_rdata[17:16] == 2'd0) ? 2'd1 : (mem_rdata[17:16] == 2'd1) ? 2'd2 : 2'd3;
                                tfmt  <= mem_rdata[17:16]; tclut <= mem_rdata[15:8];
                                umask <= 8'((9'd1 << mem_rdata[7:4]) - 9'd1);
                                vmask <= 8'((9'd1 << mem_rdata[3:0]) - 9'd1);
                                tsh   <= sh;
                                tvs   <= mem_rdata[7:4] - 4'(sh);
                            end else begin
                                tbase <= mem_rdata[20:0];
                            end
                        end
                        if (mem_ack) begin
                            mem_req <= 1'b0;
                            mk      <= '0;
                            mph     <= 1'b0;
                            mdone   <= '0;
                            state   <= T_MUL;
                        end
                    end
                end
                // 重なりの左上: er = e + ex dx + ey dy、ar = s + gx dx + gy dy (乗算 18 回を足していく)
                T_MUL: begin
                    mph <= !mph;
                    if (!mph) begin
                        mk <= mk + 5'd1;
                        if (mk == 5'd17) state <= T_MULW;
                    end
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
                        b_sub  <= tu;
                        walked <= walked + 32'd1;
                        for (int i = 0; i < 3; i++) ec[i] <= ec[i] + 32'(rex[i]);
                        for (int j = 0; j < 4; j++) ac[j] <= ac[j] + rgx[j];
                        ac[4] <= acu_n; ac[5] <= acv_n;          // (ワードアドレスと同じ加算器)
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
                // タイルの色 (と Z) を書く。1 行 16 ワード (走査の最後のピクセルが書き終わってから。G 段は 6 クロック後)
                T_OUTC, T_OUTZ: begin
                    if (!mem_req) begin
                        if (o_cnt == 2'd3) begin
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
