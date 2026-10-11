#!/usr/bin/env python3
"""Проверяет, что квитанции приёмки обновления связаны с подписанными данными."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "scripts/openwrt/verify_upgrade_acceptance.py"
ACCEPTANCE = ROOT / "tests/openwrt/accept_release_upgrade.py"

SPEC = importlib.util.spec_from_file_location("accept_release_upgrade", ACCEPTANCE)
assert SPEC is not None and SPEC.loader is not None
ACCEPTANCE_MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ACCEPTANCE_MODULE)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class UpgradeAcceptanceVerifierTests(unittest.TestCase):
    def test_tmpfs_default_requires_transition_even_with_architecture_selector(self) -> None:
        previous_release = "z2k_ow_manifest_select_artifact() { :; }\n"
        tmpfs_paths = 'Z2K_OW_INSTALL_TMP="${Z2K_OW_INSTALL_TMP:-/tmp/z2kow-install-stage}"\n'
        self.assertIn("z2k_ow_manifest_select_artifact", previous_release)
        self.assertTrue(ACCEPTANCE_MODULE.previous_uses_tmpfs_install_staging(tmpfs_paths))

    def test_accepts_exact_signed_baseline_and_candidate_receipt(self) -> None:
        with tempfile.TemporaryDirectory(prefix="z2k-upgrade-receipt-") as temp:
            root = Path(temp)
            private, public = root / "private.pem", root / "public.pem"
            subprocess.run(["openssl", "genpkey", "-algorithm", "Ed25519", "-out", str(private)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            public_der = subprocess.run(["openssl", "pkey", "-pubin", "-in", str(public), "-outform", "DER"],
                                        check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
            previous_archive = root / "previous.tar.gz"
            previous_archive.write_bytes(b"previous signed archive")
            candidate_archive = root / "candidate.tar.gz"
            candidate_archive.write_bytes(b"candidate archive")
            legacy_archive = root / "openwrt-rootfs.tar.gz"
            legacy_archive.write_bytes(b"legacy transition archive")
            previous = {
                "current": "r-1", "seq": 1,
                "signing": {"key_id": hashlib.sha256(public_der).hexdigest()},
                "artifact": {"filename": previous_archive.name,
                    "sha256": digest(previous_archive), "size_bytes": previous_archive.stat().st_size},
            }
            candidate = {
                "current": "r-2", "seq": 2,
                "signing": {"key_id": hashlib.sha256(public_der).hexdigest()},
                "artifacts": {"x86_64": {"filename": candidate_archive.name,
                    "sha256": digest(candidate_archive), "size_bytes": candidate_archive.stat().st_size}},
                "artifact": {"filename": legacy_archive.name,
                    "sha256": digest(legacy_archive), "size_bytes": legacy_archive.stat().st_size},
            }
            previous_path, signature_path = root / "UPDATES.json", root / "UPDATES.json.sig"
            candidate_path, candidate_signature, receipt_path = root / "candidate.json", root / "candidate.json.sig", root / "receipt.json"
            previous_path.write_text(json.dumps(previous), encoding="utf-8")
            subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(private),
                            "-in", str(previous_path), "-out", str(signature_path)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            candidate_path.write_text(json.dumps(candidate), encoding="utf-8")
            subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(private),
                            "-in", str(candidate_path), "-out", str(candidate_signature)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            receipt = {
                "schema": 1, "result": "passed", "environment": "previous-published-installer",
                "architecture": "x86_64", "previous_tag": "r-1", "previous_seq": 1,
                "previous_manifest_sha256": digest(previous_path), "previous_signature_sha256": digest(signature_path),
                "previous_archive_sha256": digest(previous_archive), "candidate_tag": "r-2", "candidate_seq": 2,
                "candidate_manifest_sha256": digest(candidate_path), "candidate_archive_sha256": digest(legacy_archive),
                "candidate_signature_verified_by_previous_engine": True,
                "candidate_test_signature_verified_by_previous_engine": True,
                "candidate_signature_sha256": digest(candidate_signature), "mem_total_kb": 131072,
                "mem_available_kb": 23000, "previous_stage_default": "tmpfs",
                "scenarios": {name: True for name in (
                    "insufficient_persistent_space", "rollback_after_service_stop",
                    "panel_update_default_persistent", "successful_upgrade",
                    "user_configuration_preserved", "services_running_after_upgrade",
                    "legacy_tmpfs_refusal",
                )},
            }
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            command = ["python3", str(VERIFIER), "--receipt", str(receipt_path),
                       "--previous-manifest", str(previous_path), "--previous-signature", str(signature_path),
                       "--candidate-manifest", str(candidate_path), "--candidate-signature", str(candidate_signature),
                       "--candidate-dir", str(root),
                       "--architecture", "x86_64", "--repository", str(ROOT), "--public-key", str(public),
                       "--candidate-public-key", str(public)]
            accepted = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(accepted.returncode, 0, accepted.stderr)

            receipt["mem_available_kb"] = 90000
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            rejected = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("диапазона приёмки малой памяти", rejected.stderr)

            receipt["mem_available_kb"] = 23000
            receipt["scenarios"].pop("panel_update_default_persistent")
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            missing_default_path = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(missing_default_path.returncode, 0)
            self.assertIn("обязательный сценарий при малом объёме памяти", missing_default_path.stderr)
            receipt["scenarios"]["panel_update_default_persistent"] = True

            receipt["scenarios"]["legacy_tmpfs_refusal"] = False
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            missing_transition = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(missing_transition.returncode, 0)
            self.assertIn("установщик", missing_transition.stderr)
            receipt["scenarios"]["legacy_tmpfs_refusal"] = True
            receipt["previous_stage_default"] = "persistent"
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            persistent_baseline = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(persistent_baseline.returncode, 0, persistent_baseline.stderr)
            receipt["previous_stage_default"] = "tmpfs"
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")

            # Новые опубликованные движки выбирают архив своей архитектуры.
            # Проверяем этот путь, даже если кандидат также содержит общий
            # переходный архив для старых установленных роутеров.
            previous["artifacts"] = {"x86_64": {
                "filename": previous_archive.name,
                "sha256": digest(previous_archive),
                "size_bytes": previous_archive.stat().st_size,
            }}
            previous_path.write_text(json.dumps(previous), encoding="utf-8")
            subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(private),
                            "-in", str(previous_path), "-out", str(signature_path)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            receipt["previous_manifest_sha256"] = digest(previous_path)
            receipt["previous_signature_sha256"] = digest(signature_path)
            receipt["candidate_archive_sha256"] = digest(candidate_archive)
            receipt["mem_available_kb"] = 23000
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            per_arch = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(per_arch.returncode, 0, per_arch.stderr)


if __name__ == "__main__":
    unittest.main()
