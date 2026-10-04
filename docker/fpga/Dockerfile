# syntax=docker/dockerfile:1
# FPGA toolchain for Tang Nano 20K (Gowin GW2AR-18)
#   yosys / nextpnr-himbaechel / apicula(gowin_pack) / iverilog / verilator / cocotb / openFPGALoader
# すべて YosysHQ の OSS CAD Suite から取得する。
FROM debian:bookworm-slim

# OSS CAD Suite のリリース日 (https://github.com/YosysHQ/oss-cad-suite-build/releases)
ARG OSS_CAD_SUITE_DATE=2026-09-30
ARG TARGETARCH

# verilator の C++ ビルドに g++/make/perl が必要 (Python は OSS CAD Suite 同梱のものを使う)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl make g++ perl \
 && rm -rf /var/lib/apt/lists/*

# 社内プロキシの CA (任意)。`make certs.pem` で用意したものを BuildKit secret で受け取り、
# このステップの間だけ使う (イメージのレイヤには残さない)。secret が空/無ければシステムの CA だけを使う。
RUN --mount=type=secret,id=ca_cert,required=false \
    set -eux; \
    if [ -s /run/secrets/ca_cert ]; then \
      cat /etc/ssl/certs/ca-certificates.crt /run/secrets/ca_cert > /tmp/ca.pem; \
      export CURL_CA_BUNDLE=/tmp/ca.pem; \
    fi; \
    case "${TARGETARCH}" in \
      amd64) arch=x64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    date_compact="$(echo "${OSS_CAD_SUITE_DATE}" | tr -d -)"; \
    curl -fsSL "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${OSS_CAD_SUITE_DATE}/oss-cad-suite-linux-${arch}-${date_compact}.tgz" \
      | tar -xz -C /opt; \
    rm -f /tmp/ca.pem

ENV PATH=/opt/oss-cad-suite/bin:${PATH}

# 同梱 Python (cocotb 入り) を python3 として使えるようにする
RUN printf '#!/bin/sh\nexec /opt/oss-cad-suite/bin/tabbypy3 "$@"\n' > /usr/local/bin/python3 \
 && chmod +x /usr/local/bin/python3

# ホストの UID で実行されても困らないように HOME を書き込み可能な場所にしておく
ENV HOME=/tmp
WORKDIR /work
