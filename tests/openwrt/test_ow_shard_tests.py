#!/usr/bin/env python3
"""Проверяет детерминированное балансирование OpenWrt acceptance-наборов."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "openwrt"))
from shard_tests import (  # noqa: E402
    choose_shard_count,
    discover_tests,
    estimate_durations,
    lpt_shards,
)


class OpenWrtShardTests(unittest.TestCase):
    def test_lpt_assigns_heaviest_suite_first_and_is_deterministic(self) -> None:
        tests = ["a", "b", "c", "d", "e"]
        durations = {"a": 9.0, "b": 8.0, "c": 7.0, "d": 2.0, "e": 1.0}

        first = lpt_shards(tests, durations, 2)
        second = lpt_shards(tests, durations, 2)

        self.assertEqual(first, second)
        self.assertEqual(first, [["a", "d", "e"], ["b", "c"]])

    def test_every_discovered_test_is_assigned_once_for_supported_shard_counts(self) -> None:
        tests = ["suite-a", "suite-b", "suite-c", "new-suite"]
        durations = {"suite-a": 12.0, "suite-b": 7.0, "suite-c": 3.0, "new-suite": 1.0}

        for count in (4, 6, 8):
            with self.subTest(count=count):
                shards = lpt_shards(tests, durations, count)
                assigned = [item for shard in shards for item in shard]
                self.assertEqual(sorted(assigned), sorted(tests))
                self.assertEqual(len(assigned), len(set(assigned)))
                self.assertEqual(len(shards), count)

    def test_unknown_tests_receive_safe_default_duration(self) -> None:
        configured = {"known": 10.0, "other": 2.0}
        estimates = estimate_durations(["known", "other", "new"], configured, fallback_seconds=1.25)

        self.assertEqual(estimates, {"known": 10.0, "other": 2.0, "new": 1.25})

    def test_discovery_includes_shell_and_python_acceptance_tests(self) -> None:
        found = discover_tests(ROOT)

        self.assertIn("tests/openwrt/test_ow_arch.sh", found)
        self.assertIn("tests/openwrt/test_ow_shard_tests.py", found)

    def test_shard_count_recommendation_uses_measured_runtime_and_cost(self) -> None:
        tests = [f"suite-{index}" for index in range(20)]
        durations = {name: 0.1 for name in tests}
        durations["suite-0"] = 150.0
        durations["suite-1"] = 80.0
        durations["suite-2"] = 60.0
        durations["suite-3"] = 40.0

        count = choose_shard_count(tests, durations, setup_seconds=45.0, runner_minute_penalty=20.0)

        self.assertIn(count, (4, 6, 8))


if __name__ == "__main__":
    unittest.main()
