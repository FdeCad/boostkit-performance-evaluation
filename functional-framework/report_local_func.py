#!/usr/bin/env python3
"""Compare this run's functional results on one self-hosted runner."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from report_func import atomic_write_json, load_json, render_junit

LABELS = {"passed": "PASS", "failed": "FAIL", "missing": "MISSING", "unknown": "UNKNOWN"}


def safe_part(value: str) -> str:
    if not value or value in {".", ".."} or "/" in value or "\\" in value:
        raise ValueError(f"unsafe result path component: {value!r}")
    return value


def read_cell(
    cell: dict[str, Any], output_root: Path, run_id: str, run_folder: str | None = None
) -> dict[str, Any]:
    parts = [safe_part(str(cell[key])) for key in (
        "category", "software", "version", "os", "hardware"
    )]
    if run_folder is None:
        directory = output_root.joinpath(*parts, safe_part(run_id))
    else:
        directory = output_root.joinpath(*parts[:3], safe_part(run_folder), parts[3])
    functional = load_json(directory / "functional_result.json")
    result = load_json(directory / "result.json")
    stage = load_json(directory / "status.json")
    status = functional.get("status") or result.get("status")
    if stage.get("failed_stage") or stage.get("exit_code") not in {None, 0}:
        status = "failed"
    elif status not in {"passed", "failed"}:
        if stage.get("status") in {"passed", "failed"}:
            status = stage["status"]
        else:
            status = "unknown" if directory.is_dir() else "missing"
    checks = functional.get("checks") or result.get("checks") or []
    return {
        "category": parts[0], "software": parts[1], "version": parts[2],
        "os": parts[3], "hardware": parts[4], "run_id": run_id,
        "status": status, "checks": checks if isinstance(checks, list) else [],
        "result_dir": str(directory),
    }


def render_markdown(cells: list[dict[str, Any]], hardware: str, run_id: str) -> str:
    os_names = list(dict.fromkeys(cell["os"] for cell in cells))
    groups: dict[tuple[str, str, str], dict[str, dict[str, Any]]] = {}
    for cell in cells:
        key = (cell["category"], cell["software"], cell["version"])
        groups.setdefault(key, {})[cell["os"]] = cell

    lines = [
        "# 本机功能测试 OS 对比", "",
        f"- 硬件：`{hardware}`",
        f"- 运行 ID：`{run_id}`",
        f"- 预期单元：{len(cells)}",
        f"- 通过：{sum(cell['status'] == 'passed' for cell in cells)}",
        f"- 失败：{sum(cell['status'] == 'failed' for cell in cells)}",
        f"- 缺失或未完成：{sum(cell['status'] in {'missing', 'unknown'} for cell in cells)}",
        "",
        "| 类别 | 软件 | 版本 | " + " | ".join(os_names) + " |",
        "| --- | --- | --- | " + " | ".join("---" for _ in os_names) + " |",
    ]
    for key, by_os in sorted(groups.items()):
        values = [LABELS[by_os[os_name]["status"]] if os_name in by_os else "—"
                  for os_name in os_names]
        lines.append("| " + " | ".join((*key, *values)) + " |")

    for key, by_os in sorted(groups.items()):
        check_names = sorted({
            check.get("name") for cell in by_os.values() for check in cell["checks"]
            if isinstance(check, dict) and isinstance(check.get("name"), str)
        })
        if not check_names:
            continue
        lines.extend([
            "", f"## {key[1]} {key[2]}：检查项对比", "",
            "| 检查项 | " + " | ".join(os_names) + " |",
            "| --- | " + " | ".join("---" for _ in os_names) + " |",
        ])
        for name in check_names:
            values = []
            for os_name in os_names:
                cell = by_os.get(os_name)
                if cell is None:
                    values.append("—")
                    continue
                check = next((item for item in cell["checks"]
                              if isinstance(item, dict) and item.get("name") == name), None)
                values.append(LABELS.get(check.get("status"), "UNKNOWN") if check else "—")
            lines.append("| " + " | ".join((name, *values)) + " |")

    lines.extend(["", "每项原始日志与 JSON 位于对应单元的结果目录。", ""])
    return "\n".join(lines)


def generate(
    matrix_file: Path, output_root: Path, hardware: str, run_id: str, output_dir: Path,
    run_folder: str | None = None, category: str | None = None,
    software: str | None = None, version: str | None = None,
) -> dict[str, Any]:
    if not output_root.is_absolute() or not output_dir.is_absolute():
        raise ValueError("output paths must be absolute")
    matrix = json.loads(matrix_file.read_text(encoding="utf-8"))
    expected = [
        cell for cell in matrix["include"]
        if cell["hardware"] == hardware
        and (category is None or cell["category"] == category)
        and (software is None or cell["software"] == software)
        and (version is None or cell["version"] == version)
    ]
    if not expected:
        raise ValueError(f"hardware {hardware!r} is absent from the run matrix")
    cells = [read_cell(cell, output_root, run_id, run_folder) for cell in expected]
    summary = {
        "total_cells": len(cells),
        "passed": sum(cell["status"] == "passed" for cell in cells),
        "failed": sum(cell["status"] == "failed" for cell in cells),
        "missing_or_unknown": sum(cell["status"] in {"missing", "unknown"} for cell in cells),
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    atomic_write_json(output_dir / "comparison.json", {
        "hardware": hardware, "run_id": run_id, "summary": summary, "cells": cells,
    })
    (output_dir / "comparison.md").write_text(
        render_markdown(cells, hardware, run_id), encoding="utf-8"
    )
    (output_dir / "junit.xml").write_text(render_junit(cells), encoding="utf-8")
    return summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix-file", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--hardware", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--run-folder")
    parser.add_argument("--category")
    parser.add_argument("--software")
    parser.add_argument("--version")
    args = parser.parse_args()
    summary = generate(
        args.matrix_file, args.output_root, args.hardware, args.run_id, args.output_dir,
        args.run_folder, args.category, args.software, args.version,
    )
    print(json.dumps(summary, ensure_ascii=False))
    print(f"Local OS comparison: {args.output_dir / 'comparison.md'}")
    return 1 if summary["missing_or_unknown"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
