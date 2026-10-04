#!/usr/bin/env python3
"""Regression tests for exact-source release CI verification."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/openwrt"))

from verify_source_ci import VerificationError, select_successful_run  # noqa: E402


SOURCE_SHA = "0123456789abcdef0123456789abcdef01234567"


def run(**overrides: object) -> dict:
    result: dict = {
        "id": 42,
        "head_sha": SOURCE_SHA,
        "event": "push",
        "head_branch": "main",
        "path": ".github/workflows/ci.yml",
        "status": "completed",
        "conclusion": "success",
        "created_at": "2026-10-04T12:00:00Z",
        "html_url": "https://github.com/t0fox/z2kOW/actions/runs/42",
    }
    result.update(overrides)
    return result


class VerifySourceCiTests(unittest.TestCase):
    def test_accepts_success_only_for_exact_main_push_ci(self) -> None:
        selected = select_successful_run([
            run(id=1, head_sha="f" * 40),
            run(id=2, event="workflow_dispatch"),
            run(id=3, head_branch="feature"),
            run(id=4, path=".github/workflows/other.yml"),
            run(id=5, conclusion="failure"),
            run(id=6),
        ], SOURCE_SHA)
        self.assertEqual(selected["id"], 6)

    def test_failed_or_in_progress_exact_run_is_not_success(self) -> None:
        with self.assertRaisesRegex(VerificationError, "No successful normal push CI run"):
            select_successful_run([
                run(id=7, conclusion="failure"),
                run(id=8, status="in_progress", conclusion=None),
            ], SOURCE_SHA)

    def test_missing_exact_sha_run_has_actionable_error(self) -> None:
        with self.assertRaisesRegex(VerificationError, "Push this SHA to main"):
            select_successful_run([run(head_sha="f" * 40)], SOURCE_SHA)


if __name__ == "__main__":
    unittest.main()
