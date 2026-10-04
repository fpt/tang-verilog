// Gowin プリミティブのブラックボックス定義 (合成時に read_slang へ渡す専用)
// yosys-slang はパラメータ付きのブラックボックスを .sv で直接渡す必要がある。
// https://github.com/povik/sv-elab/wiki/No-unknown-modules
// 使うプリミティブを増やしたらここにも追加する (ポート/パラメータは yosys の
// share/yosys/gowin/cells_sim.v, cells_xtra_gw2a.v に合わせる)。

(* blackbox *)
module rPLL #(
    parameter FCLKIN           = "100.0",
    parameter DYN_IDIV_SEL     = "false",
    parameter IDIV_SEL         = 0,
    parameter DYN_FBDIV_SEL    = "false",
    parameter FBDIV_SEL        = 0,
    parameter DYN_ODIV_SEL     = "false",
    parameter ODIV_SEL         = 8,
    parameter PSDA_SEL         = "0000",
    parameter DYN_DA_EN        = "false",
    parameter DUTYDA_SEL       = "1000",
    parameter CLKOUT_FT_DIR    = 1'b1,
    parameter CLKOUTP_FT_DIR   = 1'b1,
    parameter CLKOUT_DLY_STEP  = 0,
    parameter CLKOUTP_DLY_STEP = 0,
    parameter CLKFB_SEL        = "internal",
    parameter CLKOUT_BYPASS    = "false",
    parameter CLKOUTP_BYPASS   = "false",
    parameter CLKOUTD_BYPASS   = "false",
    parameter DYN_SDIV_SEL     = 2,
    parameter CLKOUTD_SRC      = "CLKOUT",
    parameter CLKOUTD3_SRC     = "CLKOUT",
    parameter DEVICE           = "GW1N-1"
) (
    output CLKOUT, CLKOUTP, CLKOUTD, CLKOUTD3, LOCK,
    input  CLKIN, CLKFB, RESET, RESET_P,
    input  [5:0] FBDSEL, IDSEL, ODSEL,
    input  [3:0] DUTYDA, PSDA, FDLY
);
endmodule

(* blackbox *)
module CLKDIV #(
    parameter DIV_MODE = "2",
    parameter GSREN    = "false"
) (
    input  HCLKIN, RESETN, CALIB,
    output CLKOUT
);
endmodule

(* blackbox *)
module OSER10 #(
    parameter GSREN = "false",
    parameter LSREN = "true"
) (
    input  D0, D1, D2, D3, D4, D5, D6, D7, D8, D9,
    input  FCLK, PCLK, RESET,
    output Q
);
endmodule

(* blackbox *)
module TLVDS_OBUF (
    input  I,
    output O, OB
);
endmodule
