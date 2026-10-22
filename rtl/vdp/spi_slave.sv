// SPI スレーブ (mode 0, MSB first) -> レジスタバス
//   SCK / COPI / CS はシステムクロックで同期化してサンプリングするので、SCK の High / Low はそれぞれ
//   システムクロック 3 周期以上必要 (63MHz なら SCK 10MHz 程度まで)。
//   CS は正論理 (High で選択)。docs/WIRING.md
//
// トランザクション:
//   書き込み: CS↑ [0 | addr(7)] [data] [data] ... CS↓   (2 バイト目以降は addr, addr+1, ... へ)
//   読み出し: CS↑ [1 | addr(7)] [xx]   [xx]   ... CS↓   (2 バイト目以降に addr, addr+1, ... の値が返る)
//   ただし 0x30..0x3F (ポート) はアドレスを進めない (同じレジスタに続けて書く / 読む)
//   1 バイト目の間、CIPO には同期確認用の 0xA5 が出る。
//   CS がバイトの途中で下がったら frame_error を 1 クロック出す。
//
// CIPO は SCK の立ち上がり (マスタのサンプル点) を検出した直後に次のビットへ進める。
// 立ち下がりを待たないので、同期化の遅れがあっても次の立ち上がりまでほぼ 1 周期の余裕がある。
module spi_slave (
    input  logic       clk,
    input  logic       rst,
    input  logic       sck,           // 非同期
    input  logic       copi,          // 非同期
    input  logic       cs,            // 非同期
    output logic       cipo,
    output logic [6:0] reg_addr,
    output logic [7:0] reg_wdata,
    output logic       reg_we,        // 1 クロックのパルス
    output logic       reg_re,        // 読み出した値をシフトレジスタに取り込んだとき 1 クロック
    input  logic [7:0] reg_rdata,     // reg_addr に対する値 (組み合わせ回路でよい)
    output logic       frame_error
);
    localparam logic [7:0] SYNC_BYTE = 8'hA5;

    // --- 同期化 (SCK / CS は 1 段多く持ってエッジを取る) ---
    logic [2:0] sck_s, cs_s;
    logic [1:0] copi_s;
    always_ff @(posedge clk) begin
        sck_s  <= {sck_s[1:0], sck};
        cs_s   <= {cs_s[1:0], cs};
        copi_s <= {copi_s[0], copi};
    end

    logic sck_rise, cs_active, cs_end;
    assign sck_rise  = sck_s[1] && !sck_s[2];
    assign cs_active = cs_s[1];
    assign cs_end    = !cs_s[1] && cs_s[2];

    logic [2:0] bit_cnt;
    logic [6:0] shift_in;
    logic [7:0] shift_out, next_in;
    logic       first_byte, is_read, load_pending;
    logic [6:0] addr;

    assign next_in = {shift_in, copi_s[1]};

    // 0x30..0x3F はポートなので進めない
    logic [6:0] addr_next;
    assign addr_next = (addr[6:4] == 3'b011) ? addr : addr + 7'd1;

    always_ff @(posedge clk) begin
        reg_we      <= 1'b0;
        reg_re      <= 1'b0;
        frame_error <= 1'b0;
        if (rst || !cs_active) begin
            if (!rst && cs_end && bit_cnt != 3'd0) frame_error <= 1'b1;
            bit_cnt      <= '0;
            first_byte   <= 1'b1;
            is_read      <= 1'b0;
            load_pending <= 1'b0;
            shift_out    <= SYNC_BYTE;
        end else if (sck_rise) begin
            shift_in  <= next_in[6:0];
            shift_out <= {shift_out[6:0], 1'b0};
            bit_cnt   <= bit_cnt + 3'd1;
            if (bit_cnt == 3'd7) begin
                if (first_byte) begin
                    first_byte <= 1'b0;
                    is_read    <= next_in[7];
                    addr       <= next_in[6:0];
                    if (next_in[7]) begin
                        reg_addr     <= next_in[6:0];
                        load_pending <= 1'b1;
                    end
                end else if (!is_read) begin
                    reg_addr  <= addr;
                    reg_wdata <= next_in;
                    reg_we    <= 1'b1;
                    addr      <= addr_next;
                end else begin
                    addr         <= addr_next;
                    reg_addr     <= addr_next;
                    load_pending <= 1'b1;
                end
            end
        end else if (load_pending) begin
            // reg_addr を更新した次のクロックで値を取り込む (次の SCK 立ち上がりより十分前)
            shift_out    <= reg_rdata;
            reg_re       <= 1'b1;
            load_pending <= 1'b0;
        end
    end

    assign cipo = cs_active ? shift_out[7] : 1'b0;
endmodule
