cmake_minimum_required(VERSION 3.13)

include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(harness_probe C CXX ASM)
set(CMAKE_C_STANDARD 11)
pico_sdk_init()

add_executable(harness_probe src/main.c)
# pins.h は make harness-fw が harness/pins.json から build/ に生成する
target_include_directories(harness_probe PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(harness_probe pico_stdlib hardware_gpio)
pico_enable_stdio_usb(harness_probe 1)
pico_enable_stdio_uart(harness_probe 0)   # GP0/GP1 は OLED 用に空けておく
pico_add_extra_outputs(harness_probe)     # .uf2 / .bin / .hex を生成
