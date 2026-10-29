// nextpnr の Gowin のタイミング解析の確かめ (docs/NEXTPNR_GOWIN_TIMING.md)
// W = 16 なら yosys は DPX9B に、W = 32 なら SDPX9B に置く。依存し合う 32bit の足し算 30 段の組み合わせ (ra) を
//   WCHAIN 0: 読み出しの番地 (ADB)、1: 書き込みの番地 (ADA)、2: 対照 (RAM でなく FF) で受ける
module repro #(parameter int W = 16, parameter int WCHAIN = 0) (
    input  logic clk,
    output logic led
);
    logic [31:0] a, b, c, d;
    logic [8:0]  ra;
    logic [W-1:0] mem [0:511];
    logic [W-1:0] q;
    always_ff @(posedge clk) begin
        a <= {a[30:0], a[31] ^ a[21] ^ a[1] ^ a[0]} | 32'(a == 0);   // LFSR (DSP を使わない)
        b <= b + a; c <= c ^ (b << 3); d <= d + c;
        if (a[0]) mem[(WCHAIN == 1) ? ra : a[8:0]] <= W'(b);      // WCHAIN: 深い組み合わせを書き込みの番地 (ADA) に
        q <= (WCHAIN == 2) ? W'(ra) : mem[(WCHAIN == 1) ? a[17:9] : ra];   // WCHAIN 2: 対照 (番地の連鎖を RAM でなく FF で受ける)
        led <= ^q;
    end
    // 番地: FF → 依存し合う 32bit の足し算 30 段 (桁上げの連鎖が長く、SDP ならここが一番遅い経路になる) → 番地
    logic [31:0] t [0:30];
    always_comb begin
        t[0] = a;
        for (int i = 1; i <= 30; i++) t[i] = (t[i - 1] + ((i % 2) ? b : c)) ^ {t[i - 1][15:0], t[i - 1][31:16]};
    end
    assign ra = t[30][31:23];
endmodule
