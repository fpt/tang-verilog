// SDRAM の調停 (4 つの利用者 -> sdram_ctrl)。docs/GPU_PLAN.md の M4, M5、docs/KESSEL_ON_VDP.md の K5a
//   優先順位: a (表示の読み出し) > d (音の PCM の読み出し、1 ワード) > b (GPU の描画) > c (メモリテスト)。
//   d は 1 標本 (20.8us) に 1 ワードだけなので、a の締め切りにも b の速さにもほとんど効かない。
//   どれも sdram_ctrl と同じ約束: req と we / addr / len を ack まで保持し、書き込みは wnext で次のワードに進める。
//   許可した利用者は ack まで変えない。rvalid / wnext / ack は許可した利用者にだけ返す。rdata は sdram_ctrl から全員に配る。
//   表示の締め切りは出力 2 ライン分 (63.5us) あり、描画のバーストは 64 ワード (約 1us) までなので、途中で止める仕組みは持たない。
module sdram_arb (
    input  logic        clk,
    input  logic        rst,
    // a (最優先)
    input  logic        a_req,
    input  logic        a_we,
    input  logic [20:0] a_addr,
    input  logic [31:0] a_wdata,
    input  logic [3:0]  a_wmask,
    input  logic [8:0]  a_len,
    output logic        a_ack,
    output logic        a_rvalid,
    output logic        a_wnext,
    // b
    input  logic        b_req,
    input  logic        b_we,
    input  logic [20:0] b_addr,
    input  logic [31:0] b_wdata,
    input  logic [3:0]  b_wmask,
    input  logic [8:0]  b_len,
    output logic        b_ack,
    output logic        b_rvalid,
    output logic        b_wnext,
    // c
    input  logic        c_req,
    input  logic        c_we,
    input  logic [20:0] c_addr,
    input  logic [31:0] c_wdata,
    input  logic [3:0]  c_wmask,
    input  logic [8:0]  c_len,
    output logic        c_ack,
    output logic        c_rvalid,
    output logic        c_wnext,
    // d (読み出しだけ)
    input  logic        d_req,
    input  logic [20:0] d_addr,
    input  logic [8:0]  d_len,
    output logic        d_ack,
    output logic        d_rvalid,
    // sdram_ctrl へ
    output logic        m_req,
    output logic        m_we,
    output logic [20:0] m_addr,
    output logic [31:0] m_wdata,
    output logic [3:0]  m_wmask,
    output logic [8:0]  m_len,
    input  logic        m_ack,
    input  logic        m_rvalid,
    input  logic        m_wnext
);
    typedef enum logic [2:0] {OWN_NONE, OWN_A, OWN_B, OWN_C, OWN_D} owner_t;
    owner_t owner;

    always_ff @(posedge clk) begin
        if (rst) begin
            owner <= OWN_NONE;
        end else if (owner == OWN_NONE) begin
            if (a_req)      owner <= OWN_A;
            else if (d_req) owner <= OWN_D;
            else if (b_req) owner <= OWN_B;
            else if (c_req) owner <= OWN_C;
        end else if (m_ack) begin
            owner <= OWN_NONE;
        end
    end

    always_comb begin
        unique case (owner)
            OWN_A: {m_req, m_we, m_addr, m_wdata, m_wmask, m_len} = {a_req, a_we, a_addr, a_wdata, a_wmask, a_len};
            OWN_B: {m_req, m_we, m_addr, m_wdata, m_wmask, m_len} = {b_req, b_we, b_addr, b_wdata, b_wmask, b_len};
            OWN_C: {m_req, m_we, m_addr, m_wdata, m_wmask, m_len} = {c_req, c_we, c_addr, c_wdata, c_wmask, c_len};
            OWN_D: {m_req, m_we, m_addr, m_wdata, m_wmask, m_len} = {d_req, 1'b0, d_addr, 32'h0, 4'h0, d_len};
            default: {m_req, m_we, m_addr, m_wdata, m_wmask, m_len} = '0;
        endcase
    end

    assign a_ack    = owner == OWN_A && m_ack;
    assign a_rvalid = owner == OWN_A && m_rvalid;
    assign a_wnext  = owner == OWN_A && m_wnext;
    assign b_ack    = owner == OWN_B && m_ack;
    assign b_rvalid = owner == OWN_B && m_rvalid;
    assign b_wnext  = owner == OWN_B && m_wnext;
    assign c_ack    = owner == OWN_C && m_ack;
    assign c_rvalid = owner == OWN_C && m_rvalid;
    assign c_wnext  = owner == OWN_C && m_wnext;
    assign d_ack    = owner == OWN_D && m_ack;
    assign d_rvalid = owner == OWN_D && m_rvalid;
endmodule
