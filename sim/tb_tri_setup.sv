// 三角形のセットアップ (G1、rtl/gpu3d/tri_setup.sv): tools/harness/raster.py の setup と同じ式の参照と、出力を全部比べる
//   - 乱数の三角形 (ガードバンド -512..+831 の中、大きいもの・小さいもの・細いもの)、両方の向き、乱数の色と z、乱数のクリップ矩形
//   - 面積 0 (同じ点、一直線)、画面の外、外接矩形がクリップ矩形と重ならない → empty
//   - 時間 (start から done まで)
`timescale 1ns/1ps
module tb_tri_setup;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic        start = 0, done, empty;
    logic [15:0] x0, y0, x1, y1, x2, y2;
    logic [23:0] c0, c1, c2;
    logic [15:0] z0, z1, z2;
    logic [31:0] t0, t1, t2;
    logic [8:0]  cx0 = 0, cx1 = 319;
    logic [7:0]  cy0 = 0, cy1 = 239;
    logic [8:0]  bx0, bx1;
    logic [7:0]  by0, by1;
    logic [2:0][31:0] e;
    logic [2:0][20:0] ex, ey;
    logic [5:0][31:0] s, gx, gy;
    tri_setup dut (.*);

    // ---------------------------------------------------------------- 参照 (raster.py の setup)
    longint rx [0:2], ry [0:2], ra [0:5][0:2];
    longint r_e [0:2], r_ex [0:2], r_ey [0:2], r_s [0:5], r_gx [0:5], r_gy [0:5];
    int     r_bx0, r_bx1, r_by0, r_by1;
    bit     r_empty;
    function automatic longint sat32(input longint v);
        if (v > 64'sh7FFFFFFF) return 64'sh7FFFFFFF;
        if (v < -64'sh80000000) return -64'sh80000000;
        return v;
    endfunction
    function automatic longint fdiv(input longint a, input longint b);     // 床の除算 (b > 0)
        longint q;
        q = a / b;
        if (a % b != 0 && a < 0) q = q - 1;
        return q;
    endfunction
    function automatic longint ashr(input longint a, input int n);
        return a >>> n;
    endfunction
    function automatic longint mn3(input longint a, input longint b, input longint c);
        longint m; m = a; if (b < m) m = b; if (c < m) m = c; return m;
    endfunction
    function automatic longint mx3(input longint a, input longint b, input longint c);
        longint m; m = a; if (b > m) m = b; if (c > m) m = c; return m;
    endfunction
    task automatic reference;
        longint area, t, sxx, syy, dx, dy, nx, ny, m, d1, d2;
        int n, i, j, ia, ib;
        area = (rx[1] - rx[0]) * (ry[2] - ry[0]) - (ry[1] - ry[0]) * (rx[2] - rx[0]);
        r_empty = 0;
        if (area == 0) begin r_empty = 1; return; end
        if (area < 0) begin
            t = rx[1]; rx[1] = rx[2]; rx[2] = t;
            t = ry[1]; ry[1] = ry[2]; ry[2] = t;
            for (j = 0; j < 6; j++) begin t = ra[j][1]; ra[j][1] = ra[j][2]; ra[j][2] = t; end
            area = -area;
        end
        r_bx0 = int'(ashr(mn3(rx[0], rx[1], rx[2]) + 7, 4));
        r_bx1 = int'(ashr(mx3(rx[0], rx[1], rx[2]) - 8, 4));
        r_by0 = int'(ashr(mn3(ry[0], ry[1], ry[2]) + 7, 4));
        r_by1 = int'(ashr(mx3(ry[0], ry[1], ry[2]) - 8, 4));
        if (r_bx0 < int'(cx0)) r_bx0 = cx0;
        if (r_bx1 > int'(cx1)) r_bx1 = cx1;
        if (r_by0 < int'(cy0)) r_by0 = cy0;
        if (r_by1 > int'(cy1)) r_by1 = cy1;
        if (r_bx0 > r_bx1 || r_by0 > r_by1) begin r_empty = 1; return; end
        sxx = r_bx0 * 16 + 8;
        syy = r_by0 * 16 + 8;
        for (i = 0; i < 3; i++) begin
            ia = (i + 1) % 3; ib = (i + 2) % 3;
            dx = rx[ib] - rx[ia]; dy = ry[ib] - ry[ia];
            r_e[i] = dx * (syy - ry[ia]) - dy * (sxx - rx[ia]) + ((dy < 0 || (dy == 0 && dx > 0)) ? 0 : -1);
            r_ex[i] = -dy * 16;
            r_ey[i] = dx * 16;
        end
        n = 0;
        for (i = 0; i < 40; i++) if (area >= (64'sd1 <<< i)) n = i + 1;
        m = fdiv((64'sd1 <<< (n + 16)) - 1, area);
        for (j = 0; j < 6; j++) begin
            d1 = ra[j][1] - ra[j][0]; d2 = ra[j][2] - ra[j][0];
            nx = d1 * (ry[2] - ry[0]) + d2 * (ry[0] - ry[1]);
            ny = d1 * (rx[0] - rx[2]) + d2 * (rx[1] - rx[0]);
            r_gx[j] = sat32(ashr(nx * m, n));
            r_gy[j] = sat32(ashr(ny * m, n));
            r_s[j] = sat32((ra[j][0] <<< 12) + ashr(r_gx[j] * (sxx - rx[0]) + r_gy[j] * (syy - ry[0]), 4));
        end
    endtask

    int errors = 0, tris = 0, empties = 0, max_cyc = 0;
    task automatic run(input longint ax, input longint ay, input longint bx, input longint by, input longint qx, input longint qy);
        int cyc;
        x0 = 16'(ax); y0 = 16'(ay); x1 = 16'(bx); y1 = 16'(by); x2 = 16'(qx); y2 = 16'(qy);
        c0 = $urandom; c1 = $urandom; c2 = $urandom; z0 = $urandom; z1 = $urandom; z2 = $urandom;
        t0 = $urandom; t1 = $urandom; t2 = $urandom;
        rx[0] = ax; ry[0] = ay; rx[1] = bx; ry[1] = by; rx[2] = qx; ry[2] = qy;
        ra[0][0] = c0[23:16]; ra[0][1] = c1[23:16]; ra[0][2] = c2[23:16];
        ra[1][0] = c0[15:8];  ra[1][1] = c1[15:8];  ra[1][2] = c2[15:8];
        ra[2][0] = c0[7:0];   ra[2][1] = c1[7:0];   ra[2][2] = c2[7:0];
        ra[3][0] = z0;        ra[3][1] = z1;        ra[3][2] = z2;
        ra[4][0] = t0[15:0];  ra[4][1] = t1[15:0];  ra[4][2] = t2[15:0];
        ra[5][0] = t0[31:16]; ra[5][1] = t1[31:16]; ra[5][2] = t2[31:16];
        reference();
        @(negedge clk) start = 1;
        @(negedge clk) start = 0;
        cyc = 1;
        while (!done) begin @(negedge clk); cyc++; end
        if (cyc > max_cyc) max_cyc = cyc;
        tris++;
        if (empty !== r_empty) begin
            if (errors < 10) $display("  (%0d,%0d)(%0d,%0d)(%0d,%0d): empty %b, expected %b", ax, ay, bx, by, qx, qy, empty, r_empty);
            errors++;
        end else if (r_empty) begin
            empties++;
        end else begin
            bit bad;
            bad = int'(bx0) != r_bx0 || int'(bx1) != r_bx1 || int'(by0) != r_by0 || int'(by1) != r_by1;
            for (int i = 0; i < 3; i++)
                bad |= longint'(signed'(e[i])) != r_e[i] || longint'(signed'(ex[i])) != r_ex[i] || longint'(signed'(ey[i])) != r_ey[i];
            for (int j = 0; j < 6; j++)
                bad |= longint'(signed'(s[j])) != r_s[j] || longint'(signed'(gx[j])) != r_gx[j] || longint'(signed'(gy[j])) != r_gy[j];
            if (bad) begin
                if (errors < 10) begin
                    $display("  (%0d,%0d)(%0d,%0d)(%0d,%0d) clip %0d..%0d x %0d..%0d:", ax, ay, bx, by, qx, qy, cx0, cx1, cy0, cy1);
                    $display("    bbox %0d..%0d %0d..%0d (exp %0d..%0d %0d..%0d)", bx0, bx1, by0, by1, r_bx0, r_bx1, r_by0, r_by1);
                    $display("    e %0d %0d %0d (exp %0d %0d %0d)", signed'(e[0]), signed'(e[1]), signed'(e[2]), r_e[0], r_e[1], r_e[2]);
                    for (int j = 0; j < 6; j++)
                        $display("    attr %0d: s %0d gx %0d gy %0d (exp %0d %0d %0d)", j, signed'(s[j]), signed'(gx[j]), signed'(gy[j]), r_s[j], r_gx[j], r_gy[j]);
                end
                errors++;
            end
        end
    endtask

    function automatic longint rnd(input longint lo, input longint hi);
        return lo + longint'($urandom % 32'(hi - lo + 1));
    endfunction

    initial begin
        longint ax, ay;
        $dumpfile("build/sim/tb_tri_setup.vcd");
        $dumpvars(0, tb_tri_setup);
        repeat (3) @(negedge clk);
        rst = 0;
        // 決まった形: 1 ピクセル、画面全体、逆向き、面積 0、画面の外、クリップの外
        run(16 * 10, 16 * 10, 16 * 11, 16 * 10, 16 * 10, 16 * 11);
        run(-8192, -8192, 13311, -8192, -8192, 13311);
        run(160, 160, 160, 320, 320, 160);
        run(100, 100, 200, 200, 300, 300);
        run(500, 500, 500, 500, 500, 500);
        run(-4000, -4000, -3000, -4000, -3500, -3000);
        cx0 = 9'd100; cx1 = 9'd120; cy0 = 8'd50; cy1 = 8'd60;
        run(0, 0, 1000, 0, 0, 500);
        cx0 = 0; cx1 = 319; cy0 = 0; cy1 = 239;
        // 乱数
        for (int n = 0; n < 1500; n++) begin
            unique case (n % 4)
                0: run(rnd(-8192, 13311), rnd(-8192, 13311), rnd(-8192, 13311), rnd(-8192, 13311), rnd(-8192, 13311), rnd(-8192, 13311));
                1: run(rnd(0, 5120), rnd(0, 3840), rnd(0, 5120), rnd(0, 3840), rnd(0, 5120), rnd(0, 3840));
                2: begin ax = rnd(0, 5000); ay = rnd(0, 3800);
                         run(ax, ay, ax + rnd(-40, 40), ay + rnd(-40, 40), ax + rnd(-40, 40), ay + rnd(-40, 40)); end
                default: begin ax = rnd(0, 5000); ay = rnd(0, 3800);         // 細長い
                         run(ax, ay, ax + rnd(-3000, 3000), ay + rnd(-2, 2), ax + rnd(-3000, 3000), ay + rnd(-3, 3)); end
            endcase
            if (n % 50 == 0) begin
                cx0 = 9'(rnd(0, 200)); cx1 = 9'(rnd(cx0, 319)); cy0 = 8'(rnd(0, 150)); cy1 = 8'(rnd(cy0, 239));
            end
            if (n % 50 == 25) begin cx0 = 0; cx1 = 319; cy0 = 0; cy1 = 239; end
        end
        $display("  %0d triangles (%0d empty), setup %0d clk at most", tris, empties, max_cyc);
        if (max_cyc > 160) begin $display("  setup too slow"); errors++; end
        if (errors == 0) $display("PASS: tb_tri_setup");
        else             $display("FAIL: tb_tri_setup (%0d errors)", errors);
        $finish;
    end
endmodule
