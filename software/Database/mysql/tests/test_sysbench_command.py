"""Keep the private Sysbench binary paired with its own Lua workloads."""

import os
import subprocess
from pathlib import Path


def test_run_sysbench_uses_private_lua_workload(tmp_path: Path) -> None:
    script = Path(__file__).resolve().parents[1] / "mysql_test.sh"
    fake_sysbench = tmp_path / "sysbench"
    fake_sysbench.write_text(
        '#!/bin/sh\nprintf "LUA_PATH=%s\\n" "$LUA_PATH"\n'
        'printf "ARG=%s\\n" "$@"\n',
        encoding="utf-8",
    )
    fake_sysbench.chmod(0o755)
    lua_directory = tmp_path / "src" / "lua"
    results = tmp_path / "results"
    environment = os.environ | {
        "TEST_SCRIPT": str(script),
        "TEST_BIN": str(fake_sysbench),
        "TEST_LUA_DIR": str(lua_directory),
        "TEST_RESULTS_DIR": str(results),
    }
    completed = subprocess.run(
        [
            "bash", "-c",
            'source "$TEST_SCRIPT"; SYSBENCH_BIN="$TEST_BIN"; '
            'SYSBENCH_LUA_DIR="$TEST_LUA_DIR"; RESULTS_DIR="$TEST_RESULTS_DIR"; '
            'mkdir -p "$RESULTS_DIR/sysbench-runs"; '
            'run_sysbench read_write 2 0 prepare',
        ],
        env=environment,
        capture_output=True,
        text=True,
        check=True,
    )
    assert f"LUA_PATH={lua_directory}/?.lua;;" in completed.stdout
    assert f"ARG={lua_directory}/oltp_read_write.lua" in completed.stdout
    assert "ARG=prepare" in completed.stdout
    assert "ARG=--table_size=10000000" in completed.stdout
    assert "ARG=--tables=64" in completed.stdout
