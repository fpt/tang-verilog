// SDRAM の自己テスト (BIST) とレジスタ経由の 1 ワード読み書き (docs/GPU_PLAN.md の M3)
//
// レジスタ (0x10..0x2F。複数バイトの値はリトルエンディアン):
//   0x10 MEM_CMD        W  1: BIST 開始, 2: MEM_ADDR を読んで MEM_DATA へ, 3: MEM_DATA を MEM_ADDR へ書く
//                          (2 と 3 のあと MEM_ADDR は 1 進む)
//   0x11 MEM_CFG        RW [2:0] 読み出しの取り込み位置 (sdram_ctrl の rd_sample)。既定 6 (実機で 5..7 が合格した真ん中)
//   0x12 MEM_STATUS     R  bit0: SDRAM 初期化完了, bit1: 実行中, bit2: BIST 完了, bit3: BIST 合格
//   0x13 BIST_SIZE      RW テストするワード数の log2 (1..21、既定 21 = 全 8MiB)
//   0x14 BIST_SEED      RW パターンの種
//   0x18 BIST_ERRORS    R  32bit 不一致の数
//   0x1C BIST_FAIL_ADDR R  32bit 最初に不一致だったワードアドレス
//   0x20 BIST_FAIL_EXP  R  32bit そのときの期待値
//   0x24 BIST_FAIL_GOT  R  32bit そのときに読めた値
//   0x28 MEM_ADDR       RW 32bit ワードアドレス (下位 21bit が有効)
//   0x2C MEM_DATA       RW 32bit
//
// BIST: pattern(a) を全域に書いて読んで比べ、次に ~pattern(a) で同じことをする。
//   pattern(a) = {~a[10:0], a[20:0]} ^ {4{seed}}。アドレスごとに値が違うのでアドレス線の不良 (別の場所に書かれる) も見つかり、
//   2 回目は全ビットを反転するので、各ビットが 0 と 1 の両方を通る。
module mem_test (
    input  logic        clk,
    input  logic        rst,
    // レジスタバス
    input  logic [6:0]  addr,
    input  logic [7:0]  wdata,
    input  logic        we,
    output logic [7:0]  rdata,
    // sdram_ctrl へ
    output logic        mem_req,
    output logic        mem_we,
    output logic [20:0] mem_addr,
    output logic [31:0] mem_wdata,
    input  logic        mem_ack,
    input  logic [31:0] mem_rdata,
    input  logic        mem_init_done,
    output logic [2:0]  rd_sample
);
    localparam logic [6:0] A_CMD    = 7'h10;
    localparam logic [6:0] A_CFG    = 7'h11;
    localparam logic [6:0] A_STATUS = 7'h12;
    localparam logic [6:0] A_SIZE   = 7'h13;
    localparam logic [6:0] A_SEED   = 7'h14;
    // 0x18..0x2F の 32bit レジスタは下の casez でバイト単位に読み書きする

    typedef enum logic [2:0] {S_IDLE, S_SINGLE, S_BIST_WRITE, S_BIST_READ} state_t;
    state_t state;

    logic [4:0]  bist_size;
    logic [7:0]  bist_seed;
    logic        bist_done, bist_inv;
    logic [31:0] errors, fail_addr, fail_exp, fail_got;
    logic [31:0] reg_addr, reg_data;
    logic [20:0] cursor, last;

    function automatic logic [31:0] pattern(input logic [20:0] a, input logic [7:0] seed, input logic inv);
        logic [31:0] p;
        p = {~a[10:0], a} ^ {4{seed}};
        return inv ? ~p : p;
    endfunction

    // last = 2^size - 1 (size は 1..21 に丸める)
    logic [4:0] size_c;
    assign size_c = (bist_size == 0) ? 5'd1 : (bist_size > 5'd21) ? 5'd21 : bist_size;
    assign last   = 21'((32'd1 << size_c) - 32'd1);

    logic [31:0] expect_now;
    assign expect_now = pattern(cursor, bist_seed, bist_inv);

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            rd_sample <= 3'd6;
            bist_size <= 5'd21;
            bist_seed <= 8'h00;
            bist_done <= 1'b0;
            errors    <= '0;
            fail_addr <= '0;
            fail_exp  <= '0;
            fail_got  <= '0;
            reg_addr  <= '0;
            reg_data  <= '0;
            mem_req   <= 1'b0;
        end else begin
            // --- レジスタ書き込み (実行中も受け付けるが、コマンドは S_IDLE のときだけ) ---
            if (we) begin
                unique case (addr)
                    A_CFG:  rd_sample <= wdata[2:0];
                    A_SIZE: bist_size <= wdata[4:0];
                    A_SEED: bist_seed <= wdata;
                    7'h28: reg_addr[7:0]   <= wdata;
                    7'h29: reg_addr[15:8]  <= wdata;
                    7'h2A: reg_addr[23:16] <= wdata;
                    7'h2B: reg_addr[31:24] <= wdata;
                    7'h2C: reg_data[7:0]   <= wdata;
                    7'h2D: reg_data[15:8]  <= wdata;
                    7'h2E: reg_data[23:16] <= wdata;
                    7'h2F: reg_data[31:24] <= wdata;
                    default: ;
                endcase
            end

            unique case (state)
                S_IDLE: if (we && addr == A_CMD && mem_init_done) begin
                    unique case (wdata)
                        8'd1: begin
                            bist_done <= 1'b0;
                            bist_inv  <= 1'b0;
                            errors    <= '0;
                            cursor    <= '0;
                            state     <= S_BIST_WRITE;
                        end
                        8'd2: begin
                            mem_req  <= 1'b1;
                            mem_we   <= 1'b0;
                            mem_addr <= reg_addr[20:0];
                            state    <= S_SINGLE;
                        end
                        8'd3: begin
                            mem_req   <= 1'b1;
                            mem_we    <= 1'b1;
                            mem_addr  <= reg_addr[20:0];
                            mem_wdata <= reg_data;
                            state     <= S_SINGLE;
                        end
                        default: ;
                    endcase
                end
                S_SINGLE: if (mem_ack) begin
                    mem_req  <= 1'b0;
                    if (!mem_we) reg_data <= mem_rdata;
                    reg_addr <= reg_addr + 32'd1;
                    state    <= S_IDLE;
                end
                S_BIST_WRITE: begin
                    if (!mem_req) begin
                        mem_req   <= 1'b1;
                        mem_we    <= 1'b1;
                        mem_addr  <= cursor;
                        mem_wdata <= expect_now;
                    end else if (mem_ack) begin
                        mem_req <= 1'b0;
                        if (cursor == last) begin
                            cursor <= '0;
                            state  <= S_BIST_READ;
                        end else begin
                            cursor <= cursor + 21'd1;
                        end
                    end
                end
                S_BIST_READ: begin
                    if (!mem_req) begin
                        mem_req  <= 1'b1;
                        mem_we   <= 1'b0;
                        mem_addr <= cursor;
                    end else if (mem_ack) begin
                        mem_req <= 1'b0;
                        // !== はシミュレーションで X / Z (誰も駆動していないバス) を不一致として数えるため。合成では != と同じ
                        if (mem_rdata !== expect_now) begin
                            if (errors == 0) begin
                                fail_addr <= {11'b0, cursor};
                                fail_exp  <= expect_now;
                                fail_got  <= mem_rdata;
                            end
                            if (errors != 32'hFFFF_FFFF) errors <= errors + 32'd1;
                        end
                        if (cursor != last) begin
                            cursor <= cursor + 21'd1;
                        end else if (!bist_inv) begin
                            bist_inv <= 1'b1;            // 反転したパターンでもう 1 周
                            cursor   <= '0;
                            state    <= S_BIST_WRITE;
                        end else begin
                            bist_done <= 1'b1;
                            state     <= S_IDLE;
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // --- レジスタ読み出し ---
    function automatic logic [7:0] byte_of(input logic [31:0] v, input logic [1:0] i);
        return v[8 * i +: 8];
    endfunction

    always_comb begin
        unique casez (addr)
            A_CFG:     rdata = {5'b0, rd_sample};
            A_STATUS:  rdata = {4'b0, bist_done && errors == 0, bist_done, state != S_IDLE, mem_init_done};
            A_SIZE:    rdata = {3'b0, bist_size};
            A_SEED:    rdata = bist_seed;
            7'b001_10??: rdata = byte_of(errors, addr[1:0]);      // 0x18..0x1B
            7'b001_11??: rdata = byte_of(fail_addr, addr[1:0]);   // 0x1C..0x1F
            7'b010_00??: rdata = byte_of(fail_exp, addr[1:0]);    // 0x20..0x23
            7'b010_01??: rdata = byte_of(fail_got, addr[1:0]);    // 0x24..0x27
            7'b010_10??: rdata = byte_of(reg_addr, addr[1:0]);    // 0x28..0x2B
            7'b010_11??: rdata = byte_of(reg_data, addr[1:0]);    // 0x2C..0x2F
            default:   rdata = 8'h00;
        endcase
    end
endmodule
