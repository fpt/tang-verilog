// Mode 7 レイヤ (E7): 乱数の VRAM とパレットで、乱数の設定 (行列・中心・スクロール・SX / SY・反転・マップの外・EXTBG・遠近) を
// 1 ラインずつ動かし、出てきたピクセルを参照の式 (bsnes と同じ clip と & ~63) と比べる
//   - 不透明なピクセルがちょうど 1 回ずつ、x の順に出る。透明 (値 0、EXTBG なら [6:0] が 0、マップの外で 2) は出ない
//   - 色はパレット、優先度は EXTBG の [7]
//   - 時間: setup から ready まで、start から busy が落ちるまで (1 ピクセル 2 クロック)
`timescale 1ns/1ps
module tb_mode7_layer;
    localparam int SRC_W = 320;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic [13:0] vram_raddr;
    logic [31:0] vram_q;
    logic [8:0]  pal_raddr;
    logic [15:0] pal_q;
    logic        setup = 0, start = 0, busy;
    logic [7:0]  line = '0;
    logic [1:0]  flip = '0, over = '0;
    logic        extbg = 0, persp = 0;
    logic [15:0] a = 16'h0100, b = '0, c = '0, d = 16'h0100, z = '0;
    logic [12:0] x0 = '0, y0 = '0, hofs = '0, vofs = '0;
    logic [9:0]  sx = '0;
    logic [8:0]  sy = '0;
    logic [13:0] map_base = 14'h0000, pat_base = 14'h1000;
    logic [7:0]  next_word;
    logic        px_valid, px_pri;
    logic [8:0]  px_x;
    logic [15:0] px_color;

    mode7_layer #(.SRC_W(SRC_W)) dut (.*);

    logic [31:0] vram [0:16383];
    logic [15:0] pal  [0:511];
    always_ff @(posedge clk) begin
        vram_q <= vram[vram_raddr];
        pal_q  <= pal[pal_raddr];
    end

    // ---------------------------------------------------------------- 参照
    function automatic int sext(input int v, input int bits);
        return (v & (1 << (bits - 1))) ? v - (1 << bits) : v;
    endfunction
    function automatic int clip(input int n);
        return (n & 'h2000) ? (n | ~1023) : (n & 1023);
    endfunction
    function automatic int vbyte(input int byte_addr);
        logic [31:0] w;
        w = vram[(byte_addr >> 2) & 16383];
        return (w >> (8 * (byte_addr & 3))) & 255;
    endfunction

    int exp_v [0:SRC_W-1];          // 1 なら不透明
    int exp_c [0:SRC_W-1];
    int exp_p [0:SRC_W-1];
    task automatic reference;
        int ea, eb, ec, ed, h, v, yy, xs, ox, oy, i, xx, px, py, oob, t, pix, xa, ya;
        if (persp) begin
            ea = sext(((z * sext(a, 16)) >>> 14) & 'hFFFF, 16);
            eb = sext(((z * sext(b, 16)) >>> 14) & 'hFFFF, 16);
            ec = sext((-eb) & 'hFFFF, 16);
            ed = ea;
        end else begin
            ea = sext(a, 16); eb = sext(b, 16); ec = sext(c, 16); ed = sext(d, 16);
        end
        h  = clip(sext(hofs, 13) - sext(x0, 13));
        v  = clip(sext(vofs, 13) - sext(y0, 13));
        yy = int'(line) - sext(sy, 9);
        if (flip[1]) yy = 255 - yy;
        xs = flip[0] ? 255 + sext(sx, 10) : -sext(sx, 10);
        ox = ((ea * h) & ~63) + ((eb * v) & ~63) + ((eb * yy) & ~63) + (sext(x0, 13) << 8);
        oy = ((ec * h) & ~63) + ((ed * v) & ~63) + ((ed * yy) & ~63) + (sext(y0, 13) << 8);
        for (i = 0; i < SRC_W; i++) begin
            xx = flip[0] ? xs - i : xs + i;
            xa = ox + ea * xx;
            ya = oy + ec * xx;
            px = xa >>> 8;
            py = ya >>> 8;
            oob = ((px | py) & ~1023) != 0;
            t = (over == 3 && oob) ? 0 : vbyte(int'(map_base) * 4 + ((py >> 3) & 127) * 128 + ((px >> 3) & 127));
            pix = vbyte(int'(pat_base) * 4 + t * 64 + (py & 7) * 8 + (px & 7));
            exp_v[i] = !(over == 2 && oob) && (extbg ? (pix & 127) != 0 : pix != 0);
            exp_c[i] = pal[extbg ? pix & 127 : pix];
            exp_p[i] = extbg && pix[7];
        end
    endtask

    // ---------------------------------------------------------------- 出力を集める
    int got_n, last_x, order_err;
    int got_c [0:SRC_W-1];
    int got_p [0:SRC_W-1];
    int got_cnt [0:SRC_W-1];
    logic [7:0] nw_prev;
    int nw_err;
    always @(posedge clk) begin
        if (px_valid) begin
            if (int'(px_x) <= last_x) order_err++;
            if (nw_prev != px_x[8:1]) nw_err++;
            last_x = px_x;
            got_c[px_x] = px_color;
            got_p[px_x] = px_pri;
            got_cnt[px_x]++;
            got_n++;
        end
        nw_prev <= next_word;
    end

    int errors = 0, setup_max = 0, pass_max = 0, lines = 0, opaque_total = 0;
    task automatic run_line(input string what);
        int k, cyc, e;
        got_n = 0; last_x = -1; order_err = 0; nw_err = 0;
        for (k = 0; k < SRC_W; k++) got_cnt[k] = 0;
        reference();
        @(negedge clk) setup = 1;
        @(negedge clk) setup = 0;
        cyc = 1;
        while (!dut.ready) begin @(negedge clk); cyc++; end
        if (cyc > setup_max) setup_max = cyc;
        start = 1;
        @(negedge clk) start = 0;
        cyc = 1;
        while (busy) begin @(negedge clk); cyc++; end
        if (cyc > pass_max) pass_max = cyc;
        e = 0;
        for (k = 0; k < SRC_W; k++) begin
            if (got_cnt[k] != exp_v[k] || (exp_v[k] && (got_c[k] != exp_c[k] || got_p[k] != exp_p[k]))) begin
                if (e < 3) $display("  %s line %0d x %0d: got n=%0d c=%h p=%0d, expected v=%0d c=%h p=%0d",
                                     what, line, k, got_cnt[k], got_c[k], got_p[k], exp_v[k], exp_c[k], exp_p[k]);
                e++;
            end
            opaque_total += exp_v[k];
        end
        if (order_err || nw_err) begin $display("  %s: order %0d next_word %0d", what, order_err, nw_err); e++; end
        errors += e;
        lines++;
    endtask

    initial begin
        int k, n;
        $dumpfile("build/sim/tb_mode7_layer.vcd");
        $dumpvars(0, tb_mode7_layer);
        for (k = 0; k < 16384; k++) vram[k] = $urandom;
        // タイル 0 の行 0 を透明に混ぜる (0 のピクセルも出てくるように)
        for (k = 0; k < 16; k++) vram[14'h1000 + k] = 32'h00FF0000 ^ ($urandom & 32'h7F007F00);
        for (k = 0; k < 512; k++) pal[k] = 16'(k * 40503 + 7);
        repeat (3) @(negedge clk);
        rst = 0;

        // 単位行列、スクロールだけ
        line = 8'd17; hofs = 13'd100; vofs = 13'd3;
        run_line("identity");
        // 90 度回転、2 倍、1/2
        a = 16'h0000; b = 16'h0100; c = 16'hFF00; d = 16'h0000; x0 = 13'd512; y0 = 13'd512;
        run_line("rot90");
        a = 16'h0080; b = 16'h0000; c = 16'h0000; d = 16'h0080; run_line("zoom2");
        a = 16'h0200; d = 16'h0200; run_line("half");
        // clip が効く大きなスクロール、マップの外の 3 モード、反転
        a = 16'h0100; d = 16'h0100; x0 = 13'h1F00; hofs = 13'h0700; vofs = 13'h1A00;
        for (k = 0; k < 4; k++) begin over = 2'(k); run_line("over"); end
        flip = 2'b11; run_line("flip");
        flip = 2'b00; extbg = 1; run_line("extbg"); extbg = 0;
        sx = 10'd32; sy = 9'd8; run_line("sx_sy");
        persp = 1; z = 16'h0180; a = 16'h2D41; b = 16'hD2BF; run_line("persp");

        // 乱数の掃引
        for (n = 0; n < 200; n++) begin
            line = 8'($urandom_range(0, 239));
            a = 16'($urandom); b = 16'($urandom); c = 16'($urandom); d = 16'($urandom);
            if (n % 3 == 0) begin a = 16'($signed(a) >>> 6); b = 16'($signed(b) >>> 6); c = 16'($signed(c) >>> 6); d = 16'($signed(d) >>> 6); end
            z = 16'($urandom);
            x0 = 13'($urandom); y0 = 13'($urandom); hofs = 13'($urandom); vofs = 13'($urandom);
            sx = 10'($urandom); sy = 9'($urandom);
            flip = 2'($urandom); over = 2'($urandom); extbg = 1'($urandom); persp = ($urandom_range(0, 3) == 0);
            map_base = 14'($urandom); pat_base = 14'($urandom);
            run_line("random");
        end

        $display("  %0d lines, %0d opaque pixels, setup %0d clk, pixel pass %0d clk", lines, opaque_total, setup_max, pass_max);
        if (setup_max > 200 || pass_max > 2 * SRC_W + 8) begin $display("  too slow"); errors++; end
        if (errors == 0) $display("PASS: tb_mode7_layer");
        else             $display("FAIL: tb_mode7_layer (%0d errors)", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("FAIL: tb_mode7_layer (timeout)");
        $finish;
    end
endmodule
