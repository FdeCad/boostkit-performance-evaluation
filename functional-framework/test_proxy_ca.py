import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from run_func_case import (
    PROXY_CA_BOOTSTRAP, PROXY_CA_MOUNT, _ensure_container, _install_proxy_ca,
    _proxy_ca_source,
)


class ProxyCATests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.anchors = self.root / "anchors"
        self.anchors.mkdir()

    def test_rejects_missing_certificates_for_proxied_cell(self):
        with patch.dict(os.environ, {
            "FUNC_PROXY_CA_DIR": str(self.anchors), "PERF_PROXY": "http://proxy:3128",
        }, clear=True):
            with self.assertRaisesRegex(RuntimeError, "contains no"):
                _proxy_ca_source()

    def test_accepts_certificate_in_nested_directory(self):
        nested = self.anchors / "department"
        nested.mkdir()
        (nested / "regional.pem").write_text("certificate fixture")
        with patch.dict(os.environ, {
            "FUNC_PROXY_CA_DIR": str(self.anchors), "PERF_PROXY": "http://proxy:3128",
        }, clear=True):
            self.assertEqual(_proxy_ca_source(), self.anchors)

    def test_mounts_anchors_read_only_before_running_stage(self):
        (self.anchors / "proxy-ca.crt").write_text("certificate fixture")
        context = SimpleNamespace(
            root=self.root, output_dir=self.root / "results", work_dir=self.root / "work",
            case_dir=self.root, image="ubuntu:26.04", run_id="123-1",
            operating_system="ubuntu-26.04.1", hardware="kunpeng950",
        )
        with patch.dict(os.environ, {
            "FUNC_PROXY_CA_DIR": str(self.anchors), "PERF_PROXY": "http://proxy:3128",
        }, clear=True), patch("run_func_case._container_status", return_value=""), \
            patch("run_func_case._ensure_image"), \
            patch("run_func_case._wait_until_running") as wait, \
            patch("run_func_case._install_proxy_ca") as install, \
            patch("run_func_case.subprocess.run") as run:
            run.return_value.returncode = 0
            _ensure_container(context, {"http_proxy": "http://proxy:3128"})
            command = run.call_args.args[0]
            self.assertIn("--mount", command)
            self.assertIn(
                f"type=bind,src={self.anchors},dst={PROXY_CA_MOUNT},readonly", command
            )
            wait.assert_called_once()
            install.assert_called_once_with(
                "docker", "boostkit-func-123-1-ubuntu-26.04.1-kunpeng950",
                {"http_proxy": "http://proxy:3128"}, "ubuntu-26.04.1",
            )

    def test_bootstrap_copies_entire_anchor_tree_without_parsing(self):
        certificate = self.anchors / "HuaweiITMiniRootCA.pem"
        certificate.write_bytes(
            b"Bag Attributes\r\n-----BEGIN CERTIFICATE-----\r\n"
            b"certificate-content\r\n-----END CERTIFICATE-----\r\n"
        )
        nested = self.anchors / "department"
        nested.mkdir()
        (nested / "regional.pem").write_bytes(b"regional-certificate\n")
        (nested / "README").write_bytes(b"anchor notes\n")
        (self.anchors / ".hidden.crt").write_bytes(b"hidden-certificate\n")
        tool_dir = self.root / "bin"
        tool_dir.mkdir()
        for family, anchor_path, system_path, updater in (
            ("ubuntu", "/usr/local/share/ca-certificates",
             "/etc/ssl/certs/ca-certificates.crt", "update-ca-certificates"),
            ("openeuler", "/etc/pki/ca-trust/source/anchors",
             "/etc/pki/tls/certs/ca-bundle.crt", "update-ca-trust"),
        ):
            with self.subTest(family=family):
                target = self.root / f"container-anchors-{family}"
                marker = self.root / f"ready-{family}"
                system_bundle = self.root / f"system-bundle-{family}.crt"
                system_bundle.write_bytes(b"existing-root\n")
                update = tool_dir / updater
                update.write_text("#!/bin/sh\nexit 0\n")
                update.chmod(0o755)
                script = (
                    PROXY_CA_BOOTSTRAP
                    .replace(PROXY_CA_MOUNT, str(self.anchors))
                    .replace(anchor_path, str(target))
                    .replace(system_path, str(system_bundle))
                    .replace("/tmp/boostkit-proxy-bootstrap-ca.crt",
                             str(self.root / f"bootstrap-{family}.crt"))
                    .replace("/tmp/boostkit-proxy-ca-ready", str(marker))
                )
                result = subprocess.run(
                    ["sh", "-ec", script, "sh", family], capture_output=True, text=True,
                    env={**os.environ, "PATH": f"{tool_dir}:{os.environ['PATH']}"},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(marker.is_file())
                original_files = {
                    item.relative_to(self.anchors): item.read_bytes()
                    for item in self.anchors.rglob("*") if item.is_file()
                }
                copied_files = {
                    item.relative_to(target): item.read_bytes()
                    for item in target.rglob("*") if item.is_file()
                }
                self.assertEqual(copied_files, original_files)
                if family == "ubuntu":
                    self.assertTrue(system_bundle.read_bytes().startswith(b"existing-root\n"))
                    self.assertIn(certificate.read_bytes(), system_bundle.read_bytes())
                    self.assertIn((nested / "regional.pem").read_bytes(), system_bundle.read_bytes())

    def test_ca_setup_passes_proxy_to_container_exec(self):
        with patch("run_func_case.subprocess.run") as run:
            run.return_value.returncode = 0
            _install_proxy_ca(
                "docker", "test-container", {"https_proxy": "http://proxy:3128"},
                "openeuler-24.03-sp4",
            )
            command = run.call_args.args[0]
            self.assertEqual(command[:5], [
                "docker", "exec", "-e", "https_proxy=http://proxy:3128", "test-container",
            ])
            self.assertEqual(command[-1], "openeuler")


if __name__ == "__main__":
    unittest.main()
