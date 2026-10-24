// ラインごとの合成: 小さい画面 (ソース 8x4 -> 出力 16x8) で確かめる
//   - ビットマップ レイヤ: 全ピクセルが 2 倍に引き伸ばされて出る。fb_base はフレームの途中で変えても次のフレームから
//   - ビットマップ レイヤを切ると背景色、透過色を有効にすると透過色のピクセルが背景色になる
//   - レジスタはラインの合成を始めるときに取り込む (line_start ごとに背景色を変えると、ラインごとに違う色になる)
//   - line_start / line_num が毎フレーム 0..H-1 の順に出る。mark_req で次のライン 0 のときだけ mark_toggle が変わる
//   - タイル レイヤ: 不透明なタイルのピクセルがビットマップ / 背景色の上に出て、値 0 のところは下が見える
//   - 順位: ビットマップの順位をタイル (低) より上にするとビットマップが上 (透過色のところからタイルが見える)、
//     タイルの優先度ビットが立つとタイルが上。ビットマップの順位 0 は何も書かない
//   - スプライト: 低優先はタイル (低) の上、タイル (高) の下。高優先は一番上。スプライト同士は OAM の前が勝つ (優先度によらない)。
//     負の x / y、2 タイル幅の左右反転、ラインの上限 (列の数)
//   - 面 B: 低優先は面 A (低) の下、高優先は面 A (低) の上。ウィンドウ (ライン全体) は面 A を隠して別のマップを出す。
//     横スクロールの表 (ラインごと) で面 A と面 B を別々にずらす
//   - 8bpp のビットマップ (K1): 1 ワードに 4 ピクセルのパレットの番号を、パレット (0..255) を引いて出す。透過色 (番号) のところは
//     背景色、順位 3 ならタイル (低) の上で、透過色のところからタイルが見える
//   - ライトマップ (K4): 出力の色に、セルの R, G, B の倍率を掛ける (min(最大値, (c * L) >> 4))。倍率 0・1 倍・上限で切れる値、背景色にも掛かる
//   - 霧 (E7): 行の倍率 LINE_MUL (セルの倍率と掛けて 63 で切る) と加算 LINE_ADD (各色で飽和)。ライトマップのあり / なし、
//     霧の表 (VRAM から 1 ラインに 1 語) でラインごとに違う値
//   - メモリが遅すぎると UNDERFLOW を数える
`timescale 1ns/1ps
module tb_line_compositor;
    localparam int SRC_W = 8, SRC_H = 4;
    // 1 ライン 40 クロック: 出力 2 ライン (1,600ns) = clk_sys 266 クロックに、スプライトの OAM の走査 (128) が入るように
    localparam int H_ACTIVE = 2 * SRC_W, H_FP = 2, H_SYNC = 2, H_BP = 20;
    localparam int V_ACTIVE = 2 * SRC_H, V_FP = 1, V_SYNC = 1, V_BP = 1;   // 11 ライン
    localparam int V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;
    localparam logic [12:0] BASE = 13'd3;
    localparam logic [12:0] OTHER = 13'd40;

    logic clk_sys = 0, clk_pix = 0, rst = 1;
    always #3 clk_sys = ~clk_sys;     // システムクロックのほうが速い (実機は 63MHz と 25.2MHz)
    always #10 clk_pix = ~clk_pix;

    logic [10:0] x;
    logic [9:0]  y;
    logic        de, hsync, vsync, frame_start;
    video_timing #(
        .H_ACTIVE(H_ACTIVE), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
        .V_ACTIVE(V_ACTIVE), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP)
    ) u_timing (.clk(clk_pix), .rst, .x, .y, .de, .hsync, .vsync, .frame_start);

    logic [12:0] fb_base = BASE;
    logic        base_latched;
    logic [15:0] bg_color = 16'h0000, bitmap_key = 16'h0000;
    logic [5:0]  layer_ctrl = 6'b000001;
    logic        light_we = 0;
    logic        xreg_we = 0;
    logic [4:0]  xreg_idx = '0;
    logic [15:0] xreg_data = '0;
    logic [13:0] tileb_map_base = 14'd64;
    logic [5:0]  win_v = '0;
    logic [1:0]  hs_mode = '0;
    localparam logic [13:0] BMAP = 14'd64, WMAP = 14'd128, HSB = 14'd256;
    logic [2:0]  bitmap_rank = 3'd1;
    logic        bitmap_fmt = 1'b0;
    logic        vram_we = 0, pal_we = 0;
    logic [13:0] vram_waddr = '0;
    logic [31:0] vram_wdata = '0;
    logic [8:0]  pal_waddr = '0;
    logic [15:0] pal_wdata = '0;
    logic        oam_we = 0;
    logic [9:0]  spr_line_px = 10'd320;
    localparam logic [13:0] PAT = 14'd512;     // タイル 0 の模様 (マップは 0 番地から、全部 0 = タイル 0)
    logic        mark_req = 0, mark_toggle, line_start;
    logic [7:0]  line_num;
    logic        mem_req, mem_ack = 0, mem_rvalid = 0;
    logic [20:0] mem_addr;
    logic [8:0]  mem_len;
    logic [31:0] mem_rdata = '0;
    logic [7:0]  underflow_count;
    logic [23:0] rgb;

    line_compositor #(.SRC_W(SRC_W), .SRC_H(SRC_H), .V_TOTAL(V_TOTAL), .VRAM_WORDS(1024)) dut (
        .clk_sys, .rst_sys(rst), .fb_base, .base_latched, .bg_color, .layer_ctrl, .bitmap_key, .bitmap_rank, .bitmap_fmt,
        .tile_scroll_x(10'd0), .tile_scroll_y(10'd0), .tile_map_base(14'd0), .tile_pat_base(PAT), .tile_ctrl(8'd0),
        .tileb_scroll_x(10'd0), .tileb_scroll_y(10'd0), .tileb_map_base, .tileb_pat_base(PAT), .tileb_ctrl(8'd0),
        .win_h(6'd0), .win_v, .win_map_base(WMAP), .hs_mode, .hs_base(HSB),
        .spr_pat_base(PAT), .spr_bank(4'd1), .spr_line_cols(spr_line_px[9:3]),
        .vram_we, .vram_waddr, .vram_wdata, .pal_we, .pal_waddr, .pal_wdata, .oam_we, .light_we, .xreg_we, .xreg_idx, .xreg_data,
        .mark_req, .mark_toggle, .line_start, .line_num,
        .mem_req, .mem_addr, .mem_len, .mem_ack, .mem_rvalid, .mem_rdata, .underflow_count,
        .clk_pix, .rst_pix(rst), .x, .y, .rgb
    );

    // ソース画像のピクセル (RGB565) と、それを 8bit に広げた値
    function automatic logic [15:0] pixel(input int px, input int py);
        return 16'((py * 8 + px) * 16'h0841 ^ (py << 13) ^ (px << 2));
    endfunction
    function automatic logic [23:0] expand(input logic [15:0] p);
        return {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};
    endfunction
    // 8bpp のビットマップ: ピクセルのパレットの番号と、パレットの色
    function automatic logic [7:0] idx8(input int px, input int py);
        return 8'((py * 8 + px) * 29 + 3);
    endfunction
    function automatic logic [15:0] pal8(input int i);
        return 16'(i * 16'h0123 ^ 16'h5A5A);
    endfunction
    // ライトマップの参照 (line_compositor.sv と同じ式)。l = {B, G, R} の倍率
    logic [17:0] light_l;
    function automatic logic [15:0] lit(input logic [15:0] c, input logic [17:0] l);
        int r, g, b;
        r = (int'(c[15:11]) * int'(l[5:0])) >> 4;
        g = (int'(c[10:5]) * int'(l[11:6])) >> 4;
        b = (int'(c[4:0]) * int'(l[17:12])) >> 4;
        return {5'((r > 31) ? 31 : r), 6'((g > 63) ? 63 : g), 5'((b > 31) ? 31 : b)};
    endfunction
    // 霧の参照: L_eff = min(63, (L_cell * L_line) >> 4)、色は lit のあとに各色で加算して飽和
    function automatic logic [17:0] leff(input logic [17:0] l, input logic [14:0] m);
        int r, g, b;
        r = (int'(l[5:0]) * int'(m[4:0])) >> 4;
        g = (int'(l[11:6]) * int'(m[9:5])) >> 4;
        b = (int'(l[17:12]) * int'(m[14:10])) >> 4;
        return {6'((b > 63) ? 63 : b), 6'((g > 63) ? 63 : g), 6'((r > 63) ? 63 : r)};
    endfunction
    function automatic logic [15:0] fog(input logic [15:0] c, input logic [17:0] l, input logic [14:0] m, input logic [15:0] k);
        logic [15:0] t;
        int r, g, b;
        t = lit(c, leff(l, m));
        r = int'(t[15:11]) + int'(k[15:11]);
        g = int'(t[10:5]) + int'(k[10:5]);
        b = int'(t[4:0]) + int'(k[4:0]);
        return {5'((r > 31) ? 31 : r), 6'((g > 63) ? 63 : g), 5'((b > 31) ? 31 : b)};
    endfunction
    logic [14:0] fog_mul = {5'd16, 5'd16, 5'd16};
    logic [15:0] fog_add = '0;
    bit          fog_light = 0;
    function automatic logic [14:0] tab_mul(input int ln);
        return {5'(ln * 7 + 3), 5'(31 - ln * 5), 5'(ln * 9 + 8)};
    endfunction
    function automatic logic [15:0] tab_add(input int ln);
        return 16'(16'h0841 * (ln * 5 + 1) + 16'h3000 * ln);
    endfunction
    task automatic write_xreg(input int idx, input logic [15:0] v);
        @(negedge clk_sys); xreg_we = 1; xreg_idx = 5'(idx); xreg_data = v;
        @(negedge clk_sys); xreg_we = 0;
    endtask
    task automatic write_light(input logic [17:0] l);         // セル 0 (この小さい画面はセル 1 つ)
        @(negedge clk_sys); light_we = 1; vram_waddr = 14'd0; vram_wdata = {10'd0, l[17:12], 2'd0, l[11:6], 2'd0, l[5:0]};
        @(negedge clk_sys); light_we = 0;
        light_l = l;
    endtask
    function automatic logic [15:0] line_color(input int n);
        return 16'(16'h1111 * (n + 1));
    endfunction
    // タイル 0 の模様: 行 r のピクセル i の値は (i + r) % 4 (0 = 透明)。パレットの色 n は 16'h7C00 + n
    function automatic logic [3:0] tile_nib(input int px, input int py);
        return 4'((px + py) % 4);
    endfunction
    function automatic logic [31:0] tile_row(input int py);
        logic [31:0] w;
        for (int i = 0; i < 8; i++) w[28 - 4 * i +: 4] = tile_nib(i, py);
        return w;
    endfunction

    // スプライトのタイル 1 の模様: 行 r のピクセル i の値は (i + 2r) % 3。タイル 2 は全部 3。
    // スプライトの色はパレットの {バンク 1, パレット p, 値 n} = 64 + 16p + n に 16'h0300 + 16p + n
    function automatic logic [3:0] spr_nib(input int px, input int py);
        return 4'((px + 2 * py) % 3);
    endfunction
    // OAM: エントリ 0 = (2, -2) 1x1 タイル 1 パレット 0 (優先度 s0_pri)、エントリ 1 = (-3, 0) 2x1 タイル 1 (列優先なので右の列が 2)、
    // 左右反転、パレット 1、高優先。ほかは無効
    localparam int S0_X = 2, S0_Y = -2, S1_X = -3;
    bit s0_pri = 0, tile_hi = 0;
    function automatic logic [31:0] oam_word(input int a);
        unique case (a)
            0: return {1'b1, 1'b0, 2'd0, 2'd0, 10'(S0_Y), 6'd0, 10'(S0_X)};
            1: return {16'd0, s0_pri, 2'd0, 1'b0, 1'b0, 11'd1};
            2: return {1'b1, 1'b0, 2'd0, 2'd1, 10'd0, 6'd0, 10'(S1_X)};
            3: return {16'd0, 1'b1, 2'd1, 1'b0, 1'b1, 11'd1};
            default: return 32'h0;
        endcase
    endfunction
    // 期待する色: スプライト (先に作業ラインに入る) → タイル → ビットマップ (順位 1)、順位の一番高いもの
    function automatic logic [15:0] mixed(input int sx, input int sy);
        logic [15:0] c, sc;
        int rank, srank, cols, nib;
        bit found;
        c = pixel(sx, sy);
        rank = 1;
        if (tile_nib(sx, sy) != 0 && (tile_hi ? 5 : 2) > rank) begin
            c = 16'h7C00 + 16'(tile_nib(sx, sy));
            rank = tile_hi ? 5 : 2;
        end
        cols = int'(spr_line_px) / 8;
        found = 0;
        if (cols >= 1 && sx >= S0_X && sx < S0_X + 8 && spr_nib(sx - S0_X, sy - S0_Y) != 0) begin
            found = 1; sc = 16'h0300 + 16'(spr_nib(sx - S0_X, sy - S0_Y)); srank = s0_pri ? 6 : 3;
        end
        if (!found && cols >= 2 && sx >= S1_X && sx < S1_X + 8) begin          // 左の列 = タイル 2 (全部 3)
            found = 1; sc = 16'h0310 + 16'd3; srank = 6;
        end
        if (!found && cols >= 3 && sx >= S1_X + 8 && sx < S1_X + 16) begin     // 右の列 = タイル 1 を左右反転
            nib = int'(spr_nib(7 - (sx - S1_X - 8), sy));
            if (nib != 0) begin found = 1; sc = 16'h0310 + 16'(nib); srank = 6; end
        end
        if (found && srank > rank) c = sc;
        return c;
    endfunction

    // 面 B / ウィンドウ / 横スクロールの表: 面 B のマップはタイル 1 (パレット 1、優先度 b_hi)、ウィンドウはタイル 1 (パレット 2)。
    // 色はパレットの {バンク 0, p, n} = 16p + n に 16'h7C00 + 16p + n。横スクロールの表は面 A を y、面 B を 2y ずらす
    bit b_hi = 0, win_on = 0, hs_on = 0;
    function automatic logic [15:0] planes(input int sx, input int sy);
        int ax, bx, nib;
        ax = hs_on ? (sx + sy) % 8 : sx;
        bx = hs_on ? (sx + 2 * sy) % 8 : sx;
        nib = int'(spr_nib(bx, sy));
        if (win_on) begin                                  // ウィンドウ (順位 2、スクロールしない) > 面 B (低)
            if (spr_nib(sx, sy) != 0) return 16'h7C20 + 16'(spr_nib(sx, sy));
            if (nib != 0) return 16'h7C10 + 16'(nib);
            return 16'h0123;
        end
        if (b_hi && nib != 0) return 16'h7C10 + 16'(nib);   // 面 B (高) > 面 A (低)
        if (tile_nib(ax, sy) != 0) return 16'h7C00 + 16'(tile_nib(ax, sy));
        if (nib != 0) return 16'h7C10 + 16'(nib);
        return 16'h0123;
    endfunction

    task automatic write_oam();
        for (int i = 0; i < 256; i++) begin
            @(negedge clk_sys); oam_we = 1; vram_waddr = 14'(i); vram_wdata = oam_word(i);
        end
        @(negedge clk_sys); oam_we = 0;
    endtask
    task automatic write_map(input logic [31:0] w);
        for (int i = 0; i < 16; i++) begin
            @(negedge clk_sys); vram_we = 1; vram_waddr = 14'(i); vram_wdata = w;
        end
        @(negedge clk_sys); vram_we = 0;
    endtask

    int errors = 0;

    // SDRAM の代わり: (fb_base + line) * 256 から len ワード。latency クロック待ってから返す
    int latency = 4;
    int requests = 0;
    int latches = 0;
    always begin
        int line, i;
        @(negedge clk_sys);
        if (mem_req && !mem_ack) begin
            requests++;
            line = int'(mem_addr >> 8) - int'(BASE);
            if (mem_addr >= 21'(int'(OTHER) << 8)) line = int'(mem_addr >> 8) - int'(OTHER) + 100;   // もう 1 つの面
            // リセット直後、最初にライン 0 で fb_base を取り込むまではフレームの面が決まっていないので見ない
            if (latches > 0 && (mem_addr[7:0] != 0 || (mem_len != 9'(SRC_W / 2) && mem_len != 9'(SRC_W / 4)) || line < 0 ||
                                (line >= SRC_H && line < 100))) begin
                $display("  bad request: addr %h len %0d", mem_addr, mem_len);
                errors++;
            end
            repeat (latency) @(negedge clk_sys);
            for (i = 0; i < int'(mem_len); i++) begin            // 8bpp なら SRC_W / 4 ワード
                mem_rvalid = 1;
                mem_rdata  = (mem_len == 9'(SRC_W / 4)) ? {idx8(4 * i + 3, line), idx8(4 * i + 2, line), idx8(4 * i + 1, line), idx8(4 * i, line)}
                                                        : {pixel(2 * i + 1, line), pixel(2 * i, line)};
                @(negedge clk_sys);
            end
            mem_rvalid = 0;
            mem_ack = 1;
            @(negedge clk_sys);
            mem_ack = 0;
        end
    end

    // line_start の順番: 前のラインの次 (最後の次は 0) であること
    int other_reqs = 0, line_events = 0, mark_flips = 0, line_order_errors = 0;
    int last_line = -1;
    logic req_d = 0, mark_d = 0;
    bit   per_line_bg = 0;
    always @(posedge clk_sys) begin
        if (base_latched) latches++;
        if (mem_req && !req_d && mem_addr >= 21'(int'(OTHER) << 8)) other_reqs++;   // 新しい要求だけ数える
        req_d <= mem_req;
        if (line_start) begin
            line_events++;
            if (last_line >= 0 && int'(line_num) != (last_line + 1) % SRC_H) line_order_errors++;
            last_line = int'(line_num);
            // ラインごとに背景色を変える: line_num の合成が始まったので、次のラインの色にしておく
            if (per_line_bg) bg_color <= line_color((int'(line_num) + 1) % SRC_H);
        end
        if (mark_toggle != mark_d) begin
            mark_flips++;
            if (!(line_start && line_num == 0)) begin
                $display("  mark_toggle changed outside line 0"); errors++;
            end
        end
        mark_d <= mark_toggle;
    end

    // 出力は x, y の 1 クロック後。mode: 0 = ビットマップ、1 = 背景色だけ (ラインごと)、2 = 透過色あり、
    // 3 = タイル + ビットマップ、4 = タイル + 背景色、5 = ビットマップ (透過色あり) が上でタイルが下、
    // 6 = スプライト + タイル + ビットマップ (mixed)、7 = 面 A + 面 B (+ ウィンドウ、横スクロールの表) + 背景色 (planes)、
    // 8 = 8bpp のビットマップ (透過色の番号 key8 は背景色)、9 = 8bpp (順位 3、透過色あり) が上でタイル (低) が下、
    // 10 = RGB565 のビットマップにライトマップ、11 = 背景色にライトマップ、12 = 霧 (レジスタ)、13 = 霧の表 (ラインごと)
    logic [10:0] x_d;
    logic [9:0]  y_d;
    logic        de_d;
    bit          check_on = 0;
    int          mode = 0, checked = 0;
    logic [15:0] key_px;
    logic [7:0]  key8;
    always @(posedge clk_pix) begin
        if (check_on && de_d) begin
            logic [15:0] e;
            int sx, sy;
            sx = int'(x_d) / 2;
            sy = int'(y_d) / 2;
            unique case (mode)
                0: e = pixel(sx, sy);
                1: e = line_color(sy);
                2: e = (pixel(sx, sy) == key_px) ? 16'hABCD : pixel(sx, sy);
                3: e = (tile_nib(sx, sy) != 0) ? 16'h7C00 + 16'(tile_nib(sx, sy)) : pixel(sx, sy);
                4: e = (tile_nib(sx, sy) != 0) ? 16'h7C00 + 16'(tile_nib(sx, sy)) : 16'h0123;
                6: e = mixed(sx, sy);
                7: e = planes(sx, sy);
                8: e = (idx8(sx, sy) == key8) ? 16'h0123 : pal8(idx8(sx, sy));
                9: e = (idx8(sx, sy) != key8) ? pal8(idx8(sx, sy)) :
                       (tile_nib(sx, sy) != 0) ? pal8(tile_nib(sx, sy)) : 16'h0123;
                10: e = lit(pixel(sx, sy), light_l);
                11: e = lit(16'hABCD, light_l);
                12: e = fog(pixel(sx, sy), fog_light ? light_l : {6'd16, 6'd16, 6'd16}, fog_mul, fog_add);
                13: e = fog(pixel(sx, sy), {6'd16, 6'd16, 6'd16}, tab_mul(sy), tab_add(sy));
                default: e = (pixel(sx, sy) != key_px) ? pixel(sx, sy) :
                             (tile_nib(sx, sy) != 0) ? 16'h7C00 + 16'(tile_nib(sx, sy)) : 16'h0123;
            endcase
            checked++;
            if (rgb !== expand(e)) begin
                if (errors < 10) $display("  mode %0d (%0d,%0d): got %06h, expected %06h (sprite limit %0d, s0_pri %0d, tile_hi %0d)",
                                          mode, x_d, y_d, rgb, expand(e), spr_line_px, s0_pri, tile_hi);
                errors++;
            end
        end
        x_d  <= x;
        y_d  <= y;
        de_d <= de;
    end

    task automatic check_frames(input int m, input int frames);
        mode = m;
        @(posedge frame_start);
        @(posedge frame_start);       // 設定を変えたあとの最初のフレームは見ない
        checked = 0;
        check_on = 1;
        repeat (frames) @(posedge frame_start);
        check_on = 0;
        if (checked != frames * H_ACTIVE * V_ACTIVE) begin $display("  mode %0d: checked %0d pixels", m, checked); errors++; end
    endtask

    initial begin
        int flips0;
        $dumpfile("build/sim/tb_line_compositor.vcd");
        $dumpvars(0, tb_line_compositor);
        repeat (3) @(negedge clk_pix);
        rst = 0;

        // ビットマップ レイヤ (既定)
        check_frames(0, 2);
        if (underflow_count != 0) begin $display("  unexpected underflow: %0d", underflow_count); errors++; end
        if (requests < 2 * SRC_H) begin $display("  only %0d line requests", requests); errors++; end

        // fb_base をフレームの途中 (ライン 3 の表示中) で変えても、そのフレームの残りは前の面のまま。次のフレームのライン 0 から新しい面
        other_reqs = 0;
        wait (y == 10'd3);
        fb_base = OTHER;
        wait (y == 10'(V_ACTIVE));
        if (other_reqs != 0) begin $display("  fb_base changed mid-frame: %0d requests to the other plane", other_reqs); errors++; end
        @(posedge frame_start);
        @(posedge frame_start);
        if (other_reqs < SRC_H) begin $display("  new plane not used after the frame: %0d requests", other_reqs); errors++; end
        fb_base = BASE;

        // ビットマップを切り、ラインごとに背景色を変える
        layer_ctrl = 2'b00;
        per_line_bg = 1;
        check_frames(1, 2);
        per_line_bg = 0;

        // ビットマップの透過色: ピクセル (1,1) と同じ色のところが背景色になる
        key_px = pixel(1, 1);
        bitmap_key = key_px;
        bg_color = 16'hABCD;
        layer_ctrl = 3'b011;
        check_frames(2, 2);
        layer_ctrl = 3'b001;

        // タイル レイヤ: パレットと模様を書き、ビットマップの上、背景色の上に出す
        for (int i = 0; i < 16; i++) begin
            @(negedge clk_sys); pal_we = 1; pal_waddr = 9'(i); pal_wdata = 16'h7C00 + 16'(i);
        end
        @(negedge clk_sys); pal_we = 0;
        for (int i = 0; i < 1024; i++) begin
            @(negedge clk_sys); vram_we = 1; vram_waddr = 14'(i);
            vram_wdata = (i >= int'(PAT) && i < int'(PAT) + 8) ? tile_row(i - int'(PAT)) : 32'h0;
        end
        @(negedge clk_sys); vram_we = 0;
        layer_ctrl = 3'b101;
        check_frames(3, 2);
        bg_color = 16'h0123;
        layer_ctrl = 3'b100;
        check_frames(4, 2);

        // 順位: ビットマップ 3 > タイル (低) 2。透過色のところだけタイル (またはその下の背景色) が見える
        bitmap_rank = 3'd3;
        layer_ctrl = 3'b111;
        check_frames(5, 2);
        // ビットマップの順位 0 は書かない: タイル + 背景色と同じ
        bitmap_rank = 3'd0;
        check_frames(4, 2);
        // マップの優先度ビットを立てる (タイル 5 > ビットマップ 3): タイルが上
        bitmap_rank = 3'd3;
        for (int i = 0; i < 16; i++) begin
            @(negedge clk_sys); vram_we = 1; vram_waddr = 14'(i); vram_wdata = 32'h8000_8000;
        end
        @(negedge clk_sys); vram_we = 0;
        layer_ctrl = 3'b101;
        check_frames(3, 2);
        bitmap_rank = 3'd1;
        layer_ctrl = 3'b001;

        // スプライト: パレット (バンク 1)、タイル 1・2、OAM
        for (int i = 0; i < 32; i++) begin
            @(negedge clk_sys); pal_we = 1; pal_waddr = 9'(64 + i); pal_wdata = 16'h0300 + 16'(i);
        end
        @(negedge clk_sys); pal_we = 0;
        for (int r = 0; r < 8; r++) begin
            logic [31:0] w;
            for (int i = 0; i < 8; i++) w[28 - 4 * i +: 4] = spr_nib(i, r);
            @(negedge clk_sys); vram_we = 1; vram_waddr = PAT + 14'(8 + r); vram_wdata = w;
            @(negedge clk_sys); vram_waddr = PAT + 14'(16 + r); vram_wdata = 32'h3333_3333;
        end
        @(negedge clk_sys); vram_we = 0;
        write_oam();
        write_map(32'h0);
        layer_ctrl = 4'b1101;
        check_frames(6, 2);           // スプライト 0 (低) はタイル (低) の上、スプライト 1 (高) より前
        tile_hi = 1;
        write_map(32'h8000_8000);
        check_frames(6, 2);           // タイル (高) はスプライト 0 (低) の上、スプライト 1 (高) の下
        s0_pri = 1;
        write_oam();
        check_frames(6, 2);           // スプライト 0 (高) が一番上
        spr_line_px = 10'd23;
        check_frames(6, 2);           // 上限 2 列: スプライト 1 の右の列は描かない
        spr_line_px = 10'd8;
        check_frames(6, 2);           // 上限 1 列: スプライト 0 だけ
        spr_line_px = 10'd0;
        check_frames(6, 2);           // 上限 0: スプライトなし
        spr_line_px = 10'd320;
        layer_ctrl = 4'b0001;

        // 面 B: パレット 16..47、面 A のマップは優先度なし、面 B・ウィンドウのマップ、横スクロールの表
        for (int i = 16; i < 48; i++) begin
            @(negedge clk_sys); pal_we = 1; pal_waddr = 9'(i); pal_wdata = 16'h7C00 + 16'(i);
        end
        @(negedge clk_sys); pal_we = 0;
        write_map(32'h0);
        for (int i = 0; i < 16; i++) begin
            @(negedge clk_sys); vram_we = 1; vram_waddr = BMAP + 14'(i); vram_wdata = 32'h2001_2001;      // タイル 1、パレット 1
            @(negedge clk_sys); vram_waddr = WMAP + 14'(i); vram_wdata = 32'h4001_4001;                   // タイル 1、パレット 2
        end
        for (int i = 0; i < SRC_H; i++) begin
            @(negedge clk_sys); vram_we = 1; vram_waddr = HSB + 14'(i);
            vram_wdata = {16'(-i), 16'(-2 * i)};                                                         // 面 A -y、面 B -2y
        end
        @(negedge clk_sys); vram_we = 0;
        bg_color = 16'h0123;
        layer_ctrl = 5'b10100;
        check_frames(7, 2);           // 面 A (低) > 面 B (低)
        b_hi = 1;
        for (int i = 0; i < 16; i++) begin
            @(negedge clk_sys); vram_we = 1; vram_waddr = BMAP + 14'(i); vram_wdata = 32'hA001_A001;
        end
        @(negedge clk_sys); vram_we = 0;
        check_frames(7, 2);           // 面 B (高) > 面 A (低)
        b_hi = 0;
        for (int i = 0; i < 16; i++) begin
            @(negedge clk_sys); vram_we = 1; vram_waddr = BMAP + 14'(i); vram_wdata = 32'h2001_2001;
        end
        @(negedge clk_sys); vram_we = 0;
        hs_on = 1; hs_mode = 2'd3;
        check_frames(7, 2);           // 横スクロールの表 (ラインごと)
        hs_on = 0; hs_mode = 2'd0;
        win_on = 1; win_v = 6'b100000;
        check_frames(7, 2);           // ウィンドウ (下、位置 0 = 全ライン)
        win_on = 0; win_v = '0;
        layer_ctrl = 5'b00001;

        // 8bpp のビットマップ: パレット 0..255 を書き、透過色をピクセル (1,1) の番号にする
        for (int i = 0; i < 256; i++) begin
            @(negedge clk_sys); pal_we = 1; pal_waddr = 9'(i); pal_wdata = pal8(i);
        end
        @(negedge clk_sys); pal_we = 0;
        key8 = idx8(1, 1);
        bitmap_key = {8'hFF, key8};            // 上位は使わない
        bitmap_fmt = 1;
        layer_ctrl = 5'b00011;
        check_frames(8, 2);
        write_map(32'h0);                      // タイル 0 (低優先) の上に、順位 3 で
        bitmap_rank = 3'd3;
        layer_ctrl = 5'b00111;
        check_frames(9, 2);
        bitmap_rank = 3'd1;
        bitmap_fmt = 0;
        layer_ctrl = 6'b000001;

        // ライトマップ: 倍率 {B, G, R}。上限で切れる R、1 倍の G、半分の B / 0 / 端数
        layer_ctrl = 6'b100001;
        write_light({6'd8, 6'd16, 6'd63});
        check_frames(10, 2);
        write_light({6'd0, 6'd41, 6'd23});
        check_frames(10, 2);
        bg_color = 16'hABCD;
        layer_ctrl = 6'b100000;
        write_light({6'd63, 6'd7, 6'd16});
        check_frames(11, 2);
        layer_ctrl = 6'b000001;

        // 霧: ライトマップあり (セル x 行で 63 を超えて切れる、加算の飽和)、なし (セルは 16)、霧の表
        layer_ctrl = 6'b100001;
        write_light({6'd40, 6'd63, 6'd5});
        fog_light = 1; fog_mul = {5'd31, 5'd20, 5'd9}; fog_add = 16'h8410;
        write_xreg(15, {1'b0, fog_mul}); write_xreg(16, fog_add);
        check_frames(12, 2);
        layer_ctrl = 6'b000001;
        fog_light = 0; fog_mul = {5'd4, 5'd16, 5'd0}; fog_add = 16'hFFFF ^ 16'h0820;
        write_xreg(15, {1'b0, fog_mul}); write_xreg(16, fog_add);
        check_frames(12, 2);
        for (int i = 0; i < SRC_H; i++) begin
            @(negedge clk_sys); vram_we = 1; vram_waddr = 14'h300 + 14'(i); vram_wdata = {tab_add(i), 1'b0, tab_mul(i)};
        end
        @(negedge clk_sys); vram_we = 0;
        write_xreg(18, 16'h0300); write_xreg(17, 16'h0001);
        check_frames(13, 2);
        write_xreg(17, 16'h0000); write_xreg(15, 16'h4210); write_xreg(16, 16'h0000);
        check_frames(0, 1);           // 既定に戻すと元のまま

        // line_start の順番と、印 (次のライン 0 で 1 回だけ)
        if (line_order_errors != 0) begin $display("  line_start out of order: %0d", line_order_errors); errors++; end
        if (line_events < 8 * SRC_H) begin $display("  only %0d line_start", line_events); errors++; end
        flips0 = mark_flips;
        @(negedge clk_sys); mark_req = 1; @(negedge clk_sys); mark_req = 0;
        repeat (3) @(posedge frame_start);
        if (mark_flips - flips0 != 1) begin $display("  mark flips after one mark_req: %0d", mark_flips - flips0); errors++; end

        // ここまで (スプライトを含めて) 合成は毎ライン間に合っている
        if (underflow_count != 0) begin $display("  underflow before the slow-memory test: %0d", underflow_count); errors++; end
        // メモリが出力 2 ライン分 (40 x 2 x 20ns = 1,600ns) より遅いと間に合わず、UNDERFLOW が増える
        latency = 400;
        @(posedge frame_start);
        @(posedge frame_start);
        if (underflow_count == 0) begin $display("  slow memory did not cause underflow"); errors++; end

        if (errors == 0) $display("PASS: tb_line_compositor");
        else             $display("FAIL: tb_line_compositor (%0d errors)", errors);
        $finish;
    end
endmodule
