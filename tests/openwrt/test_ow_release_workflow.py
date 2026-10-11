#!/usr/bin/env python3
"""Проверяет сборку, подпись, публикацию и проверку релиза OpenWrt."""

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

    def test_release_identity_is_bound_to_the_official_branch_manifest_and_git_tag(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        validate = workflow.split("  validate-release:", 1)[1].split("  verify-source-ci:", 1)[0]
        controlled = (ROOT / "scripts/openwrt/controlled_release.py").read_text(encoding="utf-8")
        self.assertIn("refs/heads/z2k-enhanced", validate)
        self.assertIn('"refs/tags/$RELEASE_TAG_INPUT"', validate)
        self.assertIn("verify-upstream-tag", validate)
        self.assertGreaterEqual(workflow.count("verify-upstream-tag"), 2)
        self.assertIn("UPSTREAM_BRANCH = \"z2k-enhanced\"", controlled)
        self.assertIn("проверенный Git-тег upstream", validate)

    def test_production_workflow_checks_production_key_id_before_publishing(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        signing = workflow.split("- name: Sign and verify the exact final manifest", 1)[1]
        self.assertIn('manifest.get("signing", {}).get("key_id") != key_id', signing)
        self.assertIn("--public-key \"$key_file\"", signing)
        self.assertIn("scripts/openwrt/sign_release.py verify", signing)

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

    def test_complete_per_arch_candidate_is_accepted_before_upload_and_before_signing(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        prepare = workflow.split("  prepare-release:", 1)[1].split("  publish-release:", 1)[0]
        publish = workflow.split("  publish-release:", 1)[1]
        self.assertLess(
            prepare.index("accept_release_candidate.py"),
            prepare.index("uses: actions/upload-artifact"),
        )
        self.assertLess(
            publish.index("candidate-acceptance.json"),
            publish.index("Sign and verify the exact final manifest"),
        )
        self.assertIn("needs.prepare-release.result == 'success'", workflow)
        self.assertIn('"$RUNNER_TEMP/openwrt-release-candidate"', prepare)
        self.assertIn('"$RUNNER_TEMP/openwrt-release-candidate"', publish)
        self.assertIn('--artifact-dir "$RUNNER_TEMP/openwrt-release-candidate"', publish)

    def test_transition_fallback_uses_checked_baseline_and_is_carried_by_the_candidate(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        prepare = workflow.split("  prepare-release:", 1)[1].split("  publish-release:", 1)[0]
        publish = workflow.split("  publish-release:", 1)[1]
        copied_baseline = prepare.index('cp UPDATES.json "$RUNNER_TEMP/production-UPDATES.json"')
        controlled_copy = prepare.index('cp "$RUNNER_TEMP/controlled-UPDATES.json" UPDATES.json')
        self.assertLess(copied_baseline, controlled_copy)
        self.assertIn('migration-fallback \\\n            --manifest "$RUNNER_TEMP/production-UPDATES.json"', prepare)
        self.assertIn('--production-baseline "$RUNNER_TEMP/production-UPDATES.json"', prepare)
        self.assertIn('include_legacy_fallback', prepare)
        self.assertIn("include_legacy_fallback=", publish)
        self.assertIn("sed -n 's/^include_legacy_fallback=//p'", publish)
        self.assertIn("candidate_run_id", publish)

    def test_openwrt_ci_runs_all_checks_without_skipping_dependencies(self) -> None:
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        job = ci.split("  openwrt-unified:", 1)[1]
        self.assertIn("lighttpd", job)
        self.assertIn("curl", job)
        self.assertIn("platform/openwrt/runtime-pin", job)
        self.assertIn("sha256sum -c", job)
        self.assertIn('OW_STRICT=1 Z2K_RT_TARBALL="$runtime_archive" sh tests/openwrt/run.sh', job)
        self.assertLess(job.index("sha256sum -c"), job.index("OW_STRICT=1"))

    def test_openwrt_ci_attaches_per_arch_records_before_candidate_acceptance(self) -> None:
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        job = ci.split("  openwrt-unified:", 1)[1]
        build = job.index("build-release.sh")
        attach = job.index("controlled_release.py attach", build)
        acceptance = job.index("accept_release_candidate.py", attach)
        self.assertIn('cp UPDATES.json "$RUNNER_TEMP/production-UPDATES.json"', job)
        self.assertIn("migration-fallback", job)
        self.assertIn("--legacy-rootfs", job)
        self.assertIn('--artifact-dir "$RUNNER_TEMP/openwrt-candidate"', job)
        self.assertIn('--source-sha "$GITHUB_SHA"', job)
        self.assertIn('--production-baseline "$RUNNER_TEMP/production-UPDATES.json"', job)
        self.assertLess(build, attach)
        self.assertLess(attach, acceptance)

    def test_openwrt_ci_requires_an_upgrade_from_the_previous_published_release(self) -> None:
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        job = ci.split("  openwrt-unified:", 1)[1]
        self.assertIn("scripts/openwrt/upgrade-acceptance.sh", job)
        self.assertIn('"$RUNNER_TEMP/production-UPDATES.json"', job)
        self.assertIn('"$RUNNER_TEMP/openwrt-candidate/UPDATES.json"', job)
        self.assertLess(job.index("accept_release_candidate.py"), job.index("scripts/openwrt/upgrade-acceptance.sh"))
        self.assertLess(job.index("scripts/openwrt/upgrade-acceptance.sh"), job.index("uses: actions/upload-artifact"))

    def test_tmpfs_transition_is_required_for_every_engine_that_stages_in_tmp(self) -> None:
        acceptance = (ROOT / "tests/openwrt/accept_release_upgrade.py").read_text(encoding="utf-8")
        verifier = (ROOT / "scripts/openwrt/verify_upgrade_acceptance.py").read_text(encoding="utf-8")
        self.assertIn('legacy_installer = "z2k_ow_manifest_select_artifact" not in previous_release_text', acceptance)
        self.assertIn('previous_requires_disk_transition = previous_uses_tmpfs_install_staging(previous_paths_text)', acceptance)
        self.assertIn('return "Z2K_OW_INSTALL_TMP:-/tmp/z2kow-install-stage" in paths_text', acceptance)
        self.assertIn("if previous_requires_disk_transition:", acceptance)
        self.assertIn('"previous_stage_default": "tmpfs" if previous_requires_disk_transition else "persistent"', acceptance)
        self.assertIn('previous_stage_default == "tmpfs" and scenarios.get("legacy_tmpfs_refusal") is not True', verifier)

    def test_openwrt_ci_keeps_the_p8617_to_r865_disk_transition_regression(self) -> None:
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        job = ci.split("  openwrt-unified:", 1)[1]
        self.assertIn("772b8a0892966a1894b6cc8957f4bad843534ac5/UPDATES.json", job)
        self.assertIn("e5d287ab336eaa971ccaaecac730b94bead9e925/UPDATES.json", job)
        self.assertIn("795f272182eaed49ae0bb90269a477c89bdb7491cf5d3924d40526dea2ec1d4d", job)
        self.assertIn("b052e35dae2a19e1f5afe7934e860e8dbd65de2f6f424e43986ecdb6e7dbb112", job)
        self.assertIn("legacy-tmpfs-transition", job)

    def test_publish_blocks_signing_without_previous_installer_upgrade_receipt(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        publish = workflow.split("  publish-release:", 1)[1]
        self.assertIn("scripts/openwrt/verify_upgrade_acceptance.py", publish)
        self.assertIn('upgrade-acceptance.json', publish)
        self.assertLess(
            publish.index("Sign and verify the exact final manifest"),
            publish.index("scripts/openwrt/upgrade-acceptance.sh"),
        )
        self.assertLess(
            publish.index("scripts/openwrt/upgrade-acceptance.sh"),
            publish.index("verify_upgrade_acceptance.py"),
        )
        self.assertLess(
            publish.index("verify_upgrade_acceptance.py"),
            publish.index("run: bash scripts/openwrt/publish_release.sh"),
        )

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

    def test_candidate_plan_output_is_parsed_as_json_not_treated_as_a_path(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        prepare = workflow.split("  prepare-release:", 1)[1].split("  publish-release:", 1)[0]
        self.assertIn("plan_json, candidate_path, manifest_path, source_sha, baseline_path = sys.argv[1:]", prepare)
        self.assertIn("candidate = json.loads(plan_json)", prepare)
        self.assertNotIn('candidate = json.load(open(plan_json', prepare)

    def test_publish_verifies_the_full_release_and_commits_only_controlled_updates(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        publisher = (ROOT / "scripts/openwrt/publish_release.sh").read_text(encoding="utf-8")
        self.assertIn("controlled_release.py sync", workflow)
        self.assertIn("build-release.sh", workflow)
        self.assertIn("controlled_release.py attach", workflow)
        self.assertIn("sign_release.py", workflow)
        self.assertIn("sign_release.py verify", workflow)
        self.assertIn("--artifact-dir", workflow)
        self.assertIn('openwrt-rootfs-{arch}.tar.gz', (ROOT / "scripts/openwrt/controlled_release.py").read_text(encoding="utf-8"))
        self.assertIn("openwrt-rootfs.tar.gz", (ROOT / "scripts/openwrt/controlled_release.py").read_text(encoding="utf-8"))
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
        self.assertIn('--source-sha "$GITHUB_SHA"', workflow)
        self.assertIn('openwrt-rootfs-{arch}.tar.gz', (ROOT / "scripts/openwrt/controlled_release.py").read_text(encoding="utf-8"))
        self.assertIn('--legacy-rootfs', workflow)
        self.assertIn('openwrt-rootfs-<arch>.tar.gz', builder)
        self.assertIn('TECHNICAL_TAG="$(python3', publisher)
        self.assertIn('[[ "$TECHNICAL_TAG" == "openwrt-$SOURCE_SHA" ]]', publisher)
        self.assertIn('--target "$SOURCE_SHA"', publisher)
        self.assertIn("steps.revalidate.outputs.source_sha || github.sha", workflow)
        self.assertIn("candidate artifact URL is not bound to its exact source commit", workflow)
        self.assertNotIn('TECHNICAL_TAG="$EXPECTED_TAG"', publisher)

    def test_unsigned_candidate_builder_binds_artifact_url_to_source_commit(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        self.assertIn("--source-sha", workflow)

    def test_public_artifact_verification_keeps_the_canonical_filename(self) -> None:
        publisher = (ROOT / "scripts/openwrt/publish_release.sh").read_text(encoding="utf-8")

        self.assertIn('for asset in "${RELEASE_ASSETS[@]}" UPDATES.json UPDATES.json.sig', publisher)
        self.assertIn('"$release_url/$asset?nocache=$(date +%s%N)"', publisher)
        self.assertIn('-o "$public_assets/$asset"', publisher)
        self.assertIn('sign_release.py" verify', publisher)
        self.assertIn('--artifact-dir "$public_assets"', publisher)
        self.assertIn('compare_release_assets', publisher)

    def test_draft_asset_verification_lists_releases_instead_of_tag_lookup(self) -> None:
        publisher = (ROOT / "scripts/openwrt/publish_release.sh").read_text(encoding="utf-8")
        verifier = publisher.split("verify_release_asset_names()", 1)[1].split(
            "compare_release_assets()", 1
        )[0]

        self.assertIn('releases?per_page=100', verifier)
        self.assertIn('release.get("tag_name") == sys.argv[2]', verifier)
        self.assertNotIn('releases/tags/$tag', verifier)

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
