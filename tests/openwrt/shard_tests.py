#!/usr/bin/env python3
"""Детерминированно делит все OpenWrt acceptance-тесты по LPT-весам."""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Sequence


ROOT = Path(__file__).resolve().parents[2]
TIMINGS = ROOT / "tests/openwrt/test-durations.json"
SHARD_COUNTS = (4, 6, 8)
RUNNER_MINUTE_PENALTY_SECONDS = 20.0


def discover_tests(root: Path = ROOT) -> list[str]:
    """Находит shell- и Python acceptance-наборы без ручного списка."""
    directory = root / "tests/openwrt"
    paths = sorted({*directory.glob("test_ow_*.sh"), *directory.glob("test_ow_*.py")})
    return [path.relative_to(root).as_posix() for path in paths if path.is_file()]


def load_durations(path: Path = TIMINGS) -> tuple[dict[str, float], float, float]:
    """Загружает измеренные времена и одинаковый измеренный job setup overhead."""
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("schema") != 1 or not isinstance(document.get("durations_seconds"), dict):
        raise ValueError(f"неверный формат замеров OpenWrt: {path}")
    durations: dict[str, float] = {}
    for name, raw in document["durations_seconds"].items():
        value = float(raw)
        if not math.isfinite(value) or value <= 0:
            raise ValueError(f"неверное время OpenWrt-набора {name}: {raw}")
        durations[str(name)] = value
    fallback = float(document.get("fallback_seconds", 1.0))
    setup = float(document.get("job_setup_seconds", 45.0))
    if not math.isfinite(fallback) or fallback <= 0 or not math.isfinite(setup) or setup < 0:
        raise ValueError("неверные fallback/setup замеры OpenWrt")
    return durations, fallback, setup


def estimate_durations(
    tests: Sequence[str], configured: dict[str, float], *, fallback_seconds: float
) -> dict[str, float]:
    """Даёт новым тестам измеримый безопасный вес без изменения матрицы вручную."""
    return {name: configured.get(name, fallback_seconds) for name in tests}


def lpt_shards(tests: Sequence[str], durations: dict[str, float], count: int) -> list[list[str]]:
    """Распределяет самые долгие тесты первыми по наименее загруженному shard."""
    if count < 1:
        raise ValueError("число OpenWrt shard должно быть положительным")
    if len(tests) != len(set(tests)):
        raise ValueError("обнаружены повторные пути OpenWrt-тестов")
    missing = sorted(set(tests) - durations.keys())
    if missing:
        raise ValueError(f"для OpenWrt-тестов не рассчитано время: {', '.join(missing)}")
    shards: list[list[str]] = [[] for _ in range(count)]
    loads = [0.0] * count
    ordered = sorted(tests, key=lambda name: (-durations[name], name))
    for name in ordered:
        target = min(range(count), key=lambda index: (loads[index], index))
        shards[target].append(name)
        loads[target] += durations[name]
    assigned = [name for shard in shards for name in shard]
    if len(assigned) != len(tests) or set(assigned) != set(tests):
        raise ValueError("LPT-план потерял или повторно назначил OpenWrt-тест")
    return shards


def _score(
    tests: Sequence[str], durations: dict[str, float], count: int, *, setup_seconds: float,
    runner_minute_penalty: float,
) -> tuple[float, float, float]:
    shards = lpt_shards(tests, durations, count)
    loads = [sum(durations[name] for name in shard) for shard in shards]
    wall_seconds = max(loads, default=0.0) + setup_seconds
    runner_minutes = (sum(loads) + count * setup_seconds) / 60.0
    return wall_seconds + runner_minutes * runner_minute_penalty, wall_seconds, runner_minutes


def choose_shard_count(
    tests: Sequence[str], durations: dict[str, float], *, setup_seconds: float,
    runner_minute_penalty: float = RUNNER_MINUTE_PENALTY_SECONDS,
) -> int:
    """Выбирает 4/6/8 по измеренному wall time с учётом runner-minutes."""
    if not tests:
        raise ValueError("не найдено ни одного OpenWrt acceptance-теста")
    candidates = [
        (_score(tests, durations, count, setup_seconds=setup_seconds,
                runner_minute_penalty=runner_minute_penalty)[0], count)
        for count in SHARD_COUNTS
    ]
    return min(candidates)[1]


def _requires_runtime(root: Path, names: Sequence[str]) -> bool:
    markers = ("Z2K_RT_TARBALL", "Z2K_RUNTIME_ARCHIVE")
    return any(marker in (root / name).read_text(encoding="utf-8") for name in names for marker in markers)


def _plan() -> tuple[list[str], dict[str, float], float, float]:
    tests = discover_tests()
    measured, fallback, setup = load_durations()
    durations = estimate_durations(tests, measured, fallback_seconds=fallback)
    return tests, durations, fallback, setup


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, default=1, help="число shard; по умолчанию полный локальный прогон")
    parser.add_argument("--index", type=int, default=0, help="индекс shard от нуля")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--github-matrix", action="store_true", help="вывести выбранную GitHub Actions matrix")
    output.add_argument("--report", action="store_true", help="сравнить конфигурации из 4, 6 и 8 shard")
    args = parser.parse_args(argv)
    try:
        tests, durations, fallback, setup = _plan()
        selected_count = choose_shard_count(tests, durations, setup_seconds=setup)
        if args.github_matrix:
            assigned = lpt_shards(tests, durations, selected_count)
            shards = [
                {
                    "shard": index,
                    "count": selected_count,
                    "runtime": _requires_runtime(ROOT, shard),
                }
                for index, shard in enumerate(assigned)
            ]
            print(json.dumps({"include": shards}, separators=(",", ":")))
            return 0
        if args.report:
            print("OpenWrt acceptance: оценки LPT по замерам GitHub Actions run 38426630552")
            print(f"критерий выбора: wall time + runner-minutes × {RUNNER_MINUTE_PENALTY_SECONDS:.0f} секунд")
            for count in SHARD_COUNTS:
                score, wall, runner = _score(
                    tests, durations, count, setup_seconds=setup,
                    runner_minute_penalty=RUNNER_MINUTE_PENALTY_SECONDS,
                )
                print(f"{count} shard: predicted_wall={wall:.1f}s runner_minutes={runner:.2f} score={score:.1f}")
            print(f"выбрано: {selected_count} shard; fallback для новых тестов: {fallback:.2f}s")
            return 0
        if args.count < 1 or args.index < 0 or args.index >= args.count:
            raise ValueError("индекс shard должен быть в диапазоне [0, count)")
        shards = lpt_shards(tests, durations, args.count)
        for name in shards[args.index]:
            print(name)
    except (OSError, UnicodeError, json.JSONDecodeError, TypeError, ValueError) as error:
        print(f"план OpenWrt acceptance: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
