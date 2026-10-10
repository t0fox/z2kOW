#!/usr/bin/env python3
"""Production signing command verifies exact controlled OpenWrt releases."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts" / "openwrt"
sys.path.insert(0, str(SCRIPTS))
from controlled_release import attach_architecture_artifacts, render_manifest  # noqa: E402


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

    def write_architecture_candidate(self, *, include_legacy: bool) -> Path:
        architectures = ("arm64", "arm", "x86_64", "x86", "mips", "mipsel", "riscv64")
        artifact_dir = self.work / ("with-legacy" if include_legacy else "per-arch")
        artifact_dir.mkdir(exist_ok=True)
        manifest = json.loads(self.manifest_text())
        manifest.pop("artifact", None)
        records = {}
        for arch in architectures:
            filename = f"openwrt-rootfs-{arch}.tar.gz"
            path = artifact_dir / filename
            with tarfile.open(path, "w:gz") as archive:
                payload = f"payload for {arch}\n".encode()
                info = tarfile.TarInfo(f"bin/{arch}")
                info.size = len(payload)
                archive.addfile(info, __import__("io").BytesIO(payload))
            records[arch] = self._artifact_record(path, filename)
        manifest["artifacts"] = records
        if include_legacy:
            legacy = artifact_dir / "openwrt-rootfs.tar.gz"
            with tarfile.open(legacy, "w:gz") as archive:
                payload = b"transition fallback\n"
                info = tarfile.TarInfo("bin/legacy")
                info.size = len(payload)
                archive.addfile(info, __import__("io").BytesIO(payload))
            legacy_record = self._artifact_record(legacy, legacy.name)
            legacy_record.pop("unpacked_size_bytes")
            manifest["artifact"] = legacy_record
        self.manifest.write_text(render_manifest(manifest), encoding="utf-8")
        return artifact_dir

    @staticmethod
    def _artifact_record(path: Path, filename: str) -> dict[str, object]:
        unpacked = 0
        with tarfile.open(path, "r:gz") as archive:
            unpacked = sum(member.size for member in archive.getmembers() if member.isfile())
        return {
            "filename": filename,
            "url": "https://github.com/t0fox/z2kOW/releases/download/openwrt-" + "a" * 40 + f"/{filename}",
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "size_bytes": path.stat().st_size,
            "unpacked_size_bytes": unpacked,
        }

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

    def invoke_architectures(
        self, mode: str, artifact_dir: Path, *, private: Path | None = None,
        public: Path | None = None, include_legacy: bool | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable, str(SCRIPTS / "sign_release.py"), mode,
            "--manifest", str(self.manifest), "--artifact-dir", str(artifact_dir),
            "--signature", str(self.signature),
        ]
        if include_legacy is not None:
            command.extend(["--include-legacy-fallback", "true" if include_legacy else "false"])
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

    def test_one_signature_covers_all_seven_archives_and_actual_size_digest_and_unpack_size(self) -> None:
        artifact_dir = self.write_architecture_candidate(include_legacy=False)
        signed = self.invoke_architectures("sign", artifact_dir, private=self.private_key)
        self.assertEqual(signed.returncode, 0, signed.stderr)
        self.assertTrue(self.signature.is_file())
        verified = self.invoke_architectures("verify", artifact_dir, public=self.public_key)
        self.assertEqual(verified.returncode, 0, verified.stderr)

        manifest = json.loads(self.manifest.read_text(encoding="utf-8"))
        self.assertEqual(set(manifest["artifacts"]), {"arm64", "arm", "x86_64", "x86", "mips", "mipsel", "riscv64"})
        for arch, record in manifest["artifacts"].items():
            artifact = artifact_dir / record["filename"]
            self.assertEqual(record["size_bytes"], artifact.stat().st_size)
            self.assertEqual(record["sha256"], hashlib.sha256(artifact.read_bytes()).hexdigest())
            with tarfile.open(artifact, "r:gz") as archive:
                self.assertEqual(record["unpacked_size_bytes"], sum(item.size for item in archive.getmembers() if item.isfile()))

        (artifact_dir / "openwrt-rootfs-mipsel.tar.gz").write_bytes(b"tampered")
        rejected = self.invoke_architectures("verify", artifact_dir, public=self.public_key)
        self.assertNotEqual(rejected.returncode, 0)

    def test_transition_signature_includes_the_complete_legacy_fallback_only_as_one_extra_asset(self) -> None:
        artifact_dir = self.write_architecture_candidate(include_legacy=True)
        result = self.invoke_architectures("sign", artifact_dir, private=self.private_key)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(self.manifest.read_text(encoding="utf-8"))
        self.assertEqual(set(manifest["artifacts"]), {"arm64", "arm", "x86_64", "x86", "mips", "mipsel", "riscv64"})
        self.assertEqual(manifest["artifact"]["filename"], "openwrt-rootfs.tar.gz")
        verified = self.invoke_architectures("verify", artifact_dir, public=self.public_key)
        self.assertEqual(verified.returncode, 0, verified.stderr)

    def test_signer_requires_the_candidate_fallback_decision_to_match_the_manifest(self) -> None:
        transition_dir = self.write_architecture_candidate(include_legacy=True)
        transition_without_flag = self.invoke_architectures(
            "sign", transition_dir, private=self.private_key, include_legacy=False
        )
        self.assertNotEqual(transition_without_flag.returncode, 0)
        self.assertFalse(self.signature.exists())
        transition = self.invoke_architectures(
            "sign", transition_dir, private=self.private_key, include_legacy=True
        )
        self.assertEqual(transition.returncode, 0, transition.stderr)

        later_dir = self.write_architecture_candidate(include_legacy=False)
        later_with_flag = self.invoke_architectures(
            "sign", later_dir, private=self.private_key, include_legacy=True
        )
        self.assertNotEqual(later_with_flag.returncode, 0)

    def test_candidate_attachment_records_all_archives_and_uses_baseline_for_transition_fallback(self) -> None:
        source_sha = "b" * 40
        for include_legacy in (True, False):
            with self.subTest(include_legacy=include_legacy):
                artifact_dir = self.write_architecture_candidate(include_legacy=include_legacy)
                manifest = json.loads(self.manifest_text())
                baseline = {"artifact": {}} if include_legacy else {"artifacts": {}}
                attached_fallback = attach_architecture_artifacts(
                    manifest, artifact_dir, source_sha, baseline, self.key_id
                )
                self.assertEqual(attached_fallback, include_legacy)
                self.assertEqual(set(manifest["artifacts"]), {"arm64", "arm", "x86_64", "x86", "mips", "mipsel", "riscv64"})
                self.assertEqual("artifact" in manifest, include_legacy)
                for arch, record in manifest["artifacts"].items():
                    self.assertEqual(record["filename"], f"openwrt-rootfs-{arch}.tar.gz")
                    self.assertEqual(
                        record["url"],
                        f"https://github.com/t0fox/z2kOW/releases/download/openwrt-{source_sha}/{record['filename']}",
                    )
                    self.assertEqual(record["size_bytes"], (artifact_dir / record["filename"]).stat().st_size)
                    self.assertEqual(len(record["sha256"]), 64)
                    self.assertGreater(record["unpacked_size_bytes"], 0)

    def test_per_arch_signature_rejects_missing_or_extra_assets(self) -> None:
        artifact_dir = self.write_architecture_candidate(include_legacy=False)
        (artifact_dir / "openwrt-rootfs-arm.tar.gz").unlink()
        missing = self.invoke_architectures("sign", artifact_dir, private=self.private_key)
        self.assertNotEqual(missing.returncode, 0)
        self.assertFalse(self.signature.exists())

        artifact_dir = self.write_architecture_candidate(include_legacy=False)
        (artifact_dir / "openwrt-rootfs-extra.tar.gz").write_bytes(b"unlisted")
        extra = self.invoke_architectures("sign", artifact_dir, private=self.private_key)
        self.assertNotEqual(extra.returncode, 0)
        self.assertFalse(self.signature.exists())


if __name__ == "__main__":
    unittest.main()
