// SDR SDRAM の簡単な振る舞いモデル (シミュレーション専用。64Mbit: 4 バンク x 2048 行 x 256 列 x 32bit)
//   - ACTIVE / READ / WRITE (オートプリチャージ付きも) / PRECHARGE / REFRESH / MODE REGISTER SET
//   - 読み出しは CAS レイテンシ CL。データは CL-1 番目のクロックの T_AC 後から、CL 番目のクロックの T_OH 後まで出る
//   - タイミング違反 (tRCD, tRP, tRFC, 閉じたバンクへのアクセス, リフレッシュ間隔) を violations に数える
module sdram_model #(
    parameter int  CL          = 2,
    parameter real T_AC        = 5.4,      // ns
    parameter real T_OH        = 2.5,      // ns
    parameter int  T_RCD       = 2,        // クロック数
    parameter int  T_RP        = 2,
    parameter int  T_RFC       = 4,
    parameter real MAX_REF_GAP = 15600.0   // ns (64ms / 4096)
) (
    input  logic        clk,
    input  logic        cke,
    input  logic        cs_n,
    input  logic        ras_n,
    input  logic        cas_n,
    input  logic        we_n,
    input  logic [1:0]  ba,
    input  logic [10:0] addr,
    input  logic [3:0]  dqm,
    inout  wire  [31:0] dq
);
    logic [31:0] mem [0:(1 << 21) - 1];

    int   violations = 0;
    int   refreshes = 0;
    bit   mode_set = 0;
    int   cycle = 0;
    bit   open_bank [4];
    logic [10:0] open_row [4];
    int   act_cycle [4];
    int   ready_cycle [4];     // このクロック以降なら ACTIVE してよい (tRP)
    int   ref_ready = 0;       // このクロック以降ならコマンドを受け付ける (tRFC)
    real  last_ref = -1.0;

    logic [31:0] dq_r;
    logic        dq_en = 0;
    assign dq = dq_en ? dq_r : 'z;

    bit          rd_pending = 0, off_next = 0;
    int          rd_wait;
    logic [31:0] rd_data;

    task automatic violation(input string msg);
        $display("  sdram_model: %s (t=%0t)", msg, $time);
        violations++;
    endtask

    function automatic int index(input logic [1:0] b, input logic [10:0] r, input logic [7:0] c);
        return {b, r, c};
    endfunction

    always @(posedge clk) begin
        int b;
        logic [3:0] cmd;
        cycle++;

        // 読み出しデータの出力 / 終了
        if (off_next) begin
            dq_en <= #(T_OH) 1'b0;
            off_next = 0;
        end
        if (rd_pending) begin
            if (rd_wait <= 1) begin
                dq_r  <= #(T_AC) rd_data;
                dq_en <= #(T_AC) 1'b1;
                rd_pending = 0;
                off_next = 1;
            end else begin
                rd_wait--;
            end
        end

        cmd = {cs_n, ras_n, cas_n, we_n};
        if (cke && cmd != 4'b0111 && !cs_n) begin
            if (cycle < ref_ready) violation("command during tRFC");
            if (!mode_set && cmd != 4'b0010 && cmd != 4'b0001 && cmd != 4'b0000) violation("access before MODE REGISTER SET");
            b = ba;
            unique case (cmd)
                4'b0011: begin  // ACTIVE
                    if (open_bank[b]) violation("ACTIVE to an open bank");
                    if (cycle < ready_cycle[b]) violation("ACTIVE before tRP");
                    open_bank[b] = 1;
                    open_row[b]  = addr;
                    act_cycle[b] = cycle;
                end
                4'b0101, 4'b0100: begin  // READ / WRITE
                    if (!open_bank[b]) violation("READ/WRITE to a closed bank");
                    if (cycle - act_cycle[b] < T_RCD) violation("READ/WRITE before tRCD");
                    if (cmd == 4'b0100) begin
                        for (int i = 0; i < 4; i++)
                            if (!dqm[i]) mem[index(ba, open_row[b], addr[7:0])][8 * i +: 8] = dq[8 * i +: 8];
                    end else begin
                        rd_data    = mem[index(ba, open_row[b], addr[7:0])];
                        rd_pending = 1;
                        rd_wait    = CL - 1;
                    end
                    if (addr[10]) begin   // オートプリチャージ (書き込みは tWR 分遅れる)
                        open_bank[b]   = 0;
                        ready_cycle[b] = cycle + (cmd == 4'b0100 ? 2 : 1) + T_RP;
                    end
                end
                4'b0010: begin  // PRECHARGE
                    for (int i = 0; i < 4; i++)
                        if (addr[10] || i == b) begin
                            open_bank[i]   = 0;
                            ready_cycle[i] = cycle + T_RP;
                        end
                end
                4'b0001: begin  // REFRESH
                    for (int i = 0; i < 4; i++) begin
                        if (open_bank[i]) violation("REFRESH with an open bank");
                        if (cycle < ready_cycle[i]) violation("REFRESH before tRP");
                    end
                    if (mode_set && last_ref >= 0 && $realtime - last_ref > MAX_REF_GAP)
                        violation($sformatf("refresh gap %0.1f ns", $realtime - last_ref));
                    last_ref  = $realtime;
                    ref_ready = cycle + T_RFC;
                    refreshes++;
                end
                4'b0000: begin  // MODE REGISTER SET
                    if (addr[6:4] != 3'(CL) || addr[2:0] != 3'b000) violation("unexpected mode register value");
                    mode_set = 1;
                end
                default: violation("unsupported command");
            endcase
        end
    end
endmodule
