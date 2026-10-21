#!/usr/bin/env bash
# gcc 构建脚本:环境采集 + 准备被测软件(构建或校验)。
#   FUNC_MODE=prebuilt - 校验镜像内 gcc 版本,不构建
#   FUNC_MODE=build    - 装依赖 + 分层获取并校验版本:
#                        层1 上游官方二进制(GNU 仅源码,不可用)→ 层2 三方仓库包 → 层3 源码编译
# 暴露给 Framework 的阶段:prepare、install。独立执行时依次运行这两个阶段。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---------- 阶段:prepare ----------

func_prepare() {
    initialize_runtime || return $?
    local arch platform kernel cpu_count python_version gcc_version glibc_version
    arch="$(uname -m)"
    platform="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"' || true)"
    kernel="$(uname -r)"
    cpu_count="$(nproc 2>/dev/null || printf '0')"
    # 缺失的命令只记录为 unknown,不能因为探测失败而让 set -e 退出(否则静默 127)。
    python_version="$(python3 --version 2>/dev/null | awk '{print $2}' || true)"
    gcc_version="$(gcc -dumpfullversion -dumpversion 2>/dev/null | head -n 1 || true)"
    glibc_version="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true)"
    cat >"${RESULTS_DIR}/system_info.json" <<EOF
{
  "architecture": "$(json_escape "${arch}")",
  "platform": "$(json_escape "${platform}")",
  "kernel": "$(json_escape "${kernel}")",
  "cpu_count": ${cpu_count:-0},
  "python_version": "$(json_escape "${python_version:-unknown}")",
  "gcc_version": "$(json_escape "${gcc_version:-unknown}")",
  "glibc_version": "$(json_escape "${glibc_version:-unknown}")"
}
EOF
    log "prepared environment (os=${FUNC_OS}, mode=${FUNC_MODE}, hardware=${FUNC_HARDWARE:-unspecified})"
}

# ---------- 阶段:install ----------

# 官方发布包的 SHA-256(按版本声明);新增版本必须在此登记校验值。
gcc_source_sha256() {
    case "${SOFTWARE_VERSION}" in
        14.4.0)
            printf '%s\n' "752b6f567beac83159c77a7680b1316bdd784738bff9a9d070112c09da90f6d9"
            ;;
        16.2.0)
            printf '%s\n' "e6738e29597f733270731aa90600f37ffdc045079dfc27ec7e8192cc81085c3e"
            ;;
        *)
            return 1
            ;;
    esac
}

# 下载官方 GCC 源码 tarball、校验 SHA-256 并解压到私有源码目录。
prepare_gcc_source() {
    local expected actual tarball source_root
    expected="$(gcc_source_sha256 || true)"
    [[ -n "${expected}" ]] || {
        log "ERROR: no verified GCC release is declared for ${SOFTWARE_VERSION}"
        return 30
    }
    if [[ -e "${SRC_DIR}" ]]; then
        log "ERROR: source directory is not clean: ${SRC_DIR}"
        return 20
    fi
    tarball="${PERF_WORK_DIR}/gcc-${SOFTWARE_VERSION}.tar.xz"
    log "downloading official gcc-${SOFTWARE_VERSION}.tar.xz from ${GCC_SOURCE_BASE}"
    curl -fsSL --retry 3 --connect-timeout 30 -o "${tarball}" \
        "${GCC_SOURCE_BASE}/gcc-${SOFTWARE_VERSION}/gcc-${SOFTWARE_VERSION}.tar.xz" || {
        log "ERROR: failed to download gcc-${SOFTWARE_VERSION}.tar.xz"
        return 30
    }
    actual="$(sha256sum "${tarball}" | awk '{print $1}')"
    [[ "${actual}" == "${expected}" ]] || {
        log "ERROR: GCC tarball checksum mismatch"
        return 30
    }
    log "extracting GCC source (checksum verified)"
    tar -xJf "${tarball}" -C "${PERF_WORK_DIR}" || {
        log "ERROR: failed to extract the GCC tarball"
        return 30
    }
    rm -f "${tarball}"
    source_root="${PERF_WORK_DIR}/gcc-${SOFTWARE_VERSION}"
    [[ -f "${source_root}/configure" ]] || {
        log "ERROR: tarball did not create the expected GCC source tree"
        return 30
    }
    mv "${source_root}" "${SRC_DIR}" || {
        log "ERROR: failed to place the extracted GCC source tree"
        return 30
    }
}

# 独立构建(C/C++,out-of-tree)并安装到私有前缀。
build_gcc_from_source() {
    local version_output actual_version

    prepare_gcc_source || return $?
    log "configuring GCC ${SOFTWARE_VERSION} (C and C++, out-of-tree build)"
    mkdir -p "${BUILD_DIR}" || return 40
    (
        cd "${BUILD_DIR}"
        "${SRC_DIR}/configure" \
            --prefix="${INSTALL_DIR}" \
            --enable-languages=c,c++ \
            --disable-bootstrap \
            --disable-multilib \
            --disable-nls
    ) || {
        log "ERROR: GCC configure failed"
        return 40
    }
    log "building GCC ${SOFTWARE_VERSION} with make -j$(nproc)"
    (
        cd "${BUILD_DIR}"
        make -j"$(nproc)"
    ) || {
        log "ERROR: GCC build failed"
        return 40
    }
    log "installing GCC ${SOFTWARE_VERSION} into ${INSTALL_DIR}"
    (
        cd "${BUILD_DIR}"
        make install
    ) || {
        log "ERROR: GCC private installation failed"
        return 40
    }
    [[ -x "${GCC_BIN}" && -x "${GXX_BIN}" ]] || {
        log "ERROR: private GCC C or C++ compiler is missing"
        return 40
    }
    version_output="$("${GCC_BIN}" --version 2>/dev/null | head -n 1)" || {
        log "ERROR: built GCC cannot report its version"
        return 40
    }
    actual_version="$(printf '%s\n' "${version_output}" | awk '{print $NF}')"
    [[ "${actual_version}" == "${SOFTWARE_VERSION}" ]] || {
        log "ERROR: built GCC reports ${actual_version}, requested ${SOFTWARE_VERSION}"
        return 40
    }
    log "GCC ${SOFTWARE_VERSION} compiler is ready at ${GCC_BIN}"
}

# ---------- 分层获取(build 模式) ----------
# 按优先级(高→低)依次尝试,每一层获取后都必须用 `gcc --version` 校验版本 == SOFTWARE_VERSION,
# 不匹配或获取失败即降级到下一层;三层都不可行才让 install 失败。
# 渠道依据 config/distribution.yaml 的 gcc 条目:primary=upstream-release(gcc.gnu.org),
# channels=conda-forge/gcc_impl_linux-64、apt gcc、docker library/gcc。
# 注意:GNU 官方只提供源码,无官方预编译二进制。

# 层1:上游官方二进制 tarball。
#   gcc.gnu.org 只发布源码 tarball,无官方预编译二进制 → 该层结构性不可用。
install_gcc_layer_upstream_binary() {
    log "layer1: gcc.gnu.org publishes source only (no official binary); skipping to layer 2"
    return 1
}

# 层2:三方仓库中与请求版本一致的 gcc 包。
#   build 模式无嵌套容器 → library/gcc 镜像不可用;基础镜像也未内置 conda →
#   改用等效的发行版仓库包(apt gcc-<major> / gcc / g++)。
install_gcc_layer_repo_package() {
    local major="${SOFTWARE_VERSION%%.*}" package candidate version
    for package in "gcc-${major}" gcc; do
        if ! apt_install "${package}" g++ >/dev/null 2>&1; then
            log "layer2: distro package ${package} is unavailable"
            continue
        fi
        candidate="$(command -v "gcc-${major}" 2>/dev/null || command -v gcc 2>/dev/null || true)"
        [[ -n "${candidate}" ]] || continue
        version="$(gcc_version_of "${candidate}")"
        if [[ "${version}" == "${SOFTWARE_VERSION}" ]]; then
            printf 'GCC_BIN=%s\nGXX_BIN=%s\n' "${candidate}" "${candidate/gcc/g++}" >"${LAYERED_TOOL_FILE}"
            log "layer2: adopted distro GCC package ${package} (${candidate})"
            return 0
        fi
        log "layer2: distro package ${package} provides GCC ${version:-unknown}, not ${SOFTWARE_VERSION}"
    done
    return 1
}

# 层3:从官方源码 tarball 独立构建(最后手段;GNU 官方在 Linux 仅分发源码)。
install_gcc_layer_source_build() {
    build_gcc_from_source
}

# 分层获取入口:依次尝试三层,任一层成功即返回 0。
install_gcc_layered() {
    if install_gcc_layer_upstream_binary; then
        log "acquired GCC via layer 1 (upstream official binary)"
        return 0
    fi
    log "layer 1 (upstream official binary) unavailable; falling back to layer 2"
    if install_gcc_layer_repo_package; then
        log "acquired GCC via layer 2 (third-party repo package)"
        return 0
    fi
    log "layer 2 (third-party repo package) unavailable; falling back to layer 3"
    if install_gcc_layer_source_build; then
        log "acquired GCC via layer 3 (source build)"
        return 0
    fi
    log "ERROR: no GCC ${SOFTWARE_VERSION} acquisition layer succeeded"
    return 40
}

func_install() {
    initialize_runtime || return $?
    check_architecture || return $?

    local actual
    if [[ "${FUNC_MODE}" == "prebuilt" ]]; then
        # 镜像已装好:只定位并校验版本。
        [[ -x "${GCC_BIN}" ]] || {
            log "ERROR: gcc is not present in the software image"
            return 40
        }
    else
        # 当场构建:装依赖 + 分层获取(官方二进制→三方仓库包→官方源码构建到私有前缀)。
        require_build_commands || return $?
        [[ ! -e "${BUILD_DIR}" && ! -e "${INSTALL_DIR}" ]] || {
            log "ERROR: build directories are not clean under ${PERF_WORK_DIR}"
            return 20
        }
        install_gcc_layered || return $?
        # layer2 可能改选发行版包的 gcc,重新解析工具路径后再统一校验版本。
        configure_runtime_paths || return $?
    fi

    actual="$(gcc_version_of "${GCC_BIN}")"
    [[ "${actual}" == "${SOFTWARE_VERSION}" ]] || {
        log "ERROR: gcc ${actual:-unknown}, expected ${SOFTWARE_VERSION}"
        return 40
    }
    mkdir -p "$(dirname "${PERF_ACTUAL_VERSION_FILE}")"
    printf '%s\n' "${actual}" >"${PERF_ACTUAL_VERSION_FILE}" || return 40
    log "gcc ${actual} ready (mode=${FUNC_MODE})"
}

# ---------- 独立运行入口 ----------

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]
Capture the environment and prepare gcc for one OS/hardware cell.
  --mode prebuilt | build   (default: ${FUNC_MODE})

Options:
  --version VERSION    gcc version (default: ${SOFTWARE_VERSION})
  --results-dir DIR    Persistent result directory
  --os OS_LABEL        OS label (default: detect from /etc/os-release)
  --hardware HW_LABEL  Hardware label, e.g. kunpeng920
  --keep-workdir       Keep the isolated work directory
  -h, --help           Show this help
USAGE
}

run_build_standalone() {
    local status=0
    initialize_runtime || return $?
    func_prepare || return $?
    func_install || status=$?
    return "${status}"
}

main() {
    parse_common_args "$@"
    case "$?" in
        0) ;;
        64)
            usage
            return 0
            ;;
        *) return 10 ;;
    esac
    configure_runtime_paths || return $?
    mkdir -p "${RESULTS_DIR}" || return $?
    run_build_standalone
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi