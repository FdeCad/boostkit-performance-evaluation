# 功能测试用 openEuler 24.03 LTS SP4 基础镜像。
# 固化构建工具链,保证矩阵内可比、可离线、避免每次运行联网装包。
# 构建(aarch64 Runner 上):
#   docker build -t kunpeng/openeuler:24.03-sp4 images/openeuler-24.03
# 建议记录镜像 digest,锁定 openeuler/openeuler:24.03-lts-sp4 的实际内容。
FROM openeuler/openeuler:24.03-lts-sp4

RUN dnf install -y --setopt=install_weak_deps=False \
        bash \
        ca-certificates \
        curl \
        git \
        make \
        gcc \
        gcc-c++ \
        tcl \
        python3 \
        procps-ng \
        tar \
        gzip \
    && dnf clean all

WORKDIR /root