# 离线功能测试镜像 · toolchain 组:gcc / glibc / golang / openjdk / python
#
# 被测软件不重新编译:按安装前缀从各官方预构建镜像直接搬过来,再叠加测试框架。
# 目标机器拔网线即可跑完整功能测试。
#
# 构建(aarch64 机器,仓库根目录执行):
#   docker build -f images/functest/toolchain/Dockerfile \
#       -t openeuler/functest-toolchain:oe2403sp4-aarch64 .

FROM openeuler/openeuler-24.03-sp4:base

# ---- 被测软件安装前缀 ----
# gcc:用例只读安装前缀 /usr/local/gcc;镜像里另有 9.9G 的 /opt/gcc-16.2.0 构建树,不拷。
COPY --from=openeulertest/gcc:16.2.0-oe2403sp4-aarch64 /usr/local/gcc /usr/local/gcc
COPY --from=openeulertest/glibc:2.43-oe2403sp4-aarch64 /usr/local/glibc /usr/local/glibc
COPY --from=openeulertest/go:1.27.1-oe2403sp4-aarch64 /usr/local/go /usr/local/go
COPY --from=openeulertest/openjdk:28_19-oe2403sp4-aarch64 /usr/local/java /usr/local/java
COPY --from=openeulertest/python:3.15.0-oe2403sp4-aarch64 /usr/local/python3.15.0 /usr/local/python3.15.0

# ---- 测试框架与用例 ----
COPY functional-framework/ /opt/boostkit/func/functional-framework/
COPY functional-cases/ /opt/boostkit/func/functional-cases/
COPY config/ /opt/boostkit/func/config/

# python 用例按 /usr/local/python<主.次>/bin/python3 探测,补一个版本目录别名;
# 默认 python3 仍指向底座的 3.11,避免测试框架自身的 pyyaml 依赖失效。
# isl 是 gcc 16.2.0 的 cc1/cc1plus 运行期依赖(libisl.so.23),底座没有,漏装会
# 直接 "error while loading shared libraries: libisl.so.23"。
RUN set -eu; \
    ln -s /usr/local/python3.15.0 /usr/local/python3.15; \
    dnf install -y --setopt=install_weak_deps=False \
        python3-pyyaml \
        which \
        make \
        gcc \
        gcc-c++ \
        isl \
    && dnf clean all
# 各组件的库在 /usr/local/lib(64)。
# 注意不要把 /usr/local/glibc/lib、/usr/local/gcc/lib64 注册进 ld.so.conf:那会让
# 系统二进制(如 bash)用底座 2.38 的加载器去加载 glibc 2.43 的 libc,直接 SIGBUS。
# glibc/gcc 用例本来就是显式用 <glibc>/ld-linux --library-path 或编译期 rpath 运行的。
RUN printf '%s\n' /usr/local/lib /usr/local/lib64 \
        > /etc/ld.so.conf.d/usr-local.conf \
    && ldconfig

WORKDIR /opt/boostkit/func
