cmake_minimum_required(VERSION 3.13)

include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(vdp_host C CXX ASM)
set(CMAKE_C_STANDARD 11)
pico_sdk_init()

add_executable(vdp_host main.c)
target_link_libraries(vdp_host pico_stdlib hardware_spi)
pico_enable_stdio_usb(vdp_host 1)
pico_enable_stdio_uart(vdp_host 0)
pico_add_extra_outputs(vdp_host)   # .uf2 / .bin / .hex を生成
