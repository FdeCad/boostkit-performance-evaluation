#!/usr/bin/env bash
# scann 构建脚本:环境采集 + 准备被测软件(安装或校验)。
#   FUNC_MODE=prebuilt - 镜像内已装好 ScaNN,只定位并校验版本,不安装
#   FUNC_MODE=build    - 装依赖 + 分层优先获取(上游官方 wheel→三方仓库→源码编译)到任务私有 venv
#                        (官方仅 x86_64 wheel,aarch64 会自动降级到源码编译层)
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

# build 模式:创建任务私有 venv,再分层优先获取 ScaNN(见 common.sh acquire_build_layers)。
# 官方仅发布 x86_64 manylinux wheel;aarch64 无 wheel,层 1 会失败并自动降级到源码编译层。
install_scann_build() {
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
        fetch_scann_upstream_binary \
        fetch_scann_third_party \
        fetch_scann_source || return $?
}

# 层 1:上游官方二进制。
# ScaNN 官方在 PyPI 发布预编译 wheel(config/distribution.yaml primary: pypi),但仅 x86_64 manylinux,
# 无 arm64 产物。强制 --only-binary=:all: 确保拿到二进制;aarch64 上无 wheel,本层失败转下一层。
fetch_scann_upstream_binary() {
    local -a index_args=()
    mapfile -t index_args < <(pip_index_args)
    log "layer 1: installing the official prebuilt wheel ${SCANN_PACKAGE_SPEC}"
    "${VENV_DIR}/bin/pip" install --no-cache-dir --disable-pip-version-check \
        "${index_args[@]}" --only-binary=:all: "${SCANN_PACKAGE_SPEC}"
}

# 层 2:三方仓库已打包二进制。
# config/distribution.yaml 登记 ScaNN 的 conda/apt/docker 均为 null,无可用三方二进制渠道。
# 按分层设计显式跳过,交给下一层。
fetch_scann_third_party() {
    log "layer 2: scann has no third-party binary channel (conda/apt/docker null); skip"
    return 1
}

# 层 3:源码编译(最后手段)。
# 上游仅发布 x86_64 wheel,无 arm64 产物;此处安装官方源码 tarball(sdist)由 pip 现场编译。
fetch_scann_source() {
    require_scann_source_tools || return $?
    local -a index_args=()
    mapfile -t index_args < <(pip_index_args)
    log "no prebuilt scann wheel usable for ${EXPECTED_ARCH}; building from the upstream source tarball"
    "${VENV_DIR}/bin/pip" install --no-cache-dir --disable-pip-version-check \
        "${index_args[@]}" "${SCANN_PACKAGE_SPEC}"
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
        log "using the pre-installed ScaNN from the software image"
    else
        install_scann_build || return $?
    fi

    local actual
    actual="$(read_installed_version)"
    [[ -n "${actual}" ]] || {
        log "ERROR: cannot detect the installed ScaNN version"
        return 40
    }
    [[ "${actual}" == "${SOFTWARE_VERSION}" ]] || {
        log "ERROR: scann ${actual}, expected ${SOFTWARE_VERSION}"
        return 40
    }
    mkdir -p "$(dirname "${PERF_ACTUAL_VERSION_FILE}")"
    printf '%s\n' "${actual}" >"${PERF_ACTUAL_VERSION_FILE}" || return 40
    log "ScaNN ${actual} ready (mode=${FUNC_MODE})"
}

# ---------- 独立运行入口 ----------

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]
Capture the environment and prepare ScaNN for one OS/hardware cell.
  --mode prebuilt | build   (default: ${FUNC_MODE})

Options:
  --version VERSION    ScaNN version (default: ${SOFTWARE_VERSION})
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