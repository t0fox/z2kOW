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
        self.assertIn("p-86.13", workflow)
        self.assertIn('default: "136"', workflow)
        self.assertIn("refs/heads/main", workflow)
        self.assertIn("workflow_call:", ci)
        self.assertIn("uses: ./.github/workflows/ci.yml", workflow)

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
        validate = workflow.split("  validate-release:", 1)[1].split("  ci:", 1)[0]
        ci = workflow.split("  ci:", 1)[1].split("  prepare-release:", 1)[0]
        prepare = workflow.split("  prepare-release:", 1)[1].split("  publish-release:", 1)[0]
        publish = workflow.split("  publish-release:", 1)[1]
        self.assertIn("steps.validate.outputs.tag", validate)
        self.assertIn("steps.validate.outputs.seq", validate)
        self.assertIn("steps.validate.outputs.key_id", validate)
        self.assertIn("steps.validate.outputs.upstream_commit", validate)
        self.assertIn("id: validate", validate)
        self.assertIn("needs: validate-release", ci)
        self.assertIn("needs: [validate-release, ci]", prepare)
        self.assertIn("needs: [validate-release, prepare-release]", publish)
        self.assertIn("needs.validate-release.outputs.tag", publish)
        self.assertIn("needs.validate-release.outputs.seq", publish)

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
        self.assertLess(publish.index("Reconfirm the upstream release before production signing"), publish.index("Sign and verify the exact final manifest"))

    def test_publish_verifies_the_full_release_and_commits_only_controlled_updates(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        self.assertIn("controlled_release.py sync", workflow)
        self.assertIn("build-release.sh", workflow)
        self.assertIn("controlled_release.py attach", workflow)
        self.assertIn("sign_release.py", workflow)
        self.assertIn("sign_release.py verify", workflow)
        self.assertIn("openwrt-rootfs.tar.gz", workflow)
        self.assertIn("UPDATES.json.sig", workflow)
        self.assertIn("gh release create", workflow)
        self.assertIn("gh release upload", workflow)
        self.assertIn("gh release edit", workflow)
        self.assertIn("raw.githubusercontent.com/$GITHUB_REPOSITORY/main", workflow)
        self.assertIn("scripts/openwrt/check_immutable_releases.py", workflow)
        self.assertIn("git add -- UPDATES.json UPDATES.json.sig", workflow)
        self.assertIn('git config user.name "t0fox"', workflow)
        self.assertIn('git config user.email "t0fox@yandex.ru"', workflow)
        self.assertNotRegex(workflow, r"(?i)z2k-(?:adapter|webpanel|zapret2-runtime|warp-runtime).*\.apk")

    def test_immutable_gate_uses_a_dedicated_read_token_and_preserves_api_errors(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        publish = workflow.split("  publish-release:", 1)[1]

        self.assertIn("Z2KOW_IMMUTABILITY_TOKEN", publish)
        self.assertIn("GH_TOKEN: ${{ github.token }}", publish)
        self.assertIn("Z2KOW_IMMUTABILITY_TOKEN: ${{ secrets.Z2KOW_IMMUTABILITY_TOKEN }}", publish)
        self.assertIn("scripts/openwrt/check_immutable_releases.py", publish)
        self.assertIn("actions: read", publish)
        self.assertIn("contents: write", publish)
        self.assertNotRegex(publish, r"(?im)^\s+administration:\s*(?:write|read)")
        self.assertNotIn("2>/dev/null || printf 'false'", publish)
        self.assertNotIn("--jq '.enabled'", publish)

    def test_publish_can_reuse_the_previously_approved_candidate_without_rerunning_ci(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        ci = workflow.split("  ci:", 1)[1].split("  prepare-release:", 1)[0]
        prepare = workflow.split("  prepare-release:", 1)[1].split("  publish-release:", 1)[0]
        publish = workflow.split("  publish-release:", 1)[1]

        self.assertIn("retry-publish", workflow)
        self.assertIn("candidate_run_id", workflow)
        self.assertIn("inputs.candidate_run_id", ci)
        self.assertIn("inputs.candidate_run_id", prepare)
        self.assertIn("always()", publish)
        self.assertIn("run-id:", publish)
        self.assertIn("actions/runs/$CANDIDATE_RUN_ID/jobs", publish)


if __name__ == "__main__":
    unittest.main()
