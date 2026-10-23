# 离线功能测试镜像 · 冒烟样例(snappy 1.1.7)
#
# 目的:先用最小的一个软件验证「COPY --from 拼装 -> 打标签 -> 推送私有仓库 -> 换机器拉取运行」
# 整条链路。被测软件不重新编译,直接从官方预构建镜像按安装前缀拷过来。
#
# 构建(在仓库根目录执行,aarch64 机器):
#   docker build -f images/functest/smoke/Dockerfile \
#       -t functest-smoke:oe2403sp4-aarch64 .
#
# 底座镜像若本地还没有,先用仓库里的定义构建一次:
#   docker build -t kunpeng/openeuler-24.03-sp4:base images/openeuler-24.03

FROM kunpeng/openeuler-24.03-sp4:base

# snappy 1.1.7 的唯一安装前缀是 /usr/local:
#   lib64/libsnappy.so.1.1.7 + lib64/cmake/Snappy/SnappyConfigVersion.cmake + include/snappy*.h
# 直接把整个前缀搬过来,命令行、头文件、CMake 版本文件一起到位。
COPY --from=openeulertest/snappy:1.1.7-oe2403sp4-aarch64 /usr/local /usr/local

# 测试脚本与用例一并装进镜像,目标机器不需要再 clone 仓库。
# 目录层级与仓库保持一致,catalog_func.py 的 ROOT 会解析成 /opt/boostkit/func,
# 从而正确找到 config/functional.yaml 与 functional-cases/。
COPY functional-framework/ /opt/boostkit/func/functional-framework/
COPY functional-cases/ /opt/boostkit/func/functional-cases/
COPY config/ /opt/boostkit/func/config/

# python3-pyyaml 供 catalog_func.py 使用;ldconfig 刷新 /usr/local/lib64 的库缓存。
RUN dnf install -y --setopt=install_weak_deps=False python3-pyyaml \
    && dnf clean all \
    && ldconfig

WORKDIR /opt/boostkit/func
