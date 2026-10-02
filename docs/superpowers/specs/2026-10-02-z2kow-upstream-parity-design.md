# z2kOW Upstream Parity Audit and Documentation Design

**Date:** 2026-10-02
**Status:** Draft for review
**Target:** z2kOW on OpenWrt, compared with `necronicle/z2k` branch `z2k-enhanced`

## Goal

Complete an evidence-backed audit of z2kOW against current upstream z2k, covering installation, updates, runtime features, configuration, web panel, state, migrations, binaries, release trust, rollback, and platform adapters. Deliver a parity matrix and correct repository documentation so it describes the current production model. This task changes documentation only; it does not change product code, release tooling, or tests.

## Context and constraints

- The selected checkout is `E:\codex\2026-10-01\d\work\z2kOW`, branch `main`.
- The checkout already has user changes in `scripts/openwrt/install.sh` and `tests/openwrt/test_ow_installer.sh`, plus untracked CI/test material. These are pre-existing input and must be preserved.
- Use the current upstream branch and commit identified during the audit. Record the exact revision and audit date so the matrix can be reproduced.
- Inspect actual z2kOW source, workflows, release metadata, tests, and docs. Do not infer behavior from filenames or documentation alone.
- OpenWrt production delivery is intended to remain `signed UPDATES.json -> verified artifact -> staging -> install_release -> health check -> commit or rollback`; documentation should describe the implementation as found, and flag mismatches rather than silently asserting the intended design is already true.
- Preserve correct OpenWrt ports and adapter behavior. The audit may recommend code changes, but this task will not implement them.
- Only update or remove documentation. Do not modify shell, Lua, Go, JavaScript, CSS, JSON manifests, workflows, tests, generated artifacts, or binaries.

## Audit method

Compare upstream and z2kOW by behavior and user-visible function. Cover at minimum:

- bootstrap, fresh install, reinstall, dependency preflight, generation, and installation validation;
- patch/reinstall classification, release manifest, artifact production, signature/hash/size checks, staging, and updater behavior;
- user-data ownership, config and list preservation, backup/restore, migrations, idempotency, release state, downgrade handling, rollback, and service recovery;
- zapret2/nfqws2 installation and architecture selection, plus any other shipped architecture-specific runtime binaries;
- web panel pages, actions, backend/config behavior, status and error reporting;
- OpenWrt adapters for init/service management, packages, paths/layout, firewall/netfilter, WAN/interface detection, and network integration;
- CI/release workflows and documentation accuracy, including obsolete production APK/feed instructions.

For every behavior, inspect the upstream source and the corresponding z2kOW implementation. Consult tests for evidence of intended and exercised behavior. Record exact file/function references and relevant test names. Classify each row as `same`, `partial`, `missing`, or `OpenWrt-specific`. An OpenWrt-specific difference must identify the platform dependency and the adapter implementing it. If source and documentation disagree, report the source as observed behavior and mark the document stale.

The parity matrix must include: category, upstream behavior and source, z2kOW behavior and source, parity status, evidence/tests, Keenetic-specific dependency if any, OpenWrt adaptation, and recommended follow-up. Separate confirmed parity from claims that have not been verified.

## Documentation work

After the audit, update the repository to have one canonical source of truth for:

- how production installation and updates work;
- what the release artifact contains and how the router verifies it;
- which data and paths are user-owned, release-owned, or platform-owned;
- what happens during convergence, migration, health checks, and rollback;
- how upstream revisions are synchronized and how parity differences are documented.

Update conflicting docs to link to the canonical explanation. Remove documents that describe the retired APK/feed production architecture as current. Preserve historical records only when clearly labeled as historical and useful for provenance; do not retain obsolete instructions that could lead an operator to use the retired flow. Do not delete code, test fixtures, workflow history, release evidence, or generated binaries.

## Deliverables

1. A complete, evidence-backed parity matrix in the repository with the upstream revision/date.
2. A prioritized findings summary that distinguishes existing parity, partial/missing behavior, justified OpenWrt adaptations, and unverified claims.
3. Updated canonical install/update/release/trust/ownership/rollback/upstream-sync documentation.
4. Removal or historical relabeling of obsolete APK/feed production documentation.
5. A concise audit report listing documentation changes and code-level gaps left unchanged by this documentation-only scope.

## Acceptance criteria

- Every requested subsystem is represented in the parity matrix with source references and evidence.
- Every OpenWrt-specific difference names the platform need and corresponding adapter or states that no adapter was found.
- Matrix statuses are evidence-based; no “same” status rests only on naming or an undocumented assumption.
- Current production docs consistently describe the signed artifact flow and do not instruct users to install production z2kOW packages from an APK/feed.
- The canonical documentation explains trust, data ownership, rollback, and upstream synchronization in one place, with other docs linking to it.
- Obsolete docs are removed only after their unique useful facts have been moved or explicitly retained as historical context.
- Product code, release artifacts, tests, and all pre-existing working-tree changes remain untouched.

## Non-goals

- Implementing parity gaps in product code or changing the OpenWrt installer/updater.
- Changing manifest schemas, signatures, artifact content, CI, or release classification.
- Adding or running tests as part of this documentation-only task.
- Reworking the web panel or replacing existing OpenWrt adapters.
