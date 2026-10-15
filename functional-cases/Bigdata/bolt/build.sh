#!/usr/bin/env bash
# Bolt 构建脚本:环境采集 + 准备被测软件(自源码用 Conan+CMake 构建,或校验镜像内已有构建)。
#   FUNC_MODE=prebuilt - 校验镜像内已有 Bolt 构建(无官方预编译产物,优先复用镜像)
#   FUNC_MODE=build    - 分层获取:1) 上游官方二进制 2) 三方仓库包 3) 源码编译(Conan+CMake,很重)
#                        Bolt 官方仅有源码,层1/层2 无可用渠道,只能走层3。
# 暴露给 Framework 的阶段:prepare、install。独立执行时依次运行这两个阶段。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---------- 阶段:prepare ----------

func_prepare() {
    initialize_runtime || return $?
    local arch platform kernel cpu_count python_version gcc_version glibc_version cmake_version
    arch="$(uname -m)"
    platform="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"' || true)"
    kernel="$(uname -r)"
    cpu_count="$(nproc 2>/dev/null || printf '0')"
    # 缺失的命令只记录为 unknown,不能因为探测失败而让 set -e 退出(否则静默 127)。
    python_version="$(python3 --version 2>/dev/null | awk '{print $2}' || true)"
    gcc_version="$(gcc -dumpfullversion -dumpversion 2>/dev/null | head -n 1 || true)"
    glibc_version="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true)"
    cmake_version="$(cmake --version 2>/dev/null | head -n 1 || true)"
    cat >"${RESULTS_DIR}/system_info.json" <<EOF
{
  "architecture": "$(json_escape "${arch}")",
  "platform": "$(json_escape "${platform}")",
  "kernel": "$(json_escape "${kernel}")",
  "cpu_count": ${cpu_count:-0},
  "python_version": "$(json_escape "${python_version:-unknown}")",
  "gcc_version": "$(json_escape "${gcc_version:-unknown}")",
  "glibc_version": "$(json_escape "${glibc_version:-unknown}")",
  "cmake_version": "$(json_escape "${cmake_version:-unknown}")"
}
EOF
    log "prepared environment (os=${FUNC_OS}, mode=${FUNC_MODE}, hardware=${FUNC_HARDWARE:-unspecified})"
}

# ---------- 阶段:install ----------

# Bolt 用 Conan 2 管理依赖;缺失时通过 pip 安装到用户目录。
ensure_conan() {
    if command -v conan >/dev/null 2>&1; then
        return 0
    fi
    log "installing Conan 2 via pip"
    python3 -m pip install --upgrade --user conan ||
        python3 -m pip install --upgrade --break-system-packages conan || {
        log "ERROR: failed to install Conan"
        return 30
    }
    export PATH="${HOME}/.local/bin:${PATH}"
    command -v conan >/dev/null 2>&1 || {
        log "ERROR: conan is unavailable after installation"
        return 30
    }
}

clone_bolt_source() {
    command -v git >/dev/null 2>&1 || {
        log "ERROR: git is required to fetch the Bolt source"
        return 40
    }
    [[ ! -e "${BOLT_SOURCE_DIR}" ]] || {
        log "ERROR: source directory is not clean: ${BOLT_SOURCE_DIR}"
        return 20
    }
    log "cloning Bolt ${SOFTWARE_VERSION} from ${BOLT_SOURCE_URL}"
    GIT_TERMINAL_PROMPT=0 git clone --branch "${SOFTWARE_VERSION}" --depth 1 \
        "${BOLT_SOURCE_URL}" "${BOLT_SOURCE_DIR}" || {
        log "ERROR: failed to clone Bolt ${SOFTWARE_VERSION}"
        return 30
    }
}

build_bolt() {
    local -a make_args=(BUILD_VERSION="${SOFTWARE_VERSION}")
    # 生成 Conan profile(依据可用编译器自动探测)。
    (cd "${BOLT_SOURCE_DIR}" && python3 ./scripts/configure-conan-profile.py) || {
        log "ERROR: failed to configure the Conan profile"
        return 40
    }
    # 首次构建会用 Conan 从源码编译依赖,耗时较长(见 timeout_minutes)。
    (cd "${BOLT_SOURCE_DIR}" && make "${BOLT_BUILD_TYPE}" "${make_args[@]}") || {
        log "ERROR: Bolt build failed"
        return 40
    }
    [[ -d "${BOLT_BUILD_DIR}" ]] || {
        log "ERROR: expected Bolt build directory was not produced: ${BOLT_BUILD_DIR}"
        return 40
    }
}

# ---------- 分层获取(build 模式) ----------
# 优先级:1) 上游官方二进制  2) 三方仓库打包的二进制/包/镜像  3) 源码编译。
# Bolt(bytedance/bolt)是纯源码分发的 C++ 原生引擎:官方不发布任何二进制/release/tag,
# 也没有 Docker 镜像与发行版仓库包,且 build 模式无嵌套 docker。故层 1、层 2 均无可用渠道,
# 只能走层 3(Conan + CMake 重构建)。版本校验:上游无 tag,以 git ref(默认 main)为基准,
# 并要求构建产物目录存在。

# 读取当前获取得到的 Bolt 版本(以 git ref 为版本基准;读不到时返回非零)。
bolt_effective_ref() {
    [[ -d "${BOLT_SOURCE_DIR}/.git" ]] || return 1
    git -C "${BOLT_SOURCE_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || return 1
}

bolt_version_matches() {
    [[ "$(bolt_effective_ref || true)" == "${SOFTWARE_VERSION}" ]] || return 1
    [[ -d "${BOLT_BUILD_DIR}" ]]
}

# 层 1:上游官方二进制。Bolt 官方仅源码分发,不提供任何预编译二进制;本层不可用。
install_bolt_upstream_binary() {
    log "build layer 1/3: bytedance/bolt publishes no prebuilt binary (source-only); layer unavailable"
    return 1
}

# 层 2:三方仓库打包的二进制/包/镜像。Bolt 无任何版本匹配的三方包或镜像;本层不可用。
install_bolt_repo_package() {
    log "build layer 2/3: no version-matched Bolt package or image exists; layer unavailable"
    return 1
}

# 层 3:源码编译(唯一可行层)。克隆上游源码并用 Conan+CMake 构建。
install_bolt_from_source() {
    clone_bolt_source || return $?
    build_bolt || return $?
}

# build 模式分层安装:任一层通过 git ref 版本校验即停止。
install_bolt_build() {
    if install_bolt_upstream_binary && bolt_version_matches; then
        log "build layer 1/3 satisfied Bolt ${SOFTWARE_VERSION} (upstream binary)"
        return 0
    fi
    log "build layer 1/3 did not provide Bolt ${SOFTWARE_VERSION}; degrading"
    if install_bolt_repo_package && bolt_version_matches; then
        log "build layer 2/3 satisfied Bolt ${SOFTWARE_VERSION} (packaged binary)"
        return 0
    fi
    log "build layer 2/3 did not provide Bolt ${SOFTWARE_VERSION}; degrading"
    if install_bolt_from_source && bolt_version_matches; then
        log "build layer 3/3 satisfied Bolt ${SOFTWARE_VERSION} (source build)"
        return 0
    fi
    log "ERROR: no build layer provided Bolt ${SOFTWARE_VERSION}"
    return 40
}

func_install() {
    initialize_runtime || return $?
    check_architecture || return $?

    local actual
    if [[ "${FUNC_MODE}" == "prebuilt" ]]; then
        # 镜像已装好:定位构建产物并用版本标记文件校验,不做任何构建。
        BOLT_HOME="$(resolve_bolt_root || true)"
        [[ -n "${BOLT_HOME}" && -d "${BOLT_HOME}" ]] || {
            log "ERROR: prebuilt Bolt is not present in the software image"
            return 40
        }
        require_test_commands || return $?
        if [[ -f "${BOLT_HOME}/BUILD_VERSION" ]]; then
            actual="$(tr -d '\r\n' <"${BOLT_HOME}/BUILD_VERSION")"
        else
            log "ERROR: cannot determine the prebuilt Bolt version (missing ${BOLT_HOME}/BUILD_VERSION)"
            return 40
        fi
    else
        require_build_commands || return $?
        ensure_conan || return $?
        install_bolt_build || return $?
        # 上游无 tag,以分支名作为版本;commit 写入结果目录便于追溯。
        actual="$(bolt_effective_ref || true)"
        log "Bolt ${actual} built at $(git -C "${BOLT_SOURCE_DIR}" rev-parse --short HEAD)"
    fi

    [[ "${actual}" == "${SOFTWARE_VERSION}" ]] || {
        log "ERROR: Bolt ${actual:-unknown}, expected ${SOFTWARE_VERSION}"
        return 40
    }
    mkdir -p "$(dirname "${PERF_ACTUAL_VERSION_FILE}")"
    printf '%s\n' "${actual}" >"${PERF_ACTUAL_VERSION_FILE}" || return 40
    log "Bolt ${actual} ready (mode=${FUNC_MODE})"
}

# ---------- 独立运行入口 ----------

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]
Capture the environment and prepare Bolt for one OS/hardware cell.
  --mode prebuilt | build   (default: ${FUNC_MODE})

Options:
  --version VERSION    Bolt version / git ref (default: ${SOFTWARE_VERSION})
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