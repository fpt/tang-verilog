// vdp_video を Verilator で回し、各フレームを PPM 画像として書き出す。
//   usage: render <出力ディレクトリ> <フレーム数> [freeze]
//   freeze を 1 にすると vdp_video の freeze を立てたまま回す (実機で CONTROL のアニメーション停止を立てたときと同じ画面)
// 画像の大きさは DE の幅と行数から求める (vdp_video の MODE に依存しない)
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include "Vvdp_video.h"
#include "verilated.h"

int main(int argc, char** argv) {
    const std::string outdir = argc > 1 ? argv[1] : ".";
    const int frames = argc > 2 ? std::atoi(argv[2]) : 3;
    const bool freeze = argc > 3 && std::atoi(argv[3]) != 0;
    constexpr int MAX_W = 2048, MAX_H = 1024;

    VerilatedContext ctx;
    Vvdp_video top{&ctx};

    auto tick = [&] {
        top.clk_pix = 0; top.eval();
        top.clk_pix = 1; top.eval();
    };

    top.freeze = freeze;
    top.rst = 1;
    for (int i = 0; i < 4; i++) tick();
    top.rst = 0;

    std::vector<unsigned char> fb(MAX_W * MAX_H * 3);
    int frame = 0, px = 0, line = 0, width = 0;
    bool prev_de = false, prev_vs = true;

    while (frame < frames) {
        tick();
        // vsync の立ち下がりでフレーム終了
        if (prev_vs && !top.vsync && line > 0) {
            char path[512];
            std::snprintf(path, sizeof(path), "%s/frame_%03d.ppm", outdir.c_str(), frame);
            FILE* f = std::fopen(path, "wb");
            if (!f) { std::perror(path); return 1; }
            const int h = line < MAX_H ? line : MAX_H;
            std::fprintf(f, "P6\n%d %d\n255\n", width, h);
            for (int yy = 0; yy < h; yy++)
                std::fwrite(&fb[yy * MAX_W * 3], 1, width * 3, f);
            std::fclose(f);
            std::printf("wrote %s (%dx%d)\n", path, width, line);
            frame++;
            line = 0;
        }
        if (top.de) {
            if (line < MAX_H && px < MAX_W) {
                unsigned char* p = &fb[(line * MAX_W + px) * 3];
                p[0] = top.r; p[1] = top.g; p[2] = top.b;
            }
            px++;
        } else if (prev_de) {
            if (px > width) width = px < MAX_W ? px : MAX_W;
            px = 0;
            line++;
        }
        prev_de = top.de;
        prev_vs = top.vsync;
    }
    return 0;
}
