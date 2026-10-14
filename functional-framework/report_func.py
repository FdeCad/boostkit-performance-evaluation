#!/usr/bin/env python3
"""Aggregate functional cell results into a PASS/FAIL matrix report."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any
from xml.etree.ElementTree import Element, SubElement, tostring

STATUS_LABELS = {"passed": "PASS", "failed": "FAIL", "unknown": "?"}


def load_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def atomic_write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def collect_results(input_root: Path) -> list[dict[str, Any]]:
    """Collect one entry per cell, preferring result.json over status.json."""
    results: dict[Path, dict[str, Any]] = {}
    for path in sorted(input_root.rglob("status.json")):
        results[path.parent.resolve()] = {
            "software": None, "status": "unknown", "checks": [],
        }
    for path in sorted(input_root.rglob("result.json")):
        payload = load_json(path)
        if payload:
            results[path.parent.resolve()] = payload
    collected: list[dict[str, Any]] = []
    for directory, payload in results.items():
        if not payload.get("software"):
            status = load_json(directory / "status.json")
            payload = {**payload, **status}
        if payload.get("software"):
            collected.append(payload)
    return collected


def build_matrix(results: list[dict[str, Any]]) -> dict[str, Any]:
    columns = sorted({(r.get("os", "?"), r.get("hardware", "?")) for r in results})
    rows: dict[tuple[str, str], dict[str, Any]] = {}
    for result in results:
        key = (str(result.get("software", "?")), str(result.get("version", "?")))
        row = rows.setdefault(key, {"software": key[0], "version": key[1], "cells": {}})
        column = (str(result.get("os", "?")), str(result.get("hardware", "?")))
        row["cells"][f"{column[0]}|{column[1]}"] = {
            "status": result.get("status", "unknown"),
            "checks": result.get("checks", []),
        }
    return {
        "columns": [{"os": os_name, "hardware": hw} for os_name, hw in columns],
        "rows": [rows[key] for key in sorted(rows)],
        "summary": {
            "total_cells": len(results),
            "passed": sum(1 for r in results if r.get("status") == "passed"),
            "failed": sum(1 for r in results if r.get("status") != "passed"),
        },
    }


def render_markdown(matrix: dict[str, Any]) -> str:
    columns = matrix["columns"]
    summary = matrix["summary"]
    lines = [
        "# 功能测试矩阵",
        "",
        f"- 单元格总数：{summary['total_cells']}",
        f"- 通过：{summary['passed']}",
        f"- 失败：{summary['failed']}",
        "",
    ]
    header = ["软件", "版本", *(f"{c['os']}<br>{c['hardware']}" for c in columns)]
    lines.append("| " + " | ".join(header) + " |")
    lines.append("|" + "---|" * len(header))
    for row in matrix["rows"]:
        cells = row["cells"]
        rendered = []
        for column in columns:
            cell = cells.get(f"{column['os']}|{column['hardware']}")
            status = cell.get("status", "unknown") if cell else "missing"
            rendered.append(STATUS_LABELS.get(status, status.upper()))
        lines.append("| " + " | ".join([row["software"], row["version"], *rendered]) + " |")

    detail = [
        (row["software"], row["version"], column, row["cells"].get(f"{column['os']}|{column['hardware']}"))
        for row in matrix["rows"]
        for column in columns
        if row["cells"].get(f"{column['os']}|{column['hardware']}", {}).get("status") != "passed"
    ]
    if detail:
        lines.extend(["", "## 未通过明细", ""])
        lines.append("| 软件 | 版本 | OS | 硬件 | 检查项 |")
        lines.append("|---|---|---|---|---|")
        for software, version, column, cell in detail:
            checks = cell.get("checks", []) if cell else []
            failing = [c for c in checks if isinstance(c, dict) and c.get("status") != "passed"]
            if failing:
                for check in failing:
                    lines.append(
                        f"| {software} | {version} | {column['os']} | {column['hardware']} | "
                        f"{check.get('name')}: {check.get('detail', '')} |"
                    )
            else:
                status = cell.get("status", "missing") if cell else "missing"
                lines.append(f"| {software} | {version} | {column['os']} | {column['hardware']} | {status} |")
    lines.append("")
    return "\n".join(lines)


def render_junit(results: list[dict[str, Any]]) -> str:
    failures = sum(1 for r in results if r.get("status") != "passed")
    suite = Element(
        "testsuite", name="functional", tests=str(len(results)), failures=str(failures)
    )
    for result in results:
        case = SubElement(
            suite,
            "testcase",
            classname=f"{result.get('category')}.{result.get('software')}",
            name=f"{result.get('version')}.{result.get('os')}.{result.get('hardware')}",
        )
        if result.get("status") != "passed":
            failure = SubElement(case, "failure", message="functional test failed")
            failure.text = str(result.get("status"))
    return tostring(suite, encoding="unicode") + "\n"


def generate(input_root: Path, output_dir: Path) -> dict[str, Any]:
    results = collect_results(input_root)
    matrix = build_matrix(results)
    output_dir.mkdir(parents=True, exist_ok=True)
    atomic_write_json(output_dir / "combined-report.json", matrix)
    (output_dir / "combined-report.md").write_text(render_markdown(matrix), encoding="utf-8")
    (output_dir / "junit.xml").write_text(render_junit(results), encoding="utf-8")
    return matrix["summary"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-root", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    summary = generate(args.input_root, args.output_dir)
    print(json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())