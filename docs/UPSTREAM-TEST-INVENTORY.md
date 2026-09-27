# Upstream QA and suite inventory

This records how the p-86.1 upstream-doctrine audit maps onto the repository test
architecture. Counts compare the audit baseline `f19a2087e2f238f912b08b556d744dbdbd3f6dcd`
with the current worktree; the final GitHub Actions result is authoritative for
the committed candidate.

## File and scenario counts

| Inventory | Baseline | Current | Change |
|---|---:|---:|---:|
| Root shell suites (`tests/test_*.sh`) | 225 | 224 | -1 |
| OpenWrt shell suites (`tests/openwrt/test_ow_*.sh`) | 104 | 105 | +1 |
| Go `*_test.go` files | 110 | 103 | -7 |
| Counted shell and Go test files | 439 | 432 | -7 |
| Go `Test*` functions | 506 | 519 | +13 |
| Lua test/support files | 11 | 11 | 0 |
| JavaScript harness files | 3 | 3 | 0 |
| BDD feature files | 1 | 1 | 0 |

The shell/Go file counts exclude Lua, JavaScript, and BDD files, shown
separately. The seven-file reduction comes from deleting two same-harness WARP
files, moving the external-backend test into its owning engine suite, and
consolidating domainroute and edgepick tests; the unique-strategy workflow adds
one root shell suite. The OpenWrt sync fixture adds one shell suite. The 13 Go
test functions above baseline include the health/readiness and handshake cases,
vendored WireGuard drift guard, multi-IP detector tests, and common-target flag
tests.

The full file-level inventory is [`docs/UPSTREAM-TEST-SUITES.tsv`](UPSTREAM-TEST-SUITES.tsv):
459 rows, comprising 447 current suites/harnesses and 12 baseline-only files
that were merged. Its columns are runtime, subject, harness, named
properties/cases, overlap assessment and KEEP/MERGE action. The 447 current
entries break down to 329 POSIX shell suites, 103 Go test files, 10 Lua suites,
one Lua support harness, three JavaScript harnesses and one BDD feature.
`properties_or_cases` records assertion labels where available and otherwise
points to suite comments/fixtures; it indexes executable tests rather than
replacing them. MERGE appears on both retired source and surviving destination
rows so the consolidation history is auditable.

Baseline CI run `36193710584` on the baseline SHA passed all 14 workflow jobs.
Its shell runner reported 226 suites, 4254 passed, 0 failed, and 1 skip; its
mutation job killed 18 mutants with 0 survivors and 0 stale anchors. The first
implementation candidate, run `36257219152` on
`34c1a375b4b713d7514497e8449d58c1d7797327`, passed all 14 jobs and reported
224 shell suites, 4255 passed, 0 failed, and 1 skipped; mutation coverage was
21 killed, 0 survived, and 0 stale. That skip was
`test_release_manifest_complete.sh`, which lacked upstream p-85.9/p-85.10
history refs. The workflow now fetches those signed tags, and the final audit
candidate below ran with strict skip handling and no skips.

CI run `36277663748` validated the final implementation candidate at exact
`HEAD` `11519dd47f8580d46144514b494d235b7f85e09b`: all 14 jobs passed. The
shell runner reported 224 suites, 4288 passed, 0 failed, and 0 skipped. The
mutation job killed all 32 planned mutants, with 0 survivors and 0 stale
anchors. This includes the new WARP migration ordering and installer,
uninstaller, and scheduler dispatch mutations.

The same exact-HEAD CI run passed Go formatting, vet, race tests,
cross-compilation and the OpenWrt-tagged WireGuard overlay. Its OpenWrt 25.12.5
`mediatek/filogic` SDK job built real APKs, generated `packages.adb` with SDK
tools, checked ephemeral feed-signature acceptance/rejection, resolved and
installed packages in an isolated root, and upgraded the pinned snapshot.
The uploaded CI snapshot artifact was
`z2k-openwrt-CI-SNAPSHOT-11519dd47f8580d46144514b494d235b7f85e09b.zip`,
SHA-256 `57fe700c7f0167a1beadd5e098ba6f3a0294af4675e87fd53205cc73c4a213d3`.
This is CI candidate evidence, not a production feed publication. A subsequent
docs-only commit records these results; its own exact-HEAD CI run is the final
repository verdict.

The earlier local OpenWrt shell verification at the inventory checkpoint
reported 3180 passed and 0 failed. It skipped checks that require a committed
tree, the pinned runtime tarball, or host
`lighttpd`/`curl`; repository CI supplies those inputs and runs with strict
skip handling. A separate local root-shell run reports 224 suites, 3991
assertions passed, 0 assertion failures, 11 skipped, and four suite process
failures because `lua` is unavailable (`test_circular_core`,
`test_detector_persistence`, `test_discord_tls_timeout`, and
`test_profile_observation`). The workflow installs Lua 5.3; these four suites
must be judged from repository CI. No local Go tests or package/release builds
were run. Build and Go-test claims are derived only from repository CI runs on
the exact commit SHA being described; CI status for the docs/workflow commit is
visible in its GitHub Actions run.

## Test consolidation decisions

| Subject | Before | After | Shared harness and preserved behavior | Decision |
|---|---|---|---|---|
| WARP game refresh | `test_warp_missing_not_an_error.sh` (4 assertions) plus `test_warp_games.sh` | Missing-game cases are in `test_warp_games.sh` (4 assertions; suite is 41/0 locally) | Same updater, temporary lists, source index, and refresh lifecycle. Ordinary list failures remain failures. | MERGE |
| WARP registration retry | `test_warp_register_retry.sh` (11 assertions) | Registration/retry cases are in `test_warp_script.sh` (16 assertions) | Same WARP script sandbox, daemon/init stubs, and selfheal lifecycle. Added checks cover relay ordering, suppression window, disabled mode, and centralized registration. | MERGE |
| External network backend | `internal/engine/netsetup_test.go` | Scenario is in `internal/engine/engine_test.go` | Same engine fixtures; checks network ownership through ready, shutdown, transport cleanup, and transient status removal. | MERGE |
| Domain routing | 6 ordinary files / 19 tests, plus 1 OpenWrt-tagged file / 5 tests | `domainroute_test.go` / 19 tests, plus unchanged `nft_pairset_test.go` / 5 tests | DNS parsing, packet decode, observation, cache, expiry, client PairSet, and rules share the package fixtures. The tagged nft overlay remains separate because it runs under a different build constraint. | MERGE; tagged suite KEEP |
| Edge selection | 3 files / 12 tests | `edgepick_test.go` / 12 tests | WAN-scoped cache, probe/metadata, and candidate ranking use one package and test server/filesystem harness. | MERGE |
| Package delivery | Existing package/static suites | Remain separate from runtime suites | Artifact membership, SDK pins, package metadata, modes, and feed closure are static/package properties, not substitutes for runtime behavior. | KEEP |

## Behavioral checks and static contracts

The four suites changed in this pass had 14 implementation-shape checks
removed: four updater-convergence greps, one AU wiring grep, two detector
source-inspection checks, and seven MSS source/literal checks. They now have
zero such checks. This is a scoped before/after count for those four reviewed
suites, not a repository-wide grep count. The MSS suite retains one legitimate
cross-language configuration invariant (`MTU 1280` implies `MSS 1240`) and
executes the real NDM hook with isolated iptables/ipset stubs to inspect the
commands it issues. AU convergence injects an actual replace failure and
checks both the refusal result and preservation of old bytes; AU compatibility
executes `au_run_apply` for an addressable patch with `reset_state=true` and
checks that the reset step runs before the version advances. Detector
packet/state behavior is exercised by the production Lua harness in CI; the
wiring suite keeps delivery and configuration checks only.

The WARP installer suite went from 22 grep-shaped assertions to 35 assertions,
with 16 old implementation checks removed and six static delivery/ownership
guards retained. Refresh, uninstall and scheduler behavior execute production
helpers in temporary directories: installed-engine gating and migration order,
failure propagation into rollback, preservation of recovery controls after a
failed remove, stale download ownership, and the 25-second selfheal cadence.
The fixture also extracts and executes the real refresh, uninstall and scheduler
dispatch statements, so deleting a production call site fails the suite. The existing
`test_warp_script.sh` also exercises migration through both the explicit migrate
command and the ipset refresh path, including injected list, NDM, package and
filesystem failures. These cases share their established WARP subject and
fixture; no per-bug test files were added.

The retained static guards protect properties whose truth is source/package
structure: ownership and forbidden-file maps, package membership/exclusions,
immutable refs and dependency/version pins, release-workflow wiring, secret
absence, install destinations and architecture mappings. Tests that extract a
production function and execute it against fixtures are behavioral checks,
even when `sed`/`awk` isolates the function. A raw count of `grep`, `[ -f ]` or
`sed` occurrences is not an implementation-check metric: many inspect fixture
output or a genuinely static packaging contract.

Targeted local shell verification after these edits:

| Suite | Result |
|---|---:|
| `test_au_converge.sh` | 22 passed, 0 failed |
| `test_au_compat.sh` | 23 passed, 0 failed |
| `test_alert_detector_wiring.sh` | 16 passed, 0 failed |
| `test_warp_mss_both_ways.sh` | 5 passed, 0 failed |
| `tests/openwrt/test_ow_env.sh` | 25 passed, 0 failed |
| `tests/openwrt/test_ow_restart.sh` | 6 passed, 0 failed |
| `tests/openwrt/test_ow_source_order.sh` | 2 passed, 0 failed |
| `tests/openwrt/test_ow_lc_update.sh` | 22 passed, 0 failed |
| `test_warp_script.sh` | 124 passed, 0 failed |
| `test_warp_install_hooks.sh` | 35 passed, 0 failed |
| `test_stale_binaries_cleanup.sh` | 12 passed, 0 failed |
| `test_scheduler_supervisor.sh` | 7 passed, 0 failed |
| `test_panel_uninstall.sh` | 27 passed, 0 failed |
| `test_install_completeness.sh` | 4 passed, 0 failed |
| `tests/test_shell_review_fixes.sh` | 15 passed, 0 failed |
| `tests/test_unique_strategy_set.sh` | 73 passed, 0 failed |
| `tests/test_strategy_pick_modes.sh` | 20 passed, 0 failed |
| `tests/test_custom_strategies.sh` | 39 passed, 0 failed |
| `tests/test_panel_auth.sh` | 82 passed, 0 failed (WSL) |
| `tests/test_webpanel_api_contract.sh` | 185 passed, 0 failed |
| `tests/test_panel_frontend_contract.sh` | 220 passed, 0 failed |
| `tests/openwrt/test_ow_warp_lifecycle.sh` | 386 passed, 0 failed |
| `tests/openwrt/test_ow_warp_functional.sh` | 84 passed, 0 failed |
| `tests/openwrt/test_ow_warp_parity.sh` | 35 passed, 0 failed |
| `tests/test_warp_install_hooks.sh` | 35 passed, 0 failed |
| `tests/openwrt/test_ow_warp_static.sh` | 94 passed, 0 failed |
| `tests/openwrt/test_ow_package.sh` | 77 passed, 0 failed |
| `tests/openwrt/test_ow_upstream_docs_sync.sh` | 9 passed, 0 failed |
| `tests/openwrt/test_ow_upstream_diff.sh` | 1 passed, 0 failed |
| `test_http_classifier.sh` | skipped locally because Lua is unavailable; CI is authoritative |

No local Go tests or package/release builds were run. Those results must come
only from repository CI.

## Auto-update suite review

The AU family was checked by behavior, state machine, and sandbox. These eight
suites remain separate because they do not share all three:

| Suite | Subject and properties | Sandbox/harness | Overlap and action |
|---|---|---|---|
| `test_auto_update_decide.sh` | Decision matrix and reinstall/reset-state flags | Isolated updater state under a temporary directory | Decision logic differs from applying a plan. KEEP |
| `test_auto_update_health.sh` | Post-update service survival and rollback decisions; remote probe failure does not roll back a good update | Stubbed service and network outcomes | Health gate is distinct from update transition logic. KEEP |
| `test_auto_update_toggle.sh` | Nightly/manual/check behavior, config toggle, CGI and dashboard status | Fake install root, real script/CGI entrypoints and test server | User-facing opt-out lifecycle differs from AU apply state. KEEP |
| `test_au_steps.sh` | Required update effects, canonical order, one-time execution, unknown-step refusal | Source-only updater with isolated manifest and stubs | Step executor contract. KEEP |
| `test_au_converge.sh` | SHA-based convergence, idempotence, missing-file repair, verify-all-before-mutation | Temporary target and repository trees | Convergence/integrity state machine differs from step execution. KEEP |
| `test_au_compat.sh` | Old manifest without `install_map` chooses safe full-install path | Separate install root and manifest fixtures | Backward-compatibility path. KEEP |
| `test_au_cleanup_step.sh` | `cleanup-ip-hosts` actually removes records | Cloned updater library and mock `ndmc` process | Different copied-source sandbox from `test_au_steps.sh`. KEEP |
| `test_au_full_install_overrides_type.sh` | `full_install` flag overrides declared patch/reinstall type | Isolated install state and stubbed network/installer | Release classification and full install path. KEEP |

This keeps the explicit AU subjects: decision, integrity/download, apply,
rollback/health, compatibility/migration, state convergence, and UI/status.
No mechanically combined AU suite was justified by a matching subject,
state-machine lifecycle, and sandbox.

## Mutation map

CI mutation coverage grows from 18 to 35 mutants. Each mutant is paired with
the behavioral suite that must fail; package and release builds remain in the
repository workflow only.

| Mutant group | Count | Behavioral suite |
|---|---:|---|
| RuTracker proxy record parsing, demotion, selection, and body proof | 8 | `rt-proxy` Go tests |
| Keenetic WARP fail-open/readiness/key/mark/selfheal/install and migration propagation | 10 | `tests/test_warp_script.sh` |
| WARP refresh gating, rollback propagation, uninstall recovery, stale downloads, scheduler cadence, dispatch wiring and bounded process replacement | 9 | `tests/test_warp_install_hooks.sh`, `tests/test_stale_binaries_cleanup.sh`, `tests/openwrt/test_ow_warp_lifecycle.sh` |
| Keenetic WARP init missing-engine, duplicate-start, MIPS guard | 3 | `tests/test_warp_init_thin.sh` |
| p-85.16 one-success readiness and periodic probe hidden by RX growth | 2 | `z2k-warpd/internal/health` Go tests via source overlay |
| p-85.16 handshake/data preamble boundaries | 2 | `z2k-warpd/internal/transport/wg` Go tests via source overlay |
| p-86 common strategy candidate must pass every pinned IP | 1 | `z2k-detect/internal/classify` Go tests via source overlay |
| OpenWrt WARP replacement skips bounded process wait | 1 | `tests/openwrt/test_ow_warp_lifecycle.sh` |

The mutation runner treats a missing source anchor and a missing verdict as a
failure. The new Go mutants use `go test -overlay` in CI so they exercise the
real module test harness without editing the checkout.

## Evidence boundaries

The test inventory does not claim packet-level return-path proof, live router
kernel/netifd/fw4 behavior, multi-hour idle behavior, or provider/WAN soak.
Those remain `PARTIAL` in `docs/UPSTREAM-CONTRACTS.md` until observed on the
target hardware. Process existence, generated rules, and a green CI run are not
used as substitutes for those dataplane observations.
