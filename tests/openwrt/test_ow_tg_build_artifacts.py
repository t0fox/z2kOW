#!/usr/bin/env python3
"""Проверка объединения проверенных Rust TG артефактов CI."""

from __future__ import annotations

import hashlib
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "openwrt"))
from tg_build_artifacts import (  # noqa: E402
    GROUP_VARIANTS,
    _channel,
    _expected_globals,
    _script_pins,
    merge_artifacts,
    verify_merged,
)


SOURCE_SHA = "a" * 40
RUN_ID = "123456789"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def target_rows() -> dict[str, tuple[str, str, str, str, str, str]]:
    rows: dict[str, tuple[str, str, str, str, str, str]] = {}
    table = ROOT / "platform/openwrt/tg-rust-targets.tsv"
    for line in table.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if not fields or fields[0].startswith("#"):
            continue
        _pattern, _family, variant, target, abi, linker, _zig, cpu, std, flags = fields
        rows[variant] = (target, abi, linker, cpu, std, flags)
    return rows


def write_group(root: Path, group: str, *, source_sha: str = SOURCE_SHA, corrupt: bool = False) -> None:
    rows = target_rows()
    artifact = root / f"z2kow-tg-rust-{SOURCE_SHA}-{group}"
    artifact.mkdir(parents=True)
    license_data = (ROOT / "platform/openwrt/tg-proxy/LICENSE").read_bytes()
    (artifact / "LICENSE").write_bytes(license_data)
    binaries: dict[str, bytes] = {}
    for variant in sorted(GROUP_VARIANTS[group]):
        data = f"ELF fixture for {variant}\n".encode()
        binaries[variant] = data
        binary = artifact / f"linux-{variant}" / "tg-ws-proxy"
        binary.parent.mkdir()
        binary.write_bytes(data)

    fields = {
        **_expected_globals(source_sha),
        "ci_run_id": RUN_ID,
        "matrix_group": group,
        "crate": "platform/openwrt/tg-proxy",
        "binary": "tg-ws-proxy",
        "upstream": "valnesfjord/tg-ws-proxy-rs@53c8bfe5e9efa561cf61a862c0371f1f8ba33869",
        "license": "MIT",
        "target_table": "platform/openwrt/tg-rust-targets.tsv",
        "stable_rustc": f"rustc {_channel()} (fixture)",
        "mips_rust_toolchain": _script_pins()["_mips_toolchain"],
        "release_profile": "strip=symbols,lto=true,codegen-units=1,panic=target-dependent",
        "variants": ",".join(sorted(GROUP_VARIANTS[group])),
    }
    for variant, data in binaries.items():
        target, abi, linker, cpu, std, flags = rows[variant]
        fields.update({
            f"target_{variant}": target,
            f"abi_{variant}": abi,
            f"linker_{variant}": linker,
            f"cpu_{variant}": cpu,
            f"std_{variant}": std,
            f"flags_{variant}": flags,
            f"toolchain_{variant}": "nightly-2026-07-21" if std == "build-std" else "1.98.0",
            f"rustc_{variant}": (
                "rustc 1.99.0-nightly (abcdef0 2026-07-21)"
                if std == "build-std" else "rustc 1.98.0 (fixture)"
            ),
            f"binary_sha256_{variant}": "0" * 64 if corrupt else sha256(data),
        })
    (artifact / "PROVENANCE").write_text(
        "".join(f"{key}={value}\n" for key, value in sorted(fields.items())), encoding="utf-8"
    )


class TGArtifactMergeTests(unittest.TestCase):
    def create_groups(self, root: Path, **options: object) -> None:
        for group in GROUP_VARIANTS:
            write_group(root, group, **options)

    def test_merges_all_groups_and_verifies_exact_source_run_and_binary_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            groups = root / "groups"
            groups.mkdir()
            self.create_groups(groups)
            output = root / "merged"

            merge_artifacts(groups, output, source_sha=SOURCE_SHA, run_id=RUN_ID)

            verify_merged(output, source_sha=SOURCE_SHA, run_id=RUN_ID)
            self.assertEqual(
                {path.name.removeprefix("linux-") for path in output.glob("linux-*")},
                set(target_rows()),
            )
            self.assertTrue(all((output / f"linux-{name}" / "tg-ws-proxy").stat().st_mode & 0o111
                                for name in target_rows()))

    def test_rejects_artifact_for_another_source_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            groups = root / "groups"
            groups.mkdir()
            self.create_groups(groups)
            artifact = groups / f"z2kow-tg-rust-{SOURCE_SHA}-arm"
            provenance = artifact / "PROVENANCE"
            provenance.write_text(provenance.read_text().replace(SOURCE_SHA, "b" * 40), encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "source SHA"):
                merge_artifacts(groups, root / "merged", source_sha=SOURCE_SHA, run_id=RUN_ID)

    def test_rejects_binary_checksum_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            groups = root / "groups"
            groups.mkdir()
            self.create_groups(groups, corrupt=True)

            with self.assertRaisesRegex(ValueError, "SHA-256"):
                merge_artifacts(groups, root / "merged", source_sha=SOURCE_SHA, run_id=RUN_ID)

    def test_rejects_groups_from_a_different_ci_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            groups = root / "groups"
            groups.mkdir()
            self.create_groups(groups)
            provenance = groups / f"z2kow-tg-rust-{SOURCE_SHA}-mips" / "PROVENANCE"
            provenance.write_text(
                provenance.read_text(encoding="utf-8").replace(f"ci_run_id={RUN_ID}", "ci_run_id=987654321"),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "Actions run ID"):
                merge_artifacts(groups, root / "merged", source_sha=SOURCE_SHA, run_id=RUN_ID)

    def test_accepts_a_complete_local_build_without_a_github_run_id(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            groups = root / "groups"
            groups.mkdir()
            self.create_groups(groups)
            output = root / "merged"
            merge_artifacts(groups, output, source_sha=SOURCE_SHA, run_id=RUN_ID)
            provenance = output / "PROVENANCE"
            provenance.write_text(
                provenance.read_text(encoding="utf-8").replace(f"ci_run_id={RUN_ID}", "ci_run_id=0"),
                encoding="utf-8",
            )

            verify_merged(output, source_sha=SOURCE_SHA)

    def test_rejects_missing_group_instead_of_publishing_partial_architecture_set(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            groups = root / "groups"
            groups.mkdir()
            for group in GROUP_VARIANTS:
                if group != "mipsel":
                    write_group(groups, group)

            with self.assertRaisesRegex(ValueError, "неполный набор групп"):
                merge_artifacts(groups, root / "merged", source_sha=SOURCE_SHA, run_id=RUN_ID)


if __name__ == "__main__":
    unittest.main()
