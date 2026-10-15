#!/usr/bin/env bash
# bishengjdk (毕昇 JDK) 构建脚本:环境采集 + 准备被测软件(安装或校验)。
#   FUNC_MODE=prebuilt - 校验镜像内 JDK 版本,不构建
#   FUNC_MODE=build    - 装依赖 + 分层获取并校验版本:
#                        层1 华为云官方二进制 → 层2 三方仓库包(无)→ 层3 GA 源码编译
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

# 华为镜像上的官方 tarball 文件名(按"版本:架构"声明)。
bishengjdk_archive_name() {
    case "${SOFTWARE_VERSION}:$(normalize_arch "${EXPECTED_ARCH}")" in
        21.0.9:aarch64) printf '%s\n' "bisheng-jdk-21.0.9-b11-linux-aarch64.tar.gz" ;;
        21.0.9:x86_64) printf '%s\n' "bisheng-jdk-21.0.9-b11-linux-x64.tar.gz" ;;
        *) return 1 ;;
    esac
}

# 官方发布包的 SHA-256(按"版本:架构"声明);新增版本必须在此登记校验值。
bishengjdk_archive_sha256() {
    case "${SOFTWARE_VERSION}:$(normalize_arch "${EXPECTED_ARCH}")" in
        21.0.9:aarch64)
            printf '%s\n' "1b87106cf2eb8f85390b73732f1ecd07750d6e2fd66160baac756bee2558065a"
            ;;
        21.0.9:x86_64)
            printf '%s\n' "2b45be67978fd6279faf3f9c080d9b17abf7730bf0c21ae37491964992552f23"
            ;;
        *) return 1 ;;
    esac
}

# 下载华为镜像官方 tarball、校验 SHA-256 并解压到私有目录(不写系统 JDK)。
install_bishengjdk() {
    local expected actual filename archive
    filename="$(bishengjdk_archive_name || true)"
    expected="$(bishengjdk_archive_sha256 || true)"
    [[ -n "${filename}" && -n "${expected}" ]] || {
        log "ERROR: no verified BiSheng JDK release is declared for ${SOFTWARE_VERSION} on ${EXPECTED_ARCH}"
        return 30
    }
    if [[ -e "${JDK_HOME}" ]]; then
        log "ERROR: installation directory is not clean: ${JDK_HOME}"
        return 20
    fi
    archive="${PERF_WORK_DIR}/${filename}"
    log "downloading BiSheng JDK ${SOFTWARE_VERSION} from ${BISHENGJDK_MIRROR}"
    curl -fsSL --retry 3 --connect-timeout 30 -o "${archive}" \
        "${BISHENGJDK_MIRROR}/${filename}" || {
        log "ERROR: failed to download ${filename}"
        return 30
    }
    actual="$(sha256sum "${archive}" | awk '{print $1}')"
    [[ "${actual}" == "${expected}" ]] || {
        log "ERROR: BiSheng JDK archive checksum mismatch: ${filename}"
        return 30
    }
    mkdir -p "${JDK_HOME}" || return 30
    tar -xzf "${archive}" -C "${JDK_HOME}" --strip-components=1 || {
        log "ERROR: failed to extract ${filename}"
        return 30
    }
    rm -f "${archive}"
    [[ -x "${JAVA_BIN}" && -x "${JAVAC_BIN}" ]] || {
        log "ERROR: extracted JDK is missing bin/java or bin/javac"
        return 30
    }
    log "installed BiSheng JDK ${SOFTWARE_VERSION} for ${EXPECTED_ARCH}"
}

# ---------- 分层获取(build 模式) ----------
# 按优先级(高→低)依次尝试,每一层获取后都必须用 `java -version` 校验版本 == SOFTWARE_VERSION,
# 不匹配或获取失败即降级到下一层;三层都不可行才让 install 失败。
# 渠道依据 config/distribution.yaml 的 bishengjdk 条目:primary=official-mirror(华为云),
# channels 的 pypi/conda/apt/docker/spack 全部为 null。

# 层1:华为云镜像上的官方 aarch64/x86_64 二进制 tarball(SHA-256 校验)。
install_bishengjdk_layer_upstream_binary() {
    install_bishengjdk
}

# 层2:三方仓库已打包的二进制/包/镜像。
#   distribution.yaml 未给 bishengjdk 声明任何三方渠道(全部 null),且 build 模式无嵌套容器
#   → 该层结构性不可用(用其它厂商的 OpenJDK 包不能代表毕昇 JDK),直接降级到层3。
install_bishengjdk_layer_repo_package() {
    log "layer2: no third-party channel is declared for bishengjdk; skipping to layer 3"
    return 1
}

# 层3:从毕昇 GA 源码编译(最后手段,需要 Adoptium Temurin 引导 JDK)。
install_bishengjdk_layer_source_build() {
    local src_repo src_tag boot_release boot_version archive top_dir boot_archive boot_top jdk_image boot_jdk_home
    case "${SOFTWARE_VERSION}" in
        21.0.9)
            src_repo="bishengjdk-21"
            src_tag="jdk-21.0.9-ga-b011"
            boot_version="21.0.9"
            boot_release="jdk-21.0.9%2B10"
            ;;
        *)
            log "layer3: no BiSheng JDK source recipe is declared for ${SOFTWARE_VERSION}"
            return 1
            ;;
    esac

    install_os_packages build-tools autoconf zip jdk-deps || {
        log "layer3: failed to install the JDK build dependencies"
        return 1
    }

    # 3a: 下载并解压 GA 源码。
    archive="${PERF_WORK_DIR}/${src_repo}-${src_tag}.tar.gz"
    log "layer3: downloading BiSheng JDK GA source ${src_tag}"
    curl -fsSL --retry 3 --connect-timeout 30 -o "${archive}" \
        "${BISHENGJDK_SOURCE_BASE}/${src_repo}/archive/refs/tags/${src_tag}.tar.gz" || {
        log "layer3: failed to download the BiSheng JDK source archive"
        return 1
    }
    rm -rf -- "${SRC_DIR}"
    top_dir="$(tar -tzf "${archive}" | awk -F/ 'NR == 1 {print $1}')"
    [[ -n "${top_dir}" ]] || {
        log "layer3: unexpected BiSheng JDK source archive layout"
        return 1
    }
    tar -xzf "${archive}" -C "${PERF_WORK_DIR}" || return 1
    mv "${PERF_WORK_DIR}/${top_dir}" "${SRC_DIR}" || {
        log "layer3: failed to place the BiSheng JDK source tree"
        return 1
    }
    rm -f "${archive}"

    # 3b: 下载并解压 Adoptium Temurin 引导 JDK。
    case "$(normalize_arch "${EXPECTED_ARCH}")" in
        aarch64) boot_archive="OpenJDK21U-jdk_aarch64_linux_hotspot_${boot_version}_10.tar.gz" ;;
        x86_64) boot_archive="OpenJDK21U-jdk_x64_linux_hotspot_${boot_version}_10.tar.gz" ;;
        *)
            log "layer3: unsupported architecture for the boot JDK: ${EXPECTED_ARCH}"
            return 1
            ;;
    esac
    log "layer3: downloading Temurin boot JDK ${boot_version} for ${EXPECTED_ARCH}"
    curl -fsSL --retry 3 --connect-timeout 30 -o "${PERF_WORK_DIR}/${boot_archive}" \
        "${ADOPTIUM_RELEASE_BASE}/${boot_release}/${boot_archive}" || {
        log "layer3: failed to download the Temurin boot JDK"
        return 1
    }
    rm -rf -- "${PERF_WORK_DIR}/boot-jdk"
    boot_top="$(tar -tzf "${PERF_WORK_DIR}/${boot_archive}" | awk -F/ 'NR == 1 {print $1}')"
    tar -xzf "${PERF_WORK_DIR}/${boot_archive}" -C "${PERF_WORK_DIR}" || return 1
    mv "${PERF_WORK_DIR}/${boot_top}" "${PERF_WORK_DIR}/boot-jdk" || return 1
    rm -f "${PERF_WORK_DIR}/${boot_archive}"
    boot_jdk_home="${PERF_WORK_DIR}/boot-jdk"
    [[ -x "${boot_jdk_home}/bin/java" ]] || {
        log "layer3: the Temurin boot JDK is unusable"
        return 1
    }

    # 3c: 配置并构建 JDK 镜像,安装到私有前缀。
    log "layer3: configuring BiSheng JDK ${SOFTWARE_VERSION}"
    rm -rf -- "${JDK_HOME}"
    (
        cd "${SRC_DIR}"
        bash configure \
            --with-debug-level=release \
            --with-boot-jdk="${boot_jdk_home}" \
            --with-jvm-variants=server \
            --prefix="${JDK_HOME}" \
            --disable-warnings-as-errors \
            --disable-precompiled-headers
    ) || {
        log "layer3: BiSheng JDK configure failed"
        return 1
    }
    log "layer3: building BiSheng JDK images from source"
    make -C "${SRC_DIR}" images || {
        log "layer3: BiSheng JDK source build failed"
        return 1
    }
    jdk_image="$(find "${SRC_DIR}/build" -maxdepth 3 -type d -path '*/images/jdk' -print -quit 2>/dev/null || true)"
    [[ -n "${jdk_image}" && -x "${jdk_image}/bin/java" ]] || {
        log "layer3: the source build did not produce a JDK image"
        return 1
    }
    mkdir -p "${JDK_HOME}" || return 1
    cp -a "${jdk_image}/." "${JDK_HOME}/" || {
        log "layer3: failed to install the built JDK into ${JDK_HOME}"
        return 1
    }
    return 0
}

# 分层获取入口:依次尝试三层,任一层成功即返回 0。
install_bishengjdk_layered() {
    if install_bishengjdk_layer_upstream_binary; then
        log "acquired BiSheng JDK via layer 1 (upstream official binary)"
        return 0
    fi
    log "layer 1 (upstream official binary) unavailable; falling back to layer 2"
    if install_bishengjdk_layer_repo_package; then
        log "acquired BiSheng JDK via layer 2 (third-party repo package)"
        return 0
    fi
    log "layer 2 (third-party repo package) unavailable; falling back to layer 3"
    if install_bishengjdk_layer_source_build; then
        log "acquired BiSheng JDK via layer 3 (source build)"
        return 0
    fi
    log "ERROR: no BiSheng JDK ${SOFTWARE_VERSION} acquisition layer succeeded"
    return 40
}

func_install() {
    initialize_runtime || return $?
    check_architecture || return $?

    local actual
    if [[ "${FUNC_MODE}" == "prebuilt" ]]; then
        # 镜像已装好:只定位并校验版本。
        [[ -x "${JAVA_BIN}" ]] || {
            log "ERROR: java is not present in the software image"
            return 40
        }
    else
        # 当场安装:装依赖 + 分层获取(华为镜像二进制 → 三方仓库包 → GA 源码编译)。
        require_build_commands || return $?
        install_bishengjdk_layered || return $?
    fi

    [[ -x "${JAVAC_BIN}" ]] || {
        log "ERROR: javac is unavailable: ${JAVAC_BIN:-unset}"
        return 40
    }
    actual="$(java_version_of "${JAVA_BIN}")"
    [[ "${actual}" == "${SOFTWARE_VERSION}" ]] || {
        log "ERROR: JDK ${actual:-unknown}, expected ${SOFTWARE_VERSION}"
        return 40
    }
    mkdir -p "$(dirname "${PERF_ACTUAL_VERSION_FILE}")"
    printf '%s\n' "${actual}" >"${PERF_ACTUAL_VERSION_FILE}" || return 40
    log "bishengjdk ${actual} ready (mode=${FUNC_MODE})"
}

# ---------- 独立运行入口 ----------

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]
Capture the environment and prepare BiSheng JDK for one OS/hardware cell.
  --mode prebuilt | build   (default: ${FUNC_MODE})

Options:
  --version VERSION    BiSheng JDK version (default: ${SOFTWARE_VERSION})
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