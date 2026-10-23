// ハーネスの RP2 ブリッジ (docs/GPU_PLAN.md の M0)
//
// GPU のレジスタやコマンドの意味は知らず、ホストから受け取った SPI のバイト列を素通しするだけ。
// 一度書き込んだら、原則として書き換えない。
//
// USB シリアルで 1 行 1 コマンド、応答は 1 行 JSON ("ok" が true/false):
//   ping                 ファームウェア名・版・ボード
//   status               全ハーネスピンの値、HEARTBEAT / VSYNC / IRQ の周期、ready 判定、カウンタ
//   spi <hex>            CS を上げて送受信し、受信を hex で返す (最大 4096 バイト)。ready でなければ何も駆動しない
//   spib <n>             改行 (\n 1 文字) の直後に n バイトの生データを続けて送る。送るだけで、応答は受信の最初の 1 バイト (同期確認用) だけ。
//                        大きいデータの書き込み用 (16 進にしないので USB の量が半分、受信も送り返さない)。v2 から
//   freq <hz>            SPI の周波数
//   reset [ms]           RESET を指定時間 High にする (既定 10ms)
//   irqwait [ms]         IRQ の立ち上がりを待つ (既定 100ms)
//   wiretest             配線テスト (FPGA に top_harness_probe が入っているとき)
//   bootsel              BOOTSEL (UF2 書き込み) モードで再起動する
//
// 衝突させないための約束:
//   - ハーネスのピンは、駆動するとき以外は常に「入力 + プルダウン」(release_all / release)
//   - RP2 -> FPGA の線は正論理なので、プルダウンされた状態は「何もしていない」
//   - SPI 線を駆動するのは、HEARTBEAT が直近 100ms 以内にトグルしている (FPGA に設計が入って動いている) ときだけ
//   - ピンの向きと機能を変えるのはこのファイルだけ。ピン番号は harness/pins.json から生成した pins.h
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "pico/stdlib.h"
#include "pico/bootrom.h"
#include "hardware/gpio.h"
#include "hardware/spi.h"
#include "pins.h"

#define FW_NAME          "harness-bridge"
#define FW_VERSION       2
#define BRIDGE_SPI       spi0
#define READY_WINDOW_US  100000u
#define MAX_SPI_BYTES    4096
#define LINE_MAX         (16 + 2 * MAX_SPI_BYTES)

#ifndef HARNESS_BOARD
#define HARNESS_BOARD "unknown"
#endif

// ---------------------------------------------------------------- ピン

static void release(unsigned gpio) {
    gpio_init(gpio);                   // SIO, 入力, 出力値 0
    gpio_set_pulls(gpio, false, true);
}

// ハーネスの全ピン (と未使用の GP0/GP1) を入力 + プルダウンにする
static void release_all(void) {
    for (int i = 0; i < HARNESS_PIN_COUNT; i++) release(HARNESS_PINS[i].gpio);
    release(0);
    release(1);
}

static const char *pin_name(unsigned gpio) {
    for (int i = 0; i < HARNESS_PIN_COUNT; i++)
        if (HARNESS_PINS[i].gpio == gpio) return HARNESS_PINS[i].name;
    return "?";
}

static uint32_t harness_mask(bool fpga_output) {
    uint32_t m = 0;
    for (int i = 0; i < HARNESS_PIN_COUNT; i++)
        if (HARNESS_PINS[i].fpga_output == fpga_output) m |= 1u << HARNESS_PINS[i].gpio;
    return m;
}

// ---------------------------------------------------------------- エッジの監視

typedef struct {
    volatile uint64_t last_us;    // 直近の立ち上がり
    volatile uint32_t period_us;  // 直近 2 回の立ち上がりの間隔
    volatile uint32_t rises;
} edge_t;

static edge_t edge_hb, edge_vs, edge_irq;

static void gpio_cb(uint gpio, uint32_t events) {
    if (!(events & GPIO_IRQ_EDGE_RISE)) return;
    edge_t *e = gpio == PIN_HEARTBEAT ? &edge_hb : gpio == PIN_VSYNC ? &edge_vs : gpio == PIN_IRQ ? &edge_irq : NULL;
    if (!e) return;
    uint64_t now = time_us_64();
    if (e->last_us) e->period_us = (uint32_t)(now - e->last_us);
    e->last_us = now;
    e->rises++;
}

static void monitor_enable(void) {
    gpio_set_irq_enabled_with_callback(PIN_HEARTBEAT, GPIO_IRQ_EDGE_RISE, true, gpio_cb);
    gpio_set_irq_enabled(PIN_VSYNC, GPIO_IRQ_EDGE_RISE, true);
    gpio_set_irq_enabled(PIN_IRQ, GPIO_IRQ_EDGE_RISE, true);
}

static bool fpga_ready(void) {
    uint64_t last = edge_hb.last_us;
    return last != 0 && time_us_64() - last < READY_WINDOW_US;
}

static void print_edge(const char *name, const edge_t *e) {
    uint64_t last = e->last_us;
    uint64_t age_us = last ? time_us_64() - last : 0;
    // 1 秒以上エッジがなければ止まっているとみなす
    double hz = (last && age_us < 1000000 && e->period_us) ? 1e6 / e->period_us : 0.0;
    printf("\"%s\":{\"hz\":%.2f,\"rises\":%lu,\"age_ms\":%ld}", name, hz, (unsigned long)e->rises,
           last ? (long)(age_us / 1000) : -1L);
}

// ---------------------------------------------------------------- SPI

static uint32_t spi_hz;
static uint32_t n_spi_ok, n_spi_refused;

// CS を上げて送受信し、下げる。終わったら全部入力 + プルダウンに戻す
static void spi_xfer(const uint8_t *tx, uint8_t *rx, size_t n) {
    gpio_put(PIN_CS, 0);
    gpio_set_dir(PIN_CS, GPIO_OUT);
    gpio_set_function(PIN_SCK, GPIO_FUNC_SPI);
    gpio_set_function(PIN_COPI, GPIO_FUNC_SPI);
    gpio_set_function(PIN_CIPO, GPIO_FUNC_SPI);
    gpio_put(PIN_CS, 1);
    spi_write_read_blocking(BRIDGE_SPI, tx, rx, n);
    gpio_put(PIN_CS, 0);
    release(PIN_SCK);
    release(PIN_COPI);
    release(PIN_CIPO);
    release(PIN_CS);
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// ---------------------------------------------------------------- 配線テスト

#define WIRETEST_SAMPLE_US 500000u
#define FPGA_CLK_HZ        27000000.0

// FPGA -> RP2 の各線が使うカウンタのビット (rtl/gowin/top_harness_probe.sv と合わせる)
static const struct { unsigned gpio; int bit; } PROBE_BITS[] = {
    {PIN_CIPO, 10}, {PIN_IRQ, 11}, {PIN_VSYNC, 12}, {PIN_HEARTBEAT, 13}, {PIN_ERROR, 14},
    {PIN_LED0, 15}, {PIN_LED1, 16}, {PIN_LED2, 17}, {PIN_LED3, 18}, {PIN_LED4, 19}, {PIN_LED5, 20},
};

// RP2 が High にする線と、FPGA が折り返してくる線
static const struct { unsigned drive; unsigned echo; } LOOPBACK[] = {
    {PIN_SCK, PIN_CIPO}, {PIN_COPI, PIN_IRQ}, {PIN_CS, PIN_VSYNC}, {PIN_RESET, PIN_HEARTBEAT},
};

static void cmd_wiretest(void) {
    const uint32_t from_fpga = harness_mask(true);
    const uint32_t to_fpga   = harness_mask(false);
    bool pass = true;

    release_all();
    sleep_ms(10);

    // 第 1 段階: 読むだけ
    static uint32_t rises[32];
    memset(rises, 0, sizeof rises);
    uint32_t prev = gpio_get_all(), ever_high = prev;
    const uint64_t end = time_us_64() + WIRETEST_SAMPLE_US;
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

    printf("{\"phase1\":[");
    for (size_t i = 0; i < count_of(PROBE_BITS); i++) {
        unsigned g = PROBE_BITS[i].gpio;
        double expect = FPGA_CLK_HZ / (double)(1u << (PROBE_BITS[i].bit + 1)) * (WIRETEST_SAMPLE_US / 1e6);
        bool ok = abs((int)rises[g] - (int)(expect + 0.5)) <= (int)(expect / 10) + 2;
        pass &= ok;
        printf("%s{\"sig\":\"%s\",\"rises\":%lu,\"expect\":%.0f,\"ok\":%s}", i ? "," : "", pin_name(g),
               (unsigned long)rises[g], expect, ok ? "true" : "false");
    }
    // RP2 -> FPGA の線は FPGA が駆動していないはずなので、ずっと Low
    for (int g = 0; g < 32; g++) {
        if (!(to_fpga & (1u << g))) continue;
        bool ok = rises[g] == 0 && !(ever_high & (1u << g));
        pass &= ok;
        printf(",{\"sig\":\"%s\",\"rises\":%lu,\"high_seen\":%s,\"ok\":%s}", pin_name(g), (unsigned long)rises[g],
               (ever_high & (1u << g)) ? "true" : "false", ok ? "true" : "false");
    }
    printf("]");

    // 第 2 段階: 第 1 段階が全部通ったときだけ、1 本ずつ 100us High にして折り返しを見る
    if (pass) {
        printf(",\"phase2\":[");
        for (size_t i = 0; i < count_of(LOOPBACK); i++) {
            unsigned d = LOOPBACK[i].drive;
            gpio_put(d, 1);
            gpio_set_dir(d, GPIO_OUT);
            sleep_us(100);
            uint32_t v = gpio_get_all() & from_fpga;
            release(d);
            sleep_us(100);
            bool ok = v == (1u << LOOPBACK[i].echo);   // 折り返し先だけが High
            pass &= ok;
            printf("%s{\"drive\":\"%s\",\"echo\":\"%s\",\"seen\":\"0x%08lx\",\"ok\":%s}", i ? "," : "",
                   pin_name(d), pin_name(LOOPBACK[i].echo), (unsigned long)v, ok ? "true" : "false");
        }
        printf("]");
    } else {
        printf(",\"phase2\":\"skipped\"");
    }

    release_all();
    monitor_enable();
    printf(",\"ok\":%s}\n", pass ? "true" : "false");
}

// ---------------------------------------------------------------- コマンド

static void reply_error(const char *msg) {
    printf("{\"ok\":false,\"error\":\"%s\"}\n", msg);
}

static void cmd_status(void) {
    printf("{\"ok\":true,\"ready\":%s,\"uptime_ms\":%lu,\"spi_hz\":%lu,\"spi_ok\":%lu,\"spi_refused\":%lu,\"pins\":{",
           fpga_ready() ? "true" : "false", (unsigned long)(time_us_64() / 1000), (unsigned long)spi_hz,
           (unsigned long)n_spi_ok, (unsigned long)n_spi_refused);
    for (int i = 0; i < HARNESS_PIN_COUNT; i++)
        printf("%s\"%s\":%d", i ? "," : "", HARNESS_PINS[i].name, gpio_get(HARNESS_PINS[i].gpio));
    printf("},");
    print_edge("heartbeat", &edge_hb);
    printf(",");
    print_edge("vsync", &edge_vs);
    printf(",");
    print_edge("irq", &edge_irq);
    printf("}\n");
}

static void cmd_spi(const char *hex) {
    static uint8_t tx[MAX_SPI_BYTES], rx[MAX_SPI_BYTES];
    size_t len = strlen(hex);
    if (len == 0 || len % 2 || len / 2 > MAX_SPI_BYTES) { reply_error("spi: need 1..4096 bytes of hex"); return; }
    for (size_t i = 0; i < len / 2; i++) {
        int hi = hexval(hex[2 * i]), lo = hexval(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) { reply_error("spi: bad hex"); return; }
        tx[i] = (uint8_t)(hi << 4 | lo);
    }
    if (!fpga_ready()) {
        n_spi_refused++;
        { reply_error("not ready: HEARTBEAT is not toggling, nothing was driven"); return; }
    }
    spi_xfer(tx, rx, len / 2);
    n_spi_ok++;
    static const char digits[] = "0123456789abcdef";
    static char out[2 * MAX_SPI_BYTES + 1];
    for (size_t i = 0; i < len / 2; i++) {
        out[2 * i] = digits[rx[i] >> 4];
        out[2 * i + 1] = digits[rx[i] & 15];
    }
    out[len] = 0;
    printf("{\"ok\":true,\"rx\":\"%s\"}\n", out);
}

// ---------------------------------------------------------------- USB からの入力
// 1 文字ずつではなく、届いている分をまとめて in_buf に読む (v1 は getchar で 1 文字ずつ読んでいて、2KiB の spi に 60ms かかっていた)
#define IN_BUF_SIZE (LINE_MAX + MAX_SPI_BYTES)
static uint8_t in_buf[IN_BUF_SIZE];
static size_t  in_head, in_tail;      // [in_head, in_tail) が未処理

static void in_fill(uint32_t timeout_us) {
    if (in_head == in_tail) {
        in_head = in_tail = 0;
    } else if (in_tail == IN_BUF_SIZE) {
        memmove(in_buf, in_buf + in_head, in_tail - in_head);
        in_tail -= in_head;
        in_head = 0;
    }
    if (in_tail == IN_BUF_SIZE) return;
    int n = stdio_get_until((char *)in_buf + in_tail, (int)(IN_BUF_SIZE - in_tail), make_timeout_time_us(timeout_us));
    if (n > 0) in_tail += (size_t)n;
}

// 次の 1 行 (\n か \r まで、改行は含めない)。長すぎる行は *overflow を立てて残りを読み捨てる
static void in_line(char *line, size_t max, bool *overflow) {
    size_t len = 0;
    *overflow = false;
    while (true) {
        while (in_head < in_tail) {
            char c = (char)in_buf[in_head++];
            if (c == '\n' || c == '\r') {
                if (len || *overflow) {
                    line[len] = 0;
                    return;
                }
                continue;                   // 空行
            }
            if (len < max - 1) line[len++] = c;
            else               *overflow = true;
        }
        in_fill(100000);
    }
}

// n バイトの生データ。timeout_us 以内に揃わなければ false (それまでに読んだ分は捨てる)
static bool in_bytes(uint8_t *dst, size_t n, uint32_t timeout_us) {
    absolute_time_t until = make_timeout_time_us(timeout_us);
    size_t got = 0;
    while (got < n) {
        size_t k = in_tail - in_head;
        if (k > n - got) k = n - got;
        memcpy(dst + got, in_buf + in_head, k);
        in_head += k;
        got += k;
        if (got < n) {
            if (time_reached(until)) return false;
            in_fill(1000);
        }
    }
    return true;
}

static void cmd_spib(const char *arg) {
    static uint8_t tx[MAX_SPI_BYTES], rx[MAX_SPI_BYTES];
    long n = arg ? atol(arg) : 0;
    if (n < 1 || n > MAX_SPI_BYTES) { reply_error("spib: 1..4096 bytes"); return; }
    if (!in_bytes(tx, (size_t)n, 2000000)) { reply_error("spib: timeout waiting for data"); return; }
    if (!fpga_ready()) {
        n_spi_refused++;
        reply_error("not ready: HEARTBEAT is not toggling, nothing was driven");
        return;
    }
    spi_xfer(tx, rx, (size_t)n);
    n_spi_ok++;
    printf("{\"ok\":true,\"n\":%ld,\"rx0\":\"%02x\"}\n", n, rx[0]);
}

static void handle(char *line) {
    char *cmd = strtok(line, " \t");
    char *arg = strtok(NULL, " \t");
    if (!cmd) return;

    if (!strcmp(cmd, "ping")) {
        printf("{\"ok\":true,\"fw\":\"%s\",\"version\":%d,\"board\":\"%s\"}\n", FW_NAME, FW_VERSION, HARNESS_BOARD);
    } else if (!strcmp(cmd, "status")) {
        cmd_status();
    } else if (!strcmp(cmd, "spib")) {
        cmd_spib(arg);
    } else if (!strcmp(cmd, "spi")) {
        cmd_spi(arg ? arg : "");
    } else if (!strcmp(cmd, "freq")) {
        long hz = arg ? atol(arg) : 0;
        if (hz < 10000 || hz > 16000000) { reply_error("freq: 10000..16000000"); return; }
        spi_hz = spi_set_baudrate(BRIDGE_SPI, (uint)hz);
        printf("{\"ok\":true,\"spi_hz\":%lu}\n", (unsigned long)spi_hz);
    } else if (!strcmp(cmd, "reset")) {
        // FPGA 側は入力専用 (pincheck で保証)。止まった FPGA を戻すためのものなので ready は見ない
        long ms = arg ? atol(arg) : 10;
        if (ms < 1 || ms > 5000) { reply_error("reset: 1..5000 ms"); return; }
        gpio_put(PIN_RESET, 1);
        gpio_set_dir(PIN_RESET, GPIO_OUT);
        sleep_ms((uint32_t)ms);
        release(PIN_RESET);
        printf("{\"ok\":true,\"ms\":%ld}\n", ms);
    } else if (!strcmp(cmd, "irqwait")) {
        long ms = arg ? atol(arg) : 100;
        if (ms < 1 || ms > 10000) { reply_error("irqwait: 1..10000 ms"); return; }
        uint32_t start_rises = edge_irq.rises;
        uint64_t start = time_us_64(), deadline = start + (uint64_t)ms * 1000;
        while (edge_irq.rises == start_rises && time_us_64() < deadline) tight_loop_contents();
        if (edge_irq.rises == start_rises) { reply_error("irqwait: timeout"); return; }
        printf("{\"ok\":true,\"waited_us\":%lu}\n", (unsigned long)(edge_irq.last_us - start));
    } else if (!strcmp(cmd, "wiretest")) {
        cmd_wiretest();
    } else if (!strcmp(cmd, "bootsel")) {
        printf("{\"ok\":true}\n");
        stdio_flush();
        sleep_ms(100);
        release_all();
        reset_usb_boot(0, 0);
    } else {
        reply_error("unknown command");
    }
}

int main(void) {
    release_all();
    stdio_init_all();
    spi_hz = spi_init(BRIDGE_SPI, 1000 * 1000);   // mode 0, 8bit, MSB first
    monitor_enable();

    static char line[LINE_MAX];
    bool overflow;
    while (true) {
        in_line(line, sizeof line, &overflow);
        if (overflow) reply_error("line too long");
        else          handle(line);
        stdio_flush();
    }
}
