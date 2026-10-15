#!/usr/bin/env bash
# x264 测试脚本:功能判定 + 收尾。
# 判定:版本校验 + 上游 checkasm 汇编一致性测试 + 生成 YUV 编码 smoke。
# 暴露给 Framework 的阶段:check、cleanup。独立执行时依次运行这两个阶段。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---------- 阶段:check ----------

# 上游 checkasm 汇编一致性测试(需要 install 阶段准备好的源码树)。
run_checkasm() {
    local tree
    tree="$(resolve_x264_source_dir)" || {
        log "ERROR: x264 source tree with configure/Makefile not found"
        return 40
    }
    (cd "${tree}" && make checkasm)
}

# 生成一段小尺寸裸 YUV,用 x264 CLI 编码成 H.264 码流,并校验码流含 NAL 起始码。
run_encode_smoke() {
    mkdir -p "${X264_WORK_DIR}" || return 40
    python3 - "${X264_WORK_DIR}/input.yuv" <<'PY' || return 40
import sys

path = sys.argv[1]
width = height = 64
frames = 3
with open(path, "wb") as handle:
    for index in range(frames):
        for y in range(height):
            handle.write(bytes(((x + y + index * 7) % 256) for x in range(width)))
        chroma = (width // 2) * (height // 2)
        handle.write(bytes([128] * chroma))
        handle.write(bytes([128] * chroma))
PY
    "${X264_BIN}" --input-res 64x64 --frames 3 --fps 25 --preset ultrafast \
        -o "${X264_WORK_DIR}/out.264" "${X264_WORK_DIR}/input.yuv" \
        >"${X264_WORK_DIR}/encode.log" 2>&1 || return 40
    python3 - "${X264_WORK_DIR}/out.264" <<'PY' || return 40
import sys

data = open(sys.argv[1], "rb").read()
assert data, "empty bitstream"
assert b"\x00\x00\x00\x01" in data[:256] or b"\x00\x00\x01" in data[:256], "no NAL start code"
PY
    return 0
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
        {"name": "encode-smoke", "status": env("FUNC_C_STATUS"), "detail": env("FUNC_C_DETAIL")},
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
    [[ -x "${X264_BIN}" ]] || {
        log "ERROR: x264 binary is unavailable"
        return 40
    }

    local version_status="failed" version_detail=""
    local upstream_status="failed" upstream_detail=""
    local smoke_status="failed" smoke_detail=""
    local actual

    # 1) 版本
    actual="$(read_x264_version || true)"
    if [[ "${actual}" == "${SOFTWARE_VERSION}" ]]; then
        version_status="passed"
        version_detail="version=${actual}"
    else
        version_detail="x264 ${actual:-unknown}, expected ${SOFTWARE_VERSION}"
    fi

    # 2) 上游 checkasm
    if run_checkasm >"${RESULTS_DIR}/upstream_checkasm.log" 2>&1; then
        upstream_status="passed"
        upstream_detail="upstream make checkasm passed"
    else
        upstream_detail="upstream make checkasm failed; see upstream_checkasm.log"
    fi

    # 3) 编码 smoke
    if run_encode_smoke; then
        smoke_status="passed"
        smoke_detail="encoded 3 frames of 64x64 i420; bitstream contains NAL start codes"
    else
        smoke_detail="x264 encode smoke failed; see ${X264_WORK_DIR}/encode.log"
    fi

    local overall="passed"
    if [[ "${version_status}" != "passed" || "${upstream_status}" != "passed" || "${smoke_status}" != "passed" ]]; then
        overall="failed"
    fi
    write_functional_result "${overall}" \
        "${version_status}" "${version_detail}" \
        "${upstream_status}" "${upstream_detail}" \
        "${smoke_status}" "${smoke_detail}"
    {
        printf 'x264 functional check (version %s, mode %s)\n' "${SOFTWARE_VERSION}" "${FUNC_MODE}"
        printf 'version:  %s - %s\n' "${version_status}" "${version_detail}"
        printf 'upstream: %s - %s\n' "${upstream_status}" "${upstream_detail}"
        printf 'smoke:    %s - %s\n' "${smoke_status}" "${smoke_detail}"
        printf 'overall:  %s\n' "${overall}"
    } >"${RESULTS_DIR}/check.log"
    log "checks: version=${version_status} upstream=${upstream_status} smoke=${smoke_status}"

    [[ "${overall}" == "passed" ]] || return 50
}

# ---------- 阶段:cleanup ----------

func_cleanup() {
    initialize_runtime || return $?
    [[ -d "${X264_WORK_DIR}" ]] && rm -rf -- "${X264_WORK_DIR}"
    log "cleaned x264 task data"
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
Run the x264 functional checks and clean up for one OS/hardware cell.

Options:
  --version VERSION    x264 version (default: ${SOFTWARE_VERSION})
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