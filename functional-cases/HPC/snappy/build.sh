#!/usr/bin/env bash
# Snappy 构建脚本:环境采集 + 准备被测软件(构建)。
#   Snappy 是纯 C/C++ 库(没有 CLI),功能用例需要在私有工作区克隆并编译一份,
#   同时以 SNAPPY_BUILD_TESTS=ON 构建上游 snappy_unittest 供功能判定使用;不安装到系统。
#
# build 模式的分层优先获取分析(优先级从高到低):
#   层1 上游官方二进制:不可用。Snappy 是纯源码 C++ 库,官方不发布任何预编译二进制/包。
#   层2 三方仓库已打包的精确版本包:不可用。apt/conda-forge 的 snappy 版本滞后于 ${SOFTWARE_VERSION},
#         且功能判定需链接私有构建的 libsnappy 并运行上游 snappy_unittest,仓库包不满足该形态。
#   层3 源码编译:唯一可行层 —— 克隆 <version> tag(含 googletest 子模块)并 CMake 构建。
#   每层产物都需校验版本 == SOFTWARE_VERSION;此处仅层3 可用,故 build 模式直接源码编译。
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

# 克隆源码。上游 snappy 的单元测试依赖 third_party/googletest 子模块,
# 因此带子模块浅克隆;失败时再尝试补一次 submodule update。
clone_snappy_source() {
    local src="${SNAPPY_SOURCE_DIR}"
    command -v git >/dev/null 2>&1 || {
        log "ERROR: git is required to fetch the upstream source"
        return 40
    }
    log "cloning snappy ${SOFTWARE_VERSION} from ${SNAPPY_SOURCE_URL}"
    GIT_TERMINAL_PROMPT=0 git clone --branch "${SOFTWARE_VERSION}" --depth 1 \
        --recurse-submodules --shallow-submodules \
        "${SNAPPY_SOURCE_URL}" "${src}" || {
        log "ERROR: failed to clone snappy ${SOFTWARE_VERSION}"
        return 30
    }
    if [[ ! -f "${src}/third_party/googletest/CMakeLists.txt" ]]; then
        log "warning: googletest submodule missing; retrying submodule update"
        git -C "${src}" submodule update --init --recursive --depth 1 || true
    fi
    [[ -f "${src}/CMakeLists.txt" ]] || {
        log "ERROR: snappy source tree is incomplete: ${src}"
        return 40
    }
}

# 判断上游单测是否可用(需要 googletest 子模块)。
snappy_tests_available() {
    [[ -f "${SNAPPY_SOURCE_DIR}/third_party/googletest/CMakeLists.txt" ]]
}

build_snappy() {
    local tests_flag="OFF"
    [[ ! -e "${SNAPPY_BUILD_DIR}" ]] || {
        log "ERROR: build directory is not clean: ${SNAPPY_BUILD_DIR}"
        return 20
    }
    clone_snappy_source || return $?
    if snappy_tests_available; then
        tests_flag="ON"
    else
        log "warning: googletest submodule unavailable; building library without upstream tests"
    fi

    log "configuring snappy (shared library, tests=${tests_flag})"
    cmake -S "${SNAPPY_SOURCE_DIR}" -B "${SNAPPY_BUILD_DIR}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DSNAPPY_BUILD_TESTS="${tests_flag}" \
        -DSNAPPY_BUILD_BENCHMARKS=OFF || {
        log "ERROR: cmake configure of snappy failed"
        return 40
    }
    log "building snappy"
    cmake --build "${SNAPPY_BUILD_DIR}" -j"$(nproc)" || {
        log "ERROR: snappy build failed"
        return 40
    }
    [[ -f "${SNAPPY_LIB}" ]] || {
        log "ERROR: libsnappy shared library was not created: ${SNAPPY_LIB}"
        return 40
    }
}

func_install() {
    initialize_runtime || return $?
    check_architecture || return $?
    require_build_commands || return $?

    local actual
    build_snappy || return $?

    actual="$(read_snappy_version "${SNAPPY_SOURCE_DIR}")"
    [[ -n "${actual}" ]] || {
        log "ERROR: cannot read the built Snappy version"
        return 40
    }
    [[ "${actual}" == "${SOFTWARE_VERSION}" ]] || {
        log "ERROR: snappy ${actual}, expected ${SOFTWARE_VERSION}"
        return 40
    }
    mkdir -p "$(dirname "${PERF_ACTUAL_VERSION_FILE}")"
    printf '%s\n' "${actual}" >"${PERF_ACTUAL_VERSION_FILE}" || return 40
    log "snappy ${actual} ready (mode=${FUNC_MODE}, tests=$([[ -x "${SNAPPY_UNITTEST}" ]] && echo yes || echo no))"
}

# ---------- 独立运行入口 ----------

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]
Capture the environment and prepare snappy for one OS/hardware cell.
  --mode prebuilt | build   (default: ${FUNC_MODE})

Options:
  --version VERSION    snappy version (default: ${SOFTWARE_VERSION})
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