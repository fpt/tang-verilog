# syntax=docker/dockerfile:1
# RP2350 firmware toolchain: arm-none-eabi-gcc + pico-sdk + picotool
FROM debian:bookworm-slim

ARG PICO_SDK_VERSION=2.3.1
ARG PICOTOOL_VERSION=2.3.1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates git cmake ninja-build build-essential python3 pkg-config \
      gcc-arm-none-eabi libnewlib-arm-none-eabi libstdc++-arm-none-eabi-newlib \
      libusb-1.0-0-dev \
 && rm -rf /var/lib/apt/lists/*

ENV PICO_SDK_PATH=/opt/pico-sdk

# 社内プロキシの CA (任意)。`make certs.pem` で用意したものを BuildKit secret で受け取り、
# このステップの間だけ使う (イメージのレイヤには残さない)。secret が空/無ければシステムの CA だけを使う。
# pico-sdk 2.x は UF2 生成に picotool を使うので、ビルド時に毎回取得されないよう事前に入れておく。
RUN --mount=type=secret,id=ca_cert,required=false \
    set -eux; \
    if [ -s /run/secrets/ca_cert ]; then \
      cat /etc/ssl/certs/ca-certificates.crt /run/secrets/ca_cert > /tmp/ca.pem; \
      export GIT_SSL_CAINFO=/tmp/ca.pem; \
    fi; \
    git clone --depth 1 --branch ${PICO_SDK_VERSION} https://github.com/raspberrypi/pico-sdk.git /opt/pico-sdk; \
    git -C /opt/pico-sdk submodule update --init --depth 1; \
    git clone --depth 1 --branch ${PICOTOOL_VERSION} https://github.com/raspberrypi/picotool.git /tmp/picotool; \
    rm -f /tmp/ca.pem; \
    cmake -S /tmp/picotool -B /tmp/picotool/build -G Ninja \
      -DCMAKE_INSTALL_PREFIX=/opt/picotool -DPICOTOOL_FLAT_INSTALL=1; \
    cmake --build /tmp/picotool/build -j 2; \
    cmake --install /tmp/picotool/build; \
    rm -rf /tmp/picotool

ENV picotool_DIR=/opt/picotool/picotool
ENV PATH=/opt/picotool/picotool:${PATH}
ENV HOME=/tmp
WORKDIR /work
