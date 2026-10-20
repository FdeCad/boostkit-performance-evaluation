#!/usr/bin/env bash
# OceanBase 功能测试共享库:由 build.sh / test.sh source。
# 提供运行路径初始化、OS 探测与依赖安装、JSON 辅助。
# OceanBase 属“部署服务型”软件:通过 OceanBase Deployer(obd) 的 demo 命令在任务私有
# 目录部署单机演示集群,再用 mysql 协议做最小可用性 + 功能验证。
set -euo pipefail

SOFTWARE_NAME="oceanbase"
CATEGORY="Database"
SOFTWARE_VERSION="${SOFTWARE_VERSION:-5.0.1.0}"
EXPECTED_ARCH="${EXPECTED_ARCH:-$(uname -m)}"
FUNC_OS="${FUNC_OS:-}"
FUNC_HARDWARE="${FUNC_HARDWARE:-}"
FUNC_MODE="${FUNC_MODE:-build}"
PERF_RUN_ID="${PERF_RUN_ID:-}"
PERF_WORK_DIR="${PERF_WORK_DIR:-}"
RESULTS_DIR="${RESULTS_DIR:-}"
PERF_ACTUAL_VERSION_FILE="${PERF_ACTUAL_VERSION_FILE:-}"

# OceanBase 连接配置(obd demo 默认 root 无密码)。
OB_HOST="${OB_HOST:-127.0.0.1}"
OB_PORT="${OB_PORT:-}"
OB_RPC_PORT="${OB_RPC_PORT:-}"
OB_USER="${OB_USER:-root}"
OB_PASSWORD="${OB_PASSWORD:-}"
OB_DB="${OB_DB:-sbtest}"

# 上游 sysbench 只读烟测规模(远小于性能用例)。
OB_SYSBENCH_TABLES="${OB_SYSBENCH_TABLES:-1}"
OB_SYSBENCH_TABLE_SIZE="${OB_SYSBENCH_TABLE_SIZE:-1000}"
OB_SYSBENCH_TIME="${OB_SYSBENCH_TIME:-10}"
OB_SYSBENCH_THREADS="${OB_SYSBENCH_THREADS:-4}"

# 部署相关路径(在 configure_runtime_paths 中赋值)。
OB_DEPLOY_HOME=""
OBD_HOME=""
STANDALONE_OWNS_WORK_DIR=0
STANDALONE_KEEP_WORK_DIR=0

# 预构建镜像内 observer 的启动脚本:由 oceanbase-ce rpm 安装,镜像 CMD 亦调用它。
OB_IMAGE_SERVICE_SCRIPT="/home/admin/oceanbase/profile/oceanbase-service.sh"

log() { printf '[oceanbase-func] %s\n' "$*"; }

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

configure_runtime_paths() {
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
    # 端口:build 模式由 run_id 派生以隔离并发任务;prebuilt 模式的 observer 由镜像内
    # oceanbase-service.sh 按自身配置固定监听 2881/2882,必须对齐镜像端口才能连上。
    local checksum
    if [[ -z "${OB_PORT}" ]]; then
        if [[ "${FUNC_MODE}" == "prebuilt" ]]; then
            OB_PORT=2881
        else
            checksum="$(printf '%s' "${PERF_RUN_ID}" | cksum)"
            OB_PORT="$((20000 + ${checksum%% *} % 20000))"
        fi
    fi
    [[ "${OB_PORT}" =~ ^[0-9]+$ ]] && ((OB_PORT >= 1024 && OB_PORT <= 65535)) || {
        log "ERROR: invalid OB_PORT: ${OB_PORT}"
        return 10
    }
    if [[ -z "${OB_RPC_PORT}" ]]; then
        if [[ "${FUNC_MODE}" == "prebuilt" ]]; then
            OB_RPC_PORT=2882
        else
            OB_RPC_PORT="$((OB_PORT + 20000))"
        fi
    fi
    ((OB_RPC_PORT <= 65535)) || {
        log "ERROR: invalid OB_RPC_PORT: ${OB_RPC_PORT}"
        return 10
    }

    OB_DEPLOY_HOME="${PERF_WORK_DIR}/oceanbase-demo"
    OBD_HOME="${PERF_WORK_DIR}/obd-meta"

    export SOFTWARE_NAME CATEGORY SOFTWARE_VERSION EXPECTED_ARCH FUNC_OS FUNC_HARDWARE FUNC_MODE
    export PERF_RUN_ID PERF_WORK_DIR RESULTS_DIR PERF_ACTUAL_VERSION_FILE TMPDIR
    export OB_HOST OB_PORT OB_RPC_PORT OB_USER OB_PASSWORD OB_DB OBD_HOME
}

initialize_runtime() {
    configure_runtime_paths || return $?
    mkdir -p "${RESULTS_DIR}" "${PERF_WORK_DIR}" "${TMPDIR}"
}

# ---------- observer 连通性工具 ----------

# 经 mysql 协议对 observer 执行 SQL(默认 root 无密码)。
ob_mysql() {
    local -a args=("mysql" "-h${OB_HOST}" "-P${OB_PORT}" "-u${OB_USER}")
    [[ -n "${OB_PASSWORD}" ]] && args+=("-p${OB_PASSWORD}")
    "${args[@]}" "$@"
}

check_observer_ready() {
    ob_mysql -N -e "SELECT 1" >/dev/null 2>&1
}

# 读取并规整 observer 的四段式版本号。
query_observer_version() {
    local value
    value="$(ob_mysql -N -s -e "SELECT version()" 2>/dev/null || true)"
    printf '%s' "${value}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true
}

# 版本比对:预构建镜像的 tag 用三段式(5.0.1),而 observer 自报四段式(5.0.1.0),
# 两者同属一条版本线,故按"段前缀"判定(请求版本是实际版本的前缀即视为一致)。
version_matches() {
    local actual="$1" expected="$2"
    [[ -n "${actual}" ]] || return 1
    [[ "${actual}" == "${expected}" || "${actual}" == "${expected}".* ]]
}

# 轮询等待 observer 就绪。
wait_observer_ready() {
    local attempts="${1:-120}" attempt
    for attempt in $(seq 1 "${attempts}"); do
        if check_observer_ready; then
            log "observer ready on ${OB_HOST}:${OB_PORT} (after ${attempt} checks)"
            return 0
        fi
        sleep 3
    done
    log "ERROR: observer did not become ready on ${OB_HOST}:${OB_PORT}"
    return 40
}

# prebuilt 模式:镜像内已装好 observer(obd 不在镜像内),直接启动镜像自带实例并复用,
# 不联网从 OceanBase 官方仓库拉包,也不受 LSE/non-LSE 变体选择影响。
start_image_observer() {
    if check_observer_ready; then
        log "an OceanBase observer is already reachable on ${OB_HOST}:${OB_PORT}; reusing it"
        return 0
    fi
    [[ -f "${OB_IMAGE_SERVICE_SCRIPT}" ]] || {
        log "ERROR: the prebuilt image does not ship ${OB_IMAGE_SERVICE_SCRIPT}"
        return 30
    }
    log "starting the observer bundled in the prebuilt image (${OB_IMAGE_SERVICE_SCRIPT})"
    bash "${OB_IMAGE_SERVICE_SCRIPT}" start || {
        log "ERROR: failed to start the observer bundled in the prebuilt image"
        return 40
    }
    return 0
}

# ---------- OS 感知的依赖安装 ----------

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

# OceanBase 官方社区 el8 源(仅 rhel 家族可用)。
write_oceanbase_repo() {
    local repo_file="/etc/yum.repos.d/oceanbase.repo" arch
    [[ -f "${repo_file}" ]] && return 0
    arch="$(uname -m)"
    if [[ "$(id -u)" -eq 0 ]]; then
        printf '[oceanbase]\nname=OceanBase Community el8\nbaseurl=https://mirrors.oceanbase.com/community/stable/el/8/%s/\nenabled=1\ngpgcheck=0\n' \
            "${arch}" >"${repo_file}"
    elif command -v sudo >/dev/null 2>&1; then
        printf '[oceanbase]\nname=OceanBase Community el8\nbaseurl=https://mirrors.oceanbase.com/community/stable/el/8/%s/\nenabled=1\ngpgcheck=0\n' \
            "${arch}" | sudo tee "${repo_file}" >/dev/null
    else
        return 1
    fi
}

# Ubuntu/Debian 无法用 rpm 源,改由 pip 安装官方 oceanbase-deploy(obd)。
# 系统 Python 受 PEP 668 保护(externally-managed-environment),直接 pip3 install 会被
# 拒绝;改在任务私有 venv 中安装部署器,不动系统 Python 也不装到系统路径。
install_obd_debian() {
    local venv="${PERF_WORK_DIR}/obd-venv"
    if [[ -x "${venv}/bin/obd" ]]; then
        export PATH="${venv}/bin:${PATH}"
        return 0
    fi
    log "installing obd (oceanbase-deploy) into the task-private venv ${venv}"
    if ! python3 -m venv "${venv}" >/dev/null 2>&1; then
        # Debian/Ubuntu 把 venv 模块单独打包在 python3-venv 中,默认不随 python3 安装。
        rm -rf -- "${venv}"
        apt_install python3-venv || return 30
        python3 -m venv "${venv}" || return 30
    fi
    "${venv}/bin/pip" install --no-input oceanbase-deploy || return 30
    export PATH="${venv}/bin:${PATH}"
    command -v obd >/dev/null 2>&1 || {
        log "ERROR: obd is unusable after installing oceanbase-deploy into ${venv}"
        return 30
    }
}

install_oceanbase_dependencies() {
    local family
    local -a packages=() want=()
    family="$(os_family)"

    for want in python3 curl; do
        command -v "${want}" >/dev/null 2>&1 || packages+=("${want}")
    done
    # mysql 只是命令名,各发行版的包名不同:Debian/Ubuntu 侧是 default-mysql-client,
    # rhel 家族才叫 mysql(直接 apt install mysql 会报 Unable to locate package)。
    if ! command -v mysql >/dev/null 2>&1; then
        case "${family}" in
            debian) packages+=("default-mysql-client") ;;
            *) packages+=("mysql") ;;
        esac
    fi
    command -v sysbench >/dev/null 2>&1 || packages+=("sysbench")

    case "${family}" in
        rhel)
            # prebuilt 镜像内已有 observer、且不含 obd,无需也不应安装部署器。
            if [[ "${FUNC_MODE}" != "prebuilt" ]] &&
                ! command -v obd >/dev/null 2>&1 && ! rpm -q ob-deploy >/dev/null 2>&1; then
                write_oceanbase_repo || {
                    log "ERROR: cannot configure the OceanBase package repository"
                    return 30
                }
                packages+=("ob-deploy")
            fi
            (( ${#packages[@]} == 0 )) && return 0
            log "installing via dnf: ${packages[*]}"
            dnf_install "${packages[@]}" || return 30
            ;;
        debian)
            (( ${#packages[@]} > 0 )) && { apt_install "${packages[@]}" || return 30; }
            if [[ "${FUNC_MODE}" != "prebuilt" ]] && ! command -v obd >/dev/null 2>&1; then
                install_obd_debian || {
                    log "ERROR: could not obtain obd; OceanBase deployment requires the deployer"
                    return 30
                }
            fi
            ;;
        *)
            log "ERROR: unsupported OS family: ${family}"
            return 30
            ;;
    esac
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