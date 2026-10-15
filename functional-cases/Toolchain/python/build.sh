#!/usr/bin/env bash
# python (CPython) 构建脚本:环境采集 + 准备被测软件(构建或校验)。
#   FUNC_MODE=prebuilt - 校验镜像内 python3 版本,不构建
#   FUNC_MODE=build    - 装依赖 + 分层获取并校验版本:
#                        层1 上游官方二进制(官方仅源码,不可用)→ 层2 三方仓库包 → 层3 源码编译
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

# 下载官方 CPython 源码 tarball 并解压到私有源码目录(不动系统 Python)。
prepare_cpython_source() {
    local tarball="${PERF_WORK_DIR}/Python-${SOFTWARE_VERSION}.tgz"
    if [[ -e "${PYTHON_SOURCE_DIR}" ]]; then
        log "ERROR: source directory is not clean: ${PYTHON_SOURCE_DIR}"
        return 20
    fi
    log "downloading official CPython source Python-${SOFTWARE_VERSION}.tgz"
    curl -fsSL --retry 3 --connect-timeout 30 -o "${tarball}" \
        "${PYTHON_SOURCE_URL}/${SOFTWARE_VERSION}/Python-${SOFTWARE_VERSION}.tgz" || {
        log "ERROR: failed to download CPython ${SOFTWARE_VERSION} source"
        return 30
    }
    mkdir -p "${PYTHON_SOURCE_DIR}" || return 30
    tar -xzf "${tarball}" -C "${PYTHON_SOURCE_DIR}" --strip-components=1 || {
        log "ERROR: failed to extract the CPython source tarball"
        return 30
    }
    rm -f "${tarball}"
    [[ -f "${PYTHON_SOURCE_DIR}/configure" ]] || {
        log "ERROR: extracted CPython source has no configure script"
        return 30
    }
}

# 构建并安装到私有前缀,然后校验版本与关键模块。
build_python_from_source() {
    local -a configure_options
    local version_output actual_version

    prepare_cpython_source || return $?
    read -r -a configure_options <<<"${CONFIGURE_OPTIONS}"
    (( ${#configure_options[@]} > 0 )) || {
        log "ERROR: CPython configure options are empty"
        return 40
    }
    log "configuring CPython ${SOFTWARE_VERSION} with ${CONFIGURE_OPTIONS}"
    (
        cd "${PYTHON_SOURCE_DIR}"
        ./configure --prefix="${PYTHON_INSTALL_DIR}" "${configure_options[@]}"
    ) || {
        log "ERROR: CPython configure failed"
        return 40
    }
    log "building CPython ${SOFTWARE_VERSION} with make -j$(nproc)"
    (
        cd "${PYTHON_SOURCE_DIR}"
        make -j"$(nproc)"
    ) || {
        log "ERROR: CPython make failed"
        return 40
    }
    log "installing CPython ${SOFTWARE_VERSION} into ${PYTHON_INSTALL_DIR}"
    (
        cd "${PYTHON_SOURCE_DIR}"
        make install
    ) || {
        log "ERROR: CPython make install failed"
        return 40
    }
    [[ -x "${PYTHON_BIN}" ]] || {
        log "ERROR: CPython interpreter was not installed: ${PYTHON_BIN}"
        return 40
    }
    version_output="$("${PYTHON_BIN}" --version 2>&1)" || {
        log "ERROR: built CPython cannot report its version"
        return 40
    }
    actual_version="${version_output#Python }"
    actual_version="${actual_version%%[[:space:]]*}"
    [[ "${actual_version}" == "${SOFTWARE_VERSION}" ]] || {
        log "ERROR: built CPython reports ${actual_version:-unknown}, requested ${SOFTWARE_VERSION}"
        return 40
    }
    # 标准库关键模块必须可用(smoke 依赖 zlib,安装阶段额外确认 ssl)。
    "${PYTHON_BIN}" -c "import ssl, zlib, json, hashlib" || {
        log "ERROR: built CPython is missing required standard library modules"
        return 40
    }
    log "CPython ${SOFTWARE_VERSION} interpreter is ready at ${PYTHON_BIN}"
}

# ---------- 分层获取(build 模式) ----------
# 按优先级(高→低)依次尝试,每一层获取后都必须用 `python3 --version` 校验版本 == SOFTWARE_VERSION,
# 不匹配或获取失败即降级到下一层;三层都不可行才让 install 失败。
# 渠道依据 config/distribution.yaml 的 python 条目:primary=upstream-release(python.org),
# channels=conda-forge/python、apt python3、docker library/python。

# 层1:上游官方二进制 tarball。
#   python.org 在 Linux 仅分发源码 tarball,无官方预编译二进制 → 该层结构性不可用。
install_python_layer_upstream_binary() {
    log "layer1: python.org provides source only (no official Linux binary); skipping to layer 2"
    return 1
}

# 层2:三方仓库中与请求版本一致的 CPython 二进制/包。
#   build 模式无嵌套容器 → library/python 镜像不可用;基础镜像也未内置 conda →
#   改用等效的发行版仓库包(apt python3.14)。
install_python_layer_repo_package() {
    local package candidate version
    for package in "python${PYTHON_MM}" "python3"; do
        if ! apt_install "${package}" >/dev/null 2>&1; then
            log "layer2: distro package ${package} is unavailable"
            continue
        fi
        candidate="$(command -v "python${PYTHON_MM}" 2>/dev/null || command -v python3 2>/dev/null || true)"
        [[ -n "${candidate}" ]] || continue
        version="$(python_version_of "${candidate}")"
        if [[ "${version}" == "${SOFTWARE_VERSION}" ]]; then
            printf 'PYTHON_BIN=%s\n' "${candidate}" >"${LAYERED_TOOL_FILE}"
            log "layer2: adopted distro Python package ${package} (${candidate})"
            return 0
        fi
        log "layer2: distro package ${package} provides Python ${version:-unknown}, not ${SOFTWARE_VERSION}"
    done
    return 1
}

# 层3:从官方源码 tarball 编译(最后手段;CPython 官方在 Linux 仅分发源码)。
install_python_layer_source_build() {
    build_python_from_source
}

# 分层获取入口:依次尝试三层,任一层成功即返回 0。
install_python_layered() {
    if install_python_layer_upstream_binary; then
        log "acquired CPython via layer 1 (upstream official binary)"
        return 0
    fi
    log "layer 1 (upstream official binary) unavailable; falling back to layer 2"
    if install_python_layer_repo_package; then
        log "acquired CPython via layer 2 (third-party repo package)"
        return 0
    fi
    log "layer 2 (third-party repo package) unavailable; falling back to layer 3"
    if install_python_layer_source_build; then
        log "acquired CPython via layer 3 (source build)"
        return 0
    fi
    log "ERROR: no CPython ${SOFTWARE_VERSION} acquisition layer succeeded"
    return 40
}

func_install() {
    initialize_runtime || return $?
    check_architecture || return $?

    local actual
    if [[ "${FUNC_MODE}" == "prebuilt" ]]; then
        # 镜像已装好:只定位并校验版本。
        [[ -x "${PYTHON_BIN}" ]] || {
            log "ERROR: python3 is not present in the software image"
            return 40
        }
    else
        # 当场构建:装依赖 + 分层获取(官方二进制→三方仓库包→官方源码编译到私有前缀)。
        require_build_commands || return $?
        [[ ! -e "${PYTHON_INSTALL_DIR}" ]] || {
            log "ERROR: installation directory is not clean: ${PYTHON_INSTALL_DIR}"
            return 20
        }
        install_python_layered || return $?
        # layer2 可能改选发行版包的 python,重新解析工具路径后再统一校验版本。
        configure_runtime_paths || return $?
    fi

    actual="$(python_version_of "${PYTHON_BIN}")"
    [[ "${actual}" == "${SOFTWARE_VERSION}" ]] || {
        log "ERROR: python ${actual:-unknown}, expected ${SOFTWARE_VERSION}"
        return 40
    }
    mkdir -p "$(dirname "${PERF_ACTUAL_VERSION_FILE}")"
    printf '%s\n' "${actual}" >"${PERF_ACTUAL_VERSION_FILE}" || return 40
    log "python ${actual} ready (mode=${FUNC_MODE})"
}

# ---------- 独立运行入口 ----------

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]
Capture the environment and prepare CPython for one OS/hardware cell.
  --mode prebuilt | build   (default: ${FUNC_MODE})

Options:
  --version VERSION    CPython version (default: ${SOFTWARE_VERSION})
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