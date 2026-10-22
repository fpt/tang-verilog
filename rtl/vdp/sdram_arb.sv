// SDRAM の調停 (2 つの利用者 -> sdram_ctrl)。docs/GPU_PLAN.md の M4
//   a が優先 (表示の読み出し)、b はそれ以外 (メモリテスト、アップロード)。
//   どちらも sdram_ctrl と同じ約束: req と we / addr / wdata / len を ack まで保持する。
//   許可した利用者は ack まで変えない。rvalid / rdata / ack は許可した利用者にだけ返す。
module sdram_arb (
    input  logic        clk,
    input  logic        rst,
    // a (優先)
    input  logic        a_req,
    input  logic        a_we,
    input  logic [20:0] a_addr,
    input  logic [31:0] a_wdata,
    input  logic [8:0]  a_len,
    output logic        a_ack,
    output logic        a_rvalid,
    // b
    input  logic        b_req,
    input  logic        b_we,
    input  logic [20:0] b_addr,
    input  logic [31:0] b_wdata,
    input  logic [8:0]  b_len,
    output logic        b_ack,
    output logic        b_rvalid,
    // sdram_ctrl へ (rdata はそのまま両方に配る)
    output logic        m_req,
    output logic        m_we,
    output logic [20:0] m_addr,
    output logic [31:0] m_wdata,
    output logic [8:0]  m_len,
    input  logic        m_ack,
    input  logic        m_rvalid
);
    typedef enum logic [1:0] {OWN_NONE, OWN_A, OWN_B} owner_t;
    owner_t owner;

    always_ff @(posedge clk) begin
        if (rst) begin
            owner <= OWN_NONE;
        end else if (owner == OWN_NONE) begin
            if (a_req)      owner <= OWN_A;
            else if (b_req) owner <= OWN_B;
        end else if (m_ack) begin
            owner <= OWN_NONE;
        end
    end

    logic sel_b;
    assign sel_b = owner == OWN_B;

    assign m_req   = (owner == OWN_A && a_req) || (owner == OWN_B && b_req);
    assign m_we    = sel_b ? b_we    : a_we;
    assign m_addr  = sel_b ? b_addr  : a_addr;
    assign m_wdata = sel_b ? b_wdata : a_wdata;
    assign m_len   = sel_b ? b_len   : a_len;

    assign a_ack    = owner == OWN_A && m_ack;
    assign a_rvalid = owner == OWN_A && m_rvalid;
    assign b_ack    = owner == OWN_B && m_ack;
    assign b_rvalid = owner == OWN_B && m_rvalid;
endmodule
