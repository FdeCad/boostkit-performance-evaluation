#!/usr/bin/env bash
# sonic-go 构建脚本:环境采集 + 准备被测软件(Go 工具链 + 克隆 sonic 模块)。
#   Go 工具链优先用 PATH 上的 go;缺失时取官方二进制解压到私有目录(不安装到系统)。
#   sonic 源码克隆到私有工作区并预取模块依赖,均不污染系统。
#
# build 模式的分层优先获取(优先级从高到低,每层都校验版本 == SOFTWARE_VERSION):
#   层1 上游官方分发(Go module / GOPROXY):按精确版本 v<version> 经 GOPROXY 拉取 sonic 模块源码。
#         GOPROXY 是官方/三方 Go 模块仓库,可精确锁定版本;模块含根包与 ast/decoder/encoder 等子包,
#         独立子模块(如 loader)由 go test 经 GOPROXY 作为依赖补齐。
#         (Go 工具链本身按官方 go.dev/dl 二进制获取,见 install_go_toolchain。)
#   层2 三方仓库已打包的二进制/包:无。sonic 为纯 Go 源码库,无预编译二进制产物。
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

# 安装私有 Go 工具链:离线目录优先,否则从官方 go.dev/dl 取对应架构归档。
install_go_toolchain() {
    resolve_go_toolchain && return 0
    local filename archive offline
    filename="go${GO_SRC_VERSION}.linux-${GO_ARCH}.tar.gz"
    archive="${PERF_WORK_DIR}/${filename}"
    offline="${GO_OFFLINE_DIR}/${filename}"
    if [[ -f "${offline}" ]]; then
        log "using offline Go toolchain archive ${offline}"
        cp "${offline}" "${archive}" || return 30
    else
        log "downloading official Go toolchain ${filename}"
        curl -fsSL --retry 3 --connect-timeout 30 -o "${archive}" \
            "${GO_RELEASE_URL}/${filename}" || {
            log "ERROR: failed to download Go ${GO_SRC_VERSION} for ${GO_ARCH}"
            return 30
        }
    fi
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

# 层1:官方/三方 Go 模块仓库(GOPROXY)按精确版本 v<version> 拉取 sonic 模块源码。
#   模块 zip 含根包与 ast/decoder/encoder 等子包;独立子模块(如 loader)由 go test 经 GOPROXY 补齐。
#   取得的源码树没有 .git,写入 .sonic-go-version 供版本校验回退读取。
acquire_sonic_go_module() {
    [[ -x "${GO_BIN}" ]] || {
        log "layer1: Go toolchain is unavailable"
        return 10
    }
    [[ ! -e "${SOURCE_DIR}" ]] || {
        log "layer1: source directory is not clean: ${SOURCE_DIR}"
        return 20
    }
    local probe_dir="${PERF_WORK_DIR}/module-probe" json dir ver
    rm -rf -- "${probe_dir}"
    mkdir -p "${probe_dir}" || return 30
    (cd "${probe_dir}" && "${GO_BIN}" mod init sonic-go-probe) >/dev/null 2>&1 || true
    json="$(cd "${probe_dir}" && "${GO_BIN}" mod download -json "${SONIC_GO_MODULE}@v${SOFTWARE_VERSION}" 2>/dev/null)" || {
        log "layer1: failed to fetch ${SONIC_GO_MODULE}@v${SOFTWARE_VERSION} from GOPROXY"
        return 30
    }
    dir="$(printf '%s' "${json}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Dir",""))' 2>/dev/null || true)"
    ver="$(printf '%s' "${json}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Version",""))' 2>/dev/null || true)"
    [[ -n "${dir}" && -d "${dir}" ]] || {
        log "layer1: module cache directory is unavailable"
        return 40
    }
    [[ "${ver}" == "v${SOFTWARE_VERSION}" ]] || {
        log "layer1: module version '${ver:-none}' != v${SOFTWARE_VERSION}, downgrade"
        return 40
    }
    mkdir -p "${SOURCE_DIR}" || return 30
    cp -a "${dir}/." "${SOURCE_DIR}/" || {
        log "layer1: failed to copy the module source into ${SOURCE_DIR}"
        return 40
    }
    chmod -R u+w "${SOURCE_DIR}" 2>/dev/null || true
    [[ -f "${SOURCE_DIR}/go.mod" ]] || {
        log "layer1: go.mod is missing in the module source"
        return 40
    }
    # sonic 仓库含嵌套子模块;若模块 zip 未包含 ast 子包(上游测试需要),降级到 git 源码。
    [[ -d "${SOURCE_DIR}/ast" ]] || {
        log "layer1: ast subpackage is missing from the module source, downgrade"
        return 40
    }
    printf '%s\n' "${SOFTWARE_VERSION}" >"${SOURCE_DIR}/.sonic-go-version" || return 40
    return 0
}

clone_sonic_go_source() {
    command -v git >/dev/null 2>&1 || {
        log "ERROR: git is required to fetch the upstream source"
        return 40
    }
    [[ ! -e "${SOURCE_DIR}" ]] || {
        log "ERROR: source directory is not clean: ${SOURCE_DIR}"
        return 20
    }
    log "cloning sonic v${SOFTWARE_VERSION} from ${SONIC_GO_SOURCE_URL}"
    GIT_TERMINAL_PROMPT=0 git clone --branch "v${SOFTWARE_VERSION}" --depth 1 \
        "${SONIC_GO_SOURCE_URL}" "${SOURCE_DIR}" || {
        log "ERROR: failed to clone sonic v${SOFTWARE_VERSION}"
        return 30
    }
    [[ -f "${SOURCE_DIR}/go.mod" ]] || {
        log "ERROR: sonic source tree is incomplete: ${SOURCE_DIR}"
        return 40
    }
}

func_install() {
    initialize_runtime || return $?
    check_architecture || return $?
    require_build_commands || return $?

    local actual
    install_go_toolchain || return $?

    # 分层获取 sonic 源码:层1 Go module(GOPROXY)→ 层2 无 → 层3 git 源码(兜底)。
    if acquire_sonic_go_module; then
        log "layer1 ok: sonic ${SOFTWARE_VERSION} from Go module proxy"
    else
        log "layer1 unavailable; layer3: git source tag v${SOFTWARE_VERSION}"
        rm -rf -- "${SOURCE_DIR}"
        clone_sonic_go_source || return $?
    fi

    actual="$(read_sonic_go_version "${SOURCE_DIR}")"
    [[ "${actual}" == "${SOFTWARE_VERSION}" ]] || {
        log "ERROR: checked-out sonic tag 'v${actual:-unknown}' does not match v${SOFTWARE_VERSION}"
        return 40
    }

    log "downloading sonic module dependencies"
    (cd "${SOURCE_DIR}" && "${GO_BIN}" mod download) || {
        log "ERROR: failed to download sonic module dependencies"
        return 40
    }
    mkdir -p "$(dirname "${PERF_ACTUAL_VERSION_FILE}")"
    printf '%s\n' "${SOFTWARE_VERSION}" >"${PERF_ACTUAL_VERSION_FILE}" || return 40
    log "sonic-go ${SOFTWARE_VERSION} ready (mode=${FUNC_MODE}, go=$("${GO_BIN}" version | awk '{print $3}'))"
}

# ---------- 独立运行入口 ----------

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]
Capture the environment and prepare sonic-go for one OS/hardware cell.
  --mode prebuilt | build   (default: ${FUNC_MODE})

Options:
  --version VERSION    sonic version (default: ${SOFTWARE_VERSION})
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