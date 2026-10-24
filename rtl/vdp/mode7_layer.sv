// Mode 7 レイヤ (docs/EMU_GPU_PLAN.md の E7)。面 A の代わりに、マップをアフィン変換 (回転・拡大・遠近) して 1 ラインを出す。
// line_compositor が 1 ラインごとに setup (ラインの先頭の計算) と start (ピクセルのパス) で動かす
//
//   データ (VRAM): マップは 128 x 128 セル、1 セル 1 バイト (タイル番号)。セル n はワード map_base + n / 4 のバイト n % 4。
//                  タイルは 256 個、8 x 8、8bpp (1 ワードに 4 ピクセル)。タイル t のピクセル (px, py) はワード pat_base + t * 16 + py * 2 + px / 4
//                  のバイト px % 4。値 0 は透明 (EXTBG なら [6:0] が 0 で透明、[7] が優先度)。色はパレットの番号 0..255 (EXTBG は 0..127)
//   計算 (SNES と同じ桁。bsnes の式):
//     clip(n) = n[13] ? (n | ~1023) : (n & 1023)        (14bit の差を 11bit の符号付きに)
//     h = clip(hofs - x0)、v = clip(vofs - y0)、Y = line - sy (縦反転なら 255 - Y)
//     ox = ((A*h) & ~63) + ((B*v) & ~63) + ((B*Y) & ~63) + (x0 << 8)、oy = ((C*h) & ~63) + ((D*v) & ~63) + ((D*Y) & ~63) + (y0 << 8)
//     X = -sx (横反転なら 255 + sx)、画面の x = 0 の値は (ox + A*X, oy + C*X)。ピクセルごとに A, C を足す (横反転なら引く)
//     マップの座標は (x >> 8, y >> 8)。0..1023 の外なら over の規則 (0 / 1 折り返す、2 透明、3 タイル 0)
//   遠近 (persp): A = D = (z * a) >> 14、B = (z * b) >> 14、C = -B (z は符号なし 8.8、a = cos、b = sin は符号付き 1.14。下位 16bit を使う)
//   乗算: シフトと加算の乗算器 1 個 (17 x 17bit、1 回 18 クロック) を直列に 8 回 (遠近は 10 回) 使う。VRAM を使わないので、
//         line_compositor のスプライト・面 B のパスと同時に動く
//
//   動き方: setup で計算を始める (約 190 クロック)。start でピクセルのパス (ready の前に来たら待つ)。1 ピクセル 2 クロック:
//           マップのアドレスを出す → 届いたマップのバイトからタイルのアドレスを出す (次のピクセルのマップと交互に読み出しのポートを使う)。
//           タイルのバイトが届いたら取っておき、次のクロックにパレットを引く
//   出力:   tile_layer と同じ。px_valid のクロックに x = px_x のピクセル {px_pri, px_color} (不透明なものだけ出す)、その 1 クロック前に next_word
//
//   入力は setup から busy が落ちるまで変えないこと (line_compositor がラインの開始で取り込んだ値を渡す)。
module mode7_layer #(
    parameter int SRC_W = 320
) (
    input  logic        clk,
    input  logic        rst,
    // VRAM とパレットの読み出し (1 クロック遅れ)
    output logic [13:0] vram_raddr,
    input  logic [31:0] vram_q,
    output logic [8:0]  pal_raddr,
    input  logic [15:0] pal_q,
    // ラインの設定
    input  logic        setup,          // 1 クロック: ラインの先頭の計算を始める
    input  logic [7:0]  line,
    input  logic [1:0]  flip,           // M7_SEL の [1:0]: bit0 横反転、bit1 縦反転
    input  logic [1:0]  over,           // M7_SEL の [7:6]: マップの外 (0 / 1 折り返す、2 透明、3 タイル 0)
    input  logic        extbg,
    input  logic        persp,
    input  logic [15:0] a, b, c, d,     // 行列 (符号付き 8.8)。遠近なら a = cos、b = sin (1.14)
    input  logic [15:0] z,              // 遠近の奥行き (符号なし 8.8)
    input  logic [12:0] x0, y0, hofs, vofs,
    input  logic [9:0]  sx,
    input  logic [8:0]  sy,
    input  logic [13:0] map_base,
    input  logic [13:0] pat_base,
    // ピクセルのパス
    input  logic        start,
    output logic        busy,
    output logic [7:0]  next_word,
    output logic        px_valid,
    output logic [8:0]  px_x,
    output logic        px_pri,
    output logic [15:0] px_color
);
    // ================================================================ ラインの先頭の計算
    logic [15:0]        ea, eb, ec, ed;         // このラインの行列
    logic signed [31:0] ox, oy;
    logic signed [10:0] h, v, yy, xs;
    logic [3:0]         step;                   // 乗算の番号 0..9 (遠近でなければ 2 から)
    logic [4:0]         bitn;                   // 乗数のビット 0..16、17 で結果
    logic signed [33:0] acc, mcand;
    logic [16:0]        mplier;
    logic               calc;
    logic               ready;                  // 計算が終わった (start を受けられる)

    // clip: 差 (14bit) の符号と下位 10bit。13bit の符号付きどうしの差は 14bit であふれないので、符号は大小の比べで分かる
    logic [9:0]         dh, dv;
    logic               nh, nv;
    logic signed [10:0] y_scr;
    assign dh    = hofs[9:0] - x0[9:0];
    assign dv    = vofs[9:0] - y0[9:0];
    assign nh    = signed'(hofs) < signed'(x0);
    assign nv    = signed'(vofs) < signed'(y0);
    assign y_scr = 11'(line) - 11'(signed'(sy));

    // 乗算 step の被乗数・乗数 (どちらも 17bit の符号付き)
    logic [16:0] op_a, op_b;
    always_comb begin
        op_a = 17'(signed'(ea));
        op_b = 17'(signed'(h));
        unique case (step)
            4'd0:    begin op_a = {1'b0, z}; op_b = 17'(signed'(a)); end
            4'd1:    begin op_a = {1'b0, z}; op_b = 17'(signed'(b)); end
            4'd2:    begin op_a = 17'(signed'(ea)); op_b = 17'(signed'(h));  end
            4'd3:    begin op_a = 17'(signed'(eb)); op_b = 17'(signed'(v));  end
            4'd4:    begin op_a = 17'(signed'(eb)); op_b = 17'(signed'(yy)); end
            4'd5:    begin op_a = 17'(signed'(ec)); op_b = 17'(signed'(h));  end
            4'd6:    begin op_a = 17'(signed'(ed)); op_b = 17'(signed'(v));  end
            4'd7:    begin op_a = 17'(signed'(ed)); op_b = 17'(signed'(yy)); end
            4'd8:    begin op_a = 17'(signed'(ea)); op_b = 17'(signed'(xs)); end
            default: begin op_a = 17'(signed'(ec)); op_b = 17'(signed'(xs)); end
        endcase
    end

    logic signed [31:0] prod, prod_m;           // 結果 (下位 32bit) と、& ~63 したもの
    logic [15:0]        p14;                    // 遠近: (z * cos|sin) >> 14 の下位 16bit
    assign prod   = acc[31:0];
    assign prod_m = {acc[31:6], 6'b0};
    assign p14    = acc[29:14];

    // bitn: 18 で被乗数・乗数を入れ、0..16 で乗数のビットを 1 つずつ足し (最上位の 16 は符号なので引く)、17 で結果を入れる
    always_ff @(posedge clk) begin
        if (rst) begin
            calc  <= 1'b0;
            ready <= 1'b0;
        end else if (setup) begin
            calc  <= 1'b1;
            ready <= 1'b0;
            ea <= a; eb <= b; ec <= c; ed <= d;
            h  <= {nh, dh};
            v  <= {nv, dv};
            yy <= flip[1] ? 11'sd255 - y_scr : y_scr;
            xs <= flip[0] ? 11'sd255 + 11'(signed'(sx)) : 11'sd0 - 11'(signed'(sx));
            ox <= 32'(signed'(x0)) <<< 8;
            oy <= 32'(signed'(y0)) <<< 8;
            step <= persp ? 4'd0 : 4'd2;
            bitn <= 5'd18;
        end else if (calc) begin
            if (bitn == 5'd18) begin
                acc    <= '0;
                mcand  <= 34'(signed'(op_a));
                mplier <= op_b;
                bitn   <= 5'd0;
            end else if (bitn == 5'd17) begin
                unique case (step)
                    4'd0: begin ea <= p14; ed <= p14; end
                    4'd1: begin eb <= p14; ec <= 16'd0 - p14; end
                    4'd2, 4'd3, 4'd4: ox <= ox + prod_m;
                    4'd5, 4'd6, 4'd7: oy <= oy + prod_m;
                    4'd8: ox <= ox + prod;
                    default: oy <= oy + prod;
                endcase
                if (step == 4'd9) begin
                    calc  <= 1'b0;
                    ready <= 1'b1;
                end else begin
                    step <= step + 4'd1;
                    bitn <= 5'd18;
                end
            end else begin
                if (mplier[0]) acc <= (bitn == 5'd16) ? acc - mcand : acc + mcand;
                mcand  <= mcand <<< 1;
                mplier <= mplier >> 1;
                bitn   <= bitn + 5'd1;
            end
        end
    end

    // ================================================================ ピクセルのパス
    // 1 ピクセル 2 クロック (ph)。ph = 0: ピクセル i のマップのアドレスを出す (DDA を進める)。
    // ph = 1: ピクセル i のマップのバイトが届く → タイルのアドレスを出す。次の ph = 0 にタイルのバイトが届く → 取っておき (s3)、
    // その次の ph = 1 にパレットを引く → 次のクロックに px_valid
    logic               run, wait_rdy, ph;
    logic [8:0]         xi;                     // マップを読んでいるピクセル
    logic signed [31:0] xa, ya, da, dc;
    logic [8:0]         s1_x, s2_x, s3_x;
    logic [1:0]         s1_byte, s2_byte;
    logic [2:0]         s1_fx, s1_fy;
    logic               s1_v, s1_oob, s2_v, s2_drop, s3_v, s3_drop;
    logic [7:0]         s3_pix;
    logic               p_valid, p_pri;
    logic [8:0]         p_x;

    logic signed [23:0] mx, my;                 // マップのピクセル座標 (x >> 8)
    logic               oob;
    assign mx  = xa[31:8];
    assign my  = ya[31:8];
    assign oob = mx[23:10] != '0 || my[23:10] != '0;

    logic [7:0]  tile_no, pix;
    logic [13:0] map_addr, pat_addr;
    assign map_addr = map_base + 14'({my[9:3], mx[9:5]});
    assign tile_no     = (s1_oob && over == 2'd3) ? 8'd0 : vram_q[{s1_byte, 3'b0} +: 8];
    assign pat_addr = pat_base + {2'b0, tile_no, s1_fy, s1_fx[2]};
    assign pix      = vram_q[{s2_byte, 3'b0} +: 8];

    assign vram_raddr = ph ? pat_addr : map_addr;
    assign pal_raddr  = {1'b0, extbg ? {1'b0, s3_pix[6:0]} : s3_pix};
    assign next_word  = s3_x[8:1];
    assign px_valid   = p_valid;
    assign px_x       = p_x;
    assign px_pri     = p_pri;
    assign px_color   = pal_q;
    assign busy       = wait_rdy || run || s1_v || s2_v || s3_v || p_valid;

    logic opaque;
    assign opaque = extbg ? s3_pix[6:0] != 7'd0 : s3_pix != 8'd0;

    always_ff @(posedge clk) begin
        if (rst) begin
            run      <= 1'b0;
            wait_rdy <= 1'b0;
            ph       <= 1'b0;
            s1_v     <= 1'b0;
            s2_v     <= 1'b0;
            s3_v     <= 1'b0;
            p_valid  <= 1'b0;
        end else begin
            p_valid <= 1'b0;
            if (start) wait_rdy <= 1'b1;
            if ((start || wait_rdy) && ready && !run) begin
                wait_rdy <= 1'b0;
                run      <= 1'b1;
                ph       <= 1'b0;
                xi       <= '0;
                xa       <= ox;
                ya       <= oy;
                da       <= flip[0] ? -32'(signed'(ea)) : 32'(signed'(ea));
                dc       <= flip[0] ? -32'(signed'(ec)) : 32'(signed'(ec));
            end else if (run || s1_v || s2_v || s3_v) begin
                ph <= ~ph;
                if (!ph) begin
                    // マップを読む (run のあいだ)。前のピクセルのタイルのバイトが届いている
                    s1_v    <= run;
                    s1_x    <= xi;
                    s1_byte <= mx[4:3];
                    s1_fx   <= mx[2:0];
                    s1_fy   <= my[2:0];
                    s1_oob  <= oob;
                    if (run) begin
                        xa <= xa + da;
                        ya <= ya + dc;
                        xi <= xi + 9'd1;
                        if (xi == 9'(SRC_W - 1)) run <= 1'b0;
                    end
                    s3_v    <= s2_v;
                    s3_x    <= s2_x;
                    s3_pix  <= pix;
                    s3_drop <= s2_drop;
                    s2_v    <= 1'b0;
                end else begin
                    // タイルを読む。取っておいたバイトのパレットを引く
                    s2_v    <= s1_v;
                    s2_x    <= s1_x;
                    s2_byte <= s1_fx[1:0];
                    s2_drop <= s1_oob && over == 2'd2;
                    s1_v    <= 1'b0;
                    p_valid <= s3_v && !s3_drop && opaque;
                    p_x     <= s3_x;
                    p_pri   <= extbg && s3_pix[7];
                    s3_v    <= 1'b0;
                end
            end
        end
    end
endmodule
