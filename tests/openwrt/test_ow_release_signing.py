#!/usr/bin/env python3
"""Production signing command verifies exact controlled OpenWrt releases."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts" / "openwrt"
sys.path.insert(0, str(SCRIPTS))
from controlled_release import render_manifest  # noqa: E402


class ReleaseSigningTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="z2kow-release-signing-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.artifact = self.work / "openwrt-rootfs.tar.gz"
        self.artifact.write_bytes(b"complete test release payload\n")
        self.private_key = self.work / "release.key"
        self.public_key = self.work / "release.pub"
        self.wrong_private_key = self.work / "wrong.key"
        self.wrong_public_key = self.work / "wrong.pub"
        for private, public in (
            (self.private_key, self.public_key),
            (self.wrong_private_key, self.wrong_public_key),
        ):
            subprocess.run(
                ["openssl", "genpkey", "-algorithm", "Ed25519", "-out", str(private)],
                check=True,
                capture_output=True,
            )
            subprocess.run(
                ["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)],
                check=True,
                capture_output=True,
            )
        self.key_id = self.fingerprint(self.public_key)
        self.manifest = self.work / "UPDATES.json"
        self.signature = self.work / "UPDATES.json.sig"
        self.manifest.write_text(self.manifest_text(), encoding="utf-8")

    @staticmethod
    def fingerprint(public_key: Path) -> str:
        der = subprocess.run(
            ["openssl", "pkey", "-pubin", "-in", str(public_key), "-outform", "DER"],
            check=True,
            capture_output=True,
        ).stdout
        return hashlib.sha256(der).hexdigest()

    def manifest_text(self) -> str:
        return render_manifest(
            {
                "schema": 1,
                "branch": "main",
                "platform": "openwrt",
                "seq": 136,
                "current": "p-86.13",
                "upstream": {
                    "repository": "necronicle/z2k",
                    "branch": "z2k-enhanced",
                    "tag": "p-86.13",
                    "commit": "7f630a9d459052b9c9c9eded06298f1b8f7f0a22",
                },
                "signing": {"key_id": self.key_id},
                "history": [{"v": "p-86.13", "type": "reinstall", "ts": "2026-10-02T00:00:00Z"}],
                "artifact": {
                    "filename": self.artifact.name,
                    "url": "https://github.com/t0fox/z2kOW/releases/download/openwrt-" + "a" * 40 + "/openwrt-rootfs.tar.gz",
                    "sha256": hashlib.sha256(self.artifact.read_bytes()).hexdigest(),
                    "size_bytes": self.artifact.stat().st_size,
                },
            }
        )

    def invoke(self, mode: str, *, private: Path | None = None, public: Path | None = None) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            str(SCRIPTS / "sign_release.py"),
            mode,
            "--manifest",
            str(self.manifest),
            "--artifact",
            str(self.artifact),
            "--signature",
            str(self.signature),
        ]
        if private is not None:
            command.extend(["--private-key", str(private)])
        if public is not None:
            command.extend(["--public-key", str(public)])
        return subprocess.run(command, text=True, capture_output=True)

    def test_exact_manifest_and_complete_artifact_sign_and_verify(self) -> None:
        signed = self.invoke("sign", private=self.private_key)
        self.assertEqual(signed.returncode, 0, signed.stderr)
        self.assertTrue(self.signature.is_file())
        verified = self.invoke("verify", public=self.public_key)
        self.assertEqual(verified.returncode, 0, verified.stderr)

    def test_modified_manifest_fails_verification(self) -> None:
        self.assertEqual(self.invoke("sign", private=self.private_key).returncode, 0)
        changed = json.loads(self.manifest.read_text(encoding="utf-8"))
        changed["current"] = "p-86.14"
        self.manifest.write_text(render_manifest(changed), encoding="utf-8")
        self.assertNotEqual(self.invoke("verify", public=self.public_key).returncode, 0)

    def test_wrong_private_key_cannot_sign_for_manifest_key_id(self) -> None:
        result = self.invoke("sign", private=self.wrong_private_key)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.signature.exists())

    def test_wrong_public_key_fails_verification(self) -> None:
        self.assertEqual(self.invoke("sign", private=self.private_key).returncode, 0)
        self.assertNotEqual(self.invoke("verify", public=self.wrong_public_key).returncode, 0)

    def test_missing_signature_fails_verification(self) -> None:
        result = self.invoke("verify", public=self.public_key)
        self.assertNotEqual(result.returncode, 0)

    def test_artifact_hash_mismatch_fails_before_signing(self) -> None:
        self.artifact.write_bytes(b"tampered complete payload\n")
        result = self.invoke("sign", private=self.private_key)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.signature.exists())


if __name__ == "__main__":
    unittest.main()
