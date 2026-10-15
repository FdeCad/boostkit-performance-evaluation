#!/usr/bin/env bash
# sonic-go 测试脚本:功能判定 + 收尾。
# 判定为:git tag 版本 + sonic 自带 go test 用例 + Marshal/Unmarshal 回环。
# 暴露给 Framework 的阶段:check、cleanup。独立执行时依次运行这两个阶段。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---------- 阶段:check ----------

log_line() {
    printf '%s\n' "$*" | tee -a "${RESULTS_DIR}/sonic_go_test.log"
}

# 运行 sonic 自带的核心包与 ast 包单元测试(上游测试套件)。
run_upstream_tests() {
    [[ -f "${SOURCE_DIR}/go.mod" ]] || return 1
    (cd "${SOURCE_DIR}" && "${GO_BIN}" test . ./ast/...)
}

# 用一个临时 main 包,调用 sonic.Marshal/Unmarshal 做编解码回环。
run_marshal_roundtrip() {
    local smoke_dir="${SOURCE_DIR}/functest_smoke"
    mkdir -p "${smoke_dir}"
    cat >"${smoke_dir}/main.go" <<'GO'
package main

import (
	"fmt"
	"os"

	"github.com/bytedance/sonic"
)

type sample struct {
	Name  string `json:"name"`
	Value int    `json:"value"`
	List  []int  `json:"list"`
}

func main() {
	in := sample{Name: "sonic-go", Value: 42, List: []int{1, 2, 3}}
	encoded, err := sonic.Marshal(in)
	if err != nil {
		fmt.Fprintln(os.Stderr, "marshal:", err)
		os.Exit(1)
	}
	var out sample
	if err := sonic.Unmarshal(encoded, &out); err != nil {
		fmt.Fprintln(os.Stderr, "unmarshal:", err)
		os.Exit(1)
	}
	if out.Name != in.Name || out.Value != in.Value || len(out.List) != len(in.List) {
		fmt.Fprintln(os.Stderr, "roundtrip mismatch")
		os.Exit(1)
	}
	fmt.Printf("roundtrip ok: %s\n", string(encoded))
}
GO
    (cd "${SOURCE_DIR}" && "${GO_BIN}" run ./functest_smoke)
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
        {"name": "marshal-roundtrip", "status": env("FUNC_C_STATUS"), "detail": env("FUNC_C_DETAIL")},
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
    : >"${RESULTS_DIR}/sonic_go_test.log"

    if [[ ! -x "${GO_BIN}" ]]; then
        log "ERROR: Go toolchain is unavailable"
        return 40
    fi
    if [[ ! -f "${SOURCE_DIR}/go.mod" ]]; then
        log "ERROR: sonic source tree is unavailable: ${SOURCE_DIR}"
        return 40
    fi

    local version_status="failed" version_detail=""
    local upstream_status="failed" upstream_detail=""
    local roundtrip_status="failed" roundtrip_detail=""
    local actual

    # 1) 版本(git tag)
    actual="$(read_sonic_go_version "${SOURCE_DIR}")"
    if [[ "${actual}" == "${SOFTWARE_VERSION}" ]]; then
        version_status="passed"
        version_detail="tag v${actual}"
    else
        version_detail="tag v${actual:-unknown}, expected v${SOFTWARE_VERSION}"
    fi

    # 2) 上游 go test
    if run_upstream_tests >"${RESULTS_DIR}/upstream_test.log" 2>&1; then
        upstream_status="passed"
        upstream_detail="'go test . ./ast/...' passed"
    else
        upstream_detail="'go test . ./ast/...' failed; see upstream_test.log"
    fi

    # 3) 内部 smoke:Marshal/Unmarshal 回环
    if run_marshal_roundtrip >"${RESULTS_DIR}/marshal_roundtrip.log" 2>&1; then
        roundtrip_status="passed"
        roundtrip_detail="sonic Marshal/Unmarshal roundtrip ok"
    else
        roundtrip_detail="Marshal/Unmarshal roundtrip failed; see marshal_roundtrip.log"
    fi

    local overall="passed"
    if [[ "${version_status}" != "passed" || "${upstream_status}" != "passed" || "${roundtrip_status}" != "passed" ]]; then
        overall="failed"
    fi
    write_functional_result "${overall}" \
        "${version_status}" "${version_detail}" \
        "${upstream_status}" "${upstream_detail}" \
        "${roundtrip_status}" "${roundtrip_detail}"
    log_line "checks: version=${version_status} upstream=${upstream_status} marshal-roundtrip=${roundtrip_status}"

    [[ "${overall}" == "passed" ]] || return 50
}

# ---------- 阶段:cleanup ----------

func_cleanup() {
    initialize_runtime || return $?
    [[ -d "${SOURCE_DIR}/functest_smoke" ]] && rm -rf -- "${SOURCE_DIR}/functest_smoke"
    log "cleaned sonic-go task data"
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
Run the sonic-go functional checks and clean up for one OS/hardware cell.

Options:
  --version VERSION    sonic version (default: ${SOFTWARE_VERSION})
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