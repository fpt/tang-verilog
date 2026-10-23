// タイル レイヤ: VRAM とパレットを乱数で埋め、いろいろな設定で 1 ラインを合成して、全ピクセルを参照の計算と比べる
//   - マップの幅 32 / 64 / 128、高さ 32 / 64 / 28 (SMS)、スクロール (タイルの途中から、マップの端で折り返す)
//   - タイル単位の左右反転・上下反転・パレット、パレットのバンク、ピクセルの値 0 は透明
//   - ピクセルは x = 0..SRC_W-1 の順に 1 つずつ出て、その 1 クロック前の next_word が x / 2
//   - 1 ラインの合成が 460 クロック以内に終わる
`timescale 1ns/1ps
module tb_tile_layer;
    localparam int SRC_W = 320;
    localparam int VW = 16384;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic        vram_we = 0, pal_we = 0, start = 0, busy;
    logic [13:0] vram_waddr = '0, map_base = '0, pat_base = '0;
    logic [31:0] vram_wdata = '0;
    logic [8:0]  pal_waddr = '0;
    logic [15:0] pal_wdata = '0;
    logic [7:0]  line = '0, next_word;
    logic [9:0]  scroll_x = '0, scroll_y = '0;
    logic [6:0]  ctrl = '0;
    logic        px_valid, px_opaque, px_pri;
    logic [8:0]  px_x;
    logic [15:0] px_color;

    logic [13:0] vram_raddr;
    logic [31:0] vram_q;
    logic [8:0]  pal_raddr;
    logic [15:0] pal_q;

    tile_layer #(.SRC_W(SRC_W)) dut (
        .clk, .rst, .vram_raddr, .vram_q, .pal_raddr, .pal_q,
        .start, .line, .scroll_x, .scroll_y, .map_base, .pat_base, .ctrl, .busy, .next_word,
        .px_valid, .px_x, .px_opaque, .px_pri, .px_color
    );

    // VRAM とパレット (line_compositor と同じ 1 クロック遅れの読み出し)
    logic [31:0] vram [0:VW-1];
    logic [15:0] pal  [0:511];
    always_ff @(posedge clk) begin
        if (vram_we) vram[vram_waddr] <= vram_wdata;
        if (pal_we)  pal[pal_waddr]   <= pal_wdata;
        vram_q <= vram[vram_raddr];
        pal_q  <= pal[pal_raddr];
    end

    logic [31:0] vram_ref [0:VW-1];
    logic [15:0] pal_ref  [0:511];
    int errors = 0, max_cycles = 0, lines = 0, opaque_px = 0, clear_px = 0;

    // 出てきたピクセル {不透明, 優先度, 色} を x ごとに集める
    logic [17:0] got_px [0:SRC_W-1];
    int          px_count = 0, order_errors = 0, expect_x = 0;
    logic [7:0]  next_d;
    always @(posedge clk) begin
        if (px_valid) begin
            if (int'(px_x) != expect_x || next_d != px_x[8:1]) order_errors++;
            got_px[px_x] <= {px_opaque, px_pri, px_color};
            expect_x++;
            px_count++;
        end
        next_d <= next_word;
    end

    // 参照: 画面の x の {不透明, 優先度, 色}
    function automatic logic [17:0] expect_px(input int x);
        int mw, rows, vx, vy, col, row, idx, ty, tx, nib;
        logic [15:0] e;
        logic [31:0] w;
        mw   = 32 << ctrl[1:0];
        rows = (ctrl[3:2] == 2'd3) ? 28 : 32 << ctrl[3:2];
        vx   = (x + int'(scroll_x)) % (mw * 8);
        vy   = (int'(line) + int'(scroll_y)) % (rows * 8);
        col  = vx / 8;
        row  = vy / 8;
        idx  = row * mw + col;
        w    = vram_ref[(int'(map_base) + idx / 2) % VW];
        e    = (idx % 2) ? w[31:16] : w[15:0];
        ty   = e[12] ? 7 - vy % 8 : vy % 8;
        tx   = e[11] ? 7 - vx % 8 : vx % 8;
        w    = vram_ref[(int'(pat_base) + int'(e[10:0]) * 8 + ty) % VW];
        nib  = int'(w >> (28 - 4 * tx)) & 15;
        return {nib != 0, e[15], pal_ref[{ctrl[6:4], e[14:13], 4'(nib)}]};
    endfunction

    task automatic run_line(input logic [7:0] ln);
        int cycles, x;
        logic [17:0] got, exp_v;
        line = ln;
        px_count = 0;
        expect_x = 0;
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
        if (px_count != SRC_W) begin $display("  line %0d: %0d pixels", ln, px_count); errors++; end
        for (x = 0; x < SRC_W; x++) begin
            got = got_px[x];
            exp_v = expect_px(x);
            if (got !== exp_v) begin
                if (errors < 10) $display("  ctrl %h scroll (%0d,%0d) line %0d x %0d: got %h, expected %h",
                                          ctrl, scroll_x, scroll_y, ln, x, got, exp_v);
                errors++;
            end
            if (exp_v[17]) opaque_px++; else clear_px++;
        end
    endtask

    task automatic config_lines(input logic [6:0] c, input int sx, input int sy, input int mb, input int pb);
        ctrl = c;
        scroll_x = 10'(sx);
        scroll_y = 10'(sy);
        map_base = 14'(mb);
        pat_base = 14'(pb);
        run_line(8'd0);
        run_line(8'd1);
        run_line(8'd7);
        run_line(8'd8);
        run_line(8'd100);
        run_line(8'd239);
    endtask

    initial begin
        int i;
        $dumpfile("build/sim/tb_tile_layer.vcd");
        $dumpvars(0, tb_tile_layer);
        repeat (3) @(negedge clk);
        rst = 0;

        // VRAM とパレットを乱数で埋める (ピクセルの値 0 = 透明も 1/16 で出る)
        for (i = 0; i < VW; i++) begin
            vram_ref[i] = $urandom;
            @(negedge clk);
            vram_we = 1; vram_waddr = 14'(i); vram_wdata = vram_ref[i];
        end
        for (i = 0; i < 512; i++) begin
            pal_ref[i] = 16'($urandom);
            @(negedge clk);
            vram_we = 0;
            pal_we = 1; pal_waddr = 9'(i); pal_wdata = pal_ref[i];
        end
        @(negedge clk) pal_we = 0;

        //            ctrl {bank, 高さ, 幅}     scroll_x scroll_y  map_base pat_base
        config_lines({3'd0, 2'd0, 2'd0},      0,       0,        14'h2000, 0);
        config_lines({3'd5, 2'd0, 2'd0},      13,      77,       14'h2000, 14'h0100);   // タイルの途中から
        config_lines({3'd2, 2'd0, 2'd0},      250,     250,      14'h3F00, 14'h1234);   // 端で折り返す (アドレスも)
        config_lines({3'd1, 2'd3, 2'd0},      100,     200,      14'h0800, 0);          // 28 タイル (224 で折り返す)
        config_lines({3'd7, 2'd1, 2'd1},      511,     300,      14'h1000, 14'h0040);   // 64 x 64
        config_lines({3'd3, 2'd2, 2'd2},      1000,    1023,     14'h0000, 14'h2000);   // 128 x 128

        if (max_cycles > 460) begin $display("  line took %0d cycles", max_cycles); errors++; end
        if (order_errors != 0) begin $display("  pixels out of order / next_word wrong: %0d", order_errors); errors++; end
        if (opaque_px == 0 || clear_px == 0) begin $display("  opaque %0d, clear %0d", opaque_px, clear_px); errors++; end
        $display("  %0d lines, max %0d cycles, opaque %0d / transparent %0d", lines, max_cycles, opaque_px, clear_px);

        if (errors == 0) $display("PASS: tb_tile_layer");
        else             $display("FAIL: tb_tile_layer (%0d errors)", errors);
        $finish;
    end
endmodule
