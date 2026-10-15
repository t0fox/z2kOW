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

    def test_release_gate_accepts_only_registered_not_applicable_releases_after_target(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        validate = workflow.split("  validate-release:", 1)[1].split("  verify-source-ci:", 1)[0]
        publish = workflow.split("  publish-release:", 1)[1]

        self.assertIn("--skip-registry docs/UPSTREAM-SKIPS.json", validate)
        self.assertIn('--upstream "$RUNNER_TEMP/upstream-pinned-UPDATES.json" --controlled UPDATES.json', validate)
        self.assertIn("--skip-registry docs/UPSTREAM-SKIPS.json", publish)
        self.assertIn('"docs/UPSTREAM-SKIPS.json"', publish)

    def test_post_build_upstream_check_accepts_only_registered_skips(self) -> None:
        """После сборки повторно проверяет тег через реестр пропусков upstream."""
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        check = workflow.split(
            "- name: Повторно проверить upstream перед финальной аттестацией",
            1,
        )[1].split("- uses: actions/upload-artifact", 1)[0]

        self.assertIn("verify-upstream-tag", check)
        self.assertIn("--skip-registry docs/UPSTREAM-SKIPS.json", check)
        self.assertIn("upstream-pinned-after-build-UPDATES.json", check)
        self.assertIn("upstream-refs-after-build.txt", check)
        self.assertIn("RELEASE_UPSTREAM_COMMIT", check)

    def test_release_reuses_only_verified_rust_artifacts_for_the_exact_source_ci_run(self) -> None:
        """Release берёт ABI-бинарники из проверенного CI, а при их утрате пересобирает локально."""
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        prepare = workflow.split("  prepare-release:", 1)[1].split("  publish-release:", 1)[0]

        verify_ci = workflow.split("  verify-source-ci:", 1)[1].split("  prepare-release:", 1)[0]
        self.assertIn("ci_run_id: ${{ steps.verify.outputs.ci_run_id }}", verify_ci)
        self.assertIn('CI_RUN_ID: ${{ needs.verify-source-ci.outputs.ci_run_id }}', prepare)
        self.assertIn('gh run download "$CI_RUN_ID"', prepare)
        self.assertIn('"z2kow-tg-rust-${SOURCE_SHA}-*"', prepare)
        self.assertIn('--source-sha "$SOURCE_SHA" --run-id "$CI_RUN_ID"', prepare)
        self.assertIn('build_args+=(--tg-dir "$TG_ARTIFACT_DIR")', prepare)
        self.assertIn('Z2K_TG_EXPECTED_RUN_ID: ${{ steps.tg-artifacts.outputs.ci_run_id }}', prepare)
        self.assertIn("Локальная Rust cross-сборка только при недоступности CI-артефактов", prepare)
        self.assertIn("z2kow-tg-rust-${{ github.sha }}-${{ matrix.group }}", ci)
        self.assertNotIn("gcc-aarch64-linux-gnu libc6-dev-arm64-cross", prepare)

    def test_hotfix_fast_path_reuses_only_the_exact_ci_candidate_and_skips_duplicate_acceptance(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        prepare = workflow.split("  prepare-release:", 1)[1].split("  publish-release:", 1)[0]
        publish = workflow.split("  publish-release:", 1)[1]
        fast_path = prepare.split("id: ci-hotfix-candidate", 1)[1].split("- uses: actions/setup-go", 1)[0]

        self.assertIn("if: env.RELEASE_OPERATION_INPUT == 'hotfix'", fast_path)
        self.assertIn("needs.verify-source-ci.outputs.ci_run_id", fast_path)
        self.assertIn("ci_candidate_fastpath.py fetch", fast_path)
        self.assertIn("--source-sha \"$GITHUB_SHA\"", fast_path)
        self.assertIn("--baseline UPDATES.json", fast_path)
        self.assertIn("--baseline-signature UPDATES.json.sig", fast_path)
        self.assertIn("ci-hotfix-candidate.outputs.fast_path != 'true'", prepare)
        self.assertIn('if [ "${{ steps.ci-hotfix-candidate.outputs.fast_path }}" = true ]; then', prepare)
        self.assertIn("ci-fastpath-attestation.json", publish)
        self.assertIn("ci_candidate_fastpath.py verify-final", publish)
        self.assertIn("Sign and verify the exact final manifest", publish)
        self.assertIn("Publish immutable technical payload and optional Product Release", publish)

    def test_fastpath_verifier_binds_ci_artifact_digest_and_acceptance_receipts(self) -> None:
        verifier = (ROOT / "scripts/openwrt/ci_candidate_fastpath.py").read_text(encoding="utf-8")
        self.assertIn("verify_artifact_record", verifier)
        self.assertIn("verify_downloaded_archive", verifier)
        self.assertIn("candidate-acceptance.json", verifier)
        self.assertIn("upgrade-acceptance.json", verifier)
        self.assertIn("production_signature_sha256", verifier)
        self.assertIn("release_metadata_delta", verifier)
        self.assertIn("неуспешные или пропущенные CI jobs", verifier)

    def test_fastpath_audit_is_read_only_and_does_not_sign_or_publish(self) -> None:
        audit = (ROOT / ".github/workflows/openwrt-fastpath-audit.yml").read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", audit)
        self.assertIn("actions: read", audit)
        self.assertIn("contents: read", audit)
        self.assertIn("ci_candidate_fastpath.py fetch", audit)
        self.assertNotIn("contents: write", audit)
        self.assertNotIn("Z2KOW_RELEASE_PRIVATE_KEY", audit)
        self.assertNotIn("sign_release.py", audit)
        self.assertNotIn("publish_release.py", audit)

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
            prepare.index("accept_release_matrix.py"),
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
        self.assertIn("scripts/openwrt/accept_release_matrix.py", prepare)
        self.assertIn("--jobs 4", prepare)
        self.assertNotIn("for arch in arm64 arm x86_64 x86 mips mipsel riscv64; do", prepare)
        acceptance = (ROOT / "tests/openwrt/accept_release_candidate.py").read_text(encoding="utf-8")
        matrix = (ROOT / "scripts/openwrt/accept_release_matrix.py").read_text(encoding="utf-8")
        self.assertIn('parser.add_argument("--receipt", type=Path)', acceptance)
        self.assertIn("host_arch = args.arch", acceptance)
        self.assertIn('receipt_path = args.receipt or manifest_source.parent / f"candidate-acceptance-{host_arch}.json"', acceptance)
        self.assertIn('"architecture": host_arch', acceptance)
        self.assertIn('"--receipt",', matrix)
        self.assertIn("_aggregate_receipts(manifest, artifact_dir, receipt_dir)", matrix)
        self.assertNotIn("accepted_arches.update", acceptance)

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
        self.assertIn('"$GITHUB_SHA" "$include_legacy_fallback" <<\'PY\'', prepare)
        self.assertIn('candidate.get("include_legacy_fallback") != (expected_fallback == "true")', prepare)
        self.assertNotIn('("artifacts" not in baseline)', prepare)
        self.assertIn("include_legacy_fallback=", publish)
        self.assertIn("sed -n 's/^include_legacy_fallback=//p'", publish)
        self.assertIn("candidate_run_id", publish)

    def test_openwrt_ci_runs_all_checks_without_skipping_dependencies(self) -> None:
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        acceptance = ci.split("  openwrt-acceptance:", 1)[1].split("  openwrt-unified:", 1)[0]
        planner = ci.split("  openwrt-shard-plan:", 1)[1].split("  openwrt-shell-syntax:", 1)[0]
        runtime = ci.split("  openwrt-runtime:", 1)[1].split("  openwrt-acceptance:", 1)[0]
        builder = ci.split("  openwrt-unified:", 1)[1]
        self.assertIn("fail-fast: false", acceptance)
        self.assertIn("fromJSON(needs.openwrt-shard-plan.outputs.matrix)", acceptance)
        self.assertIn("needs: [openwrt-shard-plan, openwrt-shell-syntax, openwrt-runtime]", acceptance)
        self.assertIn("--github-matrix", planner)
        self.assertIn("--report", planner)
        self.assertIn('OW_STRICT: "1"', acceptance)
        self.assertIn("OW_SKIP_SYNTAX_CHECK: \"1\"", acceptance)
        self.assertIn("OW_SHARD_COUNT: ${{ matrix.count }}", acceptance)
        self.assertIn("OW_SHARD_INDEX:", acceptance)
        self.assertIn("lighttpd", acceptance)
        self.assertIn("curl", acceptance)
        self.assertIn("z2kow-openwrt-runtime-${{ github.sha }}", runtime)
        self.assertIn("sha256sum -c", runtime)
        self.assertIn("actions/download-artifact", acceptance)
        self.assertIn("actions/download-artifact", builder)
        self.assertIn("--runtime-tarball", builder)
        self.assertIn("--runtime-acceptance-passed", builder)
        self.assertIn("build-release.sh", builder)
        self.assertIn("tg_build_artifacts.py merge", builder)
        self.assertIn('build_args+=(--tg-dir "$RUNNER_TEMP/tg-ws-proxy")', builder)
        self.assertIn('build_args+=(--go-dir "$RUNNER_TEMP/go-artifacts")', builder)
        self.assertIn("scripts/openwrt/accept_release_matrix.py", builder)
        self.assertIn("upgrade-acceptance.sh", builder)
        self.assertIn("uses: actions/upload-artifact", builder)

    def test_ci_profiles_acceptance_suites_and_runs_shellcheck_in_bounded_batches(self) -> None:
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        shellcheck = ci.split("- name: Run shellcheck", 1)[1].split(
            "- name: Syntax-check every shipped shell script", 1
        )[0]
        runner = (ROOT / "tests/openwrt/run.sh").read_text(encoding="utf-8")

        self.assertIn("find . -name '*.sh'", shellcheck)
        for path in (
            "./z2k.sh",
            "./z2k_cleanup.sh",
            "./lib/*.sh",
            "./files/*.sh",
            "./tests/*.sh",
            "./scripts/*.sh",
            "./webpanel/*.sh",
            "./webpanel/cgi/*.sh",
        ):
            self.assertIn(f"-path '{path}'", shellcheck)
        self.assertIn("-print0", shellcheck)
        self.assertIn("xargs -0 -r -P 4 -n 32 shellcheck", shellcheck)
        self.assertIn("OPENWRT-SUITE-TIME", runner)

    def test_local_full_rust_fallback_produces_a_verifiable_merged_artifact_set(self) -> None:
        builder = (ROOT / "scripts/openwrt/build_tg_ws_proxy.sh").read_text(encoding="utf-8")

        self.assertIn('_ci_run_id="${GITHUB_RUN_ID:-0}"', builder)
        self.assertIn('elif [ "$_selected_variants" = "$_all_variants" ]; then\n    _build_group=merged', builder)

    def test_ci_reuses_attested_go_artifacts_without_duplicate_cross_compilation(self) -> None:
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        builder = (ROOT / "scripts/openwrt/build-release.sh").read_text(encoding="utf-8")
        go_job = ci.split("  go:", 1)[1].split("  binaries:", 1)[0]
        warp_job = ci.split("  warp-controller:", 1)[1].split("  go:", 1)[0]
        binaries = ci.split("  binaries:", 1)[1].split("  lua-check:", 1)[0]
        shell_tests = ci.split("  tests:", 1)[1].split("  rust-tg-proxy:", 1)[0]
        openwrt_job = ci.split("  openwrt-unified:", 1)[1]

        self.assertIn("go_build_artifacts.py attest", go_job)
        self.assertIn("z2kow-go-${{ github.sha }}-${{ matrix.module }}", go_job)
        self.assertIn("needs: [go]", binaries)
        self.assertIn("go_build_artifacts.py compare-repository", binaries)
        self.assertIn("actions/download-artifact", binaries)
        self.assertIn("actions/download-artifact", shell_tests)
        self.assertNotIn("go build", shell_tests)
        self.assertIn("-buildvcs=false", go_job)
        self.assertIn("-X main.version=$release_tag", go_job)
        self.assertIn("needs: [rust-tg-proxy, warp-controller, go, openwrt-runtime, openwrt-acceptance]", openwrt_job)
        self.assertIn('variants: "arm64 x86_64 x86 riscv64"', warp_job)
        self.assertIn('variants: "arm"', warp_job)
        self.assertIn('variants: "mips"', warp_job)
        self.assertIn('variants: "mipsel"', warp_job)
        self.assertIn("warp_controller_artifacts.py verify", warp_job)
        self.assertIn("z2kow-warp-controller-${{ github.sha }}-${{ matrix.group }}", warp_job)
        self.assertIn('go_build_artifacts.py" stage', builder)
        self.assertIn('--go-dir "$RUNNER_TEMP/go-artifacts"', openwrt_job)
        self.assertIn("warp_controller_artifacts.py merge", openwrt_job)
        self.assertIn('--warp-controller-dir "$RUNNER_TEMP/warp-controller"', openwrt_job)
        self.assertIn('if [ "$_reuse_go" -eq 0 ]; then', builder)
        self.assertNotIn("go-build-v1-", openwrt_job)

    def test_openwrt_ci_attaches_per_arch_records_before_candidate_acceptance(self) -> None:
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        job = ci.split("  openwrt-unified:", 1)[1]
        build = job.index("build-release.sh")
        attach = job.index("controlled_release.py attach", build)
        acceptance = job.index("accept_release_matrix.py", attach)
        self.assertIn('cp UPDATES.json "$RUNNER_TEMP/production-UPDATES.json"', job)
        self.assertIn("migration-fallback", job)
        self.assertIn("--legacy-rootfs", job)
        self.assertIn('--artifact-dir "$RUNNER_TEMP/openwrt-candidate"', job)
        self.assertIn('--source-sha "$GITHUB_SHA"', job)
        self.assertIn('--production-baseline "$RUNNER_TEMP/production-UPDATES.json"', job)
        self.assertLess(build, attach)
        self.assertLess(attach, acceptance)
        self.assertIn("--jobs 4", job)

    def test_release_reuses_verified_warp_controller_artifacts_or_cross_builds_all_abis(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        prepare = workflow.split("  prepare-release:", 1)[1].split("  publish-release:", 1)[0]

        self.assertIn("z2kow-warp-controller-${SOURCE_SHA}-*", prepare)
        self.assertIn("warp_controller_artifacts.py merge", prepare)
        self.assertIn("Z2K_WARP_CONTROLLER_EXPECTED_RUN_ID", prepare)
        self.assertIn("build_warp_controller.sh \"$RUNNER_TEMP/warp-controller\" --test", prepare)
        self.assertIn('--warp-controller-dir "$WARP_CONTROLLER_ARTIFACT_DIR"', prepare)

    def test_openwrt_ci_requires_an_upgrade_from_the_previous_published_release(self) -> None:
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        job = ci.split("  openwrt-unified:", 1)[1]
        self.assertIn("scripts/openwrt/upgrade-acceptance.sh", job)
        self.assertIn('"$RUNNER_TEMP/production-UPDATES.json"', job)
        self.assertIn('"$RUNNER_TEMP/openwrt-candidate/UPDATES.json"', job)
        self.assertLess(job.index("accept_release_matrix.py"), job.index("scripts/openwrt/upgrade-acceptance.sh"))
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

    def test_openwrt_ci_checks_p8617_against_the_current_candidate(self) -> None:
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        job = ci.split("  openwrt-unified:", 1)[1]
        self.assertIn("772b8a0892966a1894b6cc8957f4bad843534ac5/UPDATES.json", job)
        self.assertIn("795f272182eaed49ae0bb90269a477c89bdb7491cf5d3924d40526dea2ec1d4d", job)
        self.assertIn("p-86.17 → текущий OpenWrt-кандидат", job)
        self.assertIn('"$RUNNER_TEMP/openwrt-candidate/UPDATES.json"', job)
        self.assertIn('"$RUNNER_TEMP/openwrt-candidate"', job)
        self.assertNotIn("e5d287ab336eaa971ccaaecac730b94bead9e925", job)
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
        self.assertLess(prepare.index("build-release.sh"), prepare.index("Повторно проверить upstream перед финальной аттестацией"))
        self.assertLess(publish.index("Reconfirm live upstream current and exact pinned tag before production signing"), publish.index("Sign and verify the exact final manifest"))

    def test_candidate_plan_output_is_parsed_as_json_not_treated_as_a_path(self) -> None:
        workflow = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        prepare = workflow.split("  prepare-release:", 1)[1].split("  publish-release:", 1)[0]
        self.assertIn("plan_json, candidate_path, manifest_path, source_sha, expected_fallback = sys.argv[1:]", prepare)
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
