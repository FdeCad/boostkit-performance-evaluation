# 功能测试用 Ubuntu 26.04 基础镜像。
# 固化构建工具链,保证矩阵内可比、可离线、避免每次运行联网装包。
# 构建(aarch64 Runner 上):
#   docker build -t kunpeng/ubuntu:26.04.1 images/ubuntu-26.04
# 建议记录镜像 digest,锁定 ubuntu:26.04 这一滚动 tag 的实际内容。
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        build-essential \
        tcl \
        python3 \
        procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root