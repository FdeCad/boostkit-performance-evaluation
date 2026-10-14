#!/usr/bin/env bash
# Redis 功能测试试点。
# 双入口:Framework 分阶段调用(prepare/install/check/cleanup)与项目外独立运行(main)。
# 功能判定优先复用上游 Tcl 测试套件;OS 差异只集中在 install_os_packages。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOFTWARE_NAME="redis"
CATEGORY="Database"
SOFTWARE_VERSION="${SOFTWARE_VERSION:-8.10.2}"
EXPECTED_ARCH="${EXPECTED_ARCH:-$(uname -m)}"
FUNC_OS="${FUNC_OS:-}"
FUNC_HARDWARE="${FUNC_HARDWARE:-}"
PERF_RUN_ID="${PERF_RUN_ID:-}"
PERF_WORK_DIR="${PERF_WORK_DIR:-}"
RESULTS_DIR="${RESULTS_DIR:-}"
PERF_ACTUAL_VERSION_FILE="${PERF_ACTUAL_VERSION_FILE:-}"

REDIS_SOURCE_URL="${REDIS_SOURCE_URL:-https://github.com/redis/redis.git}"
REDIS_UPSTREAM_TEST="${REDIS_UPSTREAM_TEST:-unit/type/string}"
REDIS_SERVICE_PORT="${REDIS_SERVICE_PORT:-}"

SOURCE_DIR=""
REDIS_SERVER_BIN=""
REDIS_CLI_BIN=""
SERVICE_DIR=""
PID_FILE=""
LOG_FILE=""
STANDALONE_OWNS_WORK_DIR=0
STANDALONE_KEEP_WORK_DIR=0

log() { printf '[redis-func] %s\n' "$*"; }

# ---------- OS / 架构探测 ----------

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

# 把发行版归并到包管理器家族。OS 适配只在这里体现。
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

# ---------- 运行路径(与性能框架同名变量,便于复用注入逻辑) ----------

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
    if [[ -z "${REDIS_SERVICE_PORT}" ]]; then
        local checksum
        checksum="$(printf '%s' "${PERF_RUN_ID}" | cksum)"
        REDIS_SERVICE_PORT="$((20000 + ${checksum%% *} % 20000))"
    fi
    [[ "${REDIS_SERVICE_PORT}" =~ ^[0-9]+$ ]] && \
        ((REDIS_SERVICE_PORT >= 1024 && REDIS_SERVICE_PORT <= 65535)) || {
        log "ERROR: invalid REDIS_SERVICE_PORT: ${REDIS_SERVICE_PORT}"
        return 10
    }

    SOURCE_DIR="${PERF_WORK_DIR}/redis-source"
    REDIS_SERVER_BIN="${SOURCE_DIR}/src/redis-server"
    REDIS_CLI_BIN="${SOURCE_DIR}/src/redis-cli"
    SERVICE_DIR="${PERF_WORK_DIR}/data"
    PID_FILE="${SERVICE_DIR}/redis.pid"
    LOG_FILE="${SERVICE_DIR}/redis.log"

    export SOFTWARE_NAME CATEGORY SOFTWARE_VERSION EXPECTED_ARCH FUNC_OS FUNC_HARDWARE
    export PERF_RUN_ID PERF_WORK_DIR RESULTS_DIR PERF_ACTUAL_VERSION_FILE TMPDIR
    export REDIS_SERVICE_PORT
}

initialize_runtime() {
    configure_runtime_paths || return $?
    mkdir -p "${RESULTS_DIR}" "${PERF_WORK_DIR}" "${TMPDIR}"
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

# 逻辑依赖名 -> 各 OS 包名。软件脚本只说"要什么",不管"在哪个 OS 叫什么"。
install_os_packages() {
    local logical family
    local -a rhel=() debian=()
    for logical in "$@"; do
        case "${logical}" in
            git) rhel+=(git); debian+=(git) ;;
            python3) rhel+=(python3); debian+=(python3) ;;
            build-tools) rhel+=(gcc gcc-c++ make); debian+=(gcc g++ make) ;;
            tcl) rhel+=(tcl); debian+=(tcl) ;;
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

require_commands() {
    local -a logical=()
    command -v git >/dev/null 2>&1 || logical+=(git)
    command -v python3 >/dev/null 2>&1 || logical+=(python3)
    if ! command -v make >/dev/null 2>&1 || ! command -v cc >/dev/null 2>&1 || \
        ! command -v c++ >/dev/null 2>&1; then
        logical+=(build-tools)
    fi
    # 上游 Tcl 测试套件需要 tclsh。
    if ! command -v tclsh >/dev/null 2>&1 && ! command -v tclsh8.6 >/dev/null 2>&1; then
        logical+=(tcl)
    fi
    (( ${#logical[@]} == 0 )) && return 0
    log "installing missing dependencies: ${logical[*]}"
    install_os_packages "${logical[@]}" || return 30
}

# ---------- 阶段:prepare ----------

func_prepare() {
    initialize_runtime || return $?
    python3 - "${RESULTS_DIR}/system_info.json" <<'PY'
import json, os, platform, subprocess, sys

out = sys.argv[1]

def run(args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=10)
        return result.stdout.strip()
    except Exception:
        return ""

def os_pretty():
    try:
        with open("/etc/os-release", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return "ERROR"

payload = {
    "architecture": platform.machine(),
    "platform": os_pretty(),
    "kernel": platform.release(),
    "cpu_count": os.cpu_count() or 0,
    "python_version": platform.python_version(),
    "gcc_version": run(["gcc", "-dumpfullversion", "-dumpversion"]) or "unknown",
    "glibc_version": run(["getconf", "GNU_LIBC_VERSION"]) or "unknown",
}
tmp = out + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
os.replace(tmp, out)
PY
    log "prepared environment (os=${FUNC_OS}, hardware=${FUNC_HARDWARE:-unspecified})"
}

# ---------- 阶段:install(构建/安装) ----------

func_install() {
    initialize_runtime || return $?
    check_architecture || return $?
    require_commands || return $?
    [[ ! -e "${SOURCE_DIR}" ]] || {
        log "ERROR: source directory is not clean: ${SOURCE_DIR}"
        return 20
    }

    log "cloning redis ${SOFTWARE_VERSION} from ${REDIS_SOURCE_URL}"
    GIT_TERMINAL_PROMPT=0 git clone --branch "${SOFTWARE_VERSION}" --depth 1 \
        "${REDIS_SOURCE_URL}" "${SOURCE_DIR}" || {
        log "ERROR: failed to clone redis ${SOFTWARE_VERSION}"
        return 30
    }

    log "building redis"
    (cd "${SOURCE_DIR}" && make -j"$(nproc)" BUILD_TLS=no) || {
        log "ERROR: redis build failed"
        return 40
    }
    [[ -x "${REDIS_SERVER_BIN}" && -x "${REDIS_CLI_BIN}" ]] || {
        log "ERROR: expected redis binaries were not produced"
        return 40
    }

    local actual
    actual="$("${REDIS_SERVER_BIN}" --version | sed -n 's/.*v=\([^ ]*\).*/\1/p' | head -n 1)"
    [[ "${actual}" == "${SOFTWARE_VERSION}" ]] || {
        log "ERROR: built redis ${actual:-unknown}, expected ${SOFTWARE_VERSION}"
        return 40
    }
    mkdir -p "$(dirname "${PERF_ACTUAL_VERSION_FILE}")"
    printf '%s\n' "${actual}" >"${PERF_ACTUAL_VERSION_FILE}" || return 40
    log "redis ${actual} is installed"
}

# ---------- 阶段:check(功能判定) ----------

run_cli_roundtrip() {
    "${REDIS_SERVER_BIN}" \
        --bind 127.0.0.1 --protected-mode no \
        --port "${REDIS_SERVICE_PORT}" --dir "${SERVICE_DIR}" \
        --daemonize yes --pidfile "${PID_FILE}" --logfile "${LOG_FILE}" || return 40

    local attempt
    for attempt in {1..30}; do
        if "${REDIS_CLI_BIN}" -h 127.0.0.1 -p "${REDIS_SERVICE_PORT}" PING 2>/dev/null | grep -qx PONG; then
            break
        fi
        sleep 1
    done
    "${REDIS_CLI_BIN}" -h 127.0.0.1 -p "${REDIS_SERVICE_PORT}" PING | grep -qx PONG || return 40
    "${REDIS_CLI_BIN}" -h 127.0.0.1 -p "${REDIS_SERVICE_PORT}" SET func_key func_value >/dev/null || return 40
    local got
    got="$("${REDIS_CLI_BIN}" -h 127.0.0.1 -p "${REDIS_SERVICE_PORT}" GET func_key)"
    [[ "${got}" == "func_value" ]] || return 40
}

# 把每个检查的 PASS/FAIL 写成结构化结果,供功能矩阵报告聚合。
write_functional_result() {
    local overall="$1" v_status="$2" v_detail="$3" u_status="$4" u_detail="$5" c_status="$6" c_detail="$7"
    FUNC_OVERALL="${overall}" \
        FUNC_V_STATUS="${v_status}" FUNC_V_DETAIL="${v_detail}" \
        FUNC_U_STATUS="${u_status}" FUNC_U_DETAIL="${u_detail}" \
        FUNC_C_STATUS="${c_status}" FUNC_C_DETAIL="${c_detail}" \
        python3 - "${RESULTS_DIR}/functional_result.json" <<'PY'
import json, os, sys

out = sys.argv[1]
env = os.environ.get
payload = {
    "software": env("SOFTWARE_NAME"),
    "category": env("CATEGORY"),
    "version": env("SOFTWARE_VERSION"),
    "os": env("FUNC_OS"),
    "hardware": env("FUNC_HARDWARE") or None,
    "architecture": env("EXPECTED_ARCH"),
    "run_id": env("PERF_RUN_ID"),
    "status": env("FUNC_OVERALL"),
    "checks": [
        {"name": "version", "status": env("FUNC_V_STATUS"), "detail": env("FUNC_V_DETAIL")},
        {"name": "upstream-test", "status": env("FUNC_U_STATUS"), "detail": env("FUNC_U_DETAIL")},
        {"name": "cli-roundtrip", "status": env("FUNC_C_STATUS"), "detail": env("FUNC_C_DETAIL")},
    ],
}
tmp = out + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
os.replace(tmp, out)
PY
}

func_check() {
    initialize_runtime || return $?
    [[ -x "${REDIS_SERVER_BIN}" && -x "${REDIS_CLI_BIN}" ]] || {
        log "ERROR: redis is not built; run the install stage first"
        return 40
    }
    mkdir -p "${SERVICE_DIR}"

    local version_status="failed" version_detail=""
    local upstream_status="failed" upstream_detail=""
    local cli_status="failed" cli_detail=""

    # 1) 版本
    local actual
    actual="$("${REDIS_SERVER_BIN}" --version | sed -n 's/.*v=\([^ ]*\).*/\1/p' | head -n 1)"
    if [[ "${actual}" == "${SOFTWARE_VERSION}" ]]; then
        version_status="passed"
        version_detail="v=${actual}"
    else
        version_detail="built ${actual:-unknown}, expected ${SOFTWARE_VERSION}"
    fi

    # 2) 上游测试套件(优先判定来源)
    if (cd "${SOURCE_DIR}" && ./runtest --single "${REDIS_UPSTREAM_TEST}" --clients 5) \
        >"${RESULTS_DIR}/upstream_test.log" 2>&1; then
        upstream_status="passed"
        upstream_detail="upstream suite '${REDIS_UPSTREAM_TEST}' passed"
    else
        upstream_detail="upstream suite '${REDIS_UPSTREAM_TEST}' failed; see upstream_test.log"
    fi

    # 3) 内部 smoke:CLI 回环
    if run_cli_roundtrip >"${RESULTS_DIR}/cli_roundtrip.log" 2>&1; then
        cli_status="passed"
        cli_detail="SET/GET roundtrip ok on port ${REDIS_SERVICE_PORT}"
    else
        cli_detail="SET/GET roundtrip failed; see cli_roundtrip.log"
    fi

    local overall="passed"
    if [[ "${version_status}" != "passed" || "${upstream_status}" != "passed" || "${cli_status}" != "passed" ]]; then
        overall="failed"
    fi
    write_functional_result "${overall}" \
        "${version_status}" "${version_detail}" \
        "${upstream_status}" "${upstream_detail}" \
        "${cli_status}" "${cli_detail}"
    log "checks: version=${version_status} upstream=${upstream_status} cli=${cli_status}"

    [[ "${overall}" == "passed" ]] || return 50
}

# ---------- 阶段:cleanup ----------

func_cleanup() {
    initialize_runtime || return $?
    if [[ -x "${REDIS_CLI_BIN}" ]]; then
        "${REDIS_CLI_BIN}" -h 127.0.0.1 -p "${REDIS_SERVICE_PORT}" SHUTDOWN NOSAVE >/dev/null 2>&1 || true
    fi
    local pid=""
    if [[ -f "${PID_FILE}" ]]; then
        pid="$(<"${PID_FILE}")"
    fi
    if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
        kill -TERM "${pid}" 2>/dev/null || true
        sleep 1
        kill -KILL "${pid}" 2>/dev/null || true
    fi
    # 上游套件异常退出时可能遗留本 run 自己构建的 redis-server。
    if [[ -n "${SOURCE_DIR}" ]]; then
        pkill -f "${SOURCE_DIR}/src/redis-server" 2>/dev/null || true
    fi
    [[ -d "${SERVICE_DIR}" ]] && rm -rf -- "${SERVICE_DIR}"
    log "cleaned redis service and task data"
}

# ---------- 独立运行入口 ----------

cleanup_standalone_workdir() {
    if [[ "${STANDALONE_KEEP_WORK_DIR}" -eq 1 ]]; then
        log "keeping work directory: ${PERF_WORK_DIR}"
        return 0
    fi
    [[ "${STANDALONE_OWNS_WORK_DIR}" -eq 1 ]] || return 0
    [[ "${PERF_WORK_DIR}" == /home/runner/boostkit-func/${SOFTWARE_NAME}/local-* ]] || {
        log "ERROR: refusing to remove unexpected work directory: ${PERF_WORK_DIR}"
        return 70
    }
    [[ -d "${PERF_WORK_DIR}" ]] && rm -rf -- "${PERF_WORK_DIR}"
    log "removed standalone work directory: ${PERF_WORK_DIR}"
}

emergency_cleanup() {
    set +e
    func_cleanup
    cleanup_standalone_workdir
}

run_redis_func_standalone() {
    local stage_status=0 failed_stage="" finalize_status=0

    configure_runtime_paths || return $?
    trap emergency_cleanup EXIT
    initialize_runtime || return $?

    func_prepare || {
        stage_status=$?
        failed_stage="prepare"
    }
    if [[ "${stage_status}" -eq 0 ]]; then
        func_install || {
            stage_status=$?
            failed_stage="install"
        }
    fi
    if [[ "${stage_status}" -eq 0 ]]; then
        func_check || {
            stage_status=$?
            failed_stage="check"
        }
    fi
    func_cleanup || true
    cleanup_standalone_workdir || finalize_status=70
    trap - EXIT

    log "standalone results: ${RESULTS_DIR}"
    if [[ "${stage_status}" -ne 0 ]]; then
        log "standalone failed at stage: ${failed_stage}"
        return "${stage_status}"
    fi
    return "${finalize_status}"
}

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]
Build Redis at a fixed version, run the upstream functional test suite, and
record a PASS/FAIL result for one OS/hardware cell.

Options:
  --version VERSION    Redis version (default: ${SOFTWARE_VERSION})
  --results-dir DIR    Persistent result directory
  --os OS_LABEL        OS label (default: detect from /etc/os-release)
  --hardware HW_LABEL  Hardware label, e.g. kunpeng920
  --keep-workdir       Keep the isolated work directory for debugging
  -h, --help           Show this help
USAGE
}

main() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --version)
                [[ "$#" -ge 2 ]] || {
                    log "ERROR: --version requires a value"
                    return 10
                }
                SOFTWARE_VERSION="$2"
                shift 2
                ;;
            --results-dir)
                [[ "$#" -ge 2 ]] || {
                    log "ERROR: --results-dir requires a value"
                    return 10
                }
                RESULTS_DIR="$2"
                shift 2
                ;;
            --os)
                [[ "$#" -ge 2 ]] || {
                    log "ERROR: --os requires a value"
                    return 10
                }
                FUNC_OS="$2"
                shift 2
                ;;
            --hardware)
                [[ "$#" -ge 2 ]] || {
                    log "ERROR: --hardware requires a value"
                    return 10
                }
                FUNC_HARDWARE="$2"
                shift 2
                ;;
            --keep-workdir)
                STANDALONE_KEEP_WORK_DIR=1
                shift
                ;;
            -h | --help)
                usage
                return 0
                ;;
            *)
                log "ERROR: unsupported option: $1"
                usage
                return 10
                ;;
        esac
    done

    configure_runtime_paths || return $?
    mkdir -p "${RESULTS_DIR}" || return $?
    : >"${RESULTS_DIR}/results.log"
    local pipeline_status=0
    set +e
    run_redis_func_standalone 2>&1 | tee -a "${RESULTS_DIR}/results.log"
    pipeline_status="${PIPESTATUS[0]}"
    set -e
    return "${pipeline_status}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi