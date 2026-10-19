#!/usr/bin/env bash
# cloudwego 构建脚本:环境采集 + 准备被测软件(Go 工具链 + 获取套件各组件源码)。
#   Go 工具链优先用 PATH 上的 go;缺失时取官方二进制解压到私有目录(不安装到系统)。
#   套件源码克隆到私有工作区并预取模块依赖,均不污染系统。
#
# build 模式的分层优先获取(优先级从高到低,每层都校验版本 == 锁定版本):
#   层1 上游官方分发(Go module / GOPROXY):按精确版本 v<version> 经 GOPROXY 拉取各组件源码。
#   层2 三方仓库已打包的二进制/包:无。Kitex/Hertz/Netpoll 均为纯 Go 库,无预编译二进制产物。
#   层3 源码(兜底):git clone v<version> tag 得到完整仓库树。
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

# 安装私有 Go 工具链:优先用 PATH 上的 go,否则从官方 go.dev/dl 取对应架构归档。
install_go_toolchain() {
    resolve_go_toolchain && return 0
    local filename archive
    filename="go${GO_SRC_VERSION}.linux-${GO_ARCH}.tar.gz"
    archive="${PERF_WORK_DIR}/${filename}"
    log "downloading official Go toolchain ${filename}"
    curl -fsSL --retry 3 --connect-timeout 30 -o "${archive}" \
        "${GO_RELEASE_URL}/${filename}" || {
        log "ERROR: failed to download Go ${GO_SRC_VERSION} for ${GO_ARCH}"
        return 30
    }
    [[ ! -e "${GO_DIR}" ]] || {
        log "ERROR: Go toolchain directory already exists: ${GO_DIR}"
        return 20
    }
    mkdir -p "${GO_DIR}"
    tar -xzf "${archive}" -C "${GO_DIR}" --strip-components=1 || {
        log "ERROR: failed to extract the Go toolchain"
        return 30
    }
    rm -f "${archive}"
    GO_BIN="${GO_DIR}/bin/go"
    [[ -x "${GO_BIN}" ]] || {
        log "ERROR: Go binary is unavailable after install: ${GO_BIN}"
        return 30
    }
    log "installed private Go toolchain: $("${GO_BIN}" version | awk '{print $3}')"
}

# 层1:经 GOPROXY 按精确版本 v<version> 拉取 Go module 源码。
#   取得的源码树没有 .git,写入 .cloudwego-version 供版本校验回退读取。
acquire_component_from_proxy() {
    local name="$1" module="$2" version="$3" dest="$4"
    [[ -x "${GO_BIN}" ]] || {
        log "layer1: Go toolchain is unavailable"
        return 10
    }
    [[ ! -e "${dest}" ]] || {
        log "layer1: source directory is not clean: ${dest}"
        return 20
    }
    local probe_dir="${PERF_WORK_DIR}/probe-${name}" json dir ver
    rm -rf -- "${probe_dir}"
    mkdir -p "${probe_dir}" || return 30
    (cd "${probe_dir}" && "${GO_BIN}" mod init "probe-${name}") >/dev/null 2>&1 || true
    json="$(cd "${probe_dir}" && "${GO_BIN}" mod download -json "${module}@v${version}" 2>/dev/null)" || {
        log "layer1: failed to fetch ${module}@v${version} from GOPROXY"
        return 30
    }
    dir="$(printf '%s' "${json}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Dir",""))' 2>/dev/null || true)"
    ver="$(printf '%s' "${json}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Version",""))' 2>/dev/null || true)"
    [[ -n "${dir}" && -d "${dir}" ]] || {
        log "layer1: module cache directory is unavailable for ${name}"
        return 40
    }
    [[ "${ver}" == "v${version}" ]] || {
        log "layer1: ${name} version '${ver:-none}' != v${version}, downgrade"
        return 40
    }
    mkdir -p "${dest}" || return 30
    cp -a "${dir}/." "${dest}/" || {
        log "layer1: failed to copy the ${name} source into ${dest}"
        return 40
    }
    chmod -R u+w "${dest}" 2>/dev/null || true
    [[ -f "${dest}/go.mod" ]] || {
        log "layer1: go.mod is missing in the ${name} source"
        return 40
    }
    printf '%s\n' "${version}" >"${dest}/.cloudwego-version" || return 40
    return 0
}

# 层3:git clone 对应 tag(兜底)。
clone_component() {
    local name="$1" version="$2" dest="$3"
    command -v git >/dev/null 2>&1 || {
        log "ERROR: git is required to fetch the upstream source"
        return 40
    }
    [[ ! -e "${dest}" ]] || {
        log "ERROR: source directory is not clean: ${dest}"
        return 20
    }
    log "layer3: cloning ${name} v${version} from ${CLOUDWEGO_SOURCE_BASE}/${name}.git"
    GIT_TERMINAL_PROMPT=0 git clone --branch "v${version}" --depth 1 \
        "${CLOUDWEGO_SOURCE_BASE}/${name}.git" "${dest}" || {
        log "ERROR: failed to clone ${name} v${version}"
        return 30
    }
    [[ -f "${dest}/go.mod" ]] || {
        log "ERROR: ${name} source tree is incomplete: ${dest}"
        return 40
    }
    return 0
}

# 单组件获取:层1 GOPROXY 模块 → 层3 git 源码(兜底)。
acquire_component() {
    local name="$1" version="$2" dest="$3"
    if acquire_component_from_proxy "${name}" "${CLOUDWEGO_MODULE_BASE}/${name}" "${version}" "${dest}"; then
        log "layer1 ok: ${name} ${version} from Go module proxy"
        return 0
    fi
    log "layer1 unavailable for ${name}; layer3: git tag v${version}"
    rm -rf -- "${dest}"
    clone_component "${name}" "${version}" "${dest}"
}

func_install() {
    initialize_runtime || return $?
    check_architecture || return $?
    require_build_commands || return $?

    local actual
    install_go_toolchain || return $?

    acquire_component kitex "${SOFTWARE_VERSION}" "${KITEX_SOURCE_DIR}" || return $?
    acquire_component hertz "${CLOUDWEGO_HERTZ_VERSION}" "${HERTZ_SOURCE_DIR}" || return $?
    acquire_component netpoll "${CLOUDWEGO_NETPOLL_VERSION}" "${NETPOLL_SOURCE_DIR}" || return $?

    actual="$(read_cloudwego_version "${KITEX_SOURCE_DIR}")"
    [[ "${actual}" == "${SOFTWARE_VERSION}" ]] || {
        log "ERROR: checked-out kitex version '${actual:-unknown}' does not match ${SOFTWARE_VERSION}"
        return 40
    }

    local dir
    for dir in "${KITEX_SOURCE_DIR}" "${HERTZ_SOURCE_DIR}" "${NETPOLL_SOURCE_DIR}"; do
        log "prefetching module dependencies for $(basename "${dir}")"
        (cd "${dir}" && "${GO_BIN}" mod download) || {
            log "ERROR: failed to download module dependencies for ${dir}"
            return 40
        }
    done

    mkdir -p "$(dirname "${PERF_ACTUAL_VERSION_FILE}")"
    printf '%s\n' "${actual}" >"${PERF_ACTUAL_VERSION_FILE}" || return 40
    log "cloudwego ${actual} ready (kitex=${SOFTWARE_VERSION}, hertz=${CLOUDWEGO_HERTZ_VERSION}, netpoll=${CLOUDWEGO_NETPOLL_VERSION}, go=$("${GO_BIN}" version | awk '{print $3}'))"
}

# ---------- 独立运行入口 ----------

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]
Capture the environment and prepare CloudWeGo for one OS/hardware cell.
  --mode prebuilt | build   (default: ${FUNC_MODE})

Options:
  --version VERSION    CloudWeGo (Kitex) version (default: ${SOFTWARE_VERSION})
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
