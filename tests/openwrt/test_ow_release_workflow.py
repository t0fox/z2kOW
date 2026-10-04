#!/usr/bin/env python3
"""The trusted OpenWrt release path builds, signs, publishes, and verifies one payload."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ReleaseWorkflowTests(unittest.TestCase):
    def test_release_has_one_setup_and_publish_workflow_on_main(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("operation:", workflow)
        self.assertIn("initialize-signing", workflow)
        self.assertIn("upstream-release", workflow)
        self.assertIn("hotfix", workflow)
        self.assertIn("retry-publish", workflow)
        self.assertNotIn('default: p-86.13', workflow)
        self.assertIn("refs/heads/main", workflow)
        self.assertIn("workflow_call:", ci)
        self.assertNotIn("uses: ./.github/workflows/ci.yml", workflow)
        self.assertIn("verify-source-ci:", workflow)
        self.assertIn("actions: read", workflow)
        self.assertIn("scripts/openwrt/verify_source_ci.py", workflow)

    def test_production_signing_is_environment_gated_and_never_artifacted_as_plaintext(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        self.assertIn("name: openwrt-production", workflow)
        self.assertIn("Z2KOW_RELEASE_PRIVATE_KEY", workflow)
        self.assertIn("Z2KOW_RELEASE_KEY_ID", workflow)
        self.assertIn("pynacl==1.6.2", workflow)
        self.assertIn("sealed-secret.json", workflow)
        artifact_step = workflow.split("- uses: actions/upload-artifact", 1)[1].split("- name:", 1)[0]
        self.assertIn("sealed-secret.json", artifact_step)
        self.assertNotIn("private.pem", artifact_step)
        self.assertNotIn("echo \"$Z2KOW_RELEASE_PRIVATE_KEY\"", workflow)
        initialize = workflow.split("  initialize-signing:", 1)[1].split("  validate-release:", 1)[0]
        self.assertIn("trap 'rm -f \"$private_key\"' EXIT", initialize)
        self.assertNotIn("UPSTREAM.json", workflow)

    def test_prepare_outputs_are_wired_into_sign_and_publish_jobs(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        validate = workflow.split("  validate-release:", 1)[1].split("  verify-source-ci:", 1)[0]
        verify_ci = workflow.split("  verify-source-ci:", 1)[1].split("  prepare-release:", 1)[0]
        prepare = workflow.split("  prepare-release:", 1)[1].split("  publish-release:", 1)[0]
        publish = workflow.split("  publish-release:", 1)[1]
        self.assertIn("steps.validate.outputs.tag", validate)
        self.assertIn("steps.validate.outputs.seq", validate)
        self.assertIn("steps.validate.outputs.key_id", validate)
        self.assertIn("steps.validate.outputs.upstream_commit", validate)
        self.assertIn("id: validate", validate)
        self.assertIn("needs: validate-release", verify_ci)
        self.assertIn("actions: read", verify_ci)
        self.assertIn("needs: [validate-release, verify-source-ci]", prepare)
        self.assertIn("needs: [validate-release, prepare-release]", publish)
        self.assertIn("needs.validate-release.outputs.tag", publish)
        self.assertIn("needs.validate-release.outputs.seq", publish)
        self.assertIn("steps.validate.outputs.plan", validate)
        self.assertIn("candidate-info --candidate", publish)

    def test_shared_ci_accepts_and_verifies_only_valid_signed_manifest_shape(self) -> None:
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn('"signing"', ci)
        self.assertIn('"key_id"', ci)
        self.assertIn("UPDATES.json.sig", ci)
        self.assertIn("pkeyutl", ci)

    def test_release_rechecks_live_upstream_after_candidate_build_and_before_signing(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        prepare = workflow.split("  prepare-release:", 1)[1].split("  publish-release:", 1)[0]
        publish = workflow.split("  publish-release:", 1)[1]
        self.assertLess(prepare.index("build-release.sh"), prepare.index("Reconfirm the upstream release did not advance while OpenWrt was building"))
        self.assertLess(publish.index("Reconfirm live upstream current and exact pinned tag before production signing"), publish.index("Sign and verify the exact final manifest"))

    def test_candidate_plan_is_loaded_from_the_json_file_not_parsed_as_a_path(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        prepare = workflow.split("  prepare-release:", 1)[1].split("  publish-release:", 1)[0]
        self.assertIn('candidate = json.load(open(plan_path, encoding="utf-8"))', prepare)
        self.assertNotIn("candidate = json.loads(plan_path)", prepare)

    def test_publish_verifies_the_full_release_and_commits_only_controlled_updates(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        publisher = (ROOT / "scripts/openwrt/publish_release.sh").read_text(encoding="utf-8")
        self.assertIn("controlled_release.py sync", workflow)
        self.assertIn("build-release.sh", workflow)
        self.assertIn("controlled_release.py attach", workflow)
        self.assertIn("sign_release.py", workflow)
        self.assertIn("sign_release.py verify", workflow)
        self.assertIn("openwrt-rootfs.tar.gz", workflow)
        self.assertIn("UPDATES.json.sig", workflow)
        self.assertIn("gh release create", publisher)
        self.assertIn("gh release upload", publisher)
        self.assertIn("gh release edit", publisher)
        self.assertIn("raw.githubusercontent.com/$REPOSITORY/main", publisher)
        self.assertIn("scripts/openwrt/check_immutable_releases.py", publisher)
        self.assertIn("git -C \"$ROOT\" add -- UPDATES.json UPDATES.json.sig", publisher)
        self.assertIn('git -C "$ROOT" config user.name "t0fox"', publisher)
        self.assertIn('git -C "$ROOT" config user.email "t0fox@yandex.ru"', publisher)
        self.assertNotRegex(workflow, r"(?i)z2k-(?:adapter|webpanel|zapret2-runtime|warp-runtime).*\.apk")

    def test_artifact_release_uses_internal_source_commit_tag_without_changing_user_version(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        builder = (ROOT / "scripts/openwrt/build-release.sh").read_text(encoding="utf-8")
        publisher = (ROOT / "scripts/openwrt/publish_release.sh").read_text(encoding="utf-8")
        self.assertIn(
            '--url "https://github.com/t0fox/z2kOW/releases/download/openwrt-$_source_sha/openwrt-rootfs.tar.gz"',
            builder,
        )
        self.assertIn('TECHNICAL_TAG="$(python3', publisher)
        self.assertIn('[[ "$TECHNICAL_TAG" == "openwrt-$SOURCE_SHA" ]]', publisher)
        self.assertIn('--target "$SOURCE_SHA"', publisher)
        self.assertIn("steps.revalidate.outputs.source_sha || github.sha", workflow)
        self.assertIn("candidate artifact URL is not bound to its exact source commit", workflow)
        self.assertNotIn('TECHNICAL_TAG="$EXPECTED_TAG"', publisher)

    def test_unsigned_candidate_builder_binds_artifact_url_to_source_commit(self) -> None:
        builder = (ROOT / "scripts/openwrt/build-release.sh").read_text(encoding="utf-8")

        self.assertIn('_source_sha="${GITHUB_SHA:-$(git -C "$ROOT" rev-parse HEAD)}"', builder)
        self.assertIn(
            '--url "https://github.com/t0fox/z2kOW/releases/download/openwrt-$_source_sha/openwrt-rootfs.tar.gz"',
            builder,
        )

    def test_public_artifact_verification_keeps_the_canonical_filename(self) -> None:
        publisher = (ROOT / "scripts/openwrt/publish_release.sh").read_text(encoding="utf-8")

        self.assertIn('for asset in openwrt-rootfs.tar.gz UPDATES.json UPDATES.json.sig', publisher)
        self.assertIn('"$release_url/$asset?nocache=$(date +%s%N)"', publisher)
        self.assertIn('-o "$public_assets/$asset"', publisher)
        self.assertEqual(publisher.count('--artifact "$public_assets/openwrt-rootfs.tar.gz"'), 2)
        self.assertIn('sha256sum "$public_assets/openwrt-rootfs.tar.gz"', publisher)

    def test_immutable_gate_uses_a_dedicated_read_token_and_preserves_api_errors(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        publish = workflow.split("  publish-release:", 1)[1]
        publisher = (ROOT / "scripts/openwrt/publish_release.sh").read_text(encoding="utf-8")

        self.assertIn("Z2KOW_IMMUTABILITY_TOKEN", publish)
        self.assertIn("GH_TOKEN: ${{ github.token }}", publish)
        self.assertIn("Z2KOW_IMMUTABILITY_TOKEN: ${{ secrets.Z2KOW_IMMUTABILITY_TOKEN }}", publish)
        self.assertIn("scripts/openwrt/check_immutable_releases.py", publisher)
        self.assertIn("actions: read", publish)
        self.assertIn("contents: write", publish)
        self.assertNotRegex(publish, r"(?im)^\s+administration:\s*(?:write|read)")
        self.assertNotIn("2>/dev/null || printf 'false'", publish)
        self.assertNotIn("--jq '.enabled'", publish)

    def test_publish_can_reuse_the_previously_approved_candidate_without_rerunning_ci(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        verify_ci = workflow.split("  verify-source-ci:", 1)[1].split("  prepare-release:", 1)[0]
        prepare = workflow.split("  prepare-release:", 1)[1].split("  publish-release:", 1)[0]
        publish = workflow.split("  publish-release:", 1)[1]

        self.assertIn("retry-publish", workflow)
        self.assertIn("candidate_run_id", workflow)
        self.assertNotIn("retry-publish", verify_ci)
        self.assertNotIn("retry-publish", prepare)
        self.assertIn("always()", publish)
        self.assertIn("run-id:", publish)
        self.assertIn("actions/runs/$CANDIDATE_RUN_ID/jobs", publish)
        self.assertIn('conclusions.get("verify-source-ci") != "success"', publish)


if __name__ == "__main__":
    unittest.main()
