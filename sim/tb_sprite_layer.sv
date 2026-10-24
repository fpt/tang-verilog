// スプライト: OAM・VRAM・パレットを乱数で埋め、いろいろなラインと上限で出てくるピクセルの列を参照の計算と比べる
//   - OAM の順、1 つのスプライトの中では x の順に、画面の中の不透明なピクセルだけが出る
//   - 大きさ 1〜4 タイル、左右・上下反転、セルの並び順 (列優先 / 16 タイル幅の表 / 行優先 (K2))、パレット、優先度、負の x / y と画面の外
//   - スプライトごとのバンク (bank[3] = 1 のとき、パレットの番号は {0, ワード 1 の [19:16], 値})
//   - ラインの上限 (line_px / 8 列、画面の外の列も数える)。0 ならなにも出ない
//   - next_word が 1 クロック前に x / 2。続けて出る 2 つのピクセルが同じワードの同じ側にならない
//   - 1 ラインの時間 (上限 320 ピクセルなら 700 クロック以内)
`timescale 1ns/1ps
module tb_sprite_layer;
    localparam int SRC_W = 320;
    localparam int VW = 16384;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic        oam_we = 0, start = 0, busy;
    logic [7:0]  oam_waddr = '0, line = '0, next_word;
    logic [31:0] oam_wdata = '0;
    logic [13:0] pat_base = '0, vram_raddr;
    logic [3:0]  bank = '0;
    logic [9:0]  line_px = 10'd320;
    logic [31:0] vram_q;
    logic [8:0]  pal_raddr;
    logic [15:0] pal_q;
    logic        px_valid, px_pri;
    logic [8:0]  px_x;
    logic [15:0] px_color;

    sprite_layer #(.SRC_W(SRC_W)) dut (
        .clk, .rst, .oam_we, .oam_waddr, .oam_wdata, .vram_raddr, .vram_q, .pal_raddr, .pal_q,
        .start, .line, .pat_base, .bank, .line_cols(line_px[9:3]), .busy, .next_word, .px_valid, .px_x, .px_pri, .px_color
    );

    // VRAM とパレット (line_compositor と同じ 1 クロック遅れの読み出し)。書き込みはテストベンチから直接
    logic [31:0] vram [0:VW-1];
    logic [15:0] pal  [0:511];
    always_ff @(posedge clk) begin
        vram_q <= vram[vram_raddr];
        pal_q  <= pal[pal_raddr];
    end
    logic [31:0] oam_ref [0:255];

    // 出てきたピクセル {優先度, 色} と x を順に集める
    localparam int MAXP = 2048;
    logic [8:0]  got_x [0:MAXP-1];
    logic [16:0] got_c [0:MAXP-1];
    int          got_n = 0, order_errors = 0;
    logic [7:0]  next_d;
    logic        prev_valid = 0;
    logic [8:0]  prev_x;
    always @(posedge clk) begin
        if (px_valid) begin
            if (next_d != px_x[8:1]) order_errors++;
            if (prev_valid && prev_x == px_x) order_errors++;      // 同じワードの同じ側が続く
            if (got_n < MAXP) begin
                got_x[got_n] <= px_x;
                got_c[got_n] <= {px_pri, px_color};
            end
            got_n++;
        end
        prev_valid <= px_valid;
        prev_x     <= px_x;
        next_d     <= next_word;
    end

    // 参照: ライン ln で出るピクセルの列
    logic [8:0]  exp_x [0:MAXP-1];
    logic [16:0] exp_c [0:MAXP-1];
    int          exp_n;
    int          hit_sprites = 0, clipped_cols = 0, limited_lines = 0;
    task automatic expect_line(input int ln);
        int cols, i, sx, sy, dy, w, h, ry, col, sc, tile, k, px, pi, nib;
        logic [31:0] w0, w1, pat;
        bit stop;
        exp_n = 0;
        cols = int'(line_px) / 8;
        stop = 0;
        for (i = 0; i < 128 && !stop; i++) begin
            w0 = oam_ref[2 * i];
            w1 = oam_ref[2 * i + 1];
            sx = int'(signed'(w0[9:0]));
            sy = int'(signed'(w0[25:16]));
            w  = int'(w0[27:26]) + 1;
            h  = int'(w0[29:28]) + 1;
            dy = ln - sy;
            if (!w0[31] || dy < 0 || dy >= h * 8) continue;
            hit_sprites++;
            ry = w1[12] ? h * 8 - 1 - dy : dy;
            for (col = 0; col < w; col++) begin
                if (cols == 0) begin stop = 1; limited_lines++; break; end
                cols--;
                sc = w1[11] ? w - 1 - col : col;
                if ({w0[10], w0[30]} == 2'd1)      tile = (((int'(w1[10:4]) + ry / 8) % 128) << 4) | ((int'(w1[3:0]) + sc) % 16);
                else if ({w0[10], w0[30]} == 2'd0) tile = (int'(w1[10:0]) + sc * h + ry / 8) % 2048;
                else                               tile = (int'(w1[10:0]) + (ry / 8) * w + sc) % 2048;
                pat = vram[(int'(pat_base) + tile * 8 + ry % 8) % VW];
                if (sx + col * 8 < 0 || sx + col * 8 + 7 >= SRC_W) clipped_cols++;
                for (k = 0; k < 8; k++) begin
                    px  = sx + col * 8 + k;
                    pi  = w1[11] ? 7 - k : k;
                    nib = int'(pat >> (28 - 4 * pi)) & 15;
                    if (px >= 0 && px < SRC_W && nib != 0) begin
                        exp_x[exp_n] = 9'(px);
                        exp_c[exp_n] = {w1[15], bank[3] ? pal[{1'b0, w1[19:16], 4'(nib)}] : pal[{bank[2:0], w1[14:13], 4'(nib)}]};
                        exp_n++;
                    end
                end
            end
        end
    endtask

    int errors = 0, max_cycles = 0, lines = 0, total_px = 0;
    task automatic run_line(input int ln);
        int cycles;
        line = 8'(ln);
        got_n = 0;
        @(negedge clk) start = 1;
        @(negedge clk) start = 0;
        cycles = 1;
        while (busy) begin
            @(negedge clk);
            cycles++;
        end
        if (cycles > max_cycles) max_cycles = cycles;
        lines++;
        @(negedge clk);
        expect_line(ln);
        total_px += exp_n;
        if (got_n != exp_n) begin
            if (errors < 10) $display("  limit %0d line %0d: %0d pixels, expected %0d", line_px, ln, got_n, exp_n);
            errors++;
        end else begin
            for (int i = 0; i < exp_n; i++) begin
                if (got_x[i] !== exp_x[i] || got_c[i] !== exp_c[i]) begin
                    if (errors < 10) $display("  limit %0d line %0d pixel %0d: x %0d %h, expected x %0d %h",
                                              line_px, ln, i, got_x[i], got_c[i], exp_x[i], exp_c[i]);
                    errors++;
                    break;
                end
            end
        end
    endtask

    // OAM を乱数で埋める (有効は en_pct %)。y は画面の少し外まで、x は -64..383
    task automatic fill_oam(input int en_pct);
        logic [31:0] w0, w1;
        for (int i = 0; i < 128; i++) begin
            w0 = $urandom;
            w0[31]    = ($urandom % 100) < en_pct;
            w0[25:16] = 10'($urandom_range(0, 300) - 40);
            w0[15:11] = '0;                  // [10] はセルの並び順の上位
            w0[9:0]   = 10'($urandom_range(0, 447) - 64);
            w1 = {12'h0, 4'($urandom), 16'($urandom)};
            oam_ref[2 * i]     = w0;
            oam_ref[2 * i + 1] = w1;
        end
        for (int i = 0; i < 256; i++) begin
            @(negedge clk); oam_we = 1; oam_waddr = 8'(i); oam_wdata = oam_ref[i];
        end
        @(negedge clk) oam_we = 0;
    endtask

    int max320 = 0;
    task automatic sweep(input int lim);
        int prev_max;
        prev_max = max_cycles;
        max_cycles = 0;
        line_px = 10'(lim);
        for (int ln = 0; ln < 240; ln += 7) run_line(ln);
        run_line(1);
        run_line(239);
        if (lim == 320 && max_cycles > max320) max320 = max_cycles;
        if (prev_max > max_cycles) max_cycles = prev_max;
    endtask

    initial begin
        $dumpfile("build/sim/tb_sprite_layer.vcd");
        $dumpvars(0, tb_sprite_layer);
        for (int i = 0; i < VW; i++) vram[i] = $urandom;
        for (int i = 0; i < 512; i++) pal[i] = 16'($urandom);
        repeat (3) @(negedge clk);
        rst = 0;

        // まばら (上限に届かない) と、混んでいる (上限で切れる)
        pat_base = 14'h0000; bank = 4'd0;
        fill_oam(15);
        sweep(320);
        pat_base = 14'h3F00; bank = 4'd5;      // パターンのアドレスが VRAM の端で折り返す
        fill_oam(100);
        sweep(320);
        sweep(13);                             // 1 列
        sweep(0);                              // なにも出ない
        sweep(1023);                           // 127 列
        pat_base = 14'h0100; bank = 4'd2;
        fill_oam(60);
        sweep(64);
        sweep(320);
        bank = 4'b1011;                        // スプライトごとのバンク ([2:0] は使わない)
        sweep(320);
        pat_base = 14'h3F80; bank = 4'b1000;
        fill_oam(100);
        sweep(320);
        sweep(1023);

        if (max320 > 700) begin $display("  line took %0d cycles with a 320 pixel limit", max320); errors++; end
        if (order_errors != 0) begin $display("  next_word wrong / same side twice: %0d", order_errors); errors++; end
        if (hit_sprites == 0 || clipped_cols == 0 || limited_lines == 0 || total_px == 0) begin
            $display("  weak test: %0d hits, %0d clipped columns, %0d limited lines, %0d pixels",
                     hit_sprites, clipped_cols, limited_lines, total_px);
            errors++;
        end
        $display("  %0d lines, max %0d cycles (320 px limit), %0d pixels, %0d sprite hits, %0d clipped cols, %0d limited lines",
                 lines, max320, total_px, hit_sprites, clipped_cols, limited_lines);

        if (errors == 0) $display("PASS: tb_sprite_layer");
        else             $display("FAIL: tb_sprite_layer (%0d errors)", errors);
        $finish;
    end
endmodule
