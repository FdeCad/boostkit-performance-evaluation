#!/usr/bin/env bash
# cloudwego (CloudWeGo 套件) 功能测试共享库:由 build.sh / test.sh source。
# 提供运行路径初始化、OS 探测与依赖安装、Go 工具链解析、JSON 辅助。
set -euo pipefail

SOFTWARE_NAME="cloudwego"
CATEGORY="Middleware"
# 套件版本标识 = 套件旗舰 Kitex 的版本(git tag 去掉 v 前缀)。
SOFTWARE_VERSION="${SOFTWARE_VERSION:-0.16.4}"
EXPECTED_ARCH="${EXPECTED_ARCH:-$(uname -m)}"
FUNC_OS="${FUNC_OS:-}"
FUNC_HARDWARE="${FUNC_HARDWARE:-}"
FUNC_MODE="${FUNC_MODE:-build}"
PERF_RUN_ID="${PERF_RUN_ID:-}"
PERF_WORK_DIR="${PERF_WORK_DIR:-}"
RESULTS_DIR="${RESULTS_DIR:-}"
PERF_ACTUAL_VERSION_FILE="${PERF_ACTUAL_VERSION_FILE:-}"

# 套件组件(人工维护,与 SOFTWARE_VERSION 同批核对):
#   kitex   取套件版本标识本身,即 v${SOFTWARE_VERSION}
#   hertz   / netpoll 各自独立发版,固定为各自的最新稳定 tag
CLOUDWEGO_HERTZ_VERSION="${CLOUDWEGO_HERTZ_VERSION:-0.10.6}"
CLOUDWEGO_NETPOLL_VERSION="${CLOUDWEGO_NETPOLL_VERSION:-0.7.5}"
CLOUDWEGO_MODULE_BASE="${CLOUDWEGO_MODULE_BASE:-github.com/cloudwego}"
CLOUDWEGO_SOURCE_BASE="${CLOUDWEGO_SOURCE_BASE:-https://github.com/cloudwego}"
# 模块依赖通过 Go 代理拉取;与仓库内其它 Go 用例使用同一组镜像。
CLOUDWEGO_PROXY="${CLOUDWEGO_PROXY:-https://goproxy.cn|https://repo.huaweicloud.com/repository/goproxy/}"
# 编译套件的 Go 工具链版本;优先使用 PATH 上的 go,缺失时取官方二进制。
GO_SRC_VERSION="${GO_SRC_VERSION:-1.26.9}"
GO_RELEASE_URL="${GO_RELEASE_URL:-https://go.dev/dl}"

SOURCE_DIR=""
GO_DIR=""
GO_BIN=""
GO_ARCH=""
KITEX_SOURCE_DIR=""
HERTZ_SOURCE_DIR=""
NETPOLL_SOURCE_DIR=""
STANDALONE_OWNS_WORK_DIR=0
STANDALONE_KEEP_WORK_DIR=0

log() { printf '[cloudwego-func] %s\n' "$*"; }

# 查询某个组件锁定的版本(不含 v 前缀);kitex 跟随套件版本。
cloudwego_component_version() {
    case "$1" in
        kitex) printf '%s\n' "${SOFTWARE_VERSION}" ;;
        hertz) printf '%s\n' "${CLOUDWEGO_HERTZ_VERSION}" ;;
        netpoll) printf '%s\n' "${CLOUDWEGO_NETPOLL_VERSION}" ;;
        *) return 1 ;;
    esac
}

# 从检出源码读取版本(vX.Y.Z -> X.Y.Z)。
# 层1 经 GOPROXY 取得的 Go module 源码树没有 .git,此时回退读取安装阶段写入的版本标记。
read_cloudwego_version() {
    local src="$1" tag
    tag="$(git -C "${src}" describe --tags --exact-match 2>/dev/null || true)"
    if [[ -n "${tag}" ]]; then
        printf '%s\n' "${tag#v}"
    elif [[ -f "${src}/.cloudwego-version" ]]; then
        cat "${src}/.cloudwego-version"
    fi
}

normalize_arch() {
    case "${1,,}" in
        x86_64 | amd64) printf 'x86_64\n' ;;
        aarch64 | arm64) printf 'aarch64\n' ;;
        *) printf '%s\n' "${1,,}" ;;
    esac
}

os_id() {
    sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"' | tr 'A-Z' 'a-z'
}

os_family() {
    case "$(os_id)" in
        ubuntu | debian) printf 'debian\n' ;;
        openeuler | centos | rhel | fedora | kylin) printf 'rhel\n' ;;
        *) printf '%s\n' "$(os_id)" ;;
    esac
}

detect_os_label() {
    local id version_id
    id="$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"')"
    version_id="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"')"
    if [[ -n "${id}" && -n "${version_id}" ]]; then
        printf '%s-%s\n' "${id,,}" "${version_id}"
    else
        printf 'unknown\n'
    fi
}

check_architecture() {
    local actual expected
    actual="$(normalize_arch "$(uname -m)")"
    expected="$(normalize_arch "${EXPECTED_ARCH}")"
    [[ "${actual}" == "${expected}" ]] || {
        log "ERROR: expected architecture ${expected}, runner is ${actual}"
        return 20
    }
}

# 解析 PATH 或私有目录中的 go;找不到时返回非零,由 install 阶段负责安装。
resolve_go_toolchain() {
    local candidate
    candidate="$(command -v go 2>/dev/null || true)"
    if [[ -n "${candidate}" ]]; then
        GO_BIN="${candidate}"
        return 0
    fi
    if [[ -x "${GO_DIR}/bin/go" ]]; then
        GO_BIN="${GO_DIR}/bin/go"
        return 0
    fi
    return 1
}

configure_runtime_paths() {
    local expected_arch
    case "${EXPECTED_ARCH,,}" in
        x86_64 | amd64) expected_arch="x86_64"; GO_ARCH="amd64" ;;
        aarch64 | arm64) expected_arch="aarch64"; GO_ARCH="arm64" ;;
        *)
            log "ERROR: unsupported expected architecture: ${EXPECTED_ARCH}"
            return 20
            ;;
    esac
    EXPECTED_ARCH="${expected_arch}"

    if [[ -z "${PERF_RUN_ID}" ]]; then
        PERF_RUN_ID="local-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
    fi
    [[ "${PERF_RUN_ID}" =~ ^[A-Za-z0-9._-]+$ ]] || {
        log "ERROR: unsafe PERF_RUN_ID: ${PERF_RUN_ID}"
        return 10
    }
    if [[ -z "${RESULTS_DIR}" ]]; then
        RESULTS_DIR="${SCRIPT_DIR}/results/${SOFTWARE_VERSION}/${PERF_RUN_ID}"
    fi
    if [[ -z "${PERF_WORK_DIR}" ]]; then
        PERF_WORK_DIR="/home/runner/boostkit-func/${SOFTWARE_NAME}/local-${PERF_RUN_ID}"
        STANDALONE_OWNS_WORK_DIR=1
    fi
    TMPDIR="${PERF_WORK_DIR}/tmp"
    if [[ -z "${PERF_ACTUAL_VERSION_FILE}" ]]; then
        PERF_ACTUAL_VERSION_FILE="${RESULTS_DIR}/actual-version.txt"
    fi
    if [[ -z "${FUNC_OS}" ]]; then
        FUNC_OS="$(detect_os_label)"
    fi

    SOURCE_DIR="${PERF_WORK_DIR}/cloudwego-source"
    KITEX_SOURCE_DIR="${SOURCE_DIR}/kitex"
    HERTZ_SOURCE_DIR="${SOURCE_DIR}/hertz"
    NETPOLL_SOURCE_DIR="${SOURCE_DIR}/netpoll"
    GO_DIR="${PERF_WORK_DIR}/go${GO_SRC_VERSION}"

    # Go 环境隔离:模块/GOPATH/缓存全部落在本次任务私有目录;GOTOOLCHAIN=local
    # 禁止 go.mod 触发工具链自动下载;GOENV=off 屏蔽宿主机 go env 残留。
    unset GOROOT GOWORK GOFLAGS 2>/dev/null || true
    export GOMODCACHE="${PERF_WORK_DIR}/module-cache"
    export GOPATH="${PERF_WORK_DIR}/gopath"
    export GOPROXY="${CLOUDWEGO_PROXY}"
    export GOTOOLCHAIN=local
    export GOENV=off
    export GOCACHE="${PERF_WORK_DIR}/gocache"
    # 允许在代理不可达时直接落到源站。
    export GOSUMDB=off

    resolve_go_toolchain || true

    export SOFTWARE_NAME CATEGORY SOFTWARE_VERSION EXPECTED_ARCH FUNC_OS FUNC_HARDWARE FUNC_MODE
    export PERF_RUN_ID PERF_WORK_DIR RESULTS_DIR PERF_ACTUAL_VERSION_FILE TMPDIR
    export CLOUDWEGO_HERTZ_VERSION CLOUDWEGO_NETPOLL_VERSION CLOUDWEGO_MODULE_BASE
    export CLOUDWEGO_SOURCE_BASE CLOUDWEGO_PROXY GO_SRC_VERSION GO_RELEASE_URL GO_ARCH
    export SOURCE_DIR GO_DIR GO_BIN KITEX_SOURCE_DIR HERTZ_SOURCE_DIR NETPOLL_SOURCE_DIR
}

initialize_runtime() {
    configure_runtime_paths || return $?
    mkdir -p "${RESULTS_DIR}" "${PERF_WORK_DIR}" "${TMPDIR}"
}

# ---------- OS 感知的依赖安装(build 模式用) ----------

dnf_install() {
    local -a opts=()
    [[ -z "${PERF_PROXY:-}" ]] || opts+=("--setopt=proxy=${PERF_PROXY}")
    if [[ "$(id -u)" -eq 0 ]]; then
        dnf "${opts[@]}" install -y "$@"
    else
        sudo -n dnf "${opts[@]}" install -y "$@"
    fi
}

apt_install() {
    local -a opts=()
    if [[ -n "${PERF_PROXY:-}" ]]; then
        opts+=(-o "Acquire::http::Proxy=${PERF_PROXY}" -o "Acquire::https::Proxy=${PERF_PROXY}")
    fi
    if [[ "$(id -u)" -eq 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" update &&
            DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" install -y "$@"
    else
        sudo -n env DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" update &&
            sudo -n env DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" install -y "$@"
    fi
}

install_os_packages() {
    local logical family
    local -a rhel=() debian=()
    for logical in "$@"; do
        case "${logical}" in
            git) rhel+=(git); debian+=(git) ;;
            python3) rhel+=(python3); debian+=(python3) ;;
            curl) rhel+=(curl); debian+=(curl) ;;
            tar) rhel+=(tar); debian+=(tar) ;;
            gzip) rhel+=(gzip); debian+=(gzip) ;;
            *)
                log "ERROR: unknown logical package: ${logical}"
                return 30
                ;;
        esac
    done
    family="$(os_family)"
    (( ${#rhel[@]} == 0 )) && return 0
    case "${family}" in
        rhel)
            log "installing via dnf: ${rhel[*]}"
            dnf_install "${rhel[@]}"
            ;;
        debian)
            log "installing via apt: ${debian[*]}"
            apt_install "${debian[@]}"
            ;;
        *)
            log "ERROR: unsupported OS family: ${family}"
            return 30
            ;;
    esac
}

# 获取套件源码所需的命令:git + python3(解析 go mod download 的 JSON)+ 下载/解压工具。
require_build_commands() {
    local -a logical=()
    command -v git >/dev/null 2>&1 || logical+=(git)
    command -v python3 >/dev/null 2>&1 || logical+=(python3)
    command -v curl >/dev/null 2>&1 || logical+=(curl)
    command -v tar >/dev/null 2>&1 || logical+=(tar)
    command -v gzip >/dev/null 2>&1 || logical+=(gzip)
    (( ${#logical[@]} == 0 )) && return 0
    log "installing missing dependencies: ${logical[*]}"
    install_os_packages "${logical[@]}" || return 30
}

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n'
}

# ---------- 独立运行共用的参数解析 ----------

parse_common_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --version)
                [[ "$#" -ge 2 ]] || { log "ERROR: --version requires a value"; return 10; }
                SOFTWARE_VERSION="$2"
                shift 2
                ;;
            --results-dir)
                [[ "$#" -ge 2 ]] || { log "ERROR: --results-dir requires a value"; return 10; }
                RESULTS_DIR="$2"
                shift 2
                ;;
            --os)
                [[ "$#" -ge 2 ]] || { log "ERROR: --os requires a value"; return 10; }
                FUNC_OS="$2"
                shift 2
                ;;
            --hardware)
                [[ "$#" -ge 2 ]] || { log "ERROR: --hardware requires a value"; return 10; }
                FUNC_HARDWARE="$2"
                shift 2
                ;;
            --mode)
                [[ "$#" -ge 2 ]] || { log "ERROR: --mode requires a value"; return 10; }
                FUNC_MODE="$2"
                shift 2
                ;;
            --keep-workdir)
                STANDALONE_KEEP_WORK_DIR=1
                shift
                ;;
            -h | --help)
                return 64
                ;;
            *)
                log "ERROR: unsupported option: $1"
                return 10
                ;;
        esac
    done
}
