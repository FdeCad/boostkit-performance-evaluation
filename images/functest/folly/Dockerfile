# 离线功能测试镜像 · folly 组:folly 本体 + fast_float 依赖
#
# folly 是纯 C++ 库,预构建镜像把 folly 与全部 C++ 依赖(boost/glog/gflags/fmt 等)
# 装在 /usr/local;用例仍需要上游源码树来比对版本、编译公共 API 程序。
#
# 构建(aarch64 机器,仓库根目录执行):
#   docker build -f images/functest/folly/Dockerfile \
#       -t openeuler/functest-folly:oe2403sp4-aarch64 .

FROM openeuler/openeuler-24.03-sp4:base

COPY --from=openeulertest/folly:2026.10.12.00-oe2403sp4-aarch64 /usr/local /usr/local

# ---- 源码归档缓存:裸镜像仓库,用例用 file:// 浅克隆对应 tag ----
ENV BOOSTKIT_SRC_ROOT=/opt/boostkit/src
RUN set -eu; \
    root=/opt/boostkit/src; \
    mkdir -p "$root"; \
    git clone --mirror --quiet https://github.com/facebook/folly.git "$root/folly.git"; \
    git clone --mirror --quiet https://github.com/fastfloat/fast_float.git "$root/fast_float.git"

# ---- 测试框架与用例 ----
COPY functional-framework/ /opt/boostkit/func/functional-framework/
COPY functional-cases/ /opt/boostkit/func/functional-cases/
COPY config/ /opt/boostkit/func/config/

# folly 的 CMakeLists 对找不到的依赖会退化成 FetchContent 联网下载,离线必须全部命中
# 系统包;这里按预构建镜像构建 folly 时用的同一套 devel 包安装(boost 1.83 等版本一致)。
RUN dnf install -y --setopt=install_weak_deps=False \
        python3-pyyaml \
        cmake \
        gcc \
        gcc-c++ \
        make \
        boost-devel \
        binutils-devel \
        bzip2-devel \
        elfutils-libelf-devel \
        fmt-devel \
        gflags-devel \
        glog-devel \
        libaio-devel \
        libdwarf-devel \
        libevent-devel \
        libsodium-devel \
        libunwind-devel \
        lz4-devel \
        openssl-devel \
        snappy-devel \
        systemtap-sdt-devel \
        xz-devel \
        zlib-devel \
        zstd-devel \
    && dnf clean all
# folly 装在 /usr/local/lib,openEuler 的 ld.so.conf 不含该路径,需要补上。
RUN printf '%s\n' /usr/local/lib /usr/local/lib64 > /etc/ld.so.conf.d/usr-local.conf \
    && ldconfig

WORKDIR /opt/boostkit/func
