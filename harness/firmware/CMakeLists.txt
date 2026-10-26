cmake_minimum_required(VERSION 3.13)

include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(harness_bridge C CXX ASM)
set(CMAKE_C_STANDARD 11)
pico_sdk_init()

add_executable(harness_bridge src/main.c)
# pins.h は make harness-fw が harness/pins.json から build/ に生成する
target_include_directories(harness_bridge PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
target_compile_definitions(harness_bridge PRIVATE HARNESS_BOARD="${PICO_BOARD}"
    # USB CDC のバッファ (既定 64 バイト) を大きくして、まとめて受け取れるようにする。
    # EP_BUFSIZE: 受け取りの 1 回の転送を 512 バイトに (既定の 64 = 1 パケットだと、USB のタスクが回るたびに 1 パケットしか進まない)。
    # USB のタスクは既定 1ms ごと。stream (v3) で 1MB/s 近くを受けるために 100us に
    CFG_TUD_CDC_RX_BUFSIZE=4096 CFG_TUD_CDC_TX_BUFSIZE=1024 CFG_TUD_CDC_EP_BUFSIZE=512
    PICO_STDIO_USB_TASK_INTERVAL_US=100)
target_link_libraries(harness_bridge pico_stdlib pico_bootrom hardware_gpio hardware_spi hardware_dma)
pico_enable_stdio_usb(harness_bridge 1)
pico_enable_stdio_uart(harness_bridge 0)   # GP0/GP1 は OLED 用に空けておく
pico_add_extra_outputs(harness_bridge)     # .uf2 / .bin / .hex を生成
