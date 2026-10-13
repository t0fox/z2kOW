#!/usr/bin/env python3
"""Параллельная приёмка всех OpenWrt-архивов без пропуска ошибок."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Callable

from controlled_release import ARCHIVE_NAME_TEMPLATE, ARCHITECTURES, validate_architecture_assets


ROOT = Path(__file__).resolve().parents[2]
Runner = Callable[..., subprocess.CompletedProcess[str]]


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _aggregate_receipts(manifest_path: Path, artifact_dir: Path, receipt_dir: Path) -> dict[str, object]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("кандидат UPDATES.json должен содержать объект")
    tag = manifest.get("current")
    seq = manifest.get("seq")
    if not isinstance(tag, str) or not tag or not isinstance(seq, int) or isinstance(seq, bool) or seq < 1:
        raise ValueError("версия кандидата отсутствует или некорректна")

    asset_names = validate_architecture_assets(manifest, artifact_dir)
    asset_hashes = {name: _sha256_file(artifact_dir / name) for name in asset_names}
    manifest_hash = _sha256_file(manifest_path)

    for arch in ARCHITECTURES:
        receipt_path = receipt_dir / f"{arch}.json"
        try:
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ValueError(f"для {arch} отсутствует отдельная валидная квитанция") from error
        expected = {
            "schema": 1,
            "result": "passed",
            "environment": "staged-linux-rootfs",
            "router_verified": False,
            "architecture": arch,
            "tag": tag,
            "seq": seq,
            "manifest_sha256": manifest_hash,
            "artifact_sha256": asset_hashes[ARCHIVE_NAME_TEMPLATE.format(arch=arch)],
            "asset_sha256": asset_hashes,
        }
        if receipt != expected:
            raise ValueError(f"квитанция {arch} не подтверждает точный manifest и payload")

    return {
        "schema": 1,
        "result": "passed",
        "environment": "staged-linux-rootfs",
        "router_verified": False,
        "architectures": sorted(ARCHITECTURES),
        "tag": tag,
        "seq": seq,
        "manifest_sha256": manifest_hash,
        "artifact_sha256": asset_hashes[ARCHIVE_NAME_TEMPLATE.format(arch="x86_64")],
        "asset_sha256": asset_hashes,
    }


def _write_json_atomic(path: Path, value: dict[str, object]) -> None:
    temp_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent,
            prefix=f".{path.name}.", suffix=".tmp", delete=False,
        ) as stream:
            temp_path = Path(stream.name)
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_path, path)
    finally:
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)


def run_matrix(manifest: Path, artifact_dir: Path, *, jobs: int = 4, runner: Runner = subprocess.run) -> int:
    if jobs < 1 or jobs > len(ARCHITECTURES):
        raise ValueError(f"число параллельных проверок должно быть от 1 до {len(ARCHITECTURES)}")
    results: dict[str, tuple[int, str]] = {}
    aggregate_path = artifact_dir / "candidate-acceptance.json"
    aggregate_path.unlink(missing_ok=True)

    with tempfile.TemporaryDirectory(prefix="z2kow-openwrt-accept-matrix-") as receipt_name:
        receipt_dir = Path(receipt_name)

        def check(arch: str) -> tuple[int, str]:
            command = [
                sys.executable,
                str(ROOT / "tests/openwrt/accept_release_candidate.py"),
                str(manifest),
                str(artifact_dir),
                arch,
                "--receipt",
                str(receipt_dir / f"{arch}.json"),
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
        if failures:
            return 1

        try:
            receipt = _aggregate_receipts(manifest, artifact_dir, receipt_dir)
            _write_json_atomic(aggregate_path, receipt)
        except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
            print(f"ОШИБКА: не удалось собрать общую квитанцию CI: {error}", file=sys.stderr)
            return 1
    return 0


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
