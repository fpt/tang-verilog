// ハーネスの配線テスト (RP2 側)。FPGA に top_harness_probe を書き込んだ状態で使う
//
// 衝突させないための約束:
//   - 起動時と各テストの前後に、ハーネスの全ピンを「入力 + プルダウン」に戻す (release_all)
//   - 第 1 段階は読むだけ。FPGA -> RP2 の各線の周波数を数え、RP2 -> FPGA の線が Low のまま動かないことを確認する
//   - 第 1 段階が全部通ったときだけ、第 2 段階で RP2 -> FPGA の線を 1 本ずつ 100us だけ High にして折り返しを見る
//   - ピンの向きを変えるのはこのファイルの release_all / drive_pulse だけ
//
// 結果は USB シリアルに 1 行 1 JSON で出す ('#' で始まる行は人間向け)。
// 起動後に 1 回、以降は 3 秒ごと、または 't' を受け取ったときに実行する。
#include <stdio.h>
#include <stdlib.h>
#include "pico/stdlib.h"
#include "hardware/gpio.h"
#include "pins.h"

#define SAMPLE_US      500000u    // 第 1 段階の観測時間
#define FPGA_CLK_HZ    27000000.0
#define REPEAT_MS      3000

// FPGA -> RP2 の各線が使うカウンタのビット (rtl/gowin/top_harness_probe.sv と合わせる)
static const struct { unsigned gpio; int bit; } PROBE_BITS[] = {
    {PIN_CIPO, 10}, {PIN_IRQ_N, 11}, {PIN_VSYNC, 12}, {PIN_HEARTBEAT, 13}, {PIN_ERROR, 14},
    {PIN_LED0, 15}, {PIN_LED1, 16}, {PIN_LED2, 17}, {PIN_LED3, 18}, {PIN_LED4, 19}, {PIN_LED5, 20},
};

// 第 2 段階: RP2 が High にする線と、FPGA が折り返してくる線
static const struct { unsigned drive; unsigned echo; } LOOPBACK[] = {
    {PIN_SCK, PIN_CIPO}, {PIN_COPI, PIN_IRQ_N}, {PIN_CS_N, PIN_VSYNC}, {PIN_RESET_N, PIN_HEARTBEAT},
};

static uint32_t harness_mask(bool fpga_output) {
    uint32_t m = 0;
    for (int i = 0; i < HARNESS_PIN_COUNT; i++)
        if (HARNESS_PINS[i].fpga_output == fpga_output) m |= 1u << HARNESS_PINS[i].gpio;
    return m;
}

static const char *pin_name(unsigned gpio) {
    for (int i = 0; i < HARNESS_PIN_COUNT; i++)
        if (HARNESS_PINS[i].gpio == gpio) return HARNESS_PINS[i].name;
    return "?";
}

// ハーネスの全ピン (と未使用の GP0/GP1) を入力 + プルダウンにする
static void release_all(void) {
    for (int i = 0; i < HARNESS_PIN_COUNT; i++) {
        unsigned g = HARNESS_PINS[i].gpio;
        gpio_init(g);                  // SIO, 入力, 出力値 0
        gpio_set_pulls(g, false, true);
    }
    for (unsigned g = 0; g <= 1; g++) {
        gpio_init(g);
        gpio_set_pulls(g, false, true);
    }
}

// 1 本だけ短時間 High にして、その間の全ピンの値を返す。終わったら入力 + プルダウンに戻す
static uint32_t drive_pulse(unsigned gpio) {
    gpio_put(gpio, 1);
    gpio_set_dir(gpio, GPIO_OUT);
    sleep_us(100);
    uint32_t v = gpio_get_all();
    gpio_set_dir(gpio, GPIO_IN);
    gpio_put(gpio, 0);
    sleep_us(100);
    return v;
}

static void run_test(int run) {
    const uint32_t from_fpga = harness_mask(true);
    const uint32_t to_fpga   = harness_mask(false);
    bool pass = true;

    release_all();
    sleep_ms(10);

    // --- 第 1 段階: 読むだけ ---
    static uint32_t rises[32];
    for (int i = 0; i < 32; i++) rises[i] = 0;
    uint32_t prev = gpio_get_all(), ever_high = prev;
    const uint64_t end = time_us_64() + SAMPLE_US;
    while (time_us_64() < end) {
        uint32_t v = gpio_get_all();
        uint32_t rise = v & ~prev;
        ever_high |= v;
        while (rise) {
            rises[__builtin_ctz(rise)]++;
            rise &= rise - 1;
        }
        prev = v;
    }

    printf("{\"run\":%d,\"phase1\":[", run);
    bool first = true;
    for (size_t i = 0; i < count_of(PROBE_BITS); i++) {
        unsigned g = PROBE_BITS[i].gpio;
        double expect = FPGA_CLK_HZ / (double)(1u << (PROBE_BITS[i].bit + 1)) * (SAMPLE_US / 1e6);
        bool ok = abs((int)rises[g] - (int)(expect + 0.5)) <= (int)(expect / 10) + 2;
        pass &= ok;
        printf("%s{\"sig\":\"%s\",\"gpio\":%u,\"rises\":%lu,\"expect\":%.0f,\"ok\":%s}",
               first ? "" : ",", pin_name(g), g, (unsigned long)rises[g], expect, ok ? "true" : "false");
        first = false;
    }
    // RP2 -> FPGA の線は FPGA が駆動していないはずなので、ずっと Low
    bool idle_ok = true;
    for (int g = 0; g < 32; g++) {
        if (!(to_fpga & (1u << g))) continue;
        bool ok = rises[g] == 0 && !(ever_high & (1u << g));
        idle_ok &= ok;
        printf(",{\"sig\":\"%s\",\"gpio\":%d,\"rises\":%lu,\"high_seen\":%s,\"ok\":%s}", pin_name(g), g,
               (unsigned long)rises[g], (ever_high & (1u << g)) ? "true" : "false", ok ? "true" : "false");
    }
    pass &= idle_ok;
    printf("]");

    // --- 第 2 段階: 1 本ずつ駆動して折り返しを見る (第 1 段階が全部通ったときだけ) ---
    if (pass) {
        printf(",\"phase2\":[");
        for (size_t i = 0; i < count_of(LOOPBACK); i++) {
            uint32_t v = drive_pulse(LOOPBACK[i].drive) & from_fpga;
            bool ok = v == (1u << LOOPBACK[i].echo);   // 折り返し先だけが High、他の FPGA -> RP2 線は Low
            pass &= ok;
            printf("%s{\"drive\":\"%s\",\"echo\":\"%s\",\"seen\":\"0x%08lx\",\"ok\":%s}", i ? "," : "",
                   pin_name(LOOPBACK[i].drive), pin_name(LOOPBACK[i].echo), (unsigned long)v, ok ? "true" : "false");
        }
        printf("]");
    } else {
        printf(",\"phase2\":\"skipped\"");
    }

    release_all();
    printf(",\"pass\":%s}\n", pass ? "true" : "false");
    printf("# run %d: %s%s\n", run, pass ? "PASS" : "FAIL",
           pass ? "" : (idle_ok ? "" : " (an RP2->FPGA line is not idle low: FPGA probe not loaded or miswired; nothing was driven)"));
}

int main(void) {
    release_all();
    stdio_init_all();

    int run = 0;
    absolute_time_t next = make_timeout_time_ms(2000);   // USB の接続を少し待つ
    while (true) {
        int c = getchar_timeout_us(10000);
        if (c == 't' || time_reached(next)) {
            run_test(++run);
            next = make_timeout_time_ms(REPEAT_MS);
        }
    }
}
