cmake_minimum_required(VERSION 3.13)

include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(harness_bridge C CXX ASM)
set(CMAKE_C_STANDARD 11)
pico_sdk_init()

add_executable(harness_bridge src/main.c)
# pins.h は make harness-fw が harness/pins.json から build/ に生成する
target_include_directories(harness_bridge PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
target_compile_definitions(harness_bridge PRIVATE HARNESS_BOARD="${PICO_BOARD}"
    # USB CDC のバッファ (既定 64 バイト) を大きくして、まとめて受け取れるようにする
    CFG_TUD_CDC_RX_BUFSIZE=1024 CFG_TUD_CDC_TX_BUFSIZE=1024)
target_link_libraries(harness_bridge pico_stdlib pico_bootrom hardware_gpio hardware_spi)
pico_enable_stdio_usb(harness_bridge 1)
pico_enable_stdio_uart(harness_bridge 0)   # GP0/GP1 は OLED 用に空けておく
pico_add_extra_outputs(harness_bridge)     # .uf2 / .bin / .hex を生成
