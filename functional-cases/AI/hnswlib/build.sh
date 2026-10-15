#!/usr/bin/env bash
# hnswlib 构建脚本:环境采集 + 准备被测软件(安装或校验)。
#   FUNC_MODE=prebuilt - 镜像内已装好 hnswlib,只定位并校验版本,不安装
#   FUNC_MODE=build    - 装依赖 + 分层优先获取(上游官方二进制→三方仓库→源码编译)到任务私有 venv
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

# build 模式:创建任务私有 venv,再分层优先获取 hnswlib(见 common.sh acquire_build_layers)。
install_hnswlib_build() {
    [[ ! -e "${VENV_DIR}" ]] || {
        log "ERROR: virtual environment is not clean: ${VENV_DIR}"
        return 20
    }
    log "creating task-private virtual environment ${VENV_DIR}"
    python3 -m venv "${VENV_DIR}" || {
        log "ERROR: failed to create the virtual environment"
        return 40
    }
    [[ -x "${VENV_DIR}/bin/pip" ]] || {
        log "ERROR: the virtual environment has no usable pip"
        return 40
    }
    acquire_build_layers \
        fetch_hnswlib_upstream_binary \
        fetch_hnswlib_third_party \
        fetch_hnswlib_source || return $?
}

# 层 1:上游官方二进制。
# hnswlib 官方只发布头文件库与 Python 源码包,无预编译产品
# (config/distribution.yaml:arm64_binary: na),也没有官方 release 二进制资产。
# 本层无可用官方二进制,按分层设计显式跳过,交给下一层。
fetch_hnswlib_upstream_binary() {
    log "layer 1: hnswlib ships no upstream prebuilt artifact (header-only + sdist); skip"
    return 1
}

# 层 2:三方仓库已打包二进制。
# 官方登记的三方渠道是 conda-forge/hnswlib(已打包各架构二进制)。build 模式运行在普通容器内,
# 没有可用的 conda 运行时(被测环境统一为任务私有 venv),按"渠道不可用即改用等效产物"的规则,
# 改用等价的 PyPI 源码包 hnswlib==${SOFTWARE_VERSION},由 pip 现场编译出该版本扩展模块。
fetch_hnswlib_third_party() {
    local -a index_args=()
    mapfile -t index_args < <(pip_index_args)
    log "layer 2: installing the equivalent PyPI source package ${HNSWLIB_PACKAGE_SPEC}"
    "${VENV_DIR}/bin/pip" install --no-cache-dir --disable-pip-version-check \
        "${index_args[@]}" "${HNSWLIB_PACKAGE_SPEC}"
}

# 层 3:源码编译(最后手段)。
# 克隆官方仓库精确 tag v${SOFTWARE_VERSION},直接把源码目录安装进 venv(现场编译扩展)。
fetch_hnswlib_source() {
    local -a index_args=()
    mapfile -t index_args < <(pip_index_args)
    local src="${BUILD_DIR}/hnswlib-source"
    rm -rf -- "${src}"
    log "layer 3: cloning hnswlib v${SOFTWARE_VERSION} from ${HNSWLIB_SOURCE_URL}"
    GIT_TERMINAL_PROMPT=0 git clone --branch "v${SOFTWARE_VERSION}" --depth 1 \
        "${HNSWLIB_SOURCE_URL}" "${src}" || {
        log "ERROR: failed to clone hnswlib v${SOFTWARE_VERSION}"
        return 30
    }
    [[ -f "${src}/hnswlib/hnswlib.h" ]] || {
        log "ERROR: cloned hnswlib tree lacks hnswlib/hnswlib.h"
        return 40
    }
    "${VENV_DIR}/bin/pip" install --no-cache-dir --disable-pip-version-check \
        "${index_args[@]}" "${src}" || {
        log "ERROR: failed to build hnswlib extension from source"
        return 40
    }
}

func_install() {
    initialize_runtime || return $?
    check_architecture || return $?
    require_python_runtime || return $?

    if [[ "${FUNC_MODE}" == "prebuilt" ]]; then
        # 镜像已装好:只定位并校验版本。
        [[ -n "${PYBIN}" && -x "${PYBIN}" ]] || {
            log "ERROR: python3 is unavailable in the software image"
            return 40
        }
        log "using the pre-installed hnswlib from the software image"
    else
        install_hnswlib_build || return $?
    fi

    local actual
    actual="$(read_installed_version)"
    [[ -n "${actual}" ]] || {
        log "ERROR: cannot detect the installed hnswlib version"
        return 40
    }
    [[ "${actual}" == "${SOFTWARE_VERSION}" ]] || {
        log "ERROR: hnswlib ${actual}, expected ${SOFTWARE_VERSION}"
        return 40
    }
    mkdir -p "$(dirname "${PERF_ACTUAL_VERSION_FILE}")"
    printf '%s\n' "${actual}" >"${PERF_ACTUAL_VERSION_FILE}" || return 40
    log "hnswlib ${actual} ready (mode=${FUNC_MODE})"
}

# ---------- 独立运行入口 ----------

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]
Capture the environment and prepare hnswlib for one OS/hardware cell.
  --mode prebuilt | build   (default: ${FUNC_MODE})

Options:
  --version VERSION    hnswlib version (default: ${SOFTWARE_VERSION})
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