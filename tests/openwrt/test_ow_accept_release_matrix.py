#!/usr/bin/env python3
"""Проверяет, что параллельная приёмка запускает и агрегирует все ABI."""

from __future__ import annotations

import subprocess
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import Mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "openwrt"))
from accept_release_matrix import ARCHITECTURES, run_matrix  # noqa: E402


class ReleaseAcceptanceMatrixTests(unittest.TestCase):
    def test_runs_each_architecture_once_and_keeps_success_output(self) -> None:
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, "PASS\n", ""))

        with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
            result = run_matrix(Path("manifest.json"), Path("artifacts"), jobs=3, runner=runner)

        self.assertEqual(result, 0)
        self.assertEqual(runner.call_count, len(ARCHITECTURES))
        commands = [call.args[0] for call in runner.call_args_list]
        self.assertEqual({command[-1] for command in commands}, set(ARCHITECTURES))

    def test_runs_remaining_architectures_and_returns_failure_if_any_case_fails(self) -> None:
        def execute(command: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
            return subprocess.CompletedProcess(command, 1 if command[-1] == "mips" else 0, "fixture failure\n", "")

        runner = Mock(side_effect=execute)

        with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
            result = run_matrix(Path("manifest.json"), Path("artifacts"), jobs=4, runner=runner)

        self.assertEqual(result, 1)
        self.assertEqual(runner.call_count, len(ARCHITECTURES))


if __name__ == "__main__":
    unittest.main()
