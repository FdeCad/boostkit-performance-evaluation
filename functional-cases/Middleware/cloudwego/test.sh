#!/usr/bin/env bash
# cloudwego 测试脚本:功能判定 + 收尾。
# 判定为:Kitex 版本 + Kitex/Hertz 自带 go test 用例 + Hertz 最小 HTTP 回环 smoke。
# 暴露给 Framework 的阶段:check、cleanup。独立执行时依次运行这两个阶段。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---------- 阶段:check ----------

log_line() {
    printf '%s\n' "$*" | tee -a "${RESULTS_DIR}/cloudwego_test.log"
}

# 运行 Kitex 与 Hertz 自带的上游单元测试。
run_upstream_tests() {
    [[ -f "${KITEX_SOURCE_DIR}/go.mod" && -f "${HERTZ_SOURCE_DIR}/go.mod" ]] || return 1
    (cd "${KITEX_SOURCE_DIR}" && "${GO_BIN}" test ./client/...) || return 1
    (cd "${HERTZ_SOURCE_DIR}" && "${GO_BIN}" test ./pkg/...) || return 1
}

# 用 Hertz 起一个最小 HTTP 服务,再用标准库 client 回环请求,校验响应内容。
# 程序放在 Hertz 源码树内,这样直接复用其模块上下文与已下载的依赖。
run_hertz_smoke() {
    local smoke_dir="${HERTZ_SOURCE_DIR}/functest_smoke"
    rm -rf -- "${smoke_dir}"
    mkdir -p "${smoke_dir}"
    cat >"${smoke_dir}/main.go" <<'GO'
package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/app/server"
	"github.com/cloudwego/hertz/pkg/common/utils"
	"github.com/cloudwego/hertz/pkg/protocol/consts"
)

func main() {
	addr := "127.0.0.1:18999"
	h := server.Default(server.WithHostPorts(addr))
	h.GET("/ping", func(c context.Context, ctx *app.RequestContext) {
		ctx.JSON(consts.StatusOK, utils.H{"ping": "pong"})
	})
	go h.Spin()
	time.Sleep(time.Second)

	resp, err := http.Get("http://" + addr + "/ping")
	if err != nil {
		fmt.Fprintln(os.Stderr, "request failed:", err)
		os.Exit(1)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		fmt.Fprintln(os.Stderr, "read failed:", err)
		os.Exit(1)
	}
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "pong") {
		fmt.Fprintf(os.Stderr, "unexpected response: status=%d body=%q\n", resp.StatusCode, string(body))
		os.Exit(1)
	}
	fmt.Printf("hertz roundtrip ok: %s\n", string(body))
}
GO
    (cd "${HERTZ_SOURCE_DIR}" && "${GO_BIN}" run ./functest_smoke)
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
        {"name": "smoke", "status": env("FUNC_C_STATUS"), "detail": env("FUNC_C_DETAIL")},
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
    : >"${RESULTS_DIR}/cloudwego_test.log"

    if [[ ! -x "${GO_BIN}" ]]; then
        log "ERROR: Go toolchain is unavailable"
        return 40
    fi
    if [[ ! -f "${KITEX_SOURCE_DIR}/go.mod" ]]; then
        log "ERROR: kitex source tree is unavailable: ${KITEX_SOURCE_DIR}"
        return 40
    fi

    local version_status="failed" version_detail=""
    local upstream_status="failed" upstream_detail=""
    local smoke_status="failed" smoke_detail=""
    local actual

    # 1) 版本(Kitex)
    actual="$(read_cloudwego_version "${KITEX_SOURCE_DIR}")"
    if [[ "${actual}" == "${SOFTWARE_VERSION}" ]]; then
        version_status="passed"
        version_detail="kitex v${actual}"
    else
        version_detail="kitex v${actual:-unknown}, expected v${SOFTWARE_VERSION}"
    fi

    # 2) 上游 go test(Kitex client 包 + Hertz pkg 包)
    if run_upstream_tests >"${RESULTS_DIR}/upstream_test.log" 2>&1; then
        upstream_status="passed"
        upstream_detail="'go test ./client/...' (kitex) and 'go test ./pkg/...' (hertz) passed"
    else
        upstream_detail="'go test' failed; see upstream_test.log"
    fi

    # 3) 内部 smoke:Hertz 最小 HTTP 回环
    if run_hertz_smoke >"${RESULTS_DIR}/hertz_smoke.log" 2>&1; then
        smoke_status="passed"
        smoke_detail="hertz server/client roundtrip ok"
    else
        smoke_detail="hertz roundtrip failed; see hertz_smoke.log"
    fi

    local overall="passed"
    if [[ "${version_status}" != "passed" || "${upstream_status}" != "passed" || "${smoke_status}" != "passed" ]]; then
        overall="failed"
    fi
    write_functional_result "${overall}" \
        "${version_status}" "${version_detail}" \
        "${upstream_status}" "${upstream_detail}" \
        "${smoke_status}" "${smoke_detail}"
    log_line "checks: version=${version_status} upstream=${upstream_status} smoke=${smoke_status}"

    [[ "${overall}" == "passed" ]] || return 50
}

# ---------- 阶段:cleanup ----------

func_cleanup() {
    initialize_runtime || return $?
    [[ -d "${HERTZ_SOURCE_DIR}/functest_smoke" ]] && rm -rf -- "${HERTZ_SOURCE_DIR}/functest_smoke"
    log "cleaned cloudwego task data"
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
Run the CloudWeGo functional checks and clean up for one OS/hardware cell.

Options:
  --version VERSION    CloudWeGo (Kitex) version (default: ${SOFTWARE_VERSION})
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
