from __future__ import annotations

import importlib.util
import json
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
            "current": "p-86.13",
            "seq": 136,
            "upstream": {
                "repository": "necronicle/z2k",
                "branch": "z2k-enhanced",
                "tag": "p-86.13",
                "commit": "7f630a9d459052b9c9c9eded06298f1b8f7f0a22",
            },
            "history": [
                {"v": "p-86.2", "type": "patch", "full_install": False},
                {"v": "r-86.3", "type": "reinstall", "full_install": True},
                {"v": "p-86.13", "type": "patch", "full_install": False},
            ],
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_single_transport_artifact_hash_is_recorded_in_updates_manifest(self) -> None:
        url = "https://github.com/t0fox/z2kOW/releases/download/p-86.13/openwrt-rootfs.tar.gz"

        MODULE.attach_rootfs_artifact(self.manifest, self.artifact, url)

        record = self.manifest["artifact"]
        self.assertEqual(record["filename"], self.artifact.name)
        self.assertEqual(record["url"], url)
        self.assertEqual(record["sha256"], MODULE.sha256(self.artifact))
        self.assertEqual(record["size_bytes"], self.artifact.stat().st_size)
        self.assertEqual(set(record), {"filename", "url", "sha256", "size_bytes"})

    def test_artifact_url_is_derived_from_the_manifest_current_tag(self) -> None:
        MODULE.attach_rootfs_artifact(self.manifest, self.artifact)

        self.assertEqual(
            self.manifest["artifact"]["url"],
            "https://github.com/t0fox/z2kOW/releases/download/p-86.13/openwrt-rootfs.tar.gz",
        )

    def test_unsigned_candidate_uses_a_copy_without_replacing_the_published_artifact(self) -> None:
        source = self.root / "UPDATES.json"
        candidate = self.root / "candidate" / "UPDATES.json"
        candidate.parent.mkdir()
        self.manifest["artifact"] = {
            "filename": "openwrt-rootfs.tar.gz",
            "url": "https://github.com/t0fox/z2kOW/releases/download/p-86.13/openwrt-rootfs.tar.gz",
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
            "https://github.com/t0fox/z2kOW/releases/download/p-86.13/openwrt-rootfs.tar.gz",
        )
        final_candidate = json.loads(candidate.read_text(encoding="utf-8"))
        self.assertEqual(final_candidate["artifact"]["sha256"], MODULE.sha256(self.artifact))
        self.assertEqual(published["artifact"]["sha256"], "a" * 64)

    def test_final_manifest_attaches_the_single_signing_key_id_with_the_artifact(self) -> None:
        candidate = self.root / "final" / "UPDATES.json"
        candidate.parent.mkdir()
        MODULE.write_manifest(candidate, self.manifest)

        MODULE.attach_file(candidate, self.artifact, key_id="b" * 64)

        final = json.loads(candidate.read_text(encoding="utf-8"))
        self.assertEqual(final["signing"], {"key_id": "b" * 64})
        self.assertEqual(final["artifact"]["sha256"], MODULE.sha256(self.artifact))

    def test_final_manifest_rejects_malformed_signing_key_id(self) -> None:
        candidate = self.root / "bad" / "UPDATES.json"
        candidate.parent.mkdir()
        MODULE.write_manifest(candidate, self.manifest)

        with self.assertRaisesRegex(ValueError, "signing key id"):
            MODULE.attach_file(candidate, self.artifact, key_id="not-a-fingerprint")

    def test_manifest_cannot_carry_a_second_transport_or_component_release(self) -> None:
        url = "https://github.com/t0fox/z2kOW/releases/download/p-86.13/openwrt-rootfs.tar.gz"
        MODULE.attach_rootfs_artifact(self.manifest, self.artifact, url)
        self.manifest["adapter"] = {"version": "0.1.1"}

        with self.assertRaisesRegex(ValueError, "secondary component release"):
            MODULE.attach_rootfs_artifact(self.manifest, self.artifact, url)

    def test_artifact_must_be_an_immutable_asset_for_the_manifest_current_tag(self) -> None:
        url = "https://github.com/t0fox/z2kOW/releases/download/p-86.12/openwrt-rootfs.tar.gz"

        with self.assertRaisesRegex(ValueError, "current tag"):
            MODULE.attach_rootfs_artifact(self.manifest, self.artifact, url)

    def test_non_openwrt_manifest_is_rejected(self) -> None:
        self.manifest.pop("platform")

        with self.assertRaisesRegex(ValueError, "OpenWrt"):
            MODULE.attach_rootfs_artifact(
                self.manifest,
                self.artifact,
                "https://github.com/t0fox/z2kOW/releases/download/p-86.13/openwrt-rootfs.tar.gz",
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
        upstream = {"current": "p-100.2", "seq": 900, "history": [{"v": "p-100.2"}]}
        controlled = {"current": "r-99.12", "seq": 812, "upstream": {"tag": "r-99.12"}}

        result = MODULE.compare_upstream(upstream, controlled, "b" * 40)

        self.assertTrue(result["update_available"])
        self.assertEqual(result["latest_tag"], "p-100.2")
        self.assertEqual(result["latest_seq"], 900)

    def test_live_upstream_check_rejects_a_rewound_sequence(self) -> None:
        upstream = {"current": "p-100.2", "seq": 811, "history": [{"v": "p-100.2"}]}
        controlled = {"current": "r-99.12", "seq": 812, "upstream": {"tag": "r-99.12"}}

        with self.assertRaisesRegex(ValueError, "sequence moved backwards"):
            MODULE.compare_upstream(upstream, controlled, "c" * 40)


if __name__ == "__main__":
    unittest.main()
