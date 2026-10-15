#!/usr/bin/env python3
"""Проверяет объединение проверенных Rust WARP артефактов CI."""

from __future__ import annotations

import hashlib
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "openwrt"))
import warp_controller_artifacts as artifacts  # noqa: E402


SOURCE_SHA = "a" * 40
RUN_ID = "123456789"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_group(root: Path, group: str, *, variants: set[str] | None = None) -> None:
    selected = variants if variants is not None else artifacts.GROUPS[group]
    directory = root / f"z2kow-warp-controller-{SOURCE_SHA}-{group}"
    directory.mkdir(parents=True)
    expected = artifacts.expected(SOURCE_SHA, RUN_ID)
    fields = {
        **expected,
        "stable_rustc": f"rustc {expected['stable_rustc_prefix'].removeprefix('rustc ')}(fixture)",
        "ci_run_id": RUN_ID,
        "matrix_group": group,
        "variants": ",".join(sorted(selected)),
    }
    table = artifacts.targets()
    for variant in sorted(selected):
        target, linker, zig_target, cpu, std = table[variant]
        fields.update({
            f"target_{variant}": target,
            f"linker_{variant}": linker,
            f"zig_target_{variant}": zig_target,
            f"cpu_{variant}": cpu,
            f"std_{variant}": std,
            f"toolchain_{variant}": expected["mips_rust_toolchain"] if std == "build-std" else "1.98.0",
        })
        binary = directory / f"linux-{variant}" / "z2k-warp-controller"
        binary.parent.mkdir()
        data = f"ELF fixture for {variant}\n".encode()
        binary.write_bytes(data)
        binary.chmod(0o755)
        fields[f"binary_sha256_{variant}"] = sha256(data)
    (directory / "PROVENANCE").write_text(
        "".join(f"{key}={value}\n" for key, value in sorted(fields.items())), encoding="utf-8"
    )


class WarpControllerArtifactTests(unittest.TestCase):
    def create_groups(self, root: Path) -> None:
        for group in artifacts.GROUPS:
            write_group(root, group)

    def test_merges_exact_run_and_all_seven_abi_variants(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            groups = root / "groups"
            groups.mkdir()
            self.create_groups(groups)
            output = root / "merged"

            artifacts.merge(groups, output, source_sha=SOURCE_SHA, run_id=RUN_ID)

            metadata = artifacts.verify(output, source_sha=SOURCE_SHA, run_id=RUN_ID)
            self.assertEqual(set(metadata["variants"].split(",")), set(artifacts.targets()))
            self.assertEqual(metadata["artifact_groups"], ",".join(sorted(artifacts.GROUPS)))
            self.assertTrue(all(
                (output / f"linux-{variant}" / "z2k-warp-controller").stat().st_mode & 0o111
                for variant in artifacts.targets()
            ))

    def test_rejects_incomplete_matrix_group(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = root / f"z2kow-warp-controller-{SOURCE_SHA}-zig"
            write_group(root, "zig", variants={"arm64"})

            with self.assertRaisesRegex(ValueError, "варианты не совпадают"):
                artifacts.verify(artifact, source_sha=SOURCE_SHA, run_id=RUN_ID, group="zig")

    def test_rejects_missing_group_instead_of_building_partial_payload(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            groups = root / "groups"
            groups.mkdir()
            for group in artifacts.GROUPS:
                if group != "mipsel":
                    write_group(groups, group)

            with self.assertRaisesRegex(ValueError, "неполон"):
                artifacts.merge(groups, root / "merged", source_sha=SOURCE_SHA, run_id=RUN_ID)

    def test_rejects_artifacts_from_another_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            groups = root / "groups"
            groups.mkdir()
            self.create_groups(groups)
            provenance = groups / f"z2kow-warp-controller-{SOURCE_SHA}-mips" / "PROVENANCE"
            provenance.write_text(
                provenance.read_text(encoding="utf-8").replace(f"ci_run_id={RUN_ID}", "ci_run_id=987654321"),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "Actions run ID"):
                artifacts.merge(groups, root / "merged", source_sha=SOURCE_SHA, run_id=RUN_ID)


if __name__ == "__main__":
    unittest.main()
