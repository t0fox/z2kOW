#!/usr/bin/env python3
"""Regression coverage for user releases and immutable OpenWrt payloads."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE_A = "a" * 40
SOURCE_B = "b" * 40
SOURCE_C = "c" * 40
KEY_ID = "d" * 64
MODULE_PATH = ROOT / "scripts/openwrt/publication_policy.py"
MODULE = None
if MODULE_PATH.exists():
    SPEC = importlib.util.spec_from_file_location("publication_policy", MODULE_PATH)
    MODULE = importlib.util.module_from_spec(SPEC)
    assert SPEC and SPEC.loader
    SPEC.loader.exec_module(MODULE)
CONTROLLED_PATH = ROOT / "scripts/openwrt/controlled_release.py"
CONTROLLED = None
if CONTROLLED_PATH.exists():
    CONTROLLED_SPEC = importlib.util.spec_from_file_location("controlled_release", CONTROLLED_PATH)
    CONTROLLED = importlib.util.module_from_spec(CONTROLLED_SPEC)
    assert CONTROLLED_SPEC and CONTROLLED_SPEC.loader
    CONTROLLED_SPEC.loader.exec_module(CONTROLLED)


def controlled_manifest() -> dict[str, object]:
    return {
        "schema": 1,
        "branch": "main",
        "platform": "openwrt",
        "current": "p-86.13",
        "seq": 136,
        "upstream": {
            "repository": "necronicle/z2k",
            "branch": "z2k-enhanced",
            "tag": "p-86.13",
            "commit": "e" * 40,
        },
        "history": [{"v": "p-86.13", "desc": "Исправлена маршрутизация WARP."}],
        "artifact": {
            "filename": "openwrt-rootfs.tar.gz",
            "url": f"https://github.com/t0fox/z2kOW/releases/download/openwrt-{SOURCE_A}/openwrt-rootfs.tar.gz",
            "sha256": "f" * 64,
            "size_bytes": 123,
        },
        "signing": {"key_id": KEY_ID},
    }


def upstream_manifest(tag: str = "p-86.13", seq: int = 136) -> dict[str, object]:
    return {
        "current": tag,
        "seq": seq,
        "history": [{
            "v": tag,
            "desc": "Исправлена маршрутизация WARP." if tag == "p-86.13" else "Обновлена обработка сетевых правил.",
            "changed_files": ["lib/config.sh", "files/lists/tcp16_nets.txt"],
        }],
    }


class PublicationPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertIsNotNone(MODULE, "publication_policy.py must implement the requested publication state machine")

    def plan(
        self,
        operation: str,
        source_sha: str = SOURCE_B,
        upstream: dict[str, object] | None = None,
        controlled: dict[str, object] | None = None,
        **kwargs: object,
    ) -> dict[str, object]:
        return MODULE.plan_publication(
            operation=operation,
            requested_tag=str((upstream or upstream_manifest())["current"]),
            requested_seq=int((upstream or upstream_manifest())["seq"]),
            source_sha=source_sha,
            upstream=upstream or upstream_manifest(),
            controlled=controlled or controlled_manifest(),
            upstream_commit="e" * 40,
            **kwargs,
        )

    def test_product_release_for_current_upstream_version_is_created_only_once(self) -> None:
        advanced = upstream_manifest("p-86.14", 137)
        with self.assertRaisesRegex(ValueError, "Product Release p-86.14 already exists"):
            self.plan("upstream-release", upstream=advanced, existing_product_release=True)

    def test_same_version_fix_selects_a_technical_hotfix_payload(self) -> None:
        plan = self.plan("hotfix")
        self.assertEqual(plan["operation"], "hotfix")
        self.assertEqual(plan["technical_tag"], f"openwrt-{SOURCE_B}")
        self.assertIsNone(plan["product_tag"])

    def test_two_hotfixes_keep_the_product_version_and_get_distinct_payload_tags(self) -> None:
        first = self.plan("hotfix", SOURCE_B)
        second = self.plan("hotfix", SOURCE_C)
        self.assertEqual((first["tag"], first["seq"]), ("p-86.13", 136))
        self.assertEqual((second["tag"], second["seq"]), ("p-86.13", 136))
        self.assertNotEqual(first["technical_tag"], second["technical_tag"])

    def test_hotfix_manifest_replaces_only_the_artifact_record(self) -> None:
        self.assertIsNotNone(CONTROLLED, "controlled_release.py must retain the canonical manifest copier")
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "UPDATES.json"
            candidate = Path(temp) / "candidate.json"
            artifact = Path(temp) / "openwrt-rootfs.tar.gz"
            original = controlled_manifest()
            source.write_text(json.dumps(original), encoding="utf-8")
            artifact.write_bytes(b"new complete rootfs")
            CONTROLLED.copy_unsigned_candidate_manifest(source, candidate)
            CONTROLLED.attach_rootfs_artifact(
                (unsigned := json.loads(candidate.read_text(encoding="utf-8"))),
                artifact,
                f"https://github.com/t0fox/z2kOW/releases/download/openwrt-{SOURCE_B}/openwrt-rootfs.tar.gz",
            )
            self.assertEqual((unsigned["current"], unsigned["seq"]), ("p-86.13", 136))
            self.assertIn(f"openwrt-{SOURCE_B}", unsigned["artifact"]["url"])
            self.assertNotIn("signing", unsigned)

    def test_hotfix_plan_never_changes_current_or_sequence(self) -> None:
        plan = self.plan("hotfix")
        self.assertEqual(plan["tag"], controlled_manifest()["current"])
        self.assertEqual(plan["seq"], controlled_manifest()["seq"])

    def test_manifest_state_accepts_only_the_candidate_baseline_or_already_published_payload(self) -> None:
        candidate = self.plan("hotfix")
        controlled = controlled_manifest()
        self.assertEqual(MODULE.production_manifest_state(controlled, candidate), "baseline")

        published = controlled_manifest()
        published["artifact"] = {
            **published["artifact"],
            "url": f"https://github.com/t0fox/z2kOW/releases/download/openwrt-{SOURCE_B}/openwrt-rootfs.tar.gz",
        }
        self.assertEqual(MODULE.production_manifest_state(published, candidate), "published")

        stale = controlled_manifest()
        stale["artifact"] = {
            **stale["artifact"],
            "url": f"https://github.com/t0fox/z2kOW/releases/download/openwrt-{SOURCE_C}/openwrt-rootfs.tar.gz",
        }
        with self.assertRaisesRegex(ValueError, "advanced beyond the candidate baseline"):
            MODULE.production_manifest_state(stale, candidate)

    def test_technical_release_is_published_as_prerelease_and_never_latest(self) -> None:
        publisher = (ROOT / "scripts/openwrt/publish_release.sh").read_text(encoding="utf-8")
        self.assertRegex(publisher, r"(?s)gh release create .*?--draft --prerelease --latest=false")
        self.assertRegex(publisher, r"(?s)gh release edit .*?--draft=false --prerelease --latest=false")
        self.assertIn('--title "$TECHNICAL_TITLE"', publisher)
        self.assertIn("--latest\n", publisher)

    def test_technical_release_tag_uses_the_exact_full_source_sha(self) -> None:
        self.assertEqual(MODULE.technical_release_tag(SOURCE_B), f"openwrt-{SOURCE_B}")
        with self.assertRaisesRegex(ValueError, "full lowercase SHA"):
            MODULE.technical_release_tag("b" * 39)

    def test_duplicate_source_sha_cannot_create_another_technical_release(self) -> None:
        with self.assertRaisesRegex(ValueError, "technical release already exists"):
            self.plan("hotfix", existing_technical_release=True)

    def test_hotfix_is_rejected_if_upstream_advanced(self) -> None:
        advanced = upstream_manifest("p-86.14", 137)
        with self.assertRaisesRegex(ValueError, r"Upstream version advanced to p-86\.14.*новый Product Release"):
            self.plan("hotfix", upstream=advanced)

    def test_upstream_release_is_rejected_when_current_tag_and_seq_are_already_published(self) -> None:
        with self.assertRaisesRegex(ValueError, r"p-86\.13 / seq 136 уже опубликован как пользовательская версия"):
            self.plan("upstream-release")

    def test_generated_product_and_hotfix_notes_are_russian(self) -> None:
        with patch.object(MODULE.subprocess, "run") as run:
            run.return_value.stdout = "webpanel/www/index.html\n"
            product = MODULE.product_release_notes(
                "p-86.14", 137, SOURCE_B, upstream_manifest("p-86.14", 137), controlled_manifest(), ROOT
            )
            hotfix = MODULE.hotfix_release_notes(ROOT, controlled_manifest(), SOURCE_B)
        self.assertIn("# z2kOW p-86.14", product)
        self.assertIn("Адаптация upstream z2k p-86.14 для OpenWrt.", product)
        self.assertRegex(product, "[А-Яа-яЁё]")
        self.assertRegex(hotfix, "[А-Яа-яЁё]")
        self.assertNotIn("Complete OpenWrt payload", product + hotfix)

    def test_hotfix_notes_start_at_the_payload_source_sha_in_production_manifest(self) -> None:
        with patch.object(MODULE.subprocess, "run") as run:
            run.return_value.stdout = "webpanel/www/index.html\n"
            notes = MODULE.hotfix_release_notes(ROOT, controlled_manifest(), SOURCE_B)
            self.assertEqual(
                run.call_args.args[0],
                ["git", "diff", "--name-only", f"{SOURCE_A}..{SOURCE_B}"],
            )
        self.assertIn(f"{SOURCE_A}..{SOURCE_B}", notes)
        self.assertEqual(MODULE.previous_payload_source_sha(controlled_manifest()), SOURCE_A)

    def test_hotfix_notes_describe_ci_only_changes_as_internal(self) -> None:
        with patch.object(MODULE.subprocess, "run") as run:
            run.return_value.stdout = ".github/workflows/ci.yml\ntests/openwrt/test_example.py\n"
            notes = MODULE.hotfix_release_notes(ROOT, controlled_manifest(), SOURCE_B)
        self.assertIn(MODULE.INTERNAL_ONLY_MESSAGE, notes)
        self.assertNotIn("Обновлена логика", notes)

    def test_openwrt_installer_changes_are_not_hidden_as_release_infrastructure(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            repository = Path(temp)
            subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
            subprocess.run(["git", "config", "user.name", "Release Notes Test"], cwd=repository, check=True)
            subprocess.run(["git", "config", "user.email", "release-notes@example.invalid"], cwd=repository, check=True)
            installer = repository / "scripts/openwrt/install_release.sh"
            installer.parent.mkdir(parents=True)
            installer.write_text("#!/bin/sh\necho old\n", encoding="utf-8")
            subprocess.run(["git", "add", "scripts/openwrt/install_release.sh"], cwd=repository, check=True)
            subprocess.run(["git", "commit", "-qm", "baseline"], cwd=repository, check=True)
            previous_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()

            installer.write_text("#!/bin/sh\necho new\n", encoding="utf-8")
            subprocess.run(["git", "add", "scripts/openwrt/install_release.sh"], cwd=repository, check=True)
            subprocess.run(["git", "commit", "-qm", "installer change"], cwd=repository, check=True)
            source_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()

            manifest = controlled_manifest()
            manifest["artifact"]["url"] = (
                f"https://github.com/t0fox/z2kOW/releases/download/openwrt-{previous_sha}/openwrt-rootfs.tar.gz"
            )
            notes = MODULE.hotfix_release_notes(repository, manifest, source_sha)

        self.assertIn("Обновлена интеграция z2kOW с OpenWrt.", notes)
        self.assertNotIn(MODULE.INTERNAL_ONLY_MESSAGE, notes)

    def test_technical_release_title_never_uses_the_product_version(self) -> None:
        title = MODULE.technical_release_title(SOURCE_B)
        self.assertEqual(title, f"OpenWrt payload {SOURCE_B[:7]}")
        self.assertNotIn("p-86.13", title)
        self.assertRegex(MODULE.technical_release_tag(SOURCE_B), r"^openwrt-[0-9a-f]{40}$")

    def test_trust_chain_and_immutability_gates_remain_required(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        publish = workflow.split("  publish-release:", 1)[1]
        publisher = (ROOT / "scripts/openwrt/publish_release.sh").read_text(encoding="utf-8")
        policy = MODULE_PATH.read_text(encoding="utf-8")
        for required in (
            "Z2KOW_RELEASE_PRIVATE_KEY",
            "Z2KOW_IMMUTABILITY_TOKEN",
            "scripts/openwrt/sign_release.py verify",
        ):
            self.assertIn(required, publish)
        self.assertIn("name: openwrt-production", publish)
        self.assertIn("scripts/openwrt/check_immutable_releases.py", publisher)
        self.assertIn('cmp -s "$ARTIFACT" "$public_assets/openwrt-rootfs.tar.gz"', publisher)
        self.assertIn('sha256sum "$public_assets/openwrt-rootfs.tar.gz"', publisher)
        self.assertIn("isImmutable", publisher)
        self.assertIn("isImmutable", policy)

    def test_retry_publish_reuses_candidate_and_verifies_existing_releases_idempotently(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        verify_ci = workflow.split("  verify-source-ci:", 1)[1].split("  prepare-release:", 1)[0]
        prepare = workflow.split("  prepare-release:", 1)[1].split("  publish-release:", 1)[0]
        publish = workflow.split("  publish-release:", 1)[1]
        publisher = (ROOT / "scripts/openwrt/publish_release.sh").read_text(encoding="utf-8")
        self.assertIn("retry-publish", workflow)
        self.assertIn("candidate_run_id", workflow)
        self.assertNotIn("retry-publish", verify_ci)
        self.assertNotIn("retry-publish", prepare)
        self.assertIn("actions/download-artifact", publish)
        self.assertIn("isImmutable", publisher)
        self.assertIn("gh release view", publisher)
        self.assertIn('if [[ "$artifact_state" == missing ]]', publisher)
        self.assertIn('if [[ "$product_state" == missing ]]', publisher)
        self.assertIn("no CI or build jobs were rerun", publish)

    def test_published_release_requires_immutable_flag_and_exact_metadata(self) -> None:
        record = {
            "tagName": f"openwrt-{SOURCE_B}",
            "name": f"OpenWrt payload {SOURCE_B[:7]}",
            "targetCommitish": SOURCE_B,
            "isPrerelease": True,
            "isDraft": False,
            "isImmutable": True,
            "isLatest": False,
            "body": "Техническое обновление OpenWrt.\n",
        }
        self.assertEqual(
            MODULE.validate_release_record(
                record,
                tag=f"openwrt-{SOURCE_B}",
                title=f"OpenWrt payload {SOURCE_B[:7]}",
                target_commit=SOURCE_B,
                prerelease=True,
                latest=False,
                notes="Техническое обновление OpenWrt.\n",
            ),
            "published",
        )
        record["isImmutable"] = False
        with self.assertRaisesRegex(ValueError, "not immutable"):
            MODULE.validate_release_record(
                record,
                tag=f"openwrt-{SOURCE_B}",
                title=f"OpenWrt payload {SOURCE_B[:7]}",
                target_commit=SOURCE_B,
                prerelease=True,
                latest=False,
                notes="Техническое обновление OpenWrt.\n",
            )

    def test_release_metadata_rejects_wrong_type_latest_target_and_description(self) -> None:
        record = {
            "tagName": f"openwrt-{SOURCE_B}",
            "name": f"OpenWrt payload {SOURCE_B[:7]}",
            "targetCommitish": SOURCE_B,
            "isPrerelease": True,
            "isDraft": False,
            "isImmutable": True,
            "isLatest": False,
            "body": "Русское описание.\n",
        }
        args = {
            "tag": f"openwrt-{SOURCE_B}",
            "title": f"OpenWrt payload {SOURCE_B[:7]}",
            "target_commit": SOURCE_B,
            "prerelease": True,
            "latest": False,
            "notes": "Русское описание.\n",
        }
        for field, value, message in (
            ("isPrerelease", False, "isPrerelease"),
            ("isLatest", True, "Latest status"),
            ("targetCommitish", "f" * 40, "targetCommitish"),
            ("body", "English generic payload release", "body"),
        ):
            changed = dict(record)
            changed[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, message):
                MODULE.validate_release_record(changed, **args)

    def test_candidate_metadata_rejects_a_hotfix_that_changes_product_version(self) -> None:
        candidate = self.plan("hotfix")
        candidate["tag"] = "p-86.14"
        candidate["seq"] = 137
        with self.assertRaisesRegex(ValueError, "preserve the base product tag and sequence"):
            MODULE.validate_candidate_metadata(
                candidate, source_sha=SOURCE_B, requested_tag="p-86.14", requested_seq=137
            )


if __name__ == "__main__":
    unittest.main()
