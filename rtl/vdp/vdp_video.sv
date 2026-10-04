// タイミング生成 + VDP コアをまとめたもの (ベンダ非依存、シミュレーション可能な範囲)
module vdp_video (
    input  logic       clk_pix,
    input  logic       rst,
    output logic [7:0] r,
    output logic [7:0] g,
    output logic [7:0] b,
    output logic       de,
    output logic       hsync,
    output logic       vsync
);
    logic [10:0] x;
    logic [9:0]  y;
    logic        t_de, t_hs, t_vs, t_fs;

    video_timing u_timing (
        .clk(clk_pix), .rst,
        .x, .y, .de(t_de), .hsync(t_hs), .vsync(t_vs), .frame_start(t_fs)
    );

    vdp_core u_core (
        .clk(clk_pix), .rst,
        .x, .y, .de(t_de), .hsync(t_hs), .vsync(t_vs), .frame_start(t_fs),
        .r, .g, .b, .de_o(de), .hsync_o(hsync), .vsync_o(vsync)
    );
endmodule
