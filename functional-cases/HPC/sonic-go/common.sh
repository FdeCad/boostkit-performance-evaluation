#!/usr/bin/env bash
# sonic-go 功能测试共享库:由 build.sh / test.sh source。
# 提供运行路径初始化、OS 探测与依赖安装、Go 工具链解析、JSON 辅助。
set -euo pipefail

SOFTWARE_NAME="sonic-go"
CATEGORY="HPC"
SOFTWARE_VERSION="${SOFTWARE_VERSION:-1.15.2}"
EXPECTED_ARCH="${EXPECTED_ARCH:-$(uname -m)}"
FUNC_OS="${FUNC_OS:-}"
FUNC_HARDWARE="${FUNC_HARDWARE:-}"
FUNC_MODE="${FUNC_MODE:-build}"
PERF_RUN_ID="${PERF_RUN_ID:-}"
PERF_WORK_DIR="${PERF_WORK_DIR:-}"
RESULTS_DIR="${RESULTS_DIR:-}"
PERF_ACTUAL_VERSION_FILE="${PERF_ACTUAL_VERSION_FILE:-}"

SONIC_GO_SOURCE_URL="${SONIC_GO_SOURCE_URL:-https://github.com/bytedance/sonic.git}"
# sonic 的 Go module 路径(层1 经 GOPROXY 按精确版本取源码用)。
SONIC_GO_MODULE="${SONIC_GO_MODULE:-github.com/bytedance/sonic}"
# 编译 sonic 所需的 Go 版本;优先使用 PATH 上的 go,缺失时取官方二进制。
GO_SRC_VERSION="${GO_SRC_VERSION:-1.24.6}"
GO_RELEASE_URL="${GO_RELEASE_URL:-https://go.dev/dl}"
GO_OFFLINE_DIR="${GO_OFFLINE_DIR:-/home/runner/software/golang}"
# sonic 模块依赖通过代理拉取;与性能用例使用同一组镜像。
SONIC_GO_PROXY="${SONIC_GO_PROXY:-https://repo.huaweicloud.com/repository/goproxy/|https://goproxy.cn}"

SOURCE_DIR=""
GO_DIR=""
GO_BIN=""
GO_ARCH=""
HARNESS_DIR=""
STANDALONE_OWNS_WORK_DIR=0
STANDALONE_KEEP_WORK_DIR=0

log() { printf '[sonic-go-func] %s\n' "$*"; }

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

    SOURCE_DIR="${PERF_WORK_DIR}/sonic-source"
    GO_DIR="${PERF_WORK_DIR}/go${GO_SRC_VERSION}"
    HARNESS_DIR="${PERF_WORK_DIR}/harness"

    # Go 环境隔离:模块/GOPATH/缓存全部落在本次任务私有目录;GOTOOLCHAIN=local
    # 禁止 go.mod 触发工具链自动下载;GOENV=off 屏蔽宿主机 go env 残留。
    unset GOROOT GOWORK GOFLAGS 2>/dev/null || true
    export GOMODCACHE="${PERF_WORK_DIR}/module-cache"
    export GOPATH="${PERF_WORK_DIR}/gopath"
    export GOPROXY="${SONIC_GO_PROXY}"
    export GOTOOLCHAIN=local
    export GOENV=off
    export GOCACHE="${PERF_WORK_DIR}/gocache"
    # 允许在代理不可达时直接落到源站。
    export GOSUMDB=off

    resolve_go_toolchain || true

    export SOFTWARE_NAME CATEGORY SOFTWARE_VERSION EXPECTED_ARCH FUNC_OS FUNC_HARDWARE FUNC_MODE
    export PERF_RUN_ID PERF_WORK_DIR RESULTS_DIR PERF_ACTUAL_VERSION_FILE TMPDIR
    export SONIC_GO_SOURCE_URL SONIC_GO_MODULE GO_SRC_VERSION GO_RELEASE_URL GO_OFFLINE_DIR GO_ARCH
    export SOURCE_DIR GO_DIR GO_BIN HARNESS_DIR
}

initialize_runtime() {
    configure_runtime_paths || return $?
    mkdir -p "${RESULTS_DIR}" "${PERF_WORK_DIR}" "${TMPDIR}"
}

# 从检出源码的 tag 读取版本(vX.Y.Z -> X.Y.Z)。
# 层1 经 GOPROXY 取得的 Go module 源码树没有 .git,此时回退读取安装阶段写入的版本标记。
read_sonic_go_version() {
    local src="$1" tag
    tag="$(git -C "${src}" describe --tags --exact-match 2>/dev/null || true)"
    if [[ -n "${tag}" ]]; then
        printf '%s\n' "${tag#v}"
    elif [[ -f "${src}/.sonic-go-version" ]]; then
        cat "${src}/.sonic-go-version"
    fi
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
            build-tools) rhel+=(gcc gcc-c++ make); debian+=(gcc g++ make) ;;
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

# 克隆源码 + 编译 sonic(需 cgo,依赖 gcc)所需的命令。
require_build_commands() {
    local -a logical=()
    command -v git >/dev/null 2>&1 || logical+=(git)
    command -v python3 >/dev/null 2>&1 || logical+=(python3)
    command -v curl >/dev/null 2>&1 || logical+=(curl)
    command -v tar >/dev/null 2>&1 || logical+=(tar)
    { command -v cc >/dev/null 2>&1 && command -v gcc >/dev/null 2>&1; } || logical+=(build-tools)
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