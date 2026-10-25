// 三角形の即時描画 (G1、rtl/gpu3d/tri_engine.sv): SDRAM の代わりのメモリ (返すまでの時間は乱数) で、描いた結果のピクセルを確かめる
//   - 矩形を 2 つに割った三角形が、ちょうどその矩形を塗る (外は書かない)。行の残りが 1 ワードになる幅 (65 ワード = 130 ピクセル) も
//   - Z: 奥の三角形は Z バッファより大きいので描かれず、手前のものは描かれて Z を書く。同じ Z は先に描いたものが残る
//   - Gouraud: 頂点の色に近い色が頂点のそばに出る
//   - クリップ矩形の外は書かない
//   細かい値 (端のピクセル、補間の丸め) はシナリオ (raster.py と CRC で比べる) で確かめている
`timescale 1ns/1ps
module tb_tri_engine;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic        push = 0, go = 0, busy;
    logic [31:0] word = '0;
    logic [12:0] draw_base = 13'd16, z_base = 13'd400;
    logic [8:0]  cx0 = 0, cx1 = 319;
    logic [7:0]  cy0 = 0, cy1 = 239;
    logic        mem_req, mem_we, mem_ack = 0, mem_wnext, mem_rvalid = 0;
    logic [20:0] mem_addr;
    logic [8:0]  mem_len;
    logic [31:0] mem_wdata, mem_rdata = '0;
    logic [3:0]  mem_wmask;
    logic [31:0] walked, drawn, cycles;
    tri_engine dut (.*);

    // SDRAM の代わり: sdram_ctrl と同じ約束 (書き込みは wnext で 1 ワードずつ、ack は最後のワードの次のクロック)
    logic [31:0] mem [0:262143];                     // 1M バイト (描く面と Z バッファが入る)
    logic wn = 0;
    assign mem_wnext = wn;
    always begin
        @(negedge clk);
        if (mem_req && !mem_ack) begin
            int n;
            logic [20:0] a;
            n = int'(mem_len);
            a = mem_addr;
            repeat ($urandom_range(2, 20)) @(negedge clk);
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

    function automatic logic [15:0] px(input logic [12:0] base, input int x, input int y);
        int a;
        a = (int'(base) + y) * 256 + x / 2;
        return (x % 2) ? mem[a][31:16] : mem[a][15:0];
    endfunction
    task automatic fill_mem(input logic [12:0] base, input logic [15:0] v);
        for (int y = 0; y < 240; y++)
            for (int x = 0; x < 160; x++) mem[(int'(base) + y) * 256 + x] = {v, v};
    endtask

    // TRI を送る (座標はピクセル。12.4 にする)
    task automatic send(input logic [7:0] flags, input logic [15:0] col, input int x[3], input int y[3],
                        input logic [23:0] rgb[3], input logic [15:0] z[3]);
        @(negedge clk); push = 1; word = {8'h20, flags, col};
        for (int i = 0; i < 3; i++) begin
            @(negedge clk); word = {16'(y[i] * 16), 16'(x[i] * 16)};
            if (flags[0]) begin @(negedge clk); word = {8'h00, rgb[i]}; end
            if (flags[3]) begin @(negedge clk); word = {16'h0, z[i]}; end
        end
        @(negedge clk); push = 0; go = 1;
        @(negedge clk); go = 0;
        while (busy) @(negedge clk);
    endtask

    int errors = 0;
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
        $dumpfile("build/sim/tb_tri_engine.vcd");
        $dumpvars(0, tb_tri_engine);
        repeat (3) @(negedge clk);
        rst = 0;
        fill_mem(draw_base, 16'h0000);
        fill_mem(z_base, 16'hFFFF);
        cs = '{24'h0, 24'h0, 24'h0};
        zs = '{16'd0, 16'd0, 16'd0};

        // 矩形を 2 つに割る: 幅 130 ピクセル (65 ワード、64 ワードのバーストのあと 1 ワード)
        xs = '{10, 140, 140}; ys = '{20, 20, 50}; send(8'h00, 16'h1234, xs, ys, cs, zs);
        xs = '{10, 140, 10};  ys = '{20, 50, 50}; send(8'h00, 16'h1234, xs, ys, cs, zs);
        expect_rect("rect 130 x 30", 10, 20, 130, 30, 16'h1234, 16'h0000);
        // 1 つの三角形の行がちょうど 65 ワード (ピクセル 11..138 = ワード 5..69): 最後のワードも書く
        xs = '{10, 140, 75}; ys = '{60, 60, 90}; send(8'h00, 16'h4321, xs, ys, cs, zs);
        if (px(draw_base, 138, 60) !== 16'h4321 || px(draw_base, 11, 60) !== 16'h4321 || px(draw_base, 139, 60) !== 16'h0000) begin
            $display("  65-word row: %h %h %h", px(draw_base, 11, 60), px(draw_base, 138, 60), px(draw_base, 139, 60)); errors++;
        end
        // 奇数の位置から、逆向き
        xs = '{201, 201, 258}; ys = '{100, 141, 141}; send(8'h00, 16'h5555, xs, ys, cs, zs);
        xs = '{201, 258, 258}; ys = '{100, 141, 100}; send(8'h00, 16'h5555, xs, ys, cs, zs);
        expect_rect("rect odd x, both windings", 201, 100, 57, 41, 16'h5555, 16'h0000);

        // Z: 手前 (z 1000) を描いてから、奥 (z 2000) と同じ z (1000) を重ねる → 手前の色のまま。もっと手前 (500) は上に出る
        zs = '{16'd1000, 16'd1000, 16'd1000};
        xs = '{20, 80, 80}; ys = '{150, 150, 200}; send(8'h08, 16'hAAAA, xs, ys, cs, zs);
        xs = '{20, 80, 20}; ys = '{150, 200, 200}; send(8'h08, 16'hAAAA, xs, ys, cs, zs);
        zs = '{16'd2000, 16'd2000, 16'd2000};
        xs = '{0, 100, 0}; ys = '{140, 140, 239}; send(8'h08, 16'hBBBB, xs, ys, cs, zs);
        zs = '{16'd1000, 16'd1000, 16'd1000};
        xs = '{0, 100, 100}; ys = '{140, 140, 239}; send(8'h08, 16'hCCCC, xs, ys, cs, zs);
        if (px(draw_base, 50, 175) !== 16'hAAAA || px(draw_base, 30, 190) !== 16'hAAAA) begin
            $display("  Z: farther or equal z overwrote (%h %h)", px(draw_base, 50, 175), px(draw_base, 30, 190)); errors++;
        end
        if (px(draw_base, 5, 145) !== 16'hBBBB || px(z_base, 5, 145) !== 16'd2000) begin
            $display("  Z: empty area not drawn (%h z %0d)", px(draw_base, 5, 145), px(z_base, 5, 145)); errors++;
        end
        zs = '{16'd500, 16'd500, 16'd500};
        xs = '{40, 60, 40}; ys = '{160, 160, 180}; send(8'h08, 16'hDDDD, xs, ys, cs, zs);
        if (px(draw_base, 42, 162) !== 16'hDDDD || px(z_base, 42, 162) !== 16'd500) begin
            $display("  Z: nearer not drawn (%h z %0d)", px(draw_base, 42, 162), px(z_base, 42, 162)); errors++;
        end

        // Gouraud: 赤・緑・青の頂点のそば
        cs = '{24'hFF0000, 24'h00FF00, 24'h0000FF};
        xs = '{150, 310, 150}; ys = '{150, 150, 235}; send(8'h01, 16'h0000, xs, ys, cs, zs);
        begin
            logic [15:0] pr, pg, pb;
            pr = px(draw_base, 151, 151); pg = px(draw_base, 305, 151); pb = px(draw_base, 151, 232);
            if (pr[15:11] < 5'd28 || pg[10:5] < 6'd56 || pb[4:0] < 5'd28) begin
                $display("  Gouraud corners: %h %h %h", pr, pg, pb); errors++;
            end
        end

        // クリップ: 画面全体の三角形を (100, 5)-(120, 9) に
        fill_mem(draw_base, 16'h0000);
        cx0 = 9'd100; cx1 = 9'd120; cy0 = 8'd5; cy1 = 8'd9;
        xs = '{-100, 500, -100}; ys = '{-100, -100, 400}; send(8'h00, 16'h7777, xs, ys, cs, zs);
        expect_rect("clip", 100, 5, 21, 5, 16'h7777, 16'h0000);

        $display("  %0d pixels walked, %0d drawn, %0d cycles", walked, drawn, cycles);
        if (errors == 0) $display("PASS: tb_tri_engine");
        else             $display("FAIL: tb_tri_engine (%0d errors)", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL: tb_tri_engine (timeout)");
        $finish;
    end
endmodule
