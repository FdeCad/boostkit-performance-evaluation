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

# Ubuntu/Debian 侧 obd 的上游官方 rpm 源,以及解包后的任务私有安装根目录(在
# configure_runtime_paths 中赋值)。obd 只以 rpm 分发(PyPI 上没有对应包)。
OBD_RPM_MIRROR_BASE="https://mirrors.oceanbase.com/community/stable/el/8"
OBD_ROOT=""

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
    OBD_ROOT="${PERF_WORK_DIR}/obd-root"

    export SOFTWARE_NAME CATEGORY SOFTWARE_VERSION EXPECTED_ARCH FUNC_OS FUNC_HARDWARE FUNC_MODE
    export PERF_RUN_ID PERF_WORK_DIR RESULTS_DIR PERF_ACTUAL_VERSION_FILE TMPDIR
    export OB_HOST OB_PORT OB_RPC_PORT OB_USER OB_PASSWORD OB_DB OBD_HOME OBD_ROOT
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

# obd 只以 rpm 分发,上游没有 PyPI 包(oceanbase-deploy/ob-deploy 均无发布),因此
# Ubuntu/Debian 侧改为取官网 el8 源里的上游 rpm,解包到任务私有目录后直接运行:
# obd 是自带解释器的单文件程序,不依赖系统 Python,天然绕开 PEP 668。
# 私有目录通过 OBD_INSTALL_PRE 指认(obd 的 tool.py 用它推导安装路径 /usr/obd)。
activate_private_obd() {
    [[ -x "${OBD_ROOT}/usr/bin/obd" ]] || return 1
    export OBD_INSTALL_PRE="${OBD_ROOT}"
    export PATH="${OBD_ROOT}/usr/bin:${PATH}"
    return 0
}

# 取上游 el8 源目录索引里版本最高的 ob-deploy rpm 文件名(形如 ob-deploy-4.7.0-3.el8.aarch64.rpm)。
# 索引取不到或无匹配时输出为空并返回 0,由调用方判定为空即报错(避免 set -e 静默退出)。
obd_rpm_filename() {
    local arch="$1" listing
    listing="$(curl -fsSL --retry 3 --connect-timeout 30 \
        "${OBD_RPM_MIRROR_BASE}/${arch}/" 2>/dev/null || true)"
    printf '%s\n' "${listing}" |
        grep -oE "ob-deploy-[0-9][0-9A-Za-z._-]*\.el8\.${arch}\.rpm" |
        sort -V | tail -n 1 || true
}

install_obd_debian() {
    local arch name url rpm_file executer
    if activate_private_obd; then
        return 0
    fi
    apt_install rpm cpio || return 30
    arch="$(uname -m)"
    name="$(obd_rpm_filename "${arch}")"
    [[ -n "${name}" ]] || {
        log "ERROR: no ob-deploy rpm found for ${arch} on ${OBD_RPM_MIRROR_BASE}"
        return 30
    }
    url="${OBD_RPM_MIRROR_BASE}/${arch}/${name}"
    rpm_file="${PERF_WORK_DIR}/${name}"
    log "installing obd from the upstream rpm into ${OBD_ROOT}"
    curl -fsSL --retry 3 --connect-timeout 30 -o "${rpm_file}" "${url}" || {
        log "ERROR: failed to download ${url}"
        return 30
    }
    rm -rf -- "${OBD_ROOT}"
    mkdir -p "${OBD_ROOT}" || return 30
    # rpm 内是绝对路径(usr/bin/obd、usr/obd/*),cpio 会去掉前导斜杠,正好落到私有根下。
    (cd "${OBD_ROOT}" && rpm2cpio "${rpm_file}" | cpio -idm --quiet --no-absolute-filenames) || {
        log "ERROR: failed to unpack ${name} into ${OBD_ROOT}"
        return 30
    }
    rm -f "${rpm_file}"
    [[ -f "${OBD_ROOT}/usr/bin/obd" ]] || {
        log "ERROR: ${name} does not provide usr/bin/obd"
        return 30
    }
    chmod +x "${OBD_ROOT}/usr/bin/obd"
    executer="${OBD_ROOT}/usr/obd/lib/executer/executer27/bin/executer"
    if [[ -f "${executer}" ]]; then
        chmod +x "${executer}"
    fi
    activate_private_obd || {
        log "ERROR: obd is unusable after unpacking ${name} into ${OBD_ROOT}"
        return 30
    }
    return 0
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
            # observer 是 el8 二进制:libaio 是 rpm 里声明的硬依赖,libnuma 与上游镜像的预装保持一致。
            packages+=(libaio1t64 libnuma1)
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