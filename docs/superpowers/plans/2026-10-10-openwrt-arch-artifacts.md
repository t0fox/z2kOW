# OpenWrt per-architecture artifacts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement independent tasks in parallel, with disjoint file ownership, then do a root integration/review pass. Work in the existing `main` checkout as requested; do not create a worktree. This checkout is shared: workers must not stage, commit, reset, or otherwise change Git state; the primary agent owns integration and any final commit.

**Goal:** Make OpenWrt installation and updates select one architecture archive and complete safely on a 128 MiB OpenWrt system while preserving one signed manifest and the current transaction model.

**Architecture:** Build seven deterministic archives from one staged rootfs, each containing common files and one architecture’s binaries. Store their signed records in `UPDATES.json`; retain the full archive only when the checked production baseline is still legacy-only. Centralize installed-manifest selection/digest access, and make bootstrap plus `install_release` preflight the combined live tmpfs/RAM budget before any installed-file mutation.

**Tech Stack:** POSIX shell and BusyBox `ash`/`tar`, Python 3 standard library, Go release builds, Ed25519/OpenSSL, GitHub Actions, QEMU/KVM with OpenWrt x86_64.

**Spec:** `docs/superpowers/specs/2026-10-10-openwrt-arch-artifacts-design.md`

## Global Constraints

- Keep one schema-1 signed `UPDATES.json` as the only release metadata authority.
- Support `arm64`, `arm`, `x86_64`, `x86`, `mips`, `mipsel`, and `riscv64`; each archive contains common files plus only its target binaries in all three binary trees.
- Use the full legacy `artifact` only in the first migration release; new clients use it only when `artifacts` is entirely absent, and fail closed for an incomplete per-arch map.
- Preserve the one `install_release(tag)` path, OpenWrt adapters, upstream z2k update model, config paths, ownership, signature verification, rollback, and boot recovery; do not introduce APKs or a second installer.
- Verify signed metadata and archive length/SHA-256 before extraction. Check current `MemAvailable`, tmpfs and overlay before stopping services or mutating the active installation.
- On 128/256 MiB paths account for the simultaneous archive, staging, bootstrap engine, metadata/index, other temporary data, and safety reserve; re-check after allocations against current free memory and tmpfs.
- Keep tar handling and shell interfaces compatible with BusyBox/OpenWrt; avoid a stateful cross-process tar-index cache.

## Review Focus

1. A present but incomplete `artifacts` map must fail closed instead of selecting the legacy archive — pin in the manifest-selection tests.
2. Malformed URL, filename, size, digest, or unsupported architecture must not start a download/extraction — pin in manifest and bootstrap tests.
3. Legacy-only, transition, and per-arch-only signed documents must select exactly the intended asset — pin in signing and bootstrap tests.
4. An archive that fits by itself but whose archive + stage + engine/index + reserve exceeds current `MemAvailable` or tmpfs must fail before stopping services — pin in memory-budget and unified-release tests.
5. Interrupted downloads, wrong hashes, Dashboard reinstall, and transaction/boot failures must preserve the active release, receipt, configuration, and ownership — pin in bootstrap, Dashboard, rollback, and recovery tests.

---

## File ownership and interfaces

- **Build artifacts:** `scripts/openwrt/rootfs_bundle.py` and `build-release.sh` own deterministic archive contents and names. `stage-rootfs.sh` continues to provide the complete seven-architecture input tree; change it only if implementation proves the input layout requires it.
- **Release metadata/publication:** `controlled_release.py`, `sign_release.py`, `publication_policy.py`, `publish_release.sh`, `accept_release_candidate.py`, and release/CI workflows own the seven records, optional bridge record, signatures, and uploaded assets.
- **Installed selection:** `platform/openwrt/manifest.sh` owns selected-record validation and digest compatibility. It provides `z2k_ow_manifest_select_artifact <manifest> <arch>`, setting validated globals `Z2K_OW_ARTIFACT_MODE`, `Z2K_OW_ARTIFACT_FILENAME`, `Z2K_OW_ARTIFACT_URL`, `Z2K_OW_ARTIFACT_SHA256`, `Z2K_OW_ARTIFACT_SIZE_BYTES`, and (when available) `Z2K_OW_ARTIFACT_UNPACKED_SIZE_BYTES`. It also owns the validated hotfix digest accessor. `release.sh` and `release_state.sh` consume these helpers and do not parse `artifact.sha256` directly.
- **Bootstrap:** `scripts/openwrt/install.sh` must resolve the same canonical architecture, enforce the same map/fallback rule and validate the selected fields before download. It necessarily has a standalone pre-engine parser; tests pin its behavior to the manifest library contract.
- **Installer budgets/transaction:** bootstrap and `platform/openwrt/release.sh` own checks for combined live tmpfs/RAM and overlay. They reuse the one downloaded archive and preserve existing transaction and recovery functions.
- **Integration measurements:** a temporary OpenWrt 25.12.5 x86_64 QEMU guest, booted with 128 MiB and 256 MiB, exercises the actual BusyBox installer. It is a full OpenWrt guest, not a physical router.

**Parallel order:** Tasks 1 and 2 have disjoint files and can run in parallel. After both define the archive and selector contracts, Tasks 3 and 4 can run in parallel. Task 5 follows Task 4; Task 6 follows all code tasks. Agents work only in their assigned files and never use Git staging/commits; the primary agent resolves shared-file integration and reviews the complete diff on `main`.

## Tasks

### Task 1: Build one deterministic rootfs archive per architecture

**Files:**
- Modify: `scripts/openwrt/rootfs_bundle.py`
- Modify: `scripts/openwrt/build-release.sh`
- Test: `tests/openwrt/test_ow_payload_bundle.py`
- Test: `tests/openwrt/test_ow_unified_architecture.py`

**Interface:** extend `build_rootfs_bundle(staged_root: Path, output: Path, arch: str | None = None)`. With an architecture, retain common entries and filter every `linux-*` payload under the three specified binary roots to exactly `linux-<arch>`; with no architecture, preserve legacy full-bundle behavior for transition builds.

- [ ] Add fixtures for all seven architecture names, shared files, and binaries in all three roots. Assert each per-arch tar has common files, its own binaries, no other `linux-*` entries, and remains deterministic.
- [ ] Run `python3 tests/openwrt/test_ow_payload_bundle.py`; confirm the new assertions fail against the current all-arch bundle.
- [ ] Implement the optional architecture filter without changing metadata normalization, user-data exclusions, safe symlink rules, or existing default behavior.
- [ ] Update `build-release.sh` to emit `openwrt-rootfs-<arch>.tar.gz` for all seven keys from the single staged root; emit `openwrt-rootfs.tar.gz` only when the migration caller requests the transition fallback.
- [ ] Run `python3 tests/openwrt/test_ow_payload_bundle.py` and `python3 tests/openwrt/test_ow_unified_architecture.py`; confirm every required target executable appears in its own archive.
- [ ] Return the builder and test changes for integration; do not stage or commit from the worker.

### Task 2: Normalize per-arch manifest selection and digest consumers

**Files:**
- Modify: `platform/openwrt/manifest.sh`
- Modify: `platform/openwrt/release_state.sh`
- Modify: `platform/openwrt/release.sh`
- Test: `tests/openwrt/test_ow_release_map.sh`
- Test: `tests/openwrt/test_ow_manifest_signing.sh`
- Test: `tests/openwrt/test_ow_hotfix_panel.sh`

**Interfaces:** implement the selector/global contract in “File ownership and interfaces.” When `artifacts` is absent, it validates and returns legacy `artifact`; when `artifacts` exists, it requires the requested key and never falls back. Provide a dedicated manifest-library hotfix digest accessor so `release_state.sh` keeps its current hotfix meaning without reading JSON paths itself.

- [ ] Add tests for legacy-only, transition, and per-arch-only manifests; check the exact returned URL/SHA/size and that an invalid or missing per-arch key fails despite a valid legacy `artifact`.
- [ ] Add hotfix digest tests and a source-level assertion that `release.sh`/`release_state.sh` do not parse `artifact.sha256` directly; reserve receipt comparison for Task 4’s unified installer test.
- [ ] Run `sh tests/openwrt/test_ow_release_map.sh`, `sh tests/openwrt/test_ow_manifest_signing.sh`, and `sh tests/openwrt/test_ow_hotfix_panel.sh`; confirm failures identify the missing selected-record behavior.
- [ ] Implement the central accessors in `manifest.sh`; route release validation, download metadata, receipt comparison, and hotfix digest reads through those accessors. Preserve strict URL validation and schema-1 legacy behavior.
- [ ] Run the same tests plus `python3 tests/openwrt/test_ow_unified_architecture.py`; confirm legacy and per-arch manifest/digest paths pass.
- [ ] Return the manifest/runtime changes for integration; do not stage or commit from the worker.

### Task 3: Make signatures and candidate publication cover every archive

**Files:**
- Modify: `scripts/openwrt/controlled_release.py`
- Modify: `scripts/openwrt/sign_release.py`
- Modify: `scripts/openwrt/publication_policy.py`
- Modify: `scripts/openwrt/publish_release.sh`
- Modify: `tests/openwrt/accept_release_candidate.py`
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release-openwrt.yml`
- Test: `tests/openwrt/test_ow_release_signing.py`
- Test: `tests/openwrt/test_ow_publication_policy.py`
- Test: `tests/openwrt/test_ow_release_workflow.py`

**Interface:** records under `artifacts.<arch>` use `filename`, immutable release `url`, lowercase `sha256`, `size_bytes`, and `unpacked_size_bytes`. Before replacing workspace `UPDATES.json` with a new upstream manifest, the workflow derives `include_legacy_fallback` from `RUNNER_TEMP/production-UPDATES.json`: true only when that checked baseline has no `artifacts`; candidate validation rejects a fallback in later releases and requires it for the transition candidate. Retries reuse the exact candidate and the same decision.

- [ ] Add Python tests attaching seven records, validating actual size/SHA for each, signing/verifying the complete JSON, rejecting altered/missing/extra/mismatched assets, and covering both migration baseline states.
- [ ] Run `python3 tests/openwrt/test_ow_release_signing.py`, `python3 tests/openwrt/test_ow_publication_policy.py`, and `python3 tests/openwrt/test_ow_release_workflow.py`; confirm the new per-arch cases fail.
- [ ] Update candidate acceptance and release workflow receipts to enumerate/verify all seven per-arch files plus the optional transition archive; sign one `UPDATES.json` after all asset records are attached.
- [ ] Update publisher upload, re-download, compare, and public-URL verification for the exact asset set; keep the manifest/signature and immutable release checks unchanged.
- [ ] Change candidate acceptance to take `UPDATES.json` and an artifact directory, then run it against a synthetic signed candidate containing all seven per-arch assets and the optional transition archive.
- [ ] Return candidate/signing/publication changes for integration; do not stage or commit from the worker.

### Task 4: Select the architecture in bootstrap and budget the combined live peak

**Files:**
- Modify: `scripts/openwrt/install.sh`
- Modify: `platform/openwrt/release.sh`
- Modify: `tests/openwrt/test_ow_memory_budget.sh`
- Modify: `tests/openwrt/test_ow_bootstrap_engine.sh`
- Modify: `tests/openwrt/test_ow_unified_release.sh`

**Interface:** both paths resolve the same canonical architecture and artifact tuple. The pre-download requirement is `archive_bytes + unpacked_target_bytes + measured_engine/index_upper_bound + reserve`; compare it to current `MemAvailable` and `df` free bytes. After download/index/engine allocations, re-check remaining stage + reserve using current `MemAvailable` and tmpfs free bytes. Keep overlay preflight before transaction activation and service stop.

- [ ] Add fixtures with 128 MiB and 256 MiB `MemTotal` plus varied current `MemAvailable`; assert an archive that fits alone but not the combined peak fails before download/mutation as appropriate, and a post-download reservation failure leaves active files/services/receipt unchanged.
- [ ] Add bootstrap cases for each manifest generation, target-arch URL selection, truncated transfer, wrong SHA, and no extraction before checksum success. Assert the fake server observes one selected-arch URL only.
- [ ] Run `sh tests/openwrt/test_ow_memory_budget.sh`, `sh tests/openwrt/test_ow_bootstrap_engine.sh`, and `sh tests/openwrt/test_ow_unified_release.sh`; confirm the new assertions fail against current behavior.
- [ ] Implement checked target selection, exact compressed-size/SHA verification before extraction, combined budget checks against current memory/tmpfs, and cleanup of partial downloads; avoid a second full archive copy.
- [ ] Verify after extraction that all three binary roots contain only the target architecture and every required target executable is present; keep existing tar safety checks and BusyBox-compatible behavior.
- [ ] Run the focused tests plus `sh tests/openwrt/test_ow_archive_validation.sh`; confirm invalid archive data still fails before active installation changes.
- [ ] Return bootstrap, budget, and extraction changes for integration; do not stage or commit from the worker.

### Task 5: Preserve Dashboard reinstall, rollback, and boot recovery on selected records

**Files:**
- Modify: `tests/openwrt/test_ow_webpanel_cgi.sh`
- Modify: `tests/openwrt/test_ow_transaction_faults.sh`
- Modify: `tests/openwrt/test_ow_boot_recovery.sh`
- Modify: `tests/openwrt/test_ow_unified_architecture.py`
- Modify production code only if these flows expose a gap: `platform/openwrt/release.sh`, `platform/openwrt/webpanel.sh`

- [ ] Add regression cases that route Dashboard reinstall and ordinary update through the selected artifact for the same tag, preserve configuration/ownership, and update the digest receipt only at transaction commit.
- [ ] Add fault-injection cases for power-loss boundaries with a per-arch receipt; after recovery require either the old complete release or the new complete release, never a mixed tree.
- [ ] Run `sh tests/openwrt/test_ow_webpanel_cgi.sh`, `sh tests/openwrt/test_ow_transaction_faults.sh`, and `sh tests/openwrt/test_ow_boot_recovery.sh`; confirm the per-arch cases fail or show any missing route.
- [ ] Make only the narrow runtime fix required by a failing test; keep one `install_release(tag)` entry point and existing recovery ordering.
- [ ] Run those tests plus `python3 tests/openwrt/test_ow_unified_architecture.py`; verify all adapter entry points remain present and route to the shared release installer.
- [ ] Return regression coverage and any targeted compatibility fix for integration; do not stage or commit from the worker.

### Task 6: Measure the built artifacts and run full OpenWrt QEMU installs

**Files:**
- Create only if needed for repeatability: `tests/openwrt/run_qemu_install_measurement.sh`
- Create: `docs/superpowers/plans/openwrt-arch-artifacts-measurements.md` or a test artifact report adjacent to the plan

- [ ] Build a candidate with all seven archives and verify each archive digest, selected payload bytes, and absence of foreign architecture binaries in all three roots.
- [ ] Measure the baseline installer on the same OpenWrt 25.12.5 x86_64 ext4 guest and the new candidate using the official image `generic-ext4-combined.img.gz` (SHA-256 `23e2538e8ab0eb52dfed1c65d608ecdb71ffd432dd54885da138ae67cd9e4461`), QEMU `-m 128M` and `-m 256M`. Keep guest disk and test key ephemeral under `/tmp`.
- [ ] In each guest, record initial and minimum `MemAvailable`, peak `/tmp` bytes, archive/staging/engine/index/reserve attribution, overlay used/free before and after, elapsed install time, and final release readiness. Confirm the guest downloads only `openwrt-rootfs-x86_64.tar.gz` and installed rootfs has no non-x86_64 binaries.
- [ ] Exercise actual bootstrap and `install_release` update/reinstall in the guest; use Dashboard CGI dispatch for reinstall, and run the recovery path after an injected interruption. Keep synthetic constrained-tmpfs/overlay and other architecture tests in the normal shell suite.
- [ ] Run `sh tests/openwrt/run.sh` and the CI-equivalent release/payload gates; report actual per-arch sizes, QEMU resource/time measurements, test totals, and the explicit distinction between QEMU and physical-router evidence.
- [ ] Review the full diff and commit the integrated result on `main` only after all verification is complete; do not alter production `UPDATES.json` or claim a production signature without the protected signing key.
