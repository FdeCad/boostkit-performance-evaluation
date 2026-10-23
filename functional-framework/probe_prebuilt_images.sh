#!/usr/bin/env bash
# 一次性探测脚本:补齐多软件拼装镜像所需的三个待确认项。
#   1) 每个预构建功能镜像的体积(通过 registry manifest 统计压缩层大小,无需拉取)
#   2) faiss / openviking / pytorch 三个镜像的 site-packages 实际路径
#   3) oceanbase 镜像里 oceanbase rpm 的完整文件清单
#
# 用法:
#   bash probe_prebuilt_images.sh                    # 只统计体积(只需 python3,不拉镜像)
#   bash probe_prebuilt_images.sh --inspect          # 额外拉取 4 个镜像做本地探测(需要 docker)
#   bash probe_prebuilt_images.sh --inspect --keep   # 探测后保留镜像,便于人工复核
#
# 输出目录默认 ./prefix-probe-<UTC 时间戳>/,可用 OUT_DIR 覆盖。
# 依赖:python3(registry API + JSON 解析);--inspect 还需要 docker 与 arm64 机器。
set -euo pipefail

TAG_SUFFIX="${TAG_SUFFIX:-oe2403sp4-aarch64}"
OUT_DIR="${OUT_DIR:-$(pwd)/prefix-probe-$(date -u '+%Y%m%dT%H%M%SZ')}"
INSPECT=0
KEEP=0

usage() {
    cat <<'USAGE'
Usage: bash probe_prebuilt_images.sh [--inspect] [--keep]

  --inspect   拉取 oceanbase/faiss/openviking/pytorch 镜像做本地探测
  --keep      探测完成后不删除拉取的镜像
  -h, --help  显示帮助

环境变量:
  TAG_SUFFIX  镜像 tag 后缀,默认 oe2403sp4-aarch64
  OUT_DIR     结果输出目录,默认 ./prefix-probe-<UTC 时间戳>
USAGE
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --inspect) INSPECT=1; shift ;;
        --keep) KEEP=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

command -v python3 >/dev/null 2>&1 || {
    echo 'ERROR: python3 is required for registry queries' >&2
    exit 10
}
if [[ "$(uname -m)" != "aarch64" && "${INSPECT}" -eq 1 ]]; then
    echo "WARNING: current host is $(uname -m); images are arm64, docker run will fail" >&2
fi

mkdir -p "${OUT_DIR}"

echo "[1/3] 统计各镜像压缩体积(registry manifest)..."
python3 - "${OUT_DIR}" "${TAG_SUFFIX}" <<'PY'
import json
import os
import sys
import urllib.request

out_dir, suffix = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)

# (software, version, repo 名覆盖) — golang 的仓库名是 go
IMAGES = [
    ("faiss", "1.15.1", None),
    ("hnswlib", "0.9.0", None),
    ("openviking", "0.5.0", None),
    ("pytorch", "2.14.1", None),
    ("scann", "1.4.2", None),
    ("flink", "2.3.0", None),
    ("spark", "4.2.0", None),
    ("mysql", "26.7.0", None),
    ("oceanbase", "5.0.1", None),
    ("redis", "8.10.2", None),
    ("rocksdb", "11.8.1", None),
    ("folly", "2026.10.12.00", None),
    ("lz4", "1.10.0", None),
    ("protobuf", "36.2", None),
    ("snappy", "1.1.7", None),
    ("x264", "0480cb05", None),
    ("x265", "4.2", None),
    ("brpc", "1.18.0", None),
    ("cloudwego", "0.16.4", None),
    ("kubernetes", "1.37.1", None),
    ("gcc", "16.2.0", None),
    ("glibc", "2.43", None),
    ("golang", "1.27.1", "go"),
    ("openjdk", "28_19", None),
    ("python", "3.15.0", None),
]

ACCEPT = ",".join([
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
])


def fetch(url, headers):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def human(num):
    value = float(num)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if value < 1024 or unit == "GiB":
            return f"{value:.1f}{unit}"
        value /= 1024


records = []
for software, version, repo_override in IMAGES:
    repo = f"openeulertest/{repo_override or software}"
    tag = f"{version}-{suffix}"
    rec = {
        "software": software,
        "repo": repo,
        "tag": tag,
        "found": False,
        "arm64_digest": None,
        "compressed_bytes": None,
        "compressed_human": None,
        "layer_count": None,
        "error": None,
    }
    try:
        token = fetch(
            "https://auth.docker.io/token?service=registry.docker.io"
            f"&scope=repository:{repo}:pull",
            {},
        )["token"]
        headers = {"Authorization": f"Bearer {token}", "Accept": ACCEPT}
        index = fetch(f"https://registry-1.docker.io/v2/{repo}/manifests/{tag}", headers)
        digest = None
        if index.get("manifests"):
            for entry in index["manifests"]:
                if (entry.get("platform") or {}).get("architecture") == "arm64":
                    digest = entry["digest"]
                    break
            if not digest:
                rec["error"] = "no arm64 manifest in index"
        manifest = index
        if digest:
            rec["arm64_digest"] = digest
            manifest = fetch(
                f"https://registry-1.docker.io/v2/{repo}/manifests/{digest}", headers
            )
        layers = manifest.get("layers") or []
        if layers:
            total = sum(layer.get("size", 0) for layer in layers)
            rec.update(
                found=True,
                compressed_bytes=total,
                compressed_human=human(total),
                layer_count=len(layers),
            )
            if digest is None:
                rec["arm64_digest"] = manifest.get("config", {}).get("digest")
        elif rec["error"] is None:
            rec["error"] = "manifest has no layers"
    except Exception as exc:  # noqa: BLE001 - 一次性探测,记录后继续
        rec["error"] = str(exc)
    records.append(rec)
    flag = "OK " if rec["found"] else "ERR"
    print(
        f"  [{flag}] {software:<12} {tag:<40} "
        f"{rec['compressed_human'] or '-':>9}  "
        f"layers={rec['layer_count'] or '-':<4} {rec['error'] or ''}"
    )

found = [r for r in records if r["found"]]
total = sum(r["compressed_bytes"] for r in found)
report = {
    "tag_suffix": suffix,
    "image_count": len(records),
    "found_count": len(found),
    "total_compressed_bytes": total,
    "total_compressed_human": human(total),
    "images": records,
}
json.dump(report, open(f"{out_dir}/image-sizes.json", "w", encoding="utf-8"),
          ensure_ascii=False, indent=2)
print(f"  合计: {human(total)} ({len(found)}/{len(records)} 个镜像)")
PY

if [[ "${INSPECT}" -eq 0 ]]; then
    echo "[2/3] 跳过本地探测(未指定 --inspect)"
    echo "[3/3] 完成,结果:${OUT_DIR}/image-sizes.json"
    exit 0
fi

command -v docker >/dev/null 2>&1 || {
    echo 'ERROR: docker is required for --inspect' >&2
    exit 11
}
docker info >/dev/null 2>&1 || {
    echo 'ERROR: docker daemon is not reachable (check socket permission)' >&2
    exit 11
}

PULLED=()

pull_image() {
    local image="$1"
    if docker image inspect "${image}" >/dev/null 2>&1; then
        echo "  已存在:${image}" >&2
        return 0
    fi
    echo "  拉取:${image}" >&2
    docker pull "${image}" >/dev/null
    PULLED+=("${image}")
}

echo "[2/3] 本地探测 site-packages 与 oceanbase rpm 清单..."
: >"${OUT_DIR}/site-packages.txt"
for pair in "faiss:faiss:1.15.1" "openviking:openviking:0.5.0" "pytorch:torch:2.14.1"; do
    software="${pair%%:*}"
    rest="${pair#*:}"
    module="${rest%%:*}"
    version="${rest#*:}"
    image="openeulertest/${software}:${version}-${TAG_SUFFIX}"
    pull_image "${image}"
    {
        printf '\n==== %s (%s) ====\n' "${software}" "${image}"
        docker run --rm --entrypoint bash "${image}" -c "
            python3 -VV
            python3 -c 'import site, json; print(\"site.getsitepackages =\", json.dumps(site.getsitepackages()))'
            python3 -c 'import importlib.util as u; print(\"spec.origin =\", getattr(u.find_spec(\"${module}\"), \"origin\", None))'
        " 2>&1 || printf 'ERROR: probe failed for %s\n' "${image}"
    } | tee -a "${OUT_DIR}/site-packages.txt"
done

OB_IMAGE="openeulertest/oceanbase:5.0.1-${TAG_SUFFIX}"
pull_image "${OB_IMAGE}"
{
    printf '==== oceanbase rpm 文件清单 (%s) ====\n' "${OB_IMAGE}"
    docker run --rm --entrypoint bash "${OB_IMAGE}" -c '
        set -e
        pkgs="$(rpm -qa | grep -i oceanbase || true)"
        printf "packages:\n%s\n\n" "${pkgs}"
        for p in ${pkgs}; do
            printf "==== %s ====\n" "${p}"
            rpm -ql "${p}"
            printf "\n"
        done
    ' 2>&1 || printf 'ERROR: rpm query failed for %s\n' "${OB_IMAGE}"
} | tee "${OUT_DIR}/oceanbase-rpm.txt"

: >"${OUT_DIR}/image-sizes-uncompressed.txt"
for image in "${PULLED[@]:-}"; do
    [[ -n "${image}" ]] || continue
    size="$(docker image inspect --format '{{.Size}}' "${image}")"
    printf '%s %s\n' "${image}" "${size}" | tee -a "${OUT_DIR}/image-sizes-uncompressed.txt"
done

if [[ "${KEEP}" -eq 0 && -n "${PULLED[*]:-}" ]]; then
    echo "  清理本次拉取的镜像..."
    docker rmi "${PULLED[@]}" >/dev/null 2>&1 || true
fi

echo "[3/3] 完成,结果目录:${OUT_DIR}"
ls -1 "${OUT_DIR}"
