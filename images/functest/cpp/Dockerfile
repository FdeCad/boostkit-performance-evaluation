# 离线功能测试镜像 · cpp 组:brpc / cloudwego / protobuf / snappy / lz4 / x264 / x265
#
# 被测软件不重新编译:按安装前缀从各官方预构建镜像直接搬过来,再叠加测试框架、
# 源码归档缓存和 Go 模块缓存。目标机器拔网线即可跑完整功能测试。
#
# 构建(aarch64 机器,仓库根目录执行,需要联网拉基础镜像与上游源码):
#   docker build -f images/functest/cpp/Dockerfile \
#       -t openeuler/functest-cpp:oe2403sp4-aarch64 .

FROM openeuler/openeuler-24.03-sp4:base

# ---- 被测软件安装前缀 ----
# brpc 的安装前缀就是 /brpc(同时保留了上游源码树,含 example/echo_c++)。
# brpc 本体是静态库 /usr/lib64/libbrpc.a,头文件在 /usr/include,依赖的
# protobuf 25.1/gflags/leveldb/abseil 也都在 /usr 下,必须一并带过来。
COPY --from=openeulertest/brpc:1.18.0-oe2403sp4-aarch64 /brpc /brpc
COPY --from=openeulertest/brpc:1.18.0-oe2403sp4-aarch64 /usr/include /usr/include
COPY --from=openeulertest/brpc:1.18.0-oe2403sp4-aarch64 /usr/lib64 /usr/lib64
# brpc 的 protobuf 25.1 编译器(装在 /usr/bin);/usr/local/bin 的 36.2 供 protobuf 用例用,
# 两者靠 PATH 顺序隔离,brpc 用例按自己的安装前缀取 /usr/bin/protoc。
COPY --from=openeulertest/brpc:1.18.0-oe2403sp4-aarch64 /usr/bin/protoc /usr/bin/protoc
# 组镜像里 /usr/local/include 是 protobuf 36.2,会盖住 /usr/include 的 25.1;而 gcc 会忽略
# 指向系统目录的 -I(含符号链接)。这里把 25.1 的头文件实体复制到独立目录,
# 由 BRPC_EXTRA_INCLUDE 通知 brpc 用例优先引用,保证头文件与 libbrpc 同版本。
RUN mkdir -p /opt/protobuf25/include \
    && cp -a /usr/include/google /usr/include/absl /opt/protobuf25/include/
ENV BRPC_EXTRA_INCLUDE=/opt/protobuf25/include
# cloudwego: /usr/local/bin 下的 kitex/hz/volo、/usr/local/go 工具链、/eino 源码。
COPY --from=openeulertest/cloudwego:0.16.4-oe2403sp4-aarch64 /usr/local /usr/local
COPY --from=openeulertest/cloudwego:0.16.4-oe2403sp4-aarch64 /eino /eino
# cloudwego 镜像内的 Go 模块缓存(GOPATH=/go),离线解析依赖用。
COPY --from=openeulertest/cloudwego:0.16.4-oe2403sp4-aarch64 /go/pkg/mod /opt/boostkit/src/gomodcache
# volo 生成的项目要联网拉 crates.io;镜像里构建时留下的 registry 缓存一并带过来,
# 用例在该缓存存在时会把 CARGO_HOME 指向它并强制离线。
COPY --from=openeulertest/cloudwego:0.16.4-oe2403sp4-aarch64 /root/.cargo /opt/boostkit/src/cargo
COPY --from=openeulertest/protobuf:36.2-oe2403sp4-aarch64 /usr/local /usr/local
COPY --from=openeulertest/snappy:1.1.7-oe2403sp4-aarch64 /usr/local /usr/local
COPY --from=openeulertest/lz4:1.10.0-oe2403sp4-aarch64 /usr/local /usr/local
# 底座自带的 /usr/bin/zstd 是 1.5.5,必须用镜像里的 1.5.7 覆盖(装在 /usr/local/bin)。
COPY --from=openeulertest/zstd:1.5.7-oe2403sp4-aarch64 /usr/local /usr/local
COPY --from=openeulertest/x264:0480cb05-oe2403sp4-aarch64 /usr/local /usr/local
COPY --from=openeulertest/x264:0480cb05-oe2403sp4-aarch64 /x264 /x264
COPY --from=openeulertest/x265:4.2-oe2403sp4-aarch64 /usr/local /usr/local
COPY --from=openeulertest/x265:4.2-oe2403sp4-aarch64 /x265 /x265

# ---- 源码归档缓存 ${BOOSTKIT_SRC_ROOT} ----
# 用例的 common.sh 在本地缓存存在时把下载地址改写成 file://,缺失才回退上游。
#   snappy/x264     tag 归档(tar.gz)
#   lz4/zstd/brpc   裸镜像仓库,支持 git clone --branch <tag> --depth 1
#   cloudwego       <组件>/archive/refs/tags/<tag>.tar.gz,与上游 URL 结构一致
#   go              Go 工具链归档,镜像内已有 /usr/local/go 时不必用到
ENV BOOSTKIT_SRC_ROOT=/opt/boostkit/src
RUN set -eu; \
    root=/opt/boostkit/src; \
    mkdir -p "$root/snappy" "$root/x264" "$root/cloudwego" "$root/go"; \
    curl -fsSL --retry 3 -o "$root/snappy/1.1.7.tar.gz" \
        https://github.com/google/snappy/archive/refs/tags/1.1.7.tar.gz; \
    curl -fsSL --retry 3 -o "$root/x264/0480cb05.tar.gz" \
        https://github.com/mirror/x264/archive/0480cb05.tar.gz; \
    git clone --mirror --quiet https://github.com/lz4/lz4.git "$root/lz4.git"; \
    git clone --mirror --quiet https://github.com/facebook/zstd.git "$root/zstd.git"; \
    git clone --mirror --quiet https://github.com/apache/brpc.git "$root/brpc.git"; \
    for spec in kitex:v0.16.4 hertz:v0.10.6 eino:v0.9.22 volo:volo-thrift-0.12.2; do \
        name="${spec%%:*}"; tag="${spec#*:}"; \
        mkdir -p "$root/cloudwego/$name/archive/refs/tags"; \
        curl -fsSL --retry 3 -o "$root/cloudwego/$name/archive/refs/tags/$tag.tar.gz" \
            "https://github.com/cloudwego/$name/archive/refs/tags/$tag.tar.gz"; \
    done; \
    curl -fsSL --retry 3 -o "$root/go/go1.24.4.linux-arm64.tar.gz" \
        https://golang.google.cn/dl/go1.24.4.linux-arm64.tar.gz

# Go 模块缓存预热:预构建镜像里的 /go/pkg/mod 只覆盖它自己构建过的依赖。
# 'go mod download all' 按模块裁剪只拿构建列表,拿不到下游项目 tidy 所需的完整需求图
# (例如 hertz -> sonic -> golang.org/x/sys@v0.22.0 的 go.mod),GOPROXY=off 时直接解析失败。
# 这里在构建期用和用例完全一样的方式各生成一个项目并 tidy/build 一遍,把缺的模块补进缓存。
RUN set -eu; \
    export PATH=/usr/local/go/bin:${PATH} \
           GOPATH=/go \
           GOMODCACHE=/opt/boostkit/src/gomodcache \
           GOFLAGS=-mod=mod \
           GOTOOLCHAIN=local; \
    tmp=/tmp/gowarm; \
    for spec in kitex:v0.16.4 hertz:v0.10.6 eino:v0.9.22; do \
        name="${spec%%:*}"; tag="${spec#*:}"; \
        mkdir -p "$tmp/src/$name"; \
        tar -xzf "/opt/boostkit/src/cloudwego/$name/archive/refs/tags/$tag.tar.gz" \
            -C "$tmp/src/$name" --strip-components=1; \
        (cd "$tmp/src/$name" && go mod download all); \
    done; \
    printf 'namespace go echo\nstruct Request { 1: string message }\nstruct Response { 1: string message }\nservice Echo { Response Ping(1: Request req) (api.post="/ping") }\n' \
        >"$tmp/echo.thrift"; \
    mkdir -p "$tmp/bin" "$tmp/kitex" "$tmp/hz"; \
    (cd "$tmp/src/kitex" && go build -o "$tmp/bin/thriftgo" github.com/cloudwego/thriftgo); \
    export PATH="$tmp/bin:${PATH}"; \
    (cd "$tmp/kitex" && kitex -module cloudwego.local/echo ../echo.thrift); \
    (cd "$tmp/hz" && hz new -mod cloudwego.local/http -idl ../echo.thrift); \
    (cd "$tmp/kitex" && go mod edit -require=github.com/cloudwego/kitex@v0.16.4 \
        -replace=github.com/cloudwego/kitex="$tmp/src/kitex" && go mod tidy && go build -mod=readonly ./...); \
    (cd "$tmp/hz" && go mod edit -require=github.com/cloudwego/hertz@v0.10.6 \
        -replace=github.com/cloudwego/hertz="$tmp/src/hertz" && go mod tidy && go build -mod=readonly ./...); \
    rm -rf "$tmp"

# ---- 测试框架与用例 ----
COPY functional-framework/ /opt/boostkit/func/functional-framework/
COPY functional-cases/ /opt/boostkit/func/functional-cases/
COPY config/ /opt/boostkit/func/config/

# python3-pyyaml 供 catalog_func.py 使用;cmake/pkgconf 供 protobuf 与 brpc 的
# C++ 回环用例配置工程;tcl 供 lz4/zstd 上游测试脚本使用;diffutils 供上游
# 用例比较压缩前后文件;ffmpeg/ffprobe 供 x264 解码校验使用(离线装不了,必须预装);
# cargo/rust 供 volo init 生成项目后执行的 cargo fmt 使用。
RUN dnf install -y --setopt=install_weak_deps=False \
        python3-pyyaml \
        cmake \
        pkgconf-pkg-config \
        tcl \
        which \
        diffutils \
        ffmpeg \
        cargo \
    && dnf clean all
# volo 的 crates 缓存预热:预构建镜像的 registry 缓存只覆盖它自己那个 volo 工程,
# 用例生成的新工程按 Cargo.lock 解析出的 crate(如 bumpalo)可能缺失,
# CARGO_NET_OFFLINE 下会直接失败。这里按用例完全相同的步骤构建一遍补齐缓存。
RUN set -eu; \
    tmp=/tmp/cargowarm; \
    export CARGO_HOME=/opt/boostkit/src/cargo \
           CARGO_TARGET_DIR="$tmp/target"; \
    mkdir -p "$tmp/volo-src" "$tmp/app"; \
    tar -xzf /opt/boostkit/src/cloudwego/volo/archive/refs/tags/volo-thrift-0.12.2.tar.gz \
        -C "$tmp/volo-src" --strip-components=1; \
    printf 'namespace go echo\nstruct Request { 1: string message }\nstruct Response { 1: string message }\nservice Echo { Response Ping(1: Request req) (api.post="/ping") }\n' \
        >"$tmp/echo.thrift"; \
    cd "$tmp/app"; \
    volo init echo "$tmp/echo.thrift"; \
    python3 /opt/boostkit/func/functional-cases/Middleware/cloudwego/pin_generated.py \
        "$tmp/app" "$tmp/volo-src"; \
    cargo metadata --filter-platform "$(rustc -vV | sed -n 's/^host: //p')" --format-version 1 >/dev/null; \
    cargo build --locked; \
    rm -rf "$tmp"

# 各软件装在 /usr/local/lib(64),openEuler 的 ld.so.conf 不含这两条路径,
# 不补的话运行时找不到 libsnappy.so.1 之类的库。
RUN printf '%s\n' /usr/local/lib /usr/local/lib64 > /etc/ld.so.conf.d/usr-local.conf \
    && ldconfig

WORKDIR /opt/boostkit/func
