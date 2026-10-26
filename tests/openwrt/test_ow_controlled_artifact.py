from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts" / "openwrt" / "controlled_release.py"
MODULE = None
if MODULE_PATH.exists():
    SPEC = importlib.util.spec_from_file_location("controlled_release", MODULE_PATH)
    MODULE = importlib.util.module_from_spec(SPEC)
    assert SPEC and SPEC.loader
    SPEC.loader.exec_module(MODULE)


class ControlledArtifactTests(unittest.TestCase):
    TECHNICAL_URL = (
        "https://github.com/t0fox/z2kOW/releases/download/openwrt-"
        + "a" * 40
        + "/openwrt-rootfs.tar.gz"
    )

    def setUp(self) -> None:
        self.assertIsNotNone(MODULE, "controlled_release.py must attach signed release artifacts")
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.artifact = self.root / "openwrt-rootfs.tar.gz"
        self.artifact.write_bytes(b"verified rootfs payload")
        self.manifest = {
            "schema": 1,
            "branch": "main",
            "platform": "openwrt",
            "current": "r-86.5",
            "seq": 141,
            "upstream": {
                "repository": "necronicle/z2k",
                "branch": "z2k-enhanced",
                "tag": "r-86.5",
                "commit": "43b98092c5a337a35f5c094363f469243d7b8b80",
            },
            "history": [
                {"v": "p-86.2", "type": "patch", "full_install": False},
                {"v": "r-86.3", "type": "reinstall", "full_install": True},
                {"v": "r-86.5", "type": "reinstall", "full_install": True},
            ],
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _upstream(self, tag: str = "r-86.5", seq: int = 141) -> dict[str, object]:
        return {"branch": "z2k-enhanced", "current": tag, "seq": seq, "history": [{"v": tag}]}

    def _verify_upstream_tag(
        self, upstream: dict[str, object], pinned: dict[str, object], refs: str,
        tag: str = "r-86.5", seq: int = 141,
        skip_registry: dict[str, object] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        live_path = self.root / "upstream-live.json"
        pinned_path = self.root / "upstream-pinned.json"
        refs_path = self.root / "upstream-refs.txt"
        live_path.write_text(json.dumps(upstream), encoding="utf-8")
        pinned_path.write_text(json.dumps(pinned), encoding="utf-8")
        refs_path.write_text(refs, encoding="utf-8")
        command = [
            sys.executable, str(MODULE_PATH), "verify-upstream-tag",
            "--upstream", str(live_path), "--pinned", str(pinned_path),
            "--refs", str(refs_path), "--tag", tag, "--seq", str(seq),
        ]
        if skip_registry is not None:
            skip_path = self.root / "upstream-skips.json"
            skip_path.write_text(json.dumps(skip_registry), encoding="utf-8")
            command.extend(["--skip-registry", str(skip_path)])
        return subprocess.run(
            command,
            text=True,
            capture_output=True,
        )

    def _check_upstream(
        self, upstream: dict[str, object], skip_registry: dict[str, object]
    ) -> subprocess.CompletedProcess[str]:
        upstream_path = self.root / "upstream.json"
        controlled_path = self.root / "controlled.json"
        skip_path = self.root / "upstream-skips.json"
        upstream_path.write_text(json.dumps(upstream), encoding="utf-8")
        controlled_path.write_text(json.dumps(self.manifest), encoding="utf-8")
        skip_path.write_text(json.dumps(skip_registry), encoding="utf-8")
        return subprocess.run(
            [
                sys.executable, str(MODULE_PATH), "check-upstream",
                "--upstream", str(upstream_path), "--commit", "d" * 40,
                "--controlled", str(controlled_path), "--skip-registry", str(skip_path),
            ],
            text=True,
            capture_output=True,
        )

    def test_single_transport_artifact_hash_is_recorded_in_updates_manifest(self) -> None:
        url = self.TECHNICAL_URL

        MODULE.attach_rootfs_artifact(self.manifest, self.artifact, url)

        record = self.manifest["artifact"]
        self.assertEqual(record["filename"], self.artifact.name)
        self.assertEqual(record["url"], url)
        self.assertEqual(record["sha256"], MODULE.sha256(self.artifact))
        self.assertEqual(record["size_bytes"], self.artifact.stat().st_size)
        self.assertEqual(set(record), {"filename", "url", "sha256", "size_bytes"})

    def test_artifact_url_is_technical_and_independent_of_the_user_version(self) -> None:
        MODULE.attach_rootfs_artifact(self.manifest, self.artifact, self.TECHNICAL_URL)

        self.assertEqual(
            self.manifest["artifact"]["url"],
            self.TECHNICAL_URL,
        )

    def test_unsigned_candidate_uses_a_copy_without_replacing_the_published_artifact(self) -> None:
        source = self.root / "UPDATES.json"
        candidate = self.root / "candidate" / "UPDATES.json"
        candidate.parent.mkdir()
        self.manifest["artifact"] = {
            "filename": "openwrt-rootfs.tar.gz",
            "url": self.TECHNICAL_URL,
            "sha256": "a" * 64,
            "size_bytes": 123,
        }
        self.manifest["signing"] = {"key_id": "a" * 64}
        MODULE.write_manifest(source, self.manifest)

        MODULE.copy_unsigned_candidate_manifest(source, candidate)

        published = json.loads(source.read_text(encoding="utf-8"))
        generated = json.loads(candidate.read_text(encoding="utf-8"))
        self.assertEqual(published["artifact"]["sha256"], "a" * 64)
        self.assertNotIn("artifact", generated)
        self.assertNotIn("signing", generated)
        expected = dict(self.manifest)
        expected.pop("artifact")
        expected.pop("signing")
        self.assertEqual(generated, expected)

        MODULE.attach_file(
            candidate,
            self.artifact,
            self.TECHNICAL_URL,
        )
        final_candidate = json.loads(candidate.read_text(encoding="utf-8"))
        self.assertEqual(final_candidate["artifact"]["sha256"], MODULE.sha256(self.artifact))
        self.assertEqual(published["artifact"]["sha256"], "a" * 64)

    def test_final_manifest_attaches_the_single_signing_key_id_with_the_artifact(self) -> None:
        candidate = self.root / "final" / "UPDATES.json"
        candidate.parent.mkdir()
        MODULE.write_manifest(candidate, self.manifest)

        MODULE.attach_file(candidate, self.artifact, self.TECHNICAL_URL, key_id="b" * 64)

        final = json.loads(candidate.read_text(encoding="utf-8"))
        self.assertEqual(final["signing"], {"key_id": "b" * 64})
        self.assertEqual(final["artifact"]["sha256"], MODULE.sha256(self.artifact))

    def test_final_manifest_rejects_malformed_signing_key_id(self) -> None:
        candidate = self.root / "bad" / "UPDATES.json"
        candidate.parent.mkdir()
        MODULE.write_manifest(candidate, self.manifest)

        with self.assertRaisesRegex(ValueError, "signing key id"):
            MODULE.attach_file(candidate, self.artifact, self.TECHNICAL_URL, key_id="not-a-fingerprint")

    def test_manifest_cannot_carry_a_second_transport_or_component_release(self) -> None:
        url = self.TECHNICAL_URL
        MODULE.attach_rootfs_artifact(self.manifest, self.artifact, url)
        self.manifest["adapter"] = {"version": "0.1.1"}

        with self.assertRaisesRegex(ValueError, "secondary component release"):
            MODULE.attach_rootfs_artifact(self.manifest, self.artifact, url)

    def test_artifact_must_use_a_full_sha_technical_release_tag(self) -> None:
        urls = (
            "https://github.com/t0fox/z2kOW/releases/download/p-86.13/openwrt-rootfs.tar.gz",
            "https://github.com/other/repo/releases/download/openwrt-" + "a" * 40 + "/openwrt-rootfs.tar.gz",
            "https://github.com/t0fox/z2kOW/releases/download/openwrt-abcdef/openwrt-rootfs.tar.gz",
            "https://example.com/releases/download/openwrt-" + "a" * 40 + "/openwrt-rootfs.tar.gz",
        )
        for url in urls:
            with self.subTest(url=url), self.assertRaisesRegex(ValueError, "controlled immutable OpenWrt release"):
                MODULE.attach_rootfs_artifact(self.manifest, self.artifact, url)

    def test_artifact_url_is_required_when_attaching_a_release(self) -> None:
        with self.assertRaisesRegex(ValueError, "technical release URL"):
            MODULE.attach_rootfs_artifact(self.manifest, self.artifact)

    def test_missing_artifact_file_is_rejected(self) -> None:
        missing = self.root / "missing" / "openwrt-rootfs.tar.gz"
        with self.assertRaisesRegex(ValueError, "existing openwrt-rootfs.tar.gz"):
            MODULE.attach_rootfs_artifact(self.manifest, missing, self.TECHNICAL_URL)

    def test_non_openwrt_manifest_is_rejected(self) -> None:
        self.manifest.pop("platform")

        with self.assertRaisesRegex(ValueError, "OpenWrt"):
            MODULE.attach_rootfs_artifact(
                self.manifest,
                self.artifact,
                self.TECHNICAL_URL,
            )

    def test_render_keeps_upstream_history_objects_one_per_line_without_seq_rewrite(self) -> None:
        encoded = MODULE.render_manifest(self.manifest)
        decoded = __import__("json").loads(encoded)

        self.assertEqual(decoded["history"], self.manifest["history"])
        self.assertNotIn("seq", decoded["history"][-1])
        history_lines = [line for line in encoded.splitlines() if '"v":' in line]
        self.assertEqual(len(history_lines), 3)
        self.assertTrue(all(line.lstrip().startswith('{"v": ') for line in history_lines))

    def test_controlled_manifest_is_derived_from_the_supplied_live_upstream_manifest(self) -> None:
        upstream = {
            "branch": "z2k-enhanced",
            "current": "r-99.12",
            "seq": 812,
            "history": [
                {"v": "p-86.10", "type": "patch", "full_install": False},
                {"v": "r-99.12", "type": "reinstall", "full_install": True},
            ],
        }
        commit = "a" * 40

        controlled = MODULE.controlled_from_upstream(upstream, commit)

        self.assertEqual(controlled["current"], upstream["current"])
        self.assertEqual(controlled["seq"], upstream["seq"])
        self.assertEqual(controlled["history"], upstream["history"])
        self.assertEqual(controlled["upstream"]["tag"], upstream["current"])
        self.assertEqual(controlled["upstream"]["commit"], commit)
        self.assertEqual(set(controlled), {"schema", "branch", "platform", "seq", "current", "upstream", "history"})

    def test_live_upstream_check_detects_a_release_without_using_a_fixed_version(self) -> None:
        upstream = {"branch": "z2k-enhanced", "current": "p-100.2", "seq": 900, "history": [{"v": "p-100.2"}]}
        controlled = {"current": "r-99.12", "seq": 812, "upstream": {"tag": "r-99.12"}}

        result = MODULE.compare_upstream(upstream, controlled, "b" * 40)

        self.assertTrue(result["update_available"])
        self.assertEqual(result["latest_tag"], "p-100.2")
        self.assertEqual(result["latest_seq"], 900)

    def test_not_applicable_release_advances_review_watermark_without_repeating_or_masking_next_release(self) -> None:
        """Пропуск не повторяется, а следующий выпуск остаётся заметным."""
        skip_registry = {
            "schema": 1,
            "skips": [
                {
                    "tag": "p-86.19",
                    "seq": 143,
                    "status": "not applicable",
                    "reason": "Этот механизм не используется на OpenWrt.",
                }
            ],
        }
        upstream = {
            "branch": "z2k-enhanced",
            "current": "p-86.19",
            "seq": 143,
            "history": [{"v": "r-86.5"}, {"v": "p-86.18"}, {"v": "p-86.19"}],
        }

        skipped = self._check_upstream(upstream, skip_registry)

        self.assertEqual(skipped.returncode, 0, skipped.stderr)
        skipped_result = json.loads(skipped.stdout.splitlines()[0])
        self.assertFalse(skipped_result["update_available"])
        self.assertEqual(skipped_result["accounted_seq"], 143)
        self.assertEqual(skipped_result["not_applicable"][0]["tag"], "p-86.19")
        self.assertIn("неприменим", skipped.stdout)

        upstream["current"] = "p-86.20"
        upstream["seq"] = 144
        upstream["history"].append({"v": "p-86.20"})
        next_release = self._check_upstream(upstream, skip_registry)

        self.assertEqual(next_release.returncode, 3, next_release.stdout)
        next_result = json.loads(next_release.stdout.splitlines()[0])
        self.assertTrue(next_result["update_available"])
        self.assertEqual(next_result["accounted_seq"], 143)
        self.assertEqual(next_result["latest_tag"], "p-86.20")

    def test_upstream_skip_must_match_a_release_in_live_history(self) -> None:
        """Реестр не должен пропускать тег, которого нет в истории upstream."""
        registry = {
            "schema": 1,
            "skips": [
                {"tag": "p-86.19", "seq": 143, "status": "not applicable", "reason": "Только для другой платформы."}
            ],
        }
        upstream = self._upstream("p-86.20", 144)

        result = self._check_upstream(upstream, registry)

        self.assertEqual(result.returncode, 1)
        self.assertIn("отсутствует в актуальной истории", result.stderr)

    def test_live_upstream_check_rejects_a_rewound_sequence(self) -> None:
        upstream = {"branch": "z2k-enhanced", "current": "p-100.2", "seq": 811, "history": [{"v": "p-100.2"}]}
        controlled = {"current": "r-99.12", "seq": 812, "upstream": {"tag": "r-99.12"}}

        with self.assertRaisesRegex(ValueError, "sequence moved backwards"):
            MODULE.compare_upstream(upstream, controlled, "c" * 40)

    def test_only_the_official_existing_upstream_tag_can_set_product_identity(self) -> None:
        commit = "43b98092c5a337a35f5c094363f469243d7b8b80"
        refs = (
            f"{commit}\trefs/heads/z2k-enhanced\n"
            "bdc81a8b9aa4132876ea12e650034ecfe52b411a\trefs/tags/r-86.5\n"
            f"{commit}\trefs/tags/r-86.5^{{}}\n"
        )
        verified = self._verify_upstream_tag(self._upstream(), self._upstream(), refs)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertEqual(verified.stdout.strip(), commit)

    def test_plain_reinstall_tag_r87_is_a_valid_upstream_product_tag(self) -> None:
        commit = "e5d9850802174e6098687f09945cace33afe3a8c"
        upstream = {
            "branch": "z2k-enhanced",
            "current": "r-87",
            "seq": 150,
            "history": [{"v": "p-86.22"}, {"v": "r-87"}],
        }
        refs = f"{commit}\trefs/heads/z2k-enhanced\n{commit}\trefs/tags/r-87\n"

        verified = self._verify_upstream_tag(
            upstream, upstream, refs, tag="r-87", seq=150
        )

        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertEqual(verified.stdout.strip(), commit)

    def test_forged_tag_name_cannot_replace_the_official_current_tag(self) -> None:
        commit = "43b98092c5a337a35f5c094363f469243d7b8b80"
        refs = f"{commit}\trefs/heads/z2k-enhanced\n{commit}\trefs/tags/r-86.7\n"
        result = self._verify_upstream_tag(self._upstream(), self._upstream(), refs)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("проверенный Git-тег upstream", result.stderr)

    def test_upstream_tag_and_sequence_must_match_live_and_tagged_manifests(self) -> None:
        commit = "43b98092c5a337a35f5c094363f469243d7b8b80"
        refs = f"{commit}\trefs/heads/z2k-enhanced\n{commit}\trefs/tags/r-86.5\n"
        mismatched_tag = self._verify_upstream_tag(
            self._upstream(), self._upstream("r-86.6", 142), refs
        )
        mismatched_seq = self._verify_upstream_tag(
            self._upstream("r-86.5", 142), self._upstream("r-86.5", 142), refs
        )
        boolean_seq = self._upstream()
        boolean_seq["seq"] = True
        malformed_seq = self._verify_upstream_tag(
            boolean_seq, boolean_seq, refs, seq=1
        )
        self.assertNotEqual(mismatched_tag.returncode, 0)
        self.assertNotEqual(mismatched_seq.returncode, 0)
        self.assertNotEqual(malformed_seq.returncode, 0)

    def test_upstream_product_release_can_precede_only_registered_not_applicable_releases(self) -> None:
        """Разрешает целевой тег перед хвостом, целиком отмеченным неприменимым."""
        target_commit = "a" * 40
        branch_commit = "b" * 40
        target = {
            "branch": "z2k-enhanced",
            "current": "p-86.18",
            "seq": 142,
            "history": [{"v": "r-86.5"}, {"v": "p-86.18"}],
        }
        live = {
            "branch": "z2k-enhanced",
            "current": "p-86.19",
            "seq": 143,
            "history": [{"v": "r-86.5"}, {"v": "p-86.18"}, {"v": "p-86.19"}],
        }
        skips = {
            "schema": 1,
            "skips": [
                {
                    "tag": "p-86.19",
                    "seq": 143,
                    "status": "not applicable",
                    "reason": "Выпуск предназначен для другой платформы.",
                }
            ],
        }
        refs = (
            f"{branch_commit}\trefs/heads/z2k-enhanced\n"
            f"{target_commit}\trefs/tags/p-86.18\n"
        )

        result = self._verify_upstream_tag(live, target, refs, "p-86.18", 142, skips)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), target_commit)

    def test_historical_product_release_can_precede_a_newer_pending_upstream_release(self) -> None:
        target_commit = "9fafc758d48e52a845efd48c839d1051e5c60b78"
        branch_commit = "e5d9850802174e6098687f09945cace33afe3a8c"
        target = {
            "branch": "z2k-enhanced",
            "current": "p-86.24",
            "seq": 149,
            "history": [{"v": "p-86.22"}, {"v": "p-86.23"}, {"v": "r-86.6"}, {"v": "p-86.24"}],
        }
        live = {
            "branch": "z2k-enhanced",
            "current": "r-87",
            "seq": 150,
            "history": [
                {"v": "p-86.22"}, {"v": "p-86.23"}, {"v": "r-86.6"},
                {"v": "p-86.24"}, {"v": "r-87"},
            ],
        }
        skips = {
            "schema": 1,
            "skips": [
                {"tag": "p-86.23", "seq": 147, "status": "not applicable", "reason": "Изменение адаптировано."},
                {"tag": "r-86.6", "seq": 148, "status": "not applicable", "reason": "Собственная реализация."},
            ],
        }
        refs = (
            f"{branch_commit}\trefs/heads/z2k-enhanced\n"
            f"{target_commit}\trefs/tags/p-86.24\n"
        )

        result = self._verify_upstream_tag(live, target, refs, "p-86.24", 149, skips)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), target_commit)

    def test_upstream_product_release_rejects_an_unregistered_or_misnumbered_newer_release(self) -> None:
        """Отклоняет live-историю, где seq не соответствует числу версий после цели."""
        target_commit = "a" * 40
        branch_commit = "b" * 40
        target = {
            "branch": "z2k-enhanced",
            "current": "p-86.18",
            "seq": 142,
            "history": [{"v": "r-86.5"}, {"v": "p-86.18"}],
        }
        live = {
            "branch": "z2k-enhanced",
            "current": "p-86.20",
            "seq": 145,
            "history": [{"v": "r-86.5"}, {"v": "p-86.18"}, {"v": "p-86.19"}, {"v": "p-86.20"}],
        }
        registry = {"schema": 1, "skips": []}
        refs = (
            f"{branch_commit}\trefs/heads/z2k-enhanced\n"
            f"{target_commit}\trefs/tags/p-86.18\n"
        )

        result = self._verify_upstream_tag(live, target, refs, "p-86.18", 142, registry)

        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
