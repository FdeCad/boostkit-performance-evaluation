#!/usr/bin/env bash
# Snappy 测试脚本:功能判定 + 收尾。
# Snappy 无 CLI:上游判定使用 snappy_unittest,内部 smoke 用链接 libsnappy 的 C++ 回环程序。
# 暴露给 Framework 的阶段:check、cleanup。独立执行时依次运行这两个阶段。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---------- 阶段:check ----------

log_line() {
    printf '%s\n' "$*" | tee -a "${RESULTS_DIR}/snappy_test.log"
}

# 编译并运行一个链接 libsnappy 的 C++ 程序,做 Compress/Uncompress 回环校验。
run_roundtrip() {
    local program="${HARNESS_DIR}/roundtrip.cc"
    local binary="${HARNESS_DIR}/roundtrip"
    mkdir -p "${HARNESS_DIR}"
    cat >"${program}" <<'CPP'
#include <snappy.h>
#include <cstdio>
#include <string>

int main() {
    std::string input;
    input.reserve(120000);
    for (int i = 0; i < 120000; ++i) {
        input.push_back(static_cast<char>((i * 31 + (i / 7)) % 251));
    }
    std::string compressed;
    snappy::Compress(input.data(), input.size(), &compressed);
    std::string output;
    if (!snappy::Uncompress(compressed.data(), compressed.size(), &output)) {
        std::fprintf(stderr, "uncompress failed\n");
        return 1;
    }
    if (output != input) {
        std::fprintf(stderr, "roundtrip mismatch\n");
        return 1;
    }
    std::printf("roundtrip ok: %zu bytes -> %zu bytes\n", input.size(), compressed.size());
    return 0;
}
CPP
    c++ -std=c++11 -O2 -I"${SNAPPY_SOURCE_DIR}" "${program}" \
        -L"${SNAPPY_BUILD_DIR}" -lsnappy -Wl,-rpath,"${SNAPPY_BUILD_DIR}" \
        -o "${binary}" || return 40
    "${binary}"
}

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
    "mode": env("FUNC_MODE"),
    "hardware": env("FUNC_HARDWARE") or None,
    "architecture": env("EXPECTED_ARCH"),
    "run_id": env("PERF_RUN_ID"),
    "status": env("FUNC_OVERALL"),
    "checks": [
        {"name": "version", "status": env("FUNC_V_STATUS"), "detail": env("FUNC_V_DETAIL")},
        {"name": "upstream-test", "status": env("FUNC_U_STATUS"), "detail": env("FUNC_U_DETAIL")},
        {"name": "roundtrip", "status": env("FUNC_C_STATUS"), "detail": env("FUNC_C_DETAIL")},
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
    : >"${RESULTS_DIR}/snappy_test.log"
    [[ -f "${SNAPPY_LIB}" ]] || {
        log "ERROR: libsnappy is unavailable: ${SNAPPY_LIB}"
        return 40
    }

    local version_status="failed" version_detail=""
    local upstream_status="failed" upstream_detail=""
    local roundtrip_status="failed" roundtrip_detail=""
    local actual

    # 1) 版本(以源码 CMakeLists 为准,与构建产物同源)
    actual="$(read_snappy_version "${SNAPPY_SOURCE_DIR}")"
    if [[ "${actual}" == "${SOFTWARE_VERSION}" ]]; then
        version_status="passed"
        version_detail="v=${actual}"
    else
        version_detail="snappy ${actual:-unknown}, expected ${SOFTWARE_VERSION}"
    fi

    # 2) 上游单元测试 snappy_unittest(install 阶段以 SNAPPY_BUILD_TESTS=ON 构建)
    if [[ ! -x "${SNAPPY_UNITTEST}" ]]; then
        upstream_detail="snappy_unittest unavailable (googletest submodule or tests build missing)"
    elif "${SNAPPY_UNITTEST}" >"${RESULTS_DIR}/upstream_test.log" 2>&1; then
        upstream_status="passed"
        upstream_detail="upstream snappy_unittest passed"
    else
        upstream_detail="upstream snappy_unittest failed; see upstream_test.log"
    fi

    # 3) 内部 smoke:C++ Compress/Uncompress 回环
    if run_roundtrip >"${RESULTS_DIR}/roundtrip.log" 2>&1; then
        roundtrip_status="passed"
        roundtrip_detail="Compress/Uncompress roundtrip ok (content matched)"
    else
        roundtrip_detail="Compress/Uncompress roundtrip failed; see roundtrip.log"
    fi

    local overall="passed"
    if [[ "${version_status}" != "passed" || "${upstream_status}" != "passed" || "${roundtrip_status}" != "passed" ]]; then
        overall="failed"
    fi
    write_functional_result "${overall}" \
        "${version_status}" "${version_detail}" \
        "${upstream_status}" "${upstream_detail}" \
        "${roundtrip_status}" "${roundtrip_detail}"
    log_line "checks: version=${version_status} upstream=${upstream_status} roundtrip=${roundtrip_status}"

    [[ "${overall}" == "passed" ]] || return 50
}

# ---------- 阶段:cleanup ----------

func_cleanup() {
    initialize_runtime || return $?
    [[ -d "${HARNESS_DIR}" ]] && rm -rf -- "${HARNESS_DIR}"
    log "cleaned snappy task data"
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

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]
Run the snappy functional checks and clean up for one OS/hardware cell.

Options:
  --version VERSION    snappy version (default: ${SOFTWARE_VERSION})
  --results-dir DIR    Persistent result directory
  --os OS_LABEL        OS label (default: detect from /etc/os-release)
  --hardware HW_LABEL  Hardware label, e.g. kunpeng920
  --mode MODE          prebuilt | build (default: ${FUNC_MODE})
  --keep-workdir       Keep the isolated work directory
  -h, --help           Show this help
USAGE
}

run_test_standalone() {
    local stage_status=0 failed_stage="" finalize_status=0

    configure_runtime_paths || return $?
    trap emergency_cleanup EXIT
    initialize_runtime || return $?

    func_check || {
        stage_status=$?
        failed_stage="check"
    }
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
    mkdir -p "${RESULTS_DIR:-${SCRIPT_DIR}/results}" || return $?
    run_test_standalone
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi