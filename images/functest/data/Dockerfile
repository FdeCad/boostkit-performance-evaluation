# 离线功能测试镜像 · data 组:flink / spark / kubernetes / redis / rocksdb / mysql / oceanbase
#
# 被测软件不重新编译:按安装前缀从各官方预构建镜像直接搬过来,再叠加测试框架与
# 源码归档缓存。目标机器拔网线即可跑完整功能测试。
#
# 构建(aarch64 机器,仓库根目录执行):
#   docker build -f images/functest/data/Dockerfile \
#       -t openeuler/functest-data:oe2403sp4-aarch64 .

FROM openeuler/openeuler-24.03-sp4:base

# ---- 被测软件安装前缀 ----
# flink 自带 Java 21,spark 自带 Java 17,两套 JVM 目录名不同,可以共存。
COPY --from=openeulertest/flink:2.3.0-oe2403sp4-aarch64 /opt/flink /opt/flink
COPY --from=openeulertest/flink:2.3.0-oe2403sp4-aarch64 /usr/lib/jvm /usr/lib/jvm
COPY --from=openeulertest/spark:4.2.0-oe2403sp4-aarch64 /opt/spark /opt/spark
COPY --from=openeulertest/spark:4.2.0-oe2403sp4-aarch64 /usr/lib/jvm /usr/lib/jvm
# openEuler 的 JDK 把 conf/ 单独放在 /etc/java 下,<jvm>/conf 只是指向它的软链。
# 不一起搬过来会变成悬空软链,JVM 启动后初始化 java.security 直接失败
# (Could not initialize class java.security.Security)。
COPY --from=openeulertest/flink:2.3.0-oe2403sp4-aarch64 /etc/java /etc/java
COPY --from=openeulertest/spark:4.2.0-oe2403sp4-aarch64 /etc/java /etc/java
# kubernetes 用例只需要 kubectl,源码树的 _output 有 11G,单拷二进制即可。
COPY --from=openeulertest/kubernetes:1.37.1-oe2403sp4-aarch64 /usr/local/kubernetes-1.37.1/_output/local/go/bin/kubectl /usr/local/bin/kubectl
COPY --from=openeulertest/redis:8.10.2-oe2403sp4-aarch64 /usr/local /usr/local
COPY --from=openeulertest/rocksdb:11.8.1-oe2403sp4-aarch64 /usr/local /usr/local
# db_bench 动态链接 libgflags.so.2.2 / libsnappy.so.1,这两个库在预构建镜像的
# /usr/lib64 下(发行版包),不在 /usr/local,按文件精确搬运避免覆盖底座其它库。
COPY --from=openeulertest/rocksdb:11.8.1-oe2403sp4-aarch64 \
    /usr/lib64/libgflags.so.2.2 /usr/lib64/libgflags.so.2.2.2 \
    /usr/lib64/libgflags_nothreads.so.2.2 /usr/lib64/libgflags_nothreads.so.2.2.2 \
    /usr/lib64/libsnappy.so.1 /usr/lib64/libsnappy.so.1.1.10 \
    /usr/lib64/
# mysql:官方二进制包解压到 /usr/local/mysql(服务端在 server/ 子目录下)。
COPY --from=openeulertest/mysql:26.7.0-oe2403sp4-aarch64 /usr/local/mysql /usr/local/mysql
# oceanbase:rpm 直装到 /home/admin/oceanbase。
COPY --from=openeulertest/oceanbase:5.0.1-oe2403sp4-aarch64 /home/admin/oceanbase /home/admin/oceanbase
# oceanbase 的启动脚本 oceanbase-service.sh 固定读 /etc/oceanbase.cnf 拿端口与资源参数,
# 该文件不在安装前缀里,漏拷会导致 obshell 起不来。
COPY --from=openeulertest/oceanbase:5.0.1-oe2403sp4-aarch64 /etc/oceanbase.cnf /etc/oceanbase.cnf

# ---- 源码归档缓存:redis 上游 Tcl 套件需要源码树 ----
ENV BOOSTKIT_SRC_ROOT=/opt/boostkit/src
RUN set -eu; \
    mkdir -p /opt/boostkit/src; \
    git clone --mirror --quiet https://github.com/redis/redis.git /opt/boostkit/src/redis.git

# ---- 测试框架与用例 ----
COPY functional-framework/ /opt/boostkit/func/functional-framework/
COPY functional-cases/ /opt/boostkit/func/functional-cases/
COPY config/ /opt/boostkit/func/config/

# 预构建镜像里的 JAVA_HOME/PATH 不会随 COPY 带过来,这里把 java 固定到 Java 21
# (spark 4.x 同时接受 17/21)。libatomic 是 rocksdb db_bench 的缺失依赖,
# libaio 供 mysql/oceanbase 使用,tcl 供 redis 上游套件使用。
# mysql 官方二进制在 /usr/local/mysql/server/bin,放到 PATH 末尾:oceanbase 用发行版
# 的 mysql 8.0 客户端,只把 server/bin 当 mysql 用例定位 mysqld 的入口。
# hostname/mysql/sysbench 是 oceanbase 用例的运行期依赖,离线时装不了,必须预置。
# gcc/g++/make + gflags/压缩库开发包供 rocksdb 的 api-smoke 就地编译,
# 缺了会退回联网 dnf,断网场景直接失败。
RUN set -eu; \
    jhome="$(ls -d /usr/lib/jvm/java-21-openjdk-* | head -n 1)"; \
    ln -sf "${jhome}/bin/java" /usr/local/bin/java; \
    dnf install -y --setopt=install_weak_deps=False \
        python3-pyyaml \
        tcl \
        procps-ng \
        libaio \
        libatomic \
        xz \
        hostname \
        mysql \
        sysbench \
        gcc \
        gcc-c++ \
        make \
        gflags-devel \
        snappy-devel \
        lz4-devel \
        libzstd-devel \
        zlib-devel \
        bzip2-devel \
    && dnf clean all
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/mysql/server/bin"
# rocksdb/redis 的库在 /usr/local/lib(64),openEuler 的 ld.so.conf 不含该路径,需要补上。
RUN printf '%s\n' /usr/local/lib /usr/local/lib64 > /etc/ld.so.conf.d/usr-local.conf \
    && ldconfig

WORKDIR /opt/boostkit/func
