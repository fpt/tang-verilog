// vdp_video を Verilator で回し、各フレームを PPM 画像として書き出す。
//   usage: render <出力ディレクトリ> <フレーム数>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include "Vvdp_video.h"
#include "verilated.h"

int main(int argc, char** argv) {
    const std::string outdir = argc > 1 ? argv[1] : ".";
    const int frames = argc > 2 ? std::atoi(argv[2]) : 3;
    constexpr int W = 640, H = 480;

    VerilatedContext ctx;
    Vvdp_video top{&ctx};

    auto tick = [&] {
        top.clk_pix = 0; top.eval();
        top.clk_pix = 1; top.eval();
    };

    top.rst = 1;
    for (int i = 0; i < 4; i++) tick();
    top.rst = 0;

    std::vector<unsigned char> fb(W * H * 3);
    int frame = 0, px = 0, line = 0;
    bool prev_de = false, prev_vs = true;

    while (frame < frames) {
        tick();
        // vsync の立ち下がりでフレーム終了
        if (prev_vs && !top.vsync && line > 0) {
            char path[512];
            std::snprintf(path, sizeof(path), "%s/frame_%03d.ppm", outdir.c_str(), frame);
            FILE* f = std::fopen(path, "wb");
            if (!f) { std::perror(path); return 1; }
            std::fprintf(f, "P6\n%d %d\n255\n", W, H);
            std::fwrite(fb.data(), 1, fb.size(), f);
            std::fclose(f);
            std::printf("wrote %s (%d lines)\n", path, line);
            frame++;
            line = 0;
        }
        if (top.de) {
            if (line < H && px < W) {
                unsigned char* p = &fb[(line * W + px) * 3];
                p[0] = top.r; p[1] = top.g; p[2] = top.b;
            }
            px++;
        } else if (prev_de) {
            px = 0;
            line++;
        }
        prev_de = top.de;
        prev_vs = top.vsync;
    }
    return 0;
}
