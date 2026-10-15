#!/usr/bin/env bash
# x264 构建脚本:环境采集 + 准备被测软件(构建或校验)。
#   FUNC_MODE=prebuilt - 校验镜像内 x264 版本,并准备源码树以跑上游 checkasm
#   FUNC_MODE=build    - 分层获取:上游无二进制、仓库包版本滞后,最终以源码编译(configure && make)为准
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
    gcc_version="$(cc --version 2>/dev/null | head -n 1 || true)"
    glibc_version="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true)"
    cat >"${RESULTS_DIR}/system_info.json" <<EOF
{
  "architecture": "$(json_escape "${arch}")",
  "platform": "$(json_escape "${platform}")",
  "kernel": "$(json_escape "${kernel}")",
  "cpu_count": ${cpu_count:-0},
  "python_version": "$(json_escape "${python_version:-unknown}")",
  "compiler_version": "$(json_escape "${gcc_version:-unknown}")",
  "glibc_version": "$(json_escape "${glibc_version:-unknown}")"
}
EOF
    log "prepared environment (os=${FUNC_OS}, mode=${FUNC_MODE}, hardware=${FUNC_HARDWARE:-unspecified})"
}

# ---------- 阶段:install ----------

# 克隆 x264 源码到指定目录(默认分支;上游默认分支即为请求版本对应的代码)。
clone_x264_source() {
    local target="$1"
    command -v git >/dev/null 2>&1 || {
        log "ERROR: git is required to fetch the x264 source"
        return 40
    }
    rm -rf -- "${target}"
    log "cloning x264 from ${X264_SOURCE_URL}"
    GIT_TERMINAL_PROMPT=0 git clone --depth 1 "${X264_SOURCE_URL}" "${target}" || {
        log "ERROR: failed to clone x264 from ${X264_SOURCE_URL}"
        return 30
    }
}

# 就地 configure x264(超出源码树外构建会让 checkasm 目标不易定位)。
configure_x264() {
    local tree="$1"
    (cd "${tree}" && ./configure --prefix="${INSTALL_DIR}" --enable-pic) || {
        log "ERROR: x264 configure failed"
        return 40
    }
}

# ---------- 分层获取(build 模式) ----------
# 按优先级依次尝试,每层以 read_x264_version 强校验 == SOFTWARE_VERSION,不匹配即降级到下一层:
#   1. 上游官方二进制:x264 上游仅源码、无预编译产物(config/distribution.yaml: arm64_binary=na) → 本层不可行。
#   2. 三方仓库已打包二进制/包:发行版仓库的 x264 包(apt=libx264-dev)与 conda-forge/x264 版本普遍滞后于
#      请求版本,且 build 模式基础镜像无 conda;按"版本严格相等"门槛无法命中 → 本层不可行。
#   3. 源码编译:从上游源码 configure && make(当前唯一可行层)。
acquire_x264_upstream_binary() {
    log "upstream x264 ships source only (arm64_binary=na); no official binary layer"
    return 1
}

acquire_x264_from_repo() {
    log "distro/conda x264 packages lag the requested ${SOFTWARE_VERSION} and conda is absent; repository layer cannot meet the exact-version gate"
    return 1
}

# build 模式:克隆源码并完整构建安装出 x264 CLI。
build_x264_from_source() {
    [[ ! -e "${SOURCE_DIR}" ]] || {
        log "ERROR: source directory is not clean: ${SOURCE_DIR}"
        return 20
    }
    clone_x264_source "${SOURCE_DIR}" || return $?
    mkdir -p "${INSTALL_DIR}"
    log "building and installing x264 into ${INSTALL_DIR}"
    configure_x264 "${SOURCE_DIR}" || return $?
    (cd "${SOURCE_DIR}" && make -j"$(nproc)" && make install) || {
        log "ERROR: x264 make or install failed"
        return 40
    }
    [[ -x "${X264_BIN}" ]] || {
        log "ERROR: x264 CLI was not produced at ${X264_BIN}"
        return 40
    }
}

# prebuilt 模式:镜像只有二进制,checkasm 需要一份已 configure 的源码树。
prepare_source_tree_for_checkasm() {
    local tree
    if tree="$(resolve_x264_source_dir)"; then
        X264_SOURCE_DIR="${tree}"
        export X264_SOURCE_DIR
        log "using x264 source tree at ${X264_SOURCE_DIR}"
        return 0
    fi
    clone_x264_source "${SOURCE_DIR}" || return $?
    configure_x264 "${SOURCE_DIR}" || return $?
    X264_SOURCE_DIR="${SOURCE_DIR}"
    export X264_SOURCE_DIR
}

func_install() {
    initialize_runtime || return $?
    check_architecture || return $?
    require_build_commands || return $?

    local actual
    if [[ "${FUNC_MODE}" == "prebuilt" ]]; then
        # 镜像已装好:校验版本,并准备源码树以跑上游 checkasm。
        [[ -x "${X264_BIN}" ]] || {
            log "ERROR: x264 is not present in the software image (${X264_BIN})"
            return 40
        }
        prepare_source_tree_for_checkasm || return $?
    else
        acquire_x264_upstream_binary || {
            log "x264 upstream-binary layer infeasible; trying the repository layer"
            acquire_x264_from_repo || {
                log "x264 repository layer infeasible; building from source"
                build_x264_from_source || return $?
            }
        }
    fi

    actual="$(read_x264_version || true)"
    [[ "${actual}" == "${SOFTWARE_VERSION}" ]] || {
        log "ERROR: x264 ${actual:-unknown}, expected ${SOFTWARE_VERSION}"
        return 40
    }
    mkdir -p "$(dirname "${PERF_ACTUAL_VERSION_FILE}")"
    printf '%s\n' "${actual}" >"${PERF_ACTUAL_VERSION_FILE}" || return 40
    log "x264 ${actual} ready (mode=${FUNC_MODE})"
}

# ---------- 独立运行入口 ----------

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]
Capture the environment and prepare x264 for one OS/hardware cell.
  --mode prebuilt | build   (default: ${FUNC_MODE})

Options:
  --version VERSION    x264 version (default: ${SOFTWARE_VERSION})
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