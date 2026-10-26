# 离线功能测试镜像 · ai 组:faiss / hnswlib / openviking / pytorch / scann
#
# 被测软件不重新编译:按安装前缀从各官方预构建镜像直接搬过来,再叠加测试框架与
# 源码归档缓存。目标机器拔网线即可跑完整功能测试。
#
# 构建(aarch64 机器,仓库根目录执行):
#   docker build -f images/functest/ai/Dockerfile \
#       -t openeuler/functest-ai:oe2403sp4-aarch64 .

FROM openeuler/openeuler-24.03-sp4:base

# ---- 被测软件:python 侧安装前缀统一是 /usr/local ----
# 底座 python3.11 的 site.py 只在目录存在时才把 /usr/local/lib64|lib/python3.11
# 加进 sys.path,所以拷完 /usr/local 后 import 即可生效。
COPY --from=openeulertest/faiss:1.15.1-oe2403sp4-aarch64 /usr/local /usr/local
COPY --from=openeulertest/hnswlib:0.9.0-oe2403sp4-aarch64 /usr/local /usr/local
COPY --from=openeulertest/openviking:0.5.0-oe2403sp4-aarch64 /usr/local /usr/local
COPY --from=openeulertest/pytorch:2.14.1-oe2403sp4-aarch64 /usr/local /usr/local
COPY --from=openeulertest/scann:1.4.2-oe2403sp4-aarch64 /usr/local /usr/local
# scann 的 aarch64 wheel 只兼容 CPython 3.13,镜像自带独立解释器与 venv 在 /opt/python39。
COPY --from=openeulertest/scann:1.4.2-oe2403sp4-aarch64 /opt/python39 /opt/python39

# ---- 测试框架与用例(目标机器不需要再 clone 仓库) ----
COPY functional-framework/ /opt/boostkit/func/functional-framework/
COPY functional-cases/ /opt/boostkit/func/functional-cases/
COPY config/ /opt/boostkit/func/config/

# python3-pyyaml 供 catalog_func.py 使用;python3-pip 供 openviking/pytorch 用例的
# python 运行时探测;gcc/g++ 供 hnswlib 的 C++ 编译探针使用。
RUN dnf install -y --setopt=install_weak_deps=False \
        python3-pyyaml \
        python3-pip \
        gcc \
        gcc-c++ \
        make \
    && dnf clean all
# 各软件装在 /usr/local/lib(64),openEuler 的 ld.so.conf 不含这两条路径,需要补上。
RUN printf '%s\n' /usr/local/lib /usr/local/lib64 > /etc/ld.so.conf.d/usr-local.conf \
    && ldconfig

WORKDIR /opt/boostkit/func
