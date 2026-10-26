#!/usr/bin/env python3
"""Проверяет provenance Go ELF и безопасную передачу в OpenWrt rootfs."""

from __future__ import annotations

import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "openwrt"))
from go_build_artifacts import (  # noqa: E402
    ELF_ABI,
    MODULES,
    _matrix,
    attest,
    stage_openwrt,
    verify,
)


SOURCE_SHA = "a" * 40
RUN_ID = "123456789"
GO_VERSION = "go version go1.25.13 linux/amd64"
RELEASE_TAG = "r-87"


def fake_elf(goarch: str) -> bytes:
    elf_class, endian, machine = ELF_ABI[goarch]
    header = bytearray(20)
    header[:4] = b"\x7fELF"
    header[4] = elf_class
    header[5] = endian
    header[6] = 1
    header[18:20] = struct.pack("<H" if endian == 1 else ">H", machine)
    return bytes(header)


class GoBuildArtifactsTests(unittest.TestCase):
    def create_artifact(self, root: Path, module: str) -> Path:
        directory = root / f"z2kow-go-{SOURCE_SHA}-{module}"
        directory.mkdir(parents=True)
        for row in _matrix()[module]:
            (directory / row["filename"]).write_bytes(fake_elf(row["goarch"]))
        attest(directory, module=module, source_sha=SOURCE_SHA, run_id=RUN_ID,
               go_version=GO_VERSION, release_tag=RELEASE_TAG)
        return directory

    def test_verifies_source_run_toolchain_matrix_flags_abi_and_payload_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = self.create_artifact(Path(temporary), "rt-proxy")

            verify(directory, module="rt-proxy", source_sha=SOURCE_SHA, run_id=RUN_ID,
                   go_version=GO_VERSION, release_tag=RELEASE_TAG)

            provenance = json.loads((directory / "PROVENANCE.json").read_text(encoding="utf-8"))
            self.assertEqual(provenance["source_sha"], SOURCE_SHA)
            self.assertEqual(provenance["run_id"], RUN_ID)
            self.assertEqual(set(provenance["builds"]), {row["filename"] for row in _matrix()["rt-proxy"]})

    def test_rejects_source_run_version_or_release_tag_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = self.create_artifact(Path(temporary), "z2k-warpd")
            with self.assertRaisesRegex(ValueError, "source SHA"):
                verify(directory, module="z2k-warpd", source_sha="b" * 40, run_id=RUN_ID,
                       go_version=GO_VERSION, release_tag=RELEASE_TAG)
            with self.assertRaisesRegex(ValueError, "run ID"):
                verify(directory, module="z2k-warpd", source_sha=SOURCE_SHA, run_id="987654321",
                       go_version=GO_VERSION, release_tag=RELEASE_TAG)
            with self.assertRaisesRegex(ValueError, "release tag"):
                verify(directory, module="z2k-warpd", source_sha=SOURCE_SHA, run_id=RUN_ID,
                       go_version=GO_VERSION, release_tag="p-86.19")

    def test_rejects_payload_tampering_and_wrong_elf_abi(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = self.create_artifact(Path(temporary), "z2k-detect")
            binary = directory / _matrix()["z2k-detect"][0]["filename"]
            binary.write_bytes(b"modified")
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                verify(directory, module="z2k-detect", source_sha=SOURCE_SHA, run_id=RUN_ID,
                       go_version=GO_VERSION, release_tag=RELEASE_TAG)

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "bad-abi"
            directory.mkdir()
            row = _matrix()["rt-proxy"][0]
            other_arch = "386" if row["goarch"] != "386" else "amd64"
            (directory / row["filename"]).write_bytes(fake_elf(other_arch))
            with self.assertRaisesRegex(ValueError, "неверный ELF ABI"):
                attest(directory, module="rt-proxy", source_sha=SOURCE_SHA, run_id=RUN_ID,
                       go_version=GO_VERSION, release_tag=RELEASE_TAG)

    def test_stages_verified_artifacts_into_all_seven_rootfs_architectures(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact_root = root / "artifacts"
            artifact_root.mkdir()
            for module in MODULES:
                self.create_artifact(artifact_root, module)
            output = root / "staged"

            stage_openwrt(artifact_root, output, source_sha=SOURCE_SHA, run_id=RUN_ID,
                          go_version=GO_VERSION, release_tag=RELEASE_TAG)

            for module, binary in (("rt-proxy", "z2k-rt-proxy"),
                                   ("z2k-detect", "z2k-detect"),
                                   ("z2k-warpd", "z2k-warpd")):
                self.assertEqual(len(list((output / module).glob("linux-*"))), 7)
                for path in (output / module).glob("linux-*"):
                    self.assertEqual((path / binary).read_bytes()[:4], b"\x7fELF")


if __name__ == "__main__":
    unittest.main()
