#!/usr/bin/env python3
"""Проверки доверенного переиспользования CI-кандидата OpenWrt."""

from __future__ import annotations

import hashlib
import json
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/openwrt"))

from ci_candidate_fastpath import (  # noqa: E402
    CandidateNotReusable,
    FastPathVerificationError,
    prepare_release_candidate,
    verify_artifact_record,
    verify_ci_run,
    verify_candidate_directory,
    verify_downloaded_archive,
    verify_final_candidate,
    _extract_candidate,
)
from controlled_release import (  # noqa: E402
    ARCHITECTURES,
    attach_architecture_artifacts,
    render_manifest,
    sha256,
    write_manifest,
)


SOURCE_SHA = "0123456789abcdef0123456789abcdef01234567"
KEY_ID = "a" * 64
CI_RUN_ID = 42


def make_baseline() -> dict[str, object]:
    return {
        "schema": 1,
        "branch": "main",
        "platform": "openwrt",
        "seq": 142,
        "current": "p-86.18",
        "upstream": {
            "repository": "necronicle/z2k",
            "branch": "z2k-enhanced",
            "tag": "p-86.18",
            "commit": "b" * 40,
        },
        "history": [{"v": "p-86.18", "type": "patch", "ts": "date", "ref": "r", "desc": "d", "changed_files": []}],
        "signing": {"key_id": KEY_ID},
        "artifact": {
            "filename": "openwrt-rootfs.tar.gz",
            "url": "https://github.com/t0fox/z2kOW/releases/download/openwrt-" + "c" * 40 + "/openwrt-rootfs.tar.gz",
            "sha256": "d" * 64,
            "size_bytes": 1,
        },
    }


class CiCandidateFastPathTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.baseline = make_baseline()
        self.baseline_path = self.root / "UPDATES.json"
        self.baseline_path.write_text(render_manifest(self.baseline), encoding="utf-8")
        self.signature_path = self.root / "UPDATES.json.sig"
        self.signature_path.write_bytes(b"previous signed manifest")
        self.ci_candidate = self.root / "ci-candidate"
        self.ci_candidate.mkdir()
        for arch in ARCHITECTURES:
            self._write_archive(self.ci_candidate / f"openwrt-rootfs-{arch}.tar.gz", arch)
        self._write_archive(self.ci_candidate / "openwrt-rootfs.tar.gz", "legacy")
        manifest = {
            key: value for key, value in self.baseline.items()
            if key not in {"artifact", "artifacts", "signing"}
        }
        attach_architecture_artifacts(manifest, self.ci_candidate, SOURCE_SHA, self.baseline)
        write_manifest(self.ci_candidate / "UPDATES.json", manifest)
        self._write_acceptance_receipts(manifest)

    def tearDown(self) -> None:
        self.temp.cleanup()

    @staticmethod
    def _write_archive(path: Path, content: str) -> None:
        source = path.with_suffix(".payload")
        source.write_text(content, encoding="utf-8")
        with tarfile.open(path, "w:gz") as archive:
            archive.add(source, arcname="payload")
        source.unlink()

    def _write_acceptance_receipts(self, manifest: dict[str, object]) -> None:
        assets = [record["filename"] for record in manifest["artifacts"].values()]
        assets.append(manifest["artifact"]["filename"])
        hashes = {name: sha256(self.ci_candidate / name) for name in assets}
        manifest_bytes = (self.ci_candidate / "UPDATES.json").read_bytes()
        candidate_receipt = {
            "schema": 1,
            "result": "passed",
            "environment": "staged-linux-rootfs",
            "router_verified": False,
            "architectures": sorted(ARCHITECTURES),
            "tag": manifest["current"],
            "seq": manifest["seq"],
            "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
            "artifact_sha256": hashes["openwrt-rootfs-x86_64.tar.gz"],
            "asset_sha256": hashes,
        }
        (self.ci_candidate / "candidate-acceptance.json").write_text(
            json.dumps(candidate_receipt), encoding="utf-8"
        )
        upgrade_receipt = {
            "schema": 1,
            "result": "passed",
            "environment": "previous-published-installer",
            "architecture": "x86_64",
            "previous_tag": self.baseline["current"],
            "previous_seq": self.baseline["seq"],
            "previous_manifest_sha256": sha256(self.baseline_path),
            "previous_signature_sha256": sha256(self.signature_path),
            "candidate_tag": manifest["current"],
            "candidate_seq": manifest["seq"],
            "candidate_manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
            "candidate_archive_sha256": hashes["openwrt-rootfs-x86_64.tar.gz"],
            "candidate_signature_verified_by_previous_engine": False,
            "candidate_test_signature_verified_by_previous_engine": True,
            "scenarios": {
                "legacy_tmpfs_refusal": False,
                "panel_update_default_persistent": True,
                "insufficient_persistent_space": True,
                "rollback_after_service_stop": True,
                "successful_upgrade": True,
                "user_configuration_preserved": True,
                "services_running_after_upgrade": True,
            },
        }
        (self.ci_candidate / "upgrade-acceptance.json").write_text(
            json.dumps(upgrade_receipt), encoding="utf-8"
        )

    def test_accepts_only_a_successful_same_repository_main_push_ci_run(self) -> None:
        run = {
            "id": CI_RUN_ID,
            "event": "push",
            "head_branch": "main",
            "head_sha": SOURCE_SHA,
            "path": ".github/workflows/ci.yml",
            "status": "completed",
            "conclusion": "success",
            "head_repository": {"full_name": "t0fox/z2kOW"},
        }
        jobs = [{"name": "OpenWrt full-payload release", "status": "completed", "conclusion": "success"}]
        self.assertEqual(verify_ci_run(run, jobs, SOURCE_SHA, CI_RUN_ID, "t0fox/z2kOW"), run)
        with self.assertRaises(FastPathVerificationError):
            verify_ci_run({**run, "event": "pull_request"}, jobs, SOURCE_SHA, CI_RUN_ID, "t0fox/z2kOW")
        with self.assertRaises(FastPathVerificationError):
            verify_ci_run(run, [*jobs, {"name": "required job", "status": "completed", "conclusion": "failure"}], SOURCE_SHA, CI_RUN_ID, "t0fox/z2kOW")

    def test_artifact_must_be_from_exact_run_and_have_a_sha256_digest(self) -> None:
        artifact = {
            "id": 7,
            "name": f"z2kow-openwrt-unsigned-{SOURCE_SHA}",
            "expired": False,
            "digest": "sha256:" + "e" * 64,
            "size_in_bytes": 123,
            "workflow_run": {"id": CI_RUN_ID, "head_sha": SOURCE_SHA},
        }
        self.assertEqual(verify_artifact_record(artifact, CI_RUN_ID, SOURCE_SHA), artifact)
        with self.assertRaises(FastPathVerificationError):
            verify_artifact_record({**artifact, "digest": ""}, CI_RUN_ID, SOURCE_SHA)
        with self.assertRaises(FastPathVerificationError):
            verify_artifact_record({**artifact, "workflow_run": {"id": 99, "head_sha": SOURCE_SHA}}, CI_RUN_ID, SOURCE_SHA)

    def test_downloaded_archive_digest_and_safe_extraction_are_required(self) -> None:
        archive_path = self.root / "candidate.zip"
        with zipfile.ZipFile(archive_path, "w") as archive:
            archive.writestr("UPDATES.json", "{}")
        digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
        artifact = {"digest": f"sha256:{digest}", "size_in_bytes": archive_path.stat().st_size}
        verify_downloaded_archive(archive_path, artifact)
        with self.assertRaises(FastPathVerificationError):
            verify_downloaded_archive(archive_path, {**artifact, "digest": "sha256:" + "0" * 64})

        unsafe = self.root / "unsafe.zip"
        with zipfile.ZipFile(unsafe, "w") as archive:
            archive.writestr("../outside", "bad")
        with self.assertRaises(FastPathVerificationError):
            _extract_candidate(unsafe, self.root / "unsafe-output", "candidate")

    def test_candidate_must_match_baseline_version_receipts_and_all_payload_hashes(self) -> None:
        proof = verify_candidate_directory(
            self.ci_candidate,
            self.baseline_path,
            self.signature_path,
            SOURCE_SHA,
            self.baseline["current"],
            self.baseline["seq"],
        )
        self.assertEqual(proof["tag"], "p-86.18")
        self.assertEqual(
            set(proof["assets"]),
            {f"openwrt-rootfs-{arch}.tar.gz" for arch in ARCHITECTURES} | {"openwrt-rootfs.tar.gz"},
        )

        with self.assertRaises(FastPathVerificationError):
            verify_candidate_directory(
                self.ci_candidate,
                self.baseline_path,
                self.root / "missing.sig",
                SOURCE_SHA,
                self.baseline["current"],
                self.baseline["seq"],
            )

    def test_version_or_production_baseline_mismatch_is_not_fast_path_eligible(self) -> None:
        with self.assertRaises(CandidateNotReusable):
            verify_candidate_directory(
                self.ci_candidate,
                self.baseline_path,
                self.signature_path,
                SOURCE_SHA,
                "p-86.19",
                143,
            )

    def test_release_metadata_can_add_only_the_trusted_signing_key(self) -> None:
        output = self.root / "release-candidate"
        with patch("ci_candidate_fastpath._verify_baseline_signature", return_value=KEY_ID):
            prepare_release_candidate(
                self.ci_candidate,
                output,
                self.baseline_path,
                self.signature_path,
                SOURCE_SHA,
                CI_RUN_ID,
                7,
                "sha256:" + "e" * 64,
                123,
                KEY_ID,
            )
            attestation = verify_final_candidate(output, SOURCE_SHA, CI_RUN_ID, KEY_ID)
        self.assertEqual(attestation["release_metadata_delta"], ["signing.key_id"])
        self.assertTrue((output / "ci-candidate-UPDATES.json").is_file())

    def test_corrupted_payload_or_receipt_fails_closed(self) -> None:
        payload = self.ci_candidate / "openwrt-rootfs-mips.tar.gz"
        payload.write_bytes(payload.read_bytes() + b"corrupt")
        with self.assertRaises(FastPathVerificationError):
            verify_candidate_directory(
                self.ci_candidate,
                self.baseline_path,
                self.signature_path,
                SOURCE_SHA,
                self.baseline["current"],
                self.baseline["seq"],
            )


if __name__ == "__main__":
    unittest.main()
