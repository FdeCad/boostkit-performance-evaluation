#!/usr/bin/env bash
# hnswlib 测试脚本:功能判定 + 收尾。
# 判定:版本校验 + add/knn_query 回环 smoke + 带 filter 的过滤检索 smoke。
# 暴露给 Framework 的阶段:check、cleanup。独立执行时依次运行这两个阶段。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---------- 阶段:check ----------

# 基础 smoke:建索引、add_items、knn_query 回环,校验形状与自查询召回。
write_knn_smoke() {
    cat >"$1" <<'PY'
import hnswlib
import numpy as np

dim, num_elements, k = 16, 200, 3
rng = np.random.default_rng(0)
data = np.asarray(rng.random((num_elements, dim)), dtype="float32")
ids = np.arange(num_elements)

index = hnswlib.Index(space="l2", dim=dim)
index.init_index(max_elements=num_elements, ef_construction=200, M=16)
index.add_items(data, ids)
assert index.get_current_count() == num_elements

index.set_ef(200)
labels, distances = index.knn_query(data[:5], k=k)
assert labels.shape == (5, k), labels.shape
assert distances.shape == (5, k), distances.shape
assert (distances >= 0).all()

# 自查最近邻:高 ef 下自身命中率应接近 1。
self_labels, _ = index.knn_query(data, k=1)
recall = float((self_labels[:, 0] == ids).mean())
assert recall >= 0.9, f"self-query recall too low: {recall}"
print(f"hnswlib add/knn_query ok (self-query recall={recall:.3f})")
PY
}

# 过滤检索:仅允许偶数 id,校验返回值全部满足过滤条件。
write_filter_smoke() {
    cat >"$1" <<'PY'
import hnswlib
import numpy as np

dim, num_elements, k = 16, 200, 3
rng = np.random.default_rng(1)
data = np.asarray(rng.random((num_elements, dim)), dtype="float32")
ids = np.arange(num_elements)

index = hnswlib.Index(space="l2", dim=dim)
index.init_index(max_elements=num_elements, ef_construction=200, M=16)
index.add_items(data, ids)
index.set_ef(200)


def even_only(label):
    return label % 2 == 0


labels, distances = index.knn_query(data[:5], k=k, filter=even_only)
assert labels.shape == (5, k), labels.shape
assert (labels % 2 == 0).all(), "filtered results contain odd ids"
print("hnswlib filtered knn_query ok")
PY
}

write_functional_result() {
    local overall="$1" v_status="$2" v_detail="$3" k_status="$4" k_detail="$5" f_status="$6" f_detail="$7"
    FUNC_OVERALL="${overall}" \
        FUNC_V_STATUS="${v_status}" FUNC_V_DETAIL="${v_detail}" \
        FUNC_K_STATUS="${k_status}" FUNC_K_DETAIL="${k_detail}" \
        FUNC_F_STATUS="${f_status}" FUNC_F_DETAIL="${f_detail}" \
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
        {"name": "hnsw-knn-roundtrip", "status": env("FUNC_K_STATUS"), "detail": env("FUNC_K_DETAIL")},
        {"name": "hnsw-filter", "status": env("FUNC_F_STATUS"), "detail": env("FUNC_F_DETAIL")},
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
    [[ -n "${PYBIN}" && -x "${PYBIN}" ]] || {
        log "ERROR: python interpreter is unavailable"
        return 40
    }
    local log_file="${RESULTS_DIR}/functional_test.log"
    : >"${log_file}"

    local version_status="failed" version_detail="" actual
    local knn_status="failed" knn_detail=""
    local filter_status="failed" filter_detail=""

    # 1) 版本
    actual="$(read_installed_version)"
    if [[ "${actual}" == "${SOFTWARE_VERSION}" ]]; then
        version_status="passed"
        version_detail="hnswlib ${actual}"
    else
        version_detail="hnswlib ${actual:-unknown}, expected ${SOFTWARE_VERSION}"
    fi
    printf 'version: %s (%s)\n' "${version_status}" "${version_detail}" >>"${log_file}"

    # 2) 基础 smoke:add/knn_query 回环
    if write_knn_smoke "${TMPDIR}/hnswlib_knn.py" && \
        "${PYBIN}" "${TMPDIR}/hnswlib_knn.py" >>"${log_file}" 2>&1; then
        knn_status="passed"
        knn_detail="add_items/knn_query roundtrip returned correct shapes and self-query hits"
    else
        knn_detail="knn roundtrip smoke failed; see functional_test.log"
    fi
    printf 'hnsw-knn-roundtrip: %s (%s)\n' "${knn_status}" "${knn_detail}" >>"${log_file}"

    # 3) 过滤检索
    if write_filter_smoke "${TMPDIR}/hnswlib_filter.py" && \
        "${PYBIN}" "${TMPDIR}/hnswlib_filter.py" >>"${log_file}" 2>&1; then
        filter_status="passed"
        filter_detail="filtered knn_query honoured the allow predicate"
    else
        filter_detail="filtered knn_query smoke failed; see functional_test.log"
    fi
    printf 'hnsw-filter: %s (%s)\n' "${filter_status}" "${filter_detail}" >>"${log_file}"

    local overall="passed"
    if [[ "${version_status}" != "passed" || "${knn_status}" != "passed" || "${filter_status}" != "passed" ]]; then
        overall="failed"
    fi
    write_functional_result "${overall}" \
        "${version_status}" "${version_detail}" \
        "${knn_status}" "${knn_detail}" \
        "${filter_status}" "${filter_detail}"
    log "checks: version=${version_status} hnsw-knn-roundtrip=${knn_status} hnsw-filter=${filter_status}"

    [[ "${overall}" == "passed" ]] || return 50
}

# ---------- 阶段:cleanup ----------

func_cleanup() {
    initialize_runtime || return $?
    if [[ "${FUNC_MODE}" == "prebuilt" ]]; then
        log "prebuilt mode: nothing installed by this case to clean"
    else
        [[ -d "${VENV_DIR}" ]] && rm -rf -- "${VENV_DIR}"
        [[ -d "${BUILD_DIR}" ]] && rm -rf -- "${BUILD_DIR}"
        log "removed the task-private venv and build directory"
    fi
    [[ -d "${TMPDIR}" ]] && rm -rf -- "${TMPDIR}/hnswlib_knn.py" "${TMPDIR}/hnswlib_filter.py"
    log "cleaned hnswlib task data"
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
Run the hnswlib functional checks and clean up for one OS/hardware cell.

Options:
  --version VERSION    hnswlib version (default: ${SOFTWARE_VERSION})
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