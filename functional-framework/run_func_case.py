#!/usr/bin/env python3
"""Run one functional test cell: drive prepare/install/check/cleanup stages."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, TextIO

from catalog_func import FUNC_STAGES, ROOT, compose_image, load_config, validate_case

STAGE_EXIT_CODES = {"prepare": 20, "install": 30, "check": 50, "cleanup": 70}
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
    "PYTHONUNBUFFERED",
)
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
    hardware: str
    architecture: str
    run_id: str
    output_dir: Path
    work_dir: Path

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
    if os_spec["runtime"] != "container":
        image = ""
    elif os_spec["mode"] == "build":
        image = os_spec["image"]
    else:
        image = compose_image(os_spec["image_template"], software, args.version)
    output_dir = (
        ROOT / config["output_root"] / category / software / args.version
        / args.os / args.hardware / args.run_id
    )
    work_dir = (
        Path(config["work_root"]) / software / args.version
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
        hardware=args.hardware,
        architecture=args.architecture,
        run_id=args.run_id,
        output_dir=output_dir,
        work_dir=work_dir,
    )


def stage_environment(context: CellContext) -> dict[str, str]:
    return {
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


def _ensure_image(image: str) -> None:
    """Use the local image when present; otherwise pull it from the registry."""
    engine = _container_engine()
    local = subprocess.run(
        [engine, "image", "inspect", image], capture_output=True, text=True
    )
    if local.returncode == 0:
        print(f"[cell] using local image {image}", flush=True)
        return
    print(f"[cell] image {image} not found locally; pulling", flush=True)
    pull = subprocess.run([engine, "pull", image], capture_output=True, text=True)
    if pull.returncode != 0:
        raise RuntimeError(f"failed to pull image {image}: {pull.stderr.strip()}")


def _ensure_container(context: CellContext, environment: dict[str, str]) -> str:
    """Start (or reuse) one persistent container per cell.

    The container stays alive across stages so that build-mode installs
    (dependencies, compiled artifacts in the image filesystem) survive into
    the check stage.
    """
    engine = _container_engine()
    name = _container_name(context)
    inspect = subprocess.run(
        [engine, "inspect", "-f", "{{.State.Running}}", name],
        capture_output=True, text=True,
    )
    if inspect.returncode == 0:
        if inspect.stdout.strip() != "true":
            subprocess.run([engine, "start", name], check=True)
        return name

    _ensure_image(context.image)
    command = [engine, "run", "-d", "--name", name]
    mounted: set[str] = set()
    for host in (context.root, context.output_dir, context.work_dir):
        target = str(host)
        if target in mounted:
            continue
        mounted.add(target)
        command += ["-v", f"{target}:{target}"]
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
    return name


def _remove_container(context: CellContext) -> None:
    subprocess.run(
        [_container_engine(), "rm", "-f", _container_name(context)],
        capture_output=True, text=True,
    )


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

    returncode = run_stage(context, args.stage, timeout_minutes)
    print(f"[cell] stage {args.stage} exited with code {returncode}", flush=True)

    if args.stage == "cleanup" and context.os_runtime == "container":
        _remove_container(context)

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