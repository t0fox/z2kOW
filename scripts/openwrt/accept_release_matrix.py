#!/usr/bin/env python3
"""Параллельная приёмка всех OpenWrt-архивов без пропуска ошибок."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import subprocess
import sys
from typing import Callable


ROOT = Path(__file__).resolve().parents[2]
ARCHITECTURES = ("arm64", "arm", "x86_64", "x86", "mips", "mipsel", "riscv64")
Runner = Callable[..., subprocess.CompletedProcess[str]]


def run_matrix(manifest: Path, artifact_dir: Path, *, jobs: int = 4, runner: Runner = subprocess.run) -> int:
    if jobs < 1 or jobs > len(ARCHITECTURES):
        raise ValueError(f"число параллельных проверок должно быть от 1 до {len(ARCHITECTURES)}")
    results: dict[str, tuple[int, str]] = {}

    def check(arch: str) -> tuple[int, str]:
        command = [
            sys.executable,
            str(ROOT / "tests/openwrt/accept_release_candidate.py"),
            str(manifest),
            str(artifact_dir),
            arch,
        ]
        try:
            result = runner(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        except OSError as error:
            return 127, f"не удалось запустить приёмку: {error}\n"
        return result.returncode, result.stdout or ""

    with ThreadPoolExecutor(max_workers=jobs, thread_name_prefix="z2kow-openwrt-accept") as pool:
        futures = {pool.submit(check, arch): arch for arch in ARCHITECTURES}
        for future in as_completed(futures):
            results[futures[future]] = future.result()

    failures = 0
    for arch in ARCHITECTURES:
        return_code, output = results[arch]
        print(f"=== Приёмка {arch} ===")
        if output:
            print(output, end="" if output.endswith("\n") else "\n")
        if return_code:
            failures += 1
            print(f"ОШИБКА: приёмка {arch} завершилась с кодом {return_code}", file=sys.stderr)
    print(f"Итог приёмки OpenWrt: успешно {len(ARCHITECTURES) - failures}/{len(ARCHITECTURES)}")
    return 1 if failures else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("artifact_dir", type=Path)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args(argv)
    try:
        return run_matrix(args.manifest, args.artifact_dir, jobs=args.jobs)
    except (OSError, ValueError) as error:
        print(f"Приёмка OpenWrt: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
