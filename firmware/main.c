// RP2350 側 (VDP のホスト CPU 役) の雛形
// 今は SPI を初期化して、FPGA に送る予定のダミーコマンドを周期的に出すだけ。
// ピン配置は配線に合わせて変更すること。
#include <stdio.h>
#include "pico/stdlib.h"
#include "hardware/spi.h"

#define VDP_SPI      spi0
#define PIN_SCK      2
#define PIN_MOSI     3
#define PIN_MISO     4
#define PIN_CS       5

int main(void) {
    stdio_init_all();

    spi_init(VDP_SPI, 10 * 1000 * 1000);
    gpio_set_function(PIN_SCK, GPIO_FUNC_SPI);
    gpio_set_function(PIN_MOSI, GPIO_FUNC_SPI);
    gpio_set_function(PIN_MISO, GPIO_FUNC_SPI);
    gpio_init(PIN_CS);
    gpio_set_dir(PIN_CS, GPIO_OUT);
    gpio_put(PIN_CS, 1);

#ifdef PICO_DEFAULT_LED_PIN
    gpio_init(PICO_DEFAULT_LED_PIN);
    gpio_set_dir(PICO_DEFAULT_LED_PIN, GPIO_OUT);
#endif

    uint8_t frame = 0;
    while (true) {
        // 例: [コマンド, 引数] を送る (FPGA 側のプロトコルは今後設計)
        uint8_t cmd[2] = {0x01, frame++};
        gpio_put(PIN_CS, 0);
        spi_write_blocking(VDP_SPI, cmd, sizeof cmd);
        gpio_put(PIN_CS, 1);

#ifdef PICO_DEFAULT_LED_PIN
        gpio_put(PICO_DEFAULT_LED_PIN, frame & 0x10);
#endif
        printf("vdp cmd frame=%u\n", frame);
        sleep_ms(16);
    }
}
