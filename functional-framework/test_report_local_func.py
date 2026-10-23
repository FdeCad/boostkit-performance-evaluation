import json
from pathlib import Path
import tempfile
import unittest

from report_local_func import generate


def cell(os_name, hardware="kunpeng920"):
    return {
        "category": "Middleware", "software": "cloudwego", "version": "0.16.4",
        "os": os_name, "hardware": hardware,
    }


class LocalReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.results = self.root / "results"
        self.report = self.root / "report"
        self.matrix_file = self.root / "matrix.json"

    def write_result(self, entry, run_id, filename, payload):
        directory = self.results.joinpath(
            entry["category"], entry["software"], entry["version"],
            entry["os"], entry["hardware"], run_id,
        )
        directory.mkdir(parents=True, exist_ok=True)
        (directory / filename).write_text(json.dumps(payload), encoding="utf-8")

    def test_compares_only_selected_hardware_and_run(self):
        oe = cell("openeuler-24.03-sp4")
        ubuntu = cell("ubuntu-26.04.1")
        other_hardware = cell("ubuntu-26.04.1", "kunpeng950")
        self.matrix_file.write_text(
            json.dumps({"include": [oe, ubuntu, other_hardware]}), encoding="utf-8"
        )
        self.write_result(oe, "123-1", "functional_result.json", {
            "status": "passed", "checks": [{"name": "kitex-rpc", "status": "passed"}],
        })
        self.write_result(ubuntu, "123-1", "functional_result.json", {
            "status": "failed", "checks": [{"name": "kitex-rpc", "status": "failed"}],
        })
        self.write_result(ubuntu, "old-run", "functional_result.json", {
            "status": "passed", "checks": [],
        })
        summary = generate(self.matrix_file, self.results, "kunpeng920", "123-1", self.report)
        self.assertEqual(summary, {
            "total_cells": 2, "passed": 1, "failed": 1, "missing_or_unknown": 0,
        })
        markdown = (self.report / "comparison.md").read_text(encoding="utf-8")
        self.assertIn("| cloudwego | 0.16.4 | PASS | FAIL |", markdown)
        self.assertIn("| kitex-rpc | PASS | FAIL |", markdown)
        self.assertIn('failures="1"', (self.report / "junit.xml").read_text())

    def test_reports_failed_stage_and_missing_cell(self):
        oe = cell("openeuler-24.03-sp4")
        ubuntu = cell("ubuntu-26.04.1")
        self.matrix_file.write_text(json.dumps({"include": [oe, ubuntu]}), encoding="utf-8")
        self.write_result(oe, "123-1", "status.json", {
            "status": "running", "failed_stage": "install", "exit_code": 30,
        })
        summary = generate(self.matrix_file, self.results, "kunpeng920", "123-1", self.report)
        self.assertEqual(summary, {
            "total_cells": 2, "passed": 0, "failed": 1, "missing_or_unknown": 1,
        })
        statuses = {
            entry["os"]: entry["status"]
            for entry in json.loads((self.report / "comparison.json").read_text())["cells"]
        }
        self.assertEqual(statuses, {
            "openeuler-24.03-sp4": "failed", "ubuntu-26.04.1": "missing",
        })

    def test_cleanup_failure_overrides_successful_functional_check(self):
        oe = cell("openeuler-24.03-sp4")
        self.matrix_file.write_text(json.dumps({"include": [oe]}), encoding="utf-8")
        self.write_result(oe, "123-1", "functional_result.json", {
            "status": "passed", "checks": [],
        })
        self.write_result(oe, "123-1", "status.json", {
            "status": "failed", "failed_stage": "cleanup", "exit_code": 70,
        })
        summary = generate(self.matrix_file, self.results, "kunpeng920", "123-1", self.report)
        self.assertEqual(summary["failed"], 1)

    def test_run_folder_groups_systems_and_report_by_software(self):
        oe = cell("openeuler-24.03-sp4")
        ubuntu = cell("ubuntu-26.04.1")
        other = {**cell("ubuntu-26.04.1"), "software": "x264", "version": "0480cb05"}
        self.matrix_file.write_text(
            json.dumps({"include": [oe, ubuntu, other]}), encoding="utf-8"
        )
        run_folder = "39916799592-1-2026-10-23T07-17-36Z"
        for entry in (oe, ubuntu):
            directory = self.results.joinpath(
                entry["category"], entry["software"], entry["version"],
                run_folder, entry["os"],
            )
            directory.mkdir(parents=True)
            (directory / "functional_result.json").write_text(
                json.dumps({"status": "passed", "checks": []}), encoding="utf-8"
            )
        report = self.results / "Middleware" / "cloudwego" / "0.16.4" / run_folder / "report"
        summary = generate(
            self.matrix_file, self.results, "kunpeng920", "39916799592-1", report,
            run_folder=run_folder, category="Middleware", software="cloudwego", version="0.16.4",
        )
        self.assertEqual(summary, {
            "total_cells": 2, "passed": 2, "failed": 0, "missing_or_unknown": 0,
        })
        self.assertTrue((report / "comparison.md").is_file())
        self.assertEqual(
            {Path(cell_result["result_dir"]).name for cell_result in
             json.loads((report / "comparison.json").read_text())["cells"]},
            {"openeuler-24.03-sp4", "ubuntu-26.04.1"},
        )


if __name__ == "__main__":
    unittest.main()
