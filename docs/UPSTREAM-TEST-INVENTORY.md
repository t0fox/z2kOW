# Upstream QA and suite inventory

This records how the p-85.16 doctrine audit maps onto the repository test
architecture. Counts compare the audit baseline `f19a2087e2f238f912b08b556d744dbdbd3f6dcd`
with the current worktree; the final GitHub Actions result is authoritative for
the committed candidate.

## File and scenario counts

| Inventory | Baseline | Current | Change |
|---|---:|---:|---:|
| Root shell suites (`tests/test_*.sh`) | 225 | 223 | -2 |
| OpenWrt shell suites (`tests/openwrt/test_ow_*.sh`) | 104 | 105 | +1 |
| Go `*_test.go` files | 110 | 102 | -8 |
| Counted shell and Go test files | 439 | 430 | -9 |
| Go `Test*` functions | 506 | 511 | +5 |
| Lua test/support files | 11 | 11 | 0 |
| JavaScript harness files | 3 | 3 | 0 |
| BDD feature files | 1 | 1 | 0 |

The shell/Go file counts exclude Lua, JavaScript, and BDD files, shown
separately. The nine-file reduction comes from deleting two same-harness WARP
files, moving the external-backend test into its owning engine suite, and
consolidating domainroute and edgepick tests. The OpenWrt sync fixture adds one
shell suite. The five added Go test functions cover two health regressions, two
handshake behaviors, and the vendored WireGuard drift contract.

Baseline CI run `36193710584` on the baseline SHA passed all 14 workflow jobs.
Its shell runner reported 226 suites, 4254 passed, 0 failed, and 1 skip; its
mutation job killed 18 mutants with 0 survivors and 0 stale anchors. The
implementation-candidate CI run `36257219152` on
`34c1a375b4b713d7514497e8449d58c1d7797327` passed all 14 jobs. Its shell
runner reported 224 suites, 4255 passed, 0 failed, and 1 skip. The skipped
`test_release_manifest_complete.sh` lacked upstream p-85.9/p-85.10 history
refs in that checkout; this audit adds a bounded fetch of those signed tags to
the shell-test workflow so that the release-history suite can run in CI. A
separate direct run with those refs present reported 4 passed, 0 failed, and
0 skipped. The mutation job killed 21 mutants with 0 survivors and 0 stale
anchors.

The same CI run passed Go formatting, vet, race tests, cross-compilation and
the OpenWrt-tagged WireGuard overlay. Its OpenWrt 25.12.5
`mediatek/filogic` SDK job built real APKs, generated `packages.adb` with SDK
tools, checked ephemeral feed-signature acceptance/rejection, resolved and
installed packages in an isolated root, and upgraded the pinned snapshot.
The uploaded CI snapshot artifact was
`z2k-openwrt-CI-SNAPSHOT-34c1a375b4b713d7514497e8449d58c1d7797327.zip`,
SHA-256 `54daea99210f3fcb0471651bef775451ccb6caacc6973b0194ad2d821dfb6653`.
This is CI candidate evidence, not a production feed publication.

Current local OpenWrt shell verification reports 3180 passed and 0 failed. It
skips checks that require a committed tree, the pinned runtime tarball, or host
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

CI mutation coverage grows from 18 to 21 mutants. Each mutant is paired with
the behavioral suite that must fail; package and release builds remain in the
repository workflow only.

| Mutant group | Count | Behavioral suite |
|---|---:|---|
| RuTracker proxy record parsing, demotion, selection, and body proof | 8 | `rt-proxy` Go tests |
| Keenetic WARP fail-open/readiness/key/mark/selfheal/install | 7 | `tests/test_warp_script.sh` |
| Keenetic WARP init missing-engine, duplicate-start, MIPS guard | 3 | `tests/test_warp_init_thin.sh` |
| p-85.16 one-success readiness and periodic probe hidden by RX growth | 2 | `z2k-warpd/internal/health` Go tests via source overlay |
| p-85.16 handshake without obfuscation preamble | 1 | `z2k-warpd/internal/transport/wg` Go tests via source overlay |

The mutation runner treats a missing source anchor and a missing verdict as a
failure. The new Go mutants use `go test -overlay` in CI so they exercise the
real module test harness without editing the checkout.

## Evidence boundaries

The test inventory does not claim packet-level return-path proof, live router
kernel/netifd/fw4 behavior, multi-hour idle behavior, or provider/WAN soak.
Those remain `PARTIAL` in `docs/UPSTREAM-CONTRACTS.md` until observed on the
target hardware. Process existence, generated rules, and a green CI run are not
used as substitutes for those dataplane observations.
