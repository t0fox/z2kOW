#!/usr/bin/env python3
"""Проверяет, что параллельная приёмка запускает и агрегирует все ABI."""

from __future__ import annotations

import hashlib
import io
import json
import subprocess
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
import tarfile


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "openwrt"))
from accept_release_matrix import ARCHITECTURES, run_matrix  # noqa: E402

EXPECTED_ARCHITECTURES = ["arm", "arm64", "mips", "mipsel", "riscv64", "x86", "x86_64"]


def create_candidate(root: Path) -> tuple[Path, Path, dict[str, str], str]:
    artifact_dir = root / "artifacts"
    artifact_dir.mkdir()
    manifest_path = root / "UPDATES.json"
    source_sha = "a" * 40
    release_tag = f"openwrt-{source_sha}"
    asset_hashes: dict[str, str] = {}
    records: dict[str, dict[str, object]] = {}

    def write_archive(name: str, payload: bytes) -> Path:
        path = artifact_dir / name
        with tarfile.open(path, "w:gz") as archive:
            info = tarfile.TarInfo("payload.bin")
            info.size = len(payload)
            archive.addfile(info, io.BytesIO(payload))
        asset_hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        return path

    for arch in ARCHITECTURES:
        name = f"openwrt-rootfs-{arch}.tar.gz"
        path = write_archive(name, f"payload-{arch}".encode())
        records[arch] = {
            "filename": name,
            "url": f"https://github.com/t0fox/z2kOW/releases/download/{release_tag}/{name}",
            "sha256": asset_hashes[name],
            "size_bytes": path.stat().st_size,
            "unpacked_size_bytes": len(f"payload-{arch}".encode()),
        }
    legacy_name = "openwrt-rootfs.tar.gz"
    legacy = write_archive(legacy_name, b"legacy-payload")
    manifest = {
        "schema": 1,
        "platform": "openwrt",
        "branch": "main",
        "current": "p-86.18",
        "seq": 142,
        "artifacts": records,
        "artifact": {
            "filename": legacy_name,
            "url": f"https://github.com/t0fox/z2kOW/releases/download/{release_tag}/{legacy_name}",
            "sha256": asset_hashes[legacy_name],
            "size_bytes": legacy.stat().st_size,
        },
    }
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    manifest_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    return manifest_path, artifact_dir, asset_hashes, manifest_hash


def write_architecture_receipt(command: list[str], asset_hashes: dict[str, str], manifest_hash: str) -> None:
    arch = command[4]
    receipt_path = Path(command[command.index("--receipt") + 1])
    receipt_path.write_text(json.dumps({
        "schema": 1,
        "result": "passed",
        "environment": "staged-linux-rootfs",
        "router_verified": False,
        "architecture": arch,
        "tag": "p-86.18",
        "seq": 142,
        "manifest_sha256": manifest_hash,
        "artifact_sha256": asset_hashes[f"openwrt-rootfs-{arch}.tar.gz"],
        "asset_sha256": asset_hashes,
    }), encoding="utf-8")


class ReleaseAcceptanceMatrixTests(unittest.TestCase):
    def test_parallel_acceptance_produces_complete_receipt_without_lost_architectures(self) -> None:
        """Параллельные процессы сохраняют результаты всех семи ABI в общей квитанции."""
        with tempfile.TemporaryDirectory(prefix="z2k-accept-matrix-") as temp_name:
            root = Path(temp_name)
            manifest_path, artifact_dir, asset_hashes, manifest_hash = create_candidate(root)
            first_wave_read = threading.Barrier(len(ARCHITECTURES))

            def execute(command: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
                first_wave_read.wait(timeout=5)
                write_architecture_receipt(command, asset_hashes, manifest_hash)
                return subprocess.CompletedProcess(command, 0, "приёмка пройдена\n", "")

            with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                result = run_matrix(manifest_path, artifact_dir, jobs=len(ARCHITECTURES), runner=execute)

            self.assertEqual(result, 0)
            receipt = json.loads((artifact_dir / "candidate-acceptance.json").read_text(encoding="utf-8"))
            self.assertEqual(receipt["architectures"], EXPECTED_ARCHITECTURES)
            self.assertEqual(receipt["manifest_sha256"], manifest_hash)
            self.assertEqual(receipt["asset_sha256"], asset_hashes)
            self.assertEqual(receipt["artifact_sha256"], asset_hashes["openwrt-rootfs-x86_64.tar.gz"])

    def test_runs_each_architecture_once_and_keeps_success_output(self) -> None:
        with tempfile.TemporaryDirectory(prefix="z2k-accept-matrix-") as temp_name:
            root = Path(temp_name)
            manifest_path, artifact_dir, asset_hashes, manifest_hash = create_candidate(root)
            calls: list[list[str]] = []

            def execute(command: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
                calls.append(command)
                write_architecture_receipt(command, asset_hashes, manifest_hash)
                return subprocess.CompletedProcess(command, 0, "PASS\n", "")

            with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                result = run_matrix(manifest_path, artifact_dir, jobs=3, runner=execute)

            self.assertEqual(result, 0)
            self.assertEqual(len(calls), len(ARCHITECTURES))
            self.assertEqual({command[4] for command in calls}, set(ARCHITECTURES))

    def test_runs_remaining_architectures_and_returns_failure_if_any_case_fails(self) -> None:
        with tempfile.TemporaryDirectory(prefix="z2k-accept-matrix-") as temp_name:
            root = Path(temp_name)
            manifest_path, artifact_dir, _asset_hashes, _manifest_hash = create_candidate(root)
            calls: list[list[str]] = []

            def execute(command: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
                calls.append(command)
                arch = command[4]
                return subprocess.CompletedProcess(command, 1 if arch == "mips" else 0, "fixture failure\n", "")

            with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                result = run_matrix(manifest_path, artifact_dir, jobs=4, runner=execute)

            self.assertEqual(result, 1)
            self.assertEqual(len(calls), len(ARCHITECTURES))
            self.assertFalse((artifact_dir / "candidate-acceptance.json").exists())

    def test_missing_architecture_receipt_fails_closed_and_removes_stale_aggregate(self) -> None:
        with tempfile.TemporaryDirectory(prefix="z2k-accept-matrix-") as temp_name:
            root = Path(temp_name)
            manifest_path, artifact_dir, asset_hashes, manifest_hash = create_candidate(root)
            aggregate_path = artifact_dir / "candidate-acceptance.json"
            aggregate_path.write_text('{"result":"passed","architectures":["x86_64"]}\n', encoding="utf-8")

            def execute(command: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
                arch = command[4]
                if arch != "arm":
                    write_architecture_receipt(command, asset_hashes, manifest_hash)
                return subprocess.CompletedProcess(command, 0, "PASS\n", "")

            with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                result = run_matrix(manifest_path, artifact_dir, jobs=len(ARCHITECTURES), runner=execute)

            self.assertEqual(result, 1)
            self.assertFalse(aggregate_path.exists())


if __name__ == "__main__":
    unittest.main()
