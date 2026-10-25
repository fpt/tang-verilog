// 3D GPU の描画部 (G1・G2、rtl/gpu3d/raster3d.sv): SDRAM の代わりのメモリ (返すまでの時間は乱数) で
//   - 同じ乱数の三角形 (単色 / Gouraud、Z あり / なし) を即時モードと TBDR (BEGIN_SCENE / END_SCENE) で描き、描く面と Z バッファが全部同じ
//     (即時: 面を消して Z を 0xFFFF にしてから。TBDR: 消す色 + clear_z + write_z)
//   - TBDR の読み込み (面と Z を消さずに) で、前に描いたものの上に重なる (即時で同じ順に描いたものと同じ)
//   - タイルの上限 (1 タイル 1,024 個) を超えると error が出る
//   - シーンの外の TRI (1 つだけのシーンとして描く): 矩形を 2 つに割った三角形がちょうどその矩形を塗る、Z の規則 (奥と同じ z は描かない)、
//     Gouraud の頂点のそばの色、クリップ矩形の外は書かない
`timescale 1ns/1ps
module tb_raster3d;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic        push = 0, go = 0, busy, error;
    logic [31:0] word = '0;
    // 描く面 0x1000.. と Z バッファ 0x70000.. (パラメータバッファ 0x20000.. とタイルのリスト 0x40000..0x54000 に重ならないように)
    logic [12:0] draw_base = 13'd16, z_base = 13'd1792;
    logic [8:0]  cx0 = 0, cx1 = 319;
    logic [7:0]  cy0 = 0, cy1 = 239;
    logic        mem_req, mem_we, mem_ack = 0, mem_rvalid = 0;
    logic [20:0] mem_addr;
    logic [8:0]  mem_len;
    logic [31:0] mem_wdata, mem_rdata = '0;
    logic [3:0]  mem_wmask;
    logic [31:0] st_bin, st_pairs, st_prep, st_fetch, st_mul, st_walk, st_out, st_walked, st_drawn;
    logic        wn = 0;
    logic        mem_wnext;
    assign mem_wnext = wn;
    raster3d dut (.*);

    // SDRAM の代わり (sdram_ctrl と同じ約束)
    logic [31:0] mem [0:524287];
    always begin
        @(negedge clk);
        if (mem_req && !mem_ack) begin
            int n;
            logic [20:0] a;
            n = int'(mem_len);
            a = mem_addr;
            repeat ($urandom_range(2, 12)) @(negedge clk);
            for (int i = 0; i < n; i++) begin
                if (mem_we) begin
                    wn = 1;
                    @(posedge clk);
                    for (int k = 0; k < 4; k++)
                        if (mem_wmask[k]) mem[int'(a) + i] = mem[int'(a) + i] & ~(32'hFF << 8 * k) | (mem_wdata & (32'hFF << 8 * k));
                    @(negedge clk);
                    wn = 0;
                end else begin
                    mem_rvalid = 1;
                    mem_rdata  = mem[int'(a) + i];
                    @(negedge clk);
                    mem_rvalid = 0;
                end
            end
            mem_ack = 1;
            @(negedge clk);
            mem_ack = 0;
        end
    end

    int errors = 0, err_pulses = 0;
    always @(posedge clk) if (error) err_pulses++;

    task automatic cmd1(input logic [31:0] w);           // 1 ワードのコマンド (BEGIN_SCENE / END_SCENE)
        @(negedge clk); push = 1; word = w;
        @(negedge clk); push = 0; go = 1;
        @(negedge clk); go = 0;
        while (busy) @(negedge clk);
    endtask

    // 三角形の列 (乱数、種を固定) を作っておき、同じものを 2 回送る
    localparam int NT = 120;
    logic [31:0] tw [0:NT-1][0:9];
    int          tn [0:NT-1];
    task automatic make_tris(input int seed);
        int s;
        s = seed;
        for (int t = 0; t < NT; t++) begin
            logic [7:0] fl;
            int cx, cy, sz, n;
            fl = {4'b0, 1'(t % 3 != 0), 3'b0} | 8'(t % 2);   // bit3 Z (3 つに 2 つ)、bit0 Gouraud (2 つに 1 つ)
            sz = (t % 5 == 0) ? 3000 : (t % 5 == 1) ? 120 : 600;
            cx = $urandom(s) % 5600 - 200; s = s + 1;
            cy = $urandom(s) % 4200 - 200; s = s + 1;
            n = 0;
            tw[t][n] = {8'h20, fl, 16'($urandom)}; n++;
            for (int v = 0; v < 3; v++) begin
                tw[t][n] = {16'(cy + int'($urandom % 32'(2 * sz)) - sz), 16'(cx + int'($urandom % 32'(2 * sz)) - sz)}; n++;
                if (fl[0]) begin tw[t][n] = {8'h0, 24'($urandom)}; n++; end
                if (fl[3]) begin tw[t][n] = {16'h0, 16'($urandom)}; n++; end
            end
            tn[t] = n;
        end
    endtask
    task automatic send_tris;
        for (int t = 0; t < NT; t++) begin
            for (int i = 0; i < tn[t]; i++) begin
                @(negedge clk); push = 1; word = tw[t][i];
            end
            @(negedge clk); push = 0; go = 1;
            @(negedge clk); go = 0;
            while (busy) @(negedge clk);
        end
    endtask

    // 面と Z の写し
    logic [31:0] ref_c [0:239][0:159];
    logic [31:0] ref_z [0:239][0:159];
    task automatic fill(input logic [12:0] base, input logic [31:0] v);
        for (int y = 0; y < 240; y++) for (int x = 0; x < 160; x++) mem[(int'(base) + y) * 256 + x] = v;
    endtask
    task automatic snap;
        for (int y = 0; y < 240; y++) for (int x = 0; x < 160; x++) begin
            ref_c[y][x] = mem[(int'(draw_base) + y) * 256 + x];
            ref_z[y][x] = mem[(int'(z_base) + y) * 256 + x];
        end
    endtask
    task automatic compare(input string what, input bit with_z);
        int bc, bz;
        bc = 0; bz = 0;
        for (int y = 0; y < 240; y++) for (int x = 0; x < 160; x++) begin
            if (mem[(int'(draw_base) + y) * 256 + x] !== ref_c[y][x]) bc++;
            if (with_z && mem[(int'(z_base) + y) * 256 + x] !== ref_z[y][x]) bz++;
        end
        if (bc != 0 || bz != 0) begin $display("  %s: %0d color words, %0d z words differ", what, bc, bz); errors++; end
    endtask

    // シーンの外の TRI 1 つ (ピクセルの座標、flags: bit0 Gouraud、bit3 Z)
    task automatic send_tri(input logic [7:0] fl, input logic [15:0] col, input int x[3], input int y[3],
                        input logic [23:0] rgb[3], input logic [15:0] z[3]);
        @(negedge clk); push = 1; word = {8'h20, fl, col};
        for (int i = 0; i < 3; i++) begin
            @(negedge clk); word = {16'(y[i] * 16), 16'(x[i] * 16)};
            if (fl[0]) begin @(negedge clk); word = {8'h00, rgb[i]}; end
            if (fl[3]) begin @(negedge clk); word = {16'h0, z[i]}; end
        end
        @(negedge clk); push = 0; go = 1;
        @(negedge clk); go = 0;
        while (busy) @(negedge clk);
    endtask
    function automatic logic [15:0] px(input logic [12:0] base, input int x, input int y);
        logic [31:0] w;
        w = mem[(int'(base) + y) * 256 + x / 2];
        return (x % 2) ? w[31:16] : w[15:0];
    endfunction
    task automatic expect_rect(input string what, input int x0, input int y0, input int w, input int h, input logic [15:0] c,
                               input logic [15:0] outside);
        int bad;
        bad = 0;
        for (int y = y0 - 2; y < y0 + h + 2; y++)
            for (int x = x0 - 2; x < x0 + w + 2; x++) begin
                if (x < 0 || y < 0 || x >= 320 || y >= 240) continue;
                if (px(draw_base, x, y) !== ((x >= x0 && x < x0 + w && y >= y0 && y < y0 + h) ? c : outside)) bad++;
            end
        if (bad != 0) begin $display("  %s: %0d pixels wrong", what, bad); errors++; end
    endtask

    initial begin
        int xs[3], ys[3];
        logic [23:0] cs[3];
        logic [15:0] zs[3];
        $dumpfile("build/sim/tb_raster3d.vcd");
        $dumpvars(0, tb_raster3d);
        repeat (3) @(negedge clk);
        rst = 0;

        // 0. シーンの外の TRI
        fill(draw_base, 32'h0); fill(z_base, 32'hFFFF_FFFF);
        cs = '{24'h0, 24'h0, 24'h0}; zs = '{16'd0, 16'd0, 16'd0};
        xs = '{10, 140, 140}; ys = '{20, 20, 50}; send_tri(8'h00, 16'h1234, xs, ys, cs, zs);
        xs = '{10, 140, 10};  ys = '{20, 50, 50}; send_tri(8'h00, 16'h1234, xs, ys, cs, zs);
        expect_rect("rect 130 x 30", 10, 20, 130, 30, 16'h1234, 16'h0000);
        zs = '{16'd1000, 16'd1000, 16'd1000};
        xs = '{20, 80, 80}; ys = '{150, 150, 200}; send_tri(8'h08, 16'hAAAA, xs, ys, cs, zs);
        xs = '{20, 80, 20}; ys = '{150, 200, 200}; send_tri(8'h08, 16'hAAAA, xs, ys, cs, zs);
        zs = '{16'd2000, 16'd2000, 16'd2000};
        xs = '{0, 100, 0}; ys = '{140, 140, 239}; send_tri(8'h08, 16'hBBBB, xs, ys, cs, zs);
        zs = '{16'd1000, 16'd1000, 16'd1000};
        xs = '{0, 100, 100}; ys = '{140, 140, 239}; send_tri(8'h08, 16'hCCCC, xs, ys, cs, zs);
        if (px(draw_base, 50, 175) !== 16'hAAAA || px(draw_base, 30, 190) !== 16'hAAAA) begin
            $display("  Z: farther or equal z overwrote (%h %h)", px(draw_base, 50, 175), px(draw_base, 30, 190)); errors++;
        end
        if (px(draw_base, 5, 145) !== 16'hBBBB || px(z_base, 5, 145) !== 16'd2000) begin
            $display("  Z: empty area not drawn (%h z %0d)", px(draw_base, 5, 145), px(z_base, 5, 145)); errors++;
        end
        cs = '{24'hFF0000, 24'h00FF00, 24'h0000FF};
        xs = '{150, 310, 150}; ys = '{150, 150, 235}; send_tri(8'h01, 16'h0000, xs, ys, cs, zs);
        begin
            logic [15:0] pr, pg, pb;
            pr = px(draw_base, 151, 151); pg = px(draw_base, 305, 151); pb = px(draw_base, 151, 232);
            if (pr[15:11] < 5'd28 || pg[10:5] < 6'd56 || pb[4:0] < 5'd28) begin
                $display("  Gouraud corners: %h %h %h", pr, pg, pb); errors++;
            end
        end
        fill(draw_base, 32'h0);
        cx0 = 9'd100; cx1 = 9'd120; cy0 = 8'd5; cy1 = 8'd9;
        xs = '{-100, 500, -100}; ys = '{-100, -100, 400}; send_tri(8'h00, 16'h7777, xs, ys, cs, zs);
        expect_rect("clip", 100, 5, 21, 5, 16'h7777, 16'h0000);
        cx0 = 0; cx1 = 319; cy0 = 0; cy1 = 239;

        // 1. 即時 (面を 0x1234 で、Z を 0xFFFF で) → 写し。TBDR (消す色 0x1234、clear_z、write_z) で同じに
        make_tris(11);
        fill(draw_base, 32'h1234_1234); fill(z_base, 32'hFFFF_FFFF);
        send_tris();
        snap();
        fill(draw_base, 32'hDEAD_BEEF); fill(z_base, 32'h0BAD_0BAD);
        cmd1({8'h25, 8'h07, 16'h1234});
        send_tris();
        cmd1({8'h26, 24'h0});
        compare("scene (clear) vs immediate", 1);
        $display("  scene: %0d pairs, tiles: prep %0d fetch %0d mul %0d walk %0d out %0d", st_pairs, st_prep, st_fetch, st_mul, st_walk, st_out);

        // 2. 読み込み: 今の面と Z の上に、別の三角形を即時と TBDR (消さない、write_z) で
        make_tris(23);
        snap();
        begin
            logic [31:0] save_c [0:239][0:159];
            logic [31:0] save_z [0:239][0:159];
            save_c = ref_c; save_z = ref_z;
            send_tris();                                 // 即時
            snap();
            for (int y = 0; y < 240; y++) for (int x = 0; x < 160; x++) begin      // 元に戻して TBDR
                mem[(int'(draw_base) + y) * 256 + x] = save_c[y][x];
                mem[(int'(z_base) + y) * 256 + x] = save_z[y][x];
            end
        end
        cmd1({8'h25, 8'h04, 16'h0});
        send_tris();
        cmd1({8'h26, 24'h0});
        compare("scene (load) vs immediate", 1);

        // 3. タイル 0 に 1,030 個 → 6 回の error
        err_pulses = 0;
        cmd1({8'h25, 8'h03, 16'h0});
        for (int t = 0; t < 1030; t++) begin
            @(negedge clk); push = 1; word = {8'h20, 8'h00, 16'hFFFF};
            @(negedge clk); word = {16'(32), 16'(32)};
            @(negedge clk); word = {16'(32), 16'(80)};
            @(negedge clk); word = {16'(80), 16'(32)};
            @(negedge clk); push = 0; go = 1;
            @(negedge clk); go = 0;
            while (busy) @(negedge clk);
        end
        cmd1({8'h26, 24'h0});
        if (err_pulses != 6) begin $display("  tile overflow: %0d error pulses (expected 6)", err_pulses); errors++; end

        if (errors == 0) $display("PASS: tb_raster3d");
        else             $display("FAIL: tb_raster3d (%0d errors)", errors);
        $finish;
    end

    initial begin
        #2_000_000_000;
        $display("FAIL: tb_raster3d (timeout)");
        $finish;
    end
endmodule
