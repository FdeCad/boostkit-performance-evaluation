#!/usr/bin/env python3
"""Run one functional test cell: drive prepare/install/check/cleanup stages."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, TextIO

from catalog_func import FUNC_STAGES, ROOT, compose_image, load_config, validate_case

STAGE_EXIT_CODES = {"prepare": 20, "install": 30, "check": 50, "cleanup": 70}
# check 阶段的脚本用 python3 汇总 functional_result.json;部分基础镜像(如 ubuntu:26.04)
# 并不自带 python3,所以在容器里做一层框架级兜底,缺失时按发行版装好。
CHECK_STAGE_TOOLS = ("python3",)
# 磁盘预检:低于阈值直接失败,避免 apt/构建中途因空间耗尽报出难懂的错误。
# 源码编译类软件(如 pytorch/gcc/ceph)远超这个默认值,由各 func_case.yaml 的
# execution.min_free_disk_gb 单独声明;这里是未声明时的兜底。
DEFAULT_MIN_FREE_DISK_BYTES = 5 * 1024 ** 3
DISK_EXIT_CODE = 91
FORWARD_ENV_KEYS = (
    "SOFTWARE_VERSION",
    "EXPECTED_ARCH",
    "FUNC_OS",
    "FUNC_HARDWARE",
    "FUNC_MODE",
    "PERF_RUN_ID",
    "PERF_WORK_DIR",
    "RESULTS_DIR",
    "PERF_ACTUAL_VERSION_FILE",
    "TMPDIR",
    "PERF_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "PYTHONUNBUFFERED",
)
# 代理未单独声明 no_proxy 时的默认排除项:容器内的回环访问不能被代理接管。
DEFAULT_NO_PROXY = "localhost,127.0.0.1,::1"
PROXY_CA_MOUNT = "/run/boostkit-proxy-anchors"
PROXY_CA_BOOTSTRAP = r"""
set -eu
if [ -f /tmp/boostkit-proxy-ca-ready ]; then
    exit 0
fi
case "$1" in
    ubuntu)
        anchor_dir=/usr/local/share/ca-certificates
        update_command=update-ca-certificates
        system_bundle=/etc/ssl/certs/ca-certificates.crt
        ;;
    openeuler)
        anchor_dir=/etc/pki/ca-trust/source/anchors
        update_command=update-ca-trust
        system_bundle=/etc/pki/tls/certs/ca-bundle.crt
        ;;
    *) echo "unsupported OS for proxy CA setup: $1" >&2; exit 1 ;;
esac
mkdir -p "$anchor_dir"
bootstrap_bundle=/tmp/boostkit-proxy-bootstrap-ca.crt
if [ -s "$system_bundle" ]; then
    cat "$system_bundle" > "$bootstrap_bundle"
else
    : > "$bootstrap_bundle"
fi
cp -a /run/boostkit-proxy-anchors/. "$anchor_dir/"
append_certificates() {
    for certificate in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [ -e "$certificate" ] || continue
        if [ -d "$certificate" ] && [ ! -L "$certificate" ]; then
            append_certificates "$certificate" "$2" "$3"
        elif [ -f "$certificate" ]; then
            case "$3:$certificate" in
                all:*.crt|all:*.pem|all:*.cer|extra:*.pem|extra:*.cer)
                    cat "$certificate" >> "$2"
                    printf '\n' >> "$2"
                    ;;
            esac
        fi
    done
}
append_certificates /run/boostkit-proxy-anchors "$bootstrap_bundle" all
if ! command -v "$update_command" >/dev/null 2>&1; then
    if [ "$update_command" = update-ca-trust ]; then
        dnf --setopt="sslcacert=$bootstrap_bundle" \
            --setopt="proxy_sslcacert=$bootstrap_bundle" install -y ca-certificates
    else
        apt-get -o "Acquire::https::CaInfo=$bootstrap_bundle" update
        DEBIAN_FRONTEND=noninteractive apt-get \
            -o "Acquire::https::CaInfo=$bootstrap_bundle" install -y ca-certificates
    fi
fi
if [ "$update_command" = update-ca-trust ]; then
    update-ca-trust extract
else
    update-ca-certificates
    # Ubuntu 的更新工具只收录 .crt；保留原 .pem 文件名，并直接追加到 curl 使用的 CA bundle。
    append_certificates /run/boostkit-proxy-anchors "$system_bundle" extra
fi
touch /tmp/boostkit-proxy-ca-ready
echo "[cell] installed proxy CA certificates from mounted anchors"
"""
SHELL_FUNCTION_RUNNER = r"""
script_path="$1"
function_name="$2"
shift 2
source "${script_path}"
if ! declare -F "${function_name}" >/dev/null; then
    printf 'ERROR: declared stage function does not exist: %s in %s\n' \
        "${function_name}" "${script_path}" >&2
    exit 10
fi
"${function_name}"
"""


@dataclass(frozen=True)
class CellContext:
    root: Path
    case_path: Path
    case: dict[str, Any]
    category: str
    software: str
    version: str
    operating_system: str
    os_runtime: str
    mode: str
    image: str
    build_image: str
    hardware: str
    architecture: str
    run_id: str
    output_dir: Path
    work_dir: Path
    work_root: Path

    @property
    def case_dir(self) -> Path:
        return self.case_path.parent


class StageTerminated(RuntimeError):
    """Raised when the driver asks an active stage to terminate."""


def _terminate_process_group(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    process.wait(timeout=5)


def _raise_stage_terminated(signum: int, _frame: object) -> None:
    raise StageTerminated(f"received signal {signum}")


def _stream_output(stream: TextIO, log: TextIO) -> None:
    for line in stream:
        sys.stdout.write(line)
        sys.stdout.flush()
        log.write(line)
        log.flush()


def build_context(args: argparse.Namespace, case: dict[str, Any], config: dict[str, Any]) -> CellContext:
    category = case["category"]
    software = case["name"]
    os_spec = config["operating_systems"][args.os]
    # build 模式下用例可声明 build_image:该镜像本身就带着软件本体(如 Ubuntu 26.04
    # 没有目标版本的发行版二进制),直接拿它起容器,容器里跑的就是真实 Ubuntu。
    build_template = case.get("build_image") or ""
    build_image = ""
    if build_template and os_spec.get("mode") == "build":
        build_image = compose_image(
            build_template,
            case.get("image_name") or software,
            args.version,
            args.architecture,
        )
    if os_spec["runtime"] != "container":
        image = ""
    elif os_spec["mode"] == "build":
        image = build_image or os_spec["image"]
    else:
        image = compose_image(
            os_spec["image_template"],
            case.get("image_name") or software,
            args.version,
            args.architecture,
        )
    # 临时工作流可指定完整结果目录；正式工作流仍使用默认层级。
    if args.result_dir is not None:
        output_dir = args.result_dir
        if not output_dir.is_absolute():
            raise ValueError("result directory must be an absolute path")
    else:
        output_root = args.output_root or ROOT / config["output_root"]
        if not output_root.is_absolute():
            raise ValueError("output root must be an absolute path")
        output_dir = (
            output_root / category / software / args.version
            / args.os / args.hardware / args.run_id
        )
    work_root = Path(config["work_root"])
    work_dir = (
        work_root / software / args.version
        / args.os / args.hardware / args.run_id
    )
    return CellContext(
        root=ROOT,
        case_path=args.case.resolve(),
        case=case,
        category=category,
        software=software,
        version=args.version,
        operating_system=args.os,
        os_runtime=os_spec["runtime"],
        mode=os_spec.get("mode", ""),
        image=image,
        build_image=build_image,
        hardware=args.hardware,
        architecture=args.architecture,
        run_id=args.run_id,
        output_dir=output_dir,
        work_dir=work_dir,
        work_root=work_root,
    )


def resolve_proxy() -> str:
    """取当前生效的代理地址,优先 PERF_PROXY,其次标准代理变量。"""
    for key in ("PERF_PROXY", "https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY"):
        value = os.environ.get(key, "").strip()
        if value:
            return value
    return ""


def stage_environment(context: CellContext) -> dict[str, str]:
    environment = {
        "SOFTWARE_VERSION": context.version,
        "EXPECTED_ARCH": context.architecture,
        "FUNC_OS": context.operating_system,
        "FUNC_HARDWARE": context.hardware,
        "FUNC_MODE": context.mode,
        "PERF_RUN_ID": context.run_id,
        "PERF_WORK_DIR": str(context.work_dir),
        "RESULTS_DIR": str(context.output_dir),
        "PERF_ACTUAL_VERSION_FILE": str(context.work_dir / "actual-version.txt"),
        "TMPDIR": str(context.work_dir / "tmp"),
        "PYTHONUNBUFFERED": "1",
    }
    # 容器内 apt/dnf/curl/git/pip 都按标准代理变量取代理;这里统一派生并转发,
    # 用例脚本无需再逐个拼 --setopt=proxy / -o Acquire::http::Proxy。
    proxy = resolve_proxy()
    if proxy:
        no_proxy = (
            os.environ.get("NO_PROXY", "").strip()
            or os.environ.get("no_proxy", "").strip()
            or DEFAULT_NO_PROXY
        )
        environment.update(
            {
                "PERF_PROXY": proxy,
                "http_proxy": proxy,
                "https_proxy": proxy,
                "HTTP_PROXY": proxy,
                "HTTPS_PROXY": proxy,
                "no_proxy": no_proxy,
                "NO_PROXY": no_proxy,
            }
        )
    return environment


def _inner_shell(script: Path, function: str) -> list[str]:
    return [
        "bash",
        "--noprofile",
        "--norc",
        "-c",
        SHELL_FUNCTION_RUNNER,
        "func-stage",
        str(script),
        function,
    ]


def _container_engine() -> str:
    return os.environ.get("PERF_CONTAINER_ENGINE", "docker")


def _container_name(context: CellContext) -> str:
    raw = f"boostkit-func-{context.run_id}-{context.operating_system}-{context.hardware}"
    return "".join(char if (char.isalnum() or char in "_.-") else "-" for char in raw)


def _ensure_image(context: CellContext) -> None:
    """Use the local image when present; otherwise pull it."""
    engine = _container_engine()
    image = context.image
    local = subprocess.run(
        [engine, "image", "inspect", image], capture_output=True, text=True
    )
    if local.returncode == 0:
        print(f"[cell] using local image {image}", flush=True)
        return
    print(f"[cell] image {image} not found locally; pulling", flush=True)
    pull = subprocess.run([engine, "pull", image])
    if pull.returncode != 0:
        raise RuntimeError(f"failed to pull image {image} (exit code {pull.returncode})")


def _container_status(engine: str, name: str) -> str:
    result = subprocess.run(
        [engine, "inspect", "-f", "{{.State.Status}}", name],
        capture_output=True, text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def _wait_until_running(engine: str, name: str, attempts: int = 60) -> None:
    """Wait until the container is running and accepts exec."""
    for _ in range(attempts):
        status = _container_status(engine, name)
        if status in {"exited", "dead"}:
            logs = subprocess.run(
                [engine, "logs", "--tail", "50", name], capture_output=True, text=True
            )
            raise RuntimeError(
                f"container {name} stopped ({status}): "
                f"{logs.stdout.strip()} {logs.stderr.strip()}"
            )
        if status == "running":
            probe = subprocess.run(
                [engine, "exec", name, "true"], capture_output=True, text=True
            )
            if probe.returncode == 0:
                return
        time.sleep(0.5)
    raise RuntimeError(f"container {name} did not become exec-ready")


def _proxy_ca_source() -> Path | None:
    """Only the temporary workflow opts in; direct connections need no CA mount."""
    source = os.environ.get("FUNC_PROXY_CA_DIR", "").strip()
    if not source or not resolve_proxy():
        return None
    path = Path(source)
    if not path.is_absolute() or not path.is_dir():
        raise RuntimeError(f"proxy CA directory is unavailable: {source}")
    if not any(item.is_file() for item in path.rglob("*")):
        raise RuntimeError(f"proxy CA directory contains no files: {source}")
    return path


def _install_proxy_ca(engine: str, name: str, environment: dict[str, str], os_name: str) -> None:
    if os_name.startswith("ubuntu"):
        family = "ubuntu"
    elif os_name.startswith("openeuler"):
        family = "openeuler"
    else:
        raise RuntimeError(f"unsupported OS for proxy CA setup: {os_name}")
    command = [engine, "exec"]
    for key in ("http_proxy", "https_proxy", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"):
        value = environment.get(key)
        if value is not None:
            command += ["-e", f"{key}={value}"]
    command += [name, "sh", "-ec", PROXY_CA_BOOTSTRAP, "sh", family]
    if subprocess.run(command).returncode != 0:
        raise RuntimeError(f"failed to install proxy CA certificates in container {name}")


def _ensure_container(
    context: CellContext, environment: dict[str, str]
) -> str:
    """Start (or reuse) one persistent container per cell.

    The container stays alive across stages so that build-mode installs
    (dependencies, compiled artifacts in the image filesystem) survive into
    the check stage.  We wait until it is actually running before executing
    a stage, otherwise the first exec can race container startup.
    """
    engine = _container_engine()
    name = _container_name(context)
    proxy_ca = _proxy_ca_source()
    if _container_status(engine, name):
        if _container_status(engine, name) != "running":
            subprocess.run([engine, "start", name], check=True)
        _wait_until_running(engine, name)
        if proxy_ca is not None:
            _install_proxy_ca(engine, name, environment, context.operating_system)
        return name

    _ensure_image(context)
    command = [engine, "run", "-d", "--name", name]
    mounted: set[str] = set()
    for host in (context.root, context.output_dir, context.work_dir):
        target = str(host)
        if target in mounted:
            continue
        mounted.add(target)
        command += ["-v", f"{target}:{target}"]
    if proxy_ca is not None:
        command += ["--mount", f"type=bind,src={proxy_ca},dst={PROXY_CA_MOUNT},readonly"]
    command += ["-w", str(context.case_dir)]
    for key in FORWARD_ENV_KEYS:
        value = environment.get(key)
        if value is not None:
            command += ["-e", f"{key}={value}"]
    command += [context.image, "sleep", "infinity"]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"failed to start container {name} from {context.image}: {result.stderr.strip()}"
        )
    _wait_until_running(engine, name)
    if proxy_ca is not None:
        _install_proxy_ca(engine, name, environment, context.operating_system)
    return name


def _remove_container(context: CellContext) -> None:
    subprocess.run(
        [_container_engine(), "rm", "-f", _container_name(context)],
        capture_output=True, text=True,
    )


def _remove_work_dir(context: CellContext) -> None:
    """Reclaim the cell work directory; every artifact lives in the output directory."""
    parts = (
        context.software, context.version, context.operating_system,
        context.hardware, context.run_id,
    )
    root = context.work_root.resolve()
    target = context.work_dir.resolve()
    # 只删工作根下、由这五个已知字段拼出的那一层,任何异常一律不删。
    if (
        any(
            not part or part in {".", ".."} or "/" in part or "\\" in part
            for part in parts
        )
        or target != root.joinpath(*parts).resolve()
        or target == root
        or root not in target.parents
    ):
        print(f"[cell] refusing to remove unexpected work directory: {target}", flush=True)
        return
    if not target.is_dir():
        return
    shutil.rmtree(target, ignore_errors=True)
    print(f"[cell] removed work directory {target}", flush=True)


def _required_free_disk(case: dict[str, Any]) -> int:
    """Each software may declare its own floor as execution.min_free_disk_gb."""
    declared = case["execution"].get("min_free_disk_gb")
    if declared is None:
        return DEFAULT_MIN_FREE_DISK_BYTES
    return int(float(declared) * 1024 ** 3)


def _preflight_disk(context: CellContext, minimum_bytes: int) -> None:
    """Fail fast with an actionable message when the runner is nearly out of space."""
    usage = shutil.disk_usage(context.work_dir)
    if usage.free >= minimum_bytes:
        return
    raise RuntimeError(
        f"only {usage.free // (1024 * 1024)} MiB free on the filesystem backing "
        f"{context.work_dir}, but {context.software} needs at least "
        f"{minimum_bytes / 1024 ** 3:.1f} GiB; prune the runner "
        "(docker system prune -af, clear the work root) and retry"
    )


def _container_tool_present(engine: str, name: str, tool: str) -> bool:
    probe = subprocess.run(
        [engine, "exec", name, "sh", "-c", f"command -v {tool} >/dev/null 2>&1"],
        capture_output=True, text=True,
    )
    return probe.returncode == 0


def _ensure_container_tools(engine: str, name: str, tools: tuple[str, ...]) -> None:
    """Install stage tools that the image does not ship, using its own package manager."""
    missing = [tool for tool in tools if not _container_tool_present(engine, name, tool)]
    if not missing:
        return
    print(f"[cell] container {name} is missing {', '.join(missing)}; installing", flush=True)
    probe = subprocess.run(
        [engine, "exec", name, "sh", "-c", "sed -n 's/^ID=//p' /etc/os-release"],
        capture_output=True, text=True,
    )
    os_id = probe.stdout.strip().strip('"').lower()
    packages = " ".join(missing)
    if os_id in {"ubuntu", "debian"}:
        install = f"apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y {packages}"
    else:
        install = f"dnf install -y {packages}"
    result = subprocess.run([engine, "exec", name, "sh", "-c", install])
    if result.returncode != 0:
        raise RuntimeError(f"failed to install {', '.join(missing)} in container {name}")


def _container_exec_command(
    context: CellContext, name: str, script: Path, function: str, environment: dict[str, str]
) -> list[str]:
    command = [_container_engine(), "exec", "-i", "-w", str(context.case_dir)]
    for key in FORWARD_ENV_KEYS:
        value = environment.get(key)
        if value is None:
            continue
        command += ["-e", f"{key}={value}"]
    command += [name]
    command += _inner_shell(script, function)
    return command


def run_stage(context: CellContext, stage: str, timeout_minutes: float) -> int:
    definition = context.case["execution"]["stages"][stage]
    script = (context.case_dir / definition["script"]).resolve()
    function = definition["function"]
    log_name = f"stage-{stage}.log"
    log_path = context.output_dir / log_name
    context.output_dir.mkdir(parents=True, exist_ok=True)
    context.work_dir.mkdir(parents=True, exist_ok=True)
    (context.work_dir / "tmp").mkdir(parents=True, exist_ok=True)

    environment = stage_environment(context)
    if context.os_runtime == "container":
        name = _ensure_container(context, environment)
        if stage == "check":
            _ensure_container_tools(_container_engine(), name, CHECK_STAGE_TOOLS)
        command = _container_exec_command(context, name, script, function, environment)
        process_env = dict(os.environ)
    else:
        command = _inner_shell(script, function)
        process_env = {**os.environ, **environment}

    with log_path.open("w", encoding="utf-8") as log:
        process: subprocess.Popen[str] | None = None
        output_thread: threading.Thread | None = None
        previous_sigterm = signal.getsignal(signal.SIGTERM)
        signal.signal(signal.SIGTERM, _raise_stage_terminated)
        try:
            process = subprocess.Popen(
                command,
                cwd=str(context.case_dir),
                env=process_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                start_new_session=True,
            )
            assert process.stdout is not None
            output_thread = threading.Thread(
                target=_stream_output, args=(process.stdout, log),
                name=f"stage-output-{stage}",
            )
            output_thread.start()
            returncode = process.wait(timeout=timeout_minutes * 60)
        except subprocess.TimeoutExpired:
            assert process is not None
            message = f"[TIMEOUT] stage {stage} exceeded {timeout_minutes} minutes\n"
            sys.stderr.write(message)
            sys.stderr.flush()
            log.write(message)
            log.flush()
            _terminate_process_group(process)
            returncode = 124
        except BaseException:
            if process is not None:
                _terminate_process_group(process)
            raise
        finally:
            if output_thread is not None:
                output_thread.join()
            signal.signal(signal.SIGTERM, previous_sigterm)
    return returncode


def write_status(context: CellContext, **updates: object) -> dict[str, Any]:
    path = context.output_dir / "status.json"
    payload: dict[str, Any] = {}
    if path.is_file():
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            payload = {}
    if not payload:
        payload = {
            "category": context.category,
            "software": context.software,
            "version": context.version,
            "os": context.operating_system,
            "hardware": context.hardware,
            "architecture": context.architecture,
            "run_id": context.run_id,
            "status": "running",
            "stage": "initialized",
            "failed_stage": None,
            "exit_code": None,
        }
    payload.update(updates)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.parent.mkdir(parents=True, exist_ok=True)
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)
    return payload


def validate_stage_outputs(context: CellContext, stage: str) -> None:
    for output_name, definition in context.case.get("outputs", {}).items():
        if definition["stage"] != stage:
            continue
        path = context.output_dir / definition["path"]
        if definition["format"] == "json":
            if not path.is_file() or path.stat().st_size == 0:
                raise ValueError(f"required output {output_name} is missing: {definition['path']}")
            try:
                value = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise ValueError(f"output {output_name} contains invalid JSON: {exc}") from exc
            if not isinstance(value, dict):
                raise ValueError(f"output {output_name} JSON root must be an object")
        else:
            if not path.is_file() or path.stat().st_size == 0:
                raise ValueError(f"required output {output_name} is missing: {definition['path']}")


def record_result(context: CellContext) -> None:
    """Summarize the cell into result.json for the matrix report."""
    functional_path = context.output_dir / "functional_result.json"
    result: dict[str, Any] = {
        "software": context.software,
        "category": context.category,
        "version": context.version,
        "os": context.operating_system,
        "os_runtime": context.os_runtime,
        "hardware": context.hardware,
        "architecture": context.architecture,
        "run_id": context.run_id,
        "status": "failed",
        "checks": [],
    }
    if functional_path.is_file():
        try:
            functional = json.loads(functional_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            functional = {}
        if isinstance(functional, dict):
            result["status"] = functional.get("status", "failed")
            result["checks"] = functional.get("checks", [])
    temporary = (context.output_dir / "result.json").with_name(".result.json.tmp")
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(context.output_dir / "result.json")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--case", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--os", required=True)
    parser.add_argument("--hardware", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--stage", required=True, choices=FUNC_STAGES)
    parser.add_argument("--architecture", default=None)
    parser.add_argument("--output-root", type=Path, default=None)
    parser.add_argument("--result-dir", type=Path, default=None)
    args = parser.parse_args()

    case, errors = validate_case(args.case, ROOT)
    if errors or case is None:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 10
    if args.version not in case["versions"]:
        print(f"ERROR: version {args.version} is not declared", file=sys.stderr)
        return 10

    config = load_config(ROOT)
    if args.os not in config["operating_systems"]:
        print(f"ERROR: unknown os {args.os}", file=sys.stderr)
        return 10
    if args.hardware not in config["hardware"]:
        print(f"ERROR: unknown hardware {args.hardware}", file=sys.stderr)
        return 10
    if args.architecture is None:
        args.architecture = config["architectures"][0]

    context = build_context(args, case, config)
    context.output_dir.mkdir(parents=True, exist_ok=True)
    context.work_dir.mkdir(parents=True, exist_ok=True)
    timeout_minutes = float(context.case["execution"].get("timeout_minutes", 90))

    print(
        f"[cell] {context.software} {context.version} "
        f"os={context.operating_system}({context.os_runtime}) "
        f"hw={context.hardware} stage={args.stage}",
        flush=True,
    )
    write_status(context, status="running", stage=args.stage)

    if args.stage == "prepare":
        # 每个 cell 的 job 从 prepare 开始,在这里做一次磁盘预检。
        try:
            _preflight_disk(context, _required_free_disk(context.case))
        except RuntimeError as exc:
            write_status(
                context, status="failed", stage=args.stage, failed_stage=args.stage,
                exit_code=DISK_EXIT_CODE, error=str(exc),
            )
            print(f"ERROR: {exc}", file=sys.stderr)
            return DISK_EXIT_CODE

    returncode = run_stage(context, args.stage, timeout_minutes)
    print(f"[cell] stage {args.stage} exited with code {returncode}", flush=True)

    if args.stage == "cleanup":
        if context.os_runtime == "container":
            _remove_container(context)
        # 无论 cleanup 是否成功都回收工作目录,否则跑一轮 all 就会把 runner 撑满。
        _remove_work_dir(context)

    if returncode != 0:
        write_status(
            context, status="failed", stage=args.stage, failed_stage=args.stage,
            exit_code=returncode or STAGE_EXIT_CODES[args.stage],
        )
        return returncode or STAGE_EXIT_CODES[args.stage]

    try:
        validate_stage_outputs(context, args.stage)
    except (OSError, ValueError) as exc:
        write_status(
            context, status="failed", stage=args.stage, failed_stage=args.stage,
            exit_code=STAGE_EXIT_CODES[args.stage], error=str(exc),
        )
        print(f"ERROR: stage output validation failed: {exc}", file=sys.stderr)
        return STAGE_EXIT_CODES[args.stage]

    if args.stage == "check":
        record_result(context)
        functional_path = context.output_dir / "functional_result.json"
        status = "failed"
        try:
            status = json.loads(functional_path.read_text(encoding="utf-8")).get("status", "failed")
        except (OSError, json.JSONDecodeError):
            status = "failed"
        write_status(context, status=status, stage="complete", failed_stage=None)
        print(f"[cell] functional status: {status}", flush=True)
        return 0 if status == "passed" else STAGE_EXIT_CODES["check"]

    write_status(context, status="running", stage=args.stage)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
