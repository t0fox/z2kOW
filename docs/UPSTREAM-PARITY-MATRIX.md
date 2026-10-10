# Upstream parity matrix

This matrix tracks material product differences between z2kOW and the pinned upstream z2k baseline. It is a design/status ledger, not a test report.

## r-86.5 / seq 141 review

- Upstream baseline: `necronicle/z2k` branch `z2k-enhanced`, commits after `295257dafdc5853ceea550d9cc5871b4b4b685b2`: `cbce12c639b239d2a0081dddad13216bacf84945`, `d2b261d22f5f9f4caa0f5a5f3b6f10a7439a7ddf`, and `43b98092c5a337a35f5c094363f469243d7b8b80`.
- The release manifest/signature and the upstream panel file are controlled surfaces. The OpenWrt trusted release workflow owns its signed manifest and stamps cache-busters from the candidate tag; neither upstream `UPDATES.json` nor `webpanel/www/index.html` is copied into z2kOW.
- The official `v1.0.5.2-z2k-r0` OpenWrt archive was checked before the runtime pin changed: 4,339,405 bytes, SHA-256 `02eec373b093083b426c27191bb6af260ac51e4e2739c51270270a351d2a1a16`, official `install_bin.sh` digest unchanged, and `nfqws2`, `ip2net`, and `mdig` present for all seven supported architectures. Host binary version/profile checks pass; they do not substitute for router packet-path acceptance.
- `DIRECT` means the shared behavior or version pin is synchronized; `ADAPTED` means the behavior is implemented through an OpenWrt-native owner; `N/A` applies only to the Keenetic mechanism with no OpenWrt counterpart; `CONFLICT` / `CONTROLLED RELEASE SURFACE` means upstream output is deliberately not copied because z2kOW's local theme or trusted release workflow owns it.

| Upstream changed path / behavior | z2kOW disposition | OpenWrt mapping and evidence |
|---|---|---|
| `files/000-zapret2.sh`: remove event-dropping debounce; preserve an event during a repair and do bounded trailing work; settle before recovery; verify NFQUEUE floor; NDM journal and stale-lock handling. | ADAPTED; NDM mechanism N/A | The NDM hook is not installed on OpenWrt. `platform/openwrt/firewall.sh::z2k_ow_fw_event` coalesces through a PID lock and pending marker, bounds attempts, reuses `z2k_ow_fw_check`, and proves the final nft state. The procd reload callback, existing iface hotplug, and 5-minute checker enter this one path. `tests/openwrt/test_ow_fw_events.sh`, `test_ow_fw_check.sh`, and `test_ow_iface.sh`. |
| `files/z2k-diag.sh`: include `/tmp/z2k-log/ndm-hook.log`. | ADAPTED | No NDM journal is read. `platform/openwrt/diag.sh` reads the native bounded `logread` ring, filters `z2k-fw4`, and emits at most 20 records without a second tmpfs log. `tests/openwrt/test_ow_diag.sh`. |
| `files/z2k-nfqueue-selfheal.sh`: reassert Keenetic `nf_conntrack_fastnat{,_xfrm}=0`. | N/A mechanism; equivalent guarantee ADAPTED | No fastnat sysctl is added. Existing fw4 global software/hardware offload ownership snapshots exact UCI values and missing options, re-disables re-enabled offload during convergence, then restores the user's original state. `tests/openwrt/test_ow_offload.sh`. |
| `lib/install.sh`: advance the embedded-runtime fallback URL/comment and synchronize its fallback NDM-hook heredoc with the event-safe source. | DIRECT for shared engine pin; N/A for NDM implementation | Fallback URL now points to the verified `v1.0.5.2-z2k-r0` archive; installer digest pin is unchanged. The inline hook is a Keenetic-only install surface and is not executed by OpenWrt. OpenWrt normal install/update/reinstall remains the signed, transactional `install_release(tag)` path; equivalent event recovery uses its existing adapter. `tests/test_install_bin_pin.sh`, `test_reasm_enabled.sh`, `test_ow_fw_events.sh`, and `tests/openwrt/test_ow_runtime_artifact.sh`. |
| `tests/test_ndm_hook_fallback_sync.sh`: ensure the NDM source and install fallback heredoc match. | N/A | This asserts a Keenetic-installed NDM hook, which OpenWrt does not install. The native OpenWrt event path has independent behavior tests. |
| `tests/test_ndm_hook_storm.sh`: replace debounce expectations with event coalescing, trailing repair, bounded reruns, and stale-lock behavior. | ADAPTED | `tests/openwrt/test_ow_fw_events.sh` exercises 20 concurrent callbacks, one active reconciler, an event during repair, a bounded retry ceiling, final verification, and the actual procd callback boundary. |
| `tests/test_nfqueue_selfheal.sh`: cover the fastnat sysctl timer. | N/A mechanism; ADAPTED coverage | No Keenetic sysctl fixture is used. OpenWrt's global `fw4` flow-offload snapshot/disable/restore contract is exercised by `tests/openwrt/test_ow_offload.sh`. |
| `tests/test_reasm_enabled.sh`: compare dotted engine versions and require the reassembly-capable fork. | ADAPTED | The requested engine pin is explicitly `v1.0.5.2-z2k-r0`; the test checks the common fallback and OpenWrt runtime pin, and keeps `--reasm-disable` out of the OpenWrt argv. The official binary dry-run/profile check is separate; no live segmented-ClientHello packet claim is made without router acceptance. |
| `UPDATES.json`: advance signed upstream current release to `r-86.5` / 141. | CONTROLLED RELEASE SURFACE; not copied | Only `.github/workflows/release-openwrt.yml` may produce the single controlled OpenWrt manifest and signature after all required gates. |
| `UPDATES.json.sig`: signature for the upstream manifest. | CONTROLLED RELEASE SURFACE; not copied | The trusted OpenWrt workflow signs its generated manifest. No production manifest or signature is hand-edited. |
| `webpanel/www/index.html`: update upstream cache-buster query values. | CONFLICT with local theme / pipeline-owned | Keep the z2kOW panel and existing release builder's tag-based asset stamping; do not copy the Keenetic page. Rootfs staging and panel contract tests verify that the builder owns cache-busting. |

This table covers all 11 paths in the complete three-commit upstream diff, including the new test. Source parity, signed publication, candidate-rootfs acceptance, and live-router acceptance are reported as separate gates; a source/test pass is not evidence of a live router dataplane pass.

Последний проверенный upstream tag: `r-86.5`, seq `141`, commit `43b98092c5a337a35f5c094363f469243d7b8b80`. Версию, опубликованную для роутеров, см. в `UPDATES.json`: её изменяет только подписанный OpenWrt-релизный процесс. Обзоры `p-86.14` и `p-86.15` ниже — исторические записи синхронизации.

Status meanings:

- `PARITY` — common upstream behavior is retained.
- `ADAPTED` — upstream behavior is retained with an OpenWrt-native platform mechanism.
- `PARTIAL` — a material part of the upstream behavior or interface is still missing or different.
- `MISSING` — no usable OpenWrt implementation exists.
- `N/A` — the capability is genuinely Keenetic-specific and has no meaningful OpenWrt equivalent.

| Area | Upstream behavior | OpenWrt implementation | Status |
|---|---|---|---|
| Fresh install | Upstream installer prepares config, runtime, services, and persistent state. | Signed OpenWrt bootstrap stages a complete payload and converges through `install_release`. | ADAPTED |
| Release authority | Upstream release history drives upstream updates. | Routers use only signed z2kOW `UPDATES.json`, which records upstream provenance and OpenWrt artifact metadata. | ADAPTED |
| Patch / reinstall semantics | Upstream distinguishes patch/reinstall and may declare steps, full-install effects, or reset behavior. | OpenWrt keeps the upstream release decision but applies releases through the OpenWrt convergence engine; any upstream lifecycle effect not yet interpreted remains a gap. | PARTIAL |
| Release state | Installed release identity is used for update decisions. | Canonical `tag + seq` state is shared by installer, updater, CLI, WebPanel, and diagnostics. | ADAPTED |
| Failure recovery | Upstream update/reinstall paths restore previous state on failure. | OpenWrt journals release-owned replacement and restores previous release state on failed convergence. | ADAPTED |
| Persistent user data | Config, custom lists, strategy state, and device data survive release replacement according to upstream rules. | Persistent data is kept under `/etc/z2k`; release-owned payload lives under `/usr/lib/z2k`. | ADAPTED |
| Config and strategies | Upstream config/strategy engine generates nfqws2 runtime behavior. | Common generator and strategy code is reused with OpenWrt path/service adapters. | PARITY |
| Core lifecycle | Keenetic init/watchdog owns the service. | procd owns OpenWrt service lifecycle. | ADAPTED |
| Firewall / WAN events | Keenetic uses NDM, iptables/ipset, and device policy APIs; automatic WAN discovery accepts any interface with a main-table default except `lo`, including routed bridges. | OpenWrt uses fw4/nftables, netifd/ubus/UCI, and hotplug; firewall and self-heal consume the shared main-route WAN probe, which accepts routed bridges and ignores policy-only/connected routes. | ADAPTED |
| Scheduled maintenance | Upstream schedules updates, list refresh, TCP16, and feature maintenance. | OpenWrt cron adapter owns equivalent jobs and removes legacy `# z2k-stats-upload` rows during schedule convergence. | ADAPTED |
| Main list refresh | Upstream geosite/list helpers refresh managed domain data. | Common list/geosite logic is shipped with OpenWrt path and service adapters. | ADAPTED |
| Remote strategy reporting | p-86.16 removes strategy upload, its operator controls, and the VPS receiver. | Removed the uploader, scheduler job, config flags, API/UI controls, and receiver. The local autocircular `telemetry.tsv` remains local state and is never sent remotely. | PARITY |
| TCP16 | Upstream probes the line, stores a verdict/map, schedules retries/nightly probing, and feeds runtime config. | Probe, detector, Lua/data payload, scheduler, persistent state, WebPanel action, and OpenWrt runtime integration are shipped as one feature path. | ADAPTED |
| Diagnostics | Upstream reports service, firewall, platform, tunnels, WARP, TCP16, and state. | Common diagnostic structure delegates platform probes to OpenWrt for procd, nftables, netifd, storage, offload, and feature state. | ADAPTED |
| Telegram transport | Upstream tunnel behavior with Keenetic firewall/service integration. | Same transport purpose through procd and nftables adapters. | ADAPTED |
| RT proxy | Upstream RT proxy with Keenetic DNS/firewall/service integration. | Same proxy purpose through OpenWrt DNS/UCI, procd, and nftables adapters. | ADAPTED |
| WARP | Upstream install/register/enable/disable, routing lists, selected clients, and fail-open/self-heal behavior. | OpenWrt uses procd, nftables marks/sets, native routing policy, and persistent device state. | ADAPTED |
| Acceleration | Upstream exposes Keenetic acceleration controls. | OpenWrt exposes its own flow-offload backend only when the platform reports the required capability. Keenetic PPE controls are not copied literally. | ADAPTED |
| WebPanel | Shared UI/actions with platform-specific effects. | Common panel is kept; filesystem/service/firewall/network effects go through OpenWrt helpers and capability gating. | ADAPTED |
| WebPanel password auth | Upstream authentication includes Keenetic-specific user/NDM integration. | OpenWrt must provide an equivalent local authentication path without falling back to `ndmc`. | PARTIAL |
| CLI/operator surface | Upstream menu exposes a broad set of maintenance actions. | `z2kow` currently exposes the core release/service commands plus selected maintenance entry points; WebPanel remains the main operator surface. | PARTIAL |
| Uninstall / removal | Upstream removal has defined preservation and optional destructive cleanup semantics. | OpenWrt has cleanup primitives, but the supported operator-facing removal flow must match upstream semantics rather than package-manager removal. | PARTIAL |
| Keenetic policy / NDM-only controls | Upstream can use Keenetic device-policy APIs that do not exist on OpenWrt. | No fake equivalent is exposed when OpenWrt has no meaningful owner for the capability. | N/A |

Update this table when upstream behavior changes or an OpenWrt gap is closed. Do not add test-run counts or temporary acceptance notes here.

## p-86.14 sync review (historical)

- z2kOW base: `10f6940b51f66b9450ade16c673c030dcd084d95`.
- Upstream base: `7f630a9d459052b9c9c9eded06298f1b8f7f0a22`.
- Upstream target: `p-86.14`, seq `137`, commit `5e058c1c3944e0f0362cf9665b84108fc6e9b3dc`.
- Live `z2k-enhanced/UPDATES.json` and the peeled `p-86.14` tag were checked before implementation; both identify p-86.14/137 and the tag commit above.

| Material upstream change | Disposition | z2kOW implementation | Evidence |
|---|---|---|---|
| `lib/wan.sh`: a main-table default on a bridge is a WAN; only `lo` is excluded; policy-only routes remain excluded. | A — portable common behavior | Kept the common route parser and removed bridge-name/sysfs exclusions. The same helper is used by firewall WAN selection and OpenWrt NFQUEUE self-heal. | `tests/test_wan_detect.sh`; `tests/test_nfqueue_selfheal.sh`; final rootfs staging check. |
| `webpanel/www/index.html`: release cache-buster moves with the upstream release. | B — preserve branded source, adapt release staging | Keep the local branded panel source intact. Stamp staged HTML/JS/CSS asset URLs from the controlled root `UPDATES.json` during the one rootfs build. No separate manifest or payload version is introduced. | `tests/test_cachebuster_declared.sh` with candidate p-86.14; `tests/openwrt/test_ow_stage_rootfs.sh` against the final tarball. |
| Upstream `UPDATES.json` and signature advance to p-86.14/137. | B — controlled release metadata | The trusted `upstream-release` pipeline derives one controlled manifest from the pinned upstream manifest and commit, then signs/publishes it; repository production `UPDATES.json` remains unchanged until that workflow publishes successfully. | `tests/openwrt/test_ow_release_workflow.py`; trusted workflow live/pinned source checks. |

## p-86.15 sync review

- z2kOW source baseline: current `main` at `3f9f8ed1cd936a2b54e6be390fd19a025304dbd2` before this sync.
- Upstream base: `p-86.14`, seq `137`, commit `5e058c1c3944e0f0362cf9665b84108fc6e9b3dc`.
- Upstream target: `p-86.15`, seq `138`, commit `b90611f52ae5ba034d0181a3252efda6ecc95671`.
- The peeled tag, live `UPDATES.json` current/seq/history/changed_files, and the complete `p-86.14..p-86.15` diff were checked. The diff contains `README.md`, `UPDATES.json`, `UPDATES.json.sig`, `lib/menu.sh`, `webpanel/www/index.html`, and `webpanel/www/js/pages/credits.js`; it adds the GregMSK sponsor acknowledgement and advances release/cache metadata. No functional runtime behavior changes are present.

| Material upstream change | Disposition | z2kOW implementation | Evidence |
|---|---|---|---|
| `UPDATES.json` and signature advance from p-86.14/137 to p-86.15/138. | B — controlled release metadata | The trusted `upstream-release` workflow derives and signs the z2kOW controlled manifest from the pinned upstream release; production `UPDATES.json` changes only as part of successful publication. | `tests/openwrt/test_ow_release_workflow.py`; published manifest/signature verification. |
| Upstream panel asset cache-buster advances to p-86.15. | B — preserve branded source, adapt release staging | Keep the z2kOW-branded panel source and stamp the staged HTML/JS/CSS asset URLs from the controlled release version. | `tests/test_cachebuster_declared.sh`; `tests/openwrt/test_ow_stage_rootfs.sh`. |
| `lib/menu.sh` and upstream credits add the GregMSK sponsor acknowledgement. | B — preserve z2kOW acknowledgement policy | Add GregMSK only to the existing disclosed upstream credits section. Keep local z2kOW credits, menu roster, and branding independent. | `tests/browser/credits-page.mjs` verifies the rendered upstream acknowledgement and separate local credits. |
| Runtime behavior between p-86.14 and p-86.15. | C — no functional delta | No runtime code is copied from this patch; p-86.14's already-adapted WAN bridge fix and current z2kOW/OpenWrt/WARP changes remain in the release source. | Full upstream tag diff; complete rootfs is built from current z2kOW `main`. |

## p-86.17: синхронизация благодарности bootnet

- База z2kOW перед синхронизацией: `main` на коммите `b699d96ec3df6495c506a05f9194ddf7eb70965b`.
- База upstream: `p-86.16`, seq `139`, commit `5a11ffd82d10578039487da2ef09210278eb06ff`.
- Цель upstream: `p-86.17`, seq `140`, commit `295257dafdc5853ceea550d9cc5871b4b4b685b2`.
- Полный диапазон содержит два указанных коммита: благодарность `bootnet` и выпускные метаданные `p-86.17`. Изменений сетевого поведения нет.

| Изменение upstream | Решение | Адаптация в z2kOW | Проверка/источник |
|---|---|---|---|
| Благодарность `bootnet` в README, CLI и панели upstream. | Сохранить раздельное авторство | Добавить карточку только в раскрываемый upstream-раздел WebPanel. Локальные README и CLI-списки z2kOW не менять. | `webpanel/www/js/pages/credits.js`; `tests/test_sponsors_in_sync.sh`; `tests/browser/credits-page.mjs`. |
| Upstream `UPDATES.json`, подпись и cache-buster переходят на `p-86.17` / 140. | Использовать контролируемый релиз z2kOW | Не копировать upstream-манифест и подпись. Опубликованный манифест, артефакт OpenWrt и версия cache-buster создаются и подписываются штатным `release-openwrt.yml`. | `RELEASING.md`; `.github/workflows/release-openwrt.yml`. |
| Runtime-изменения между `p-86.16` и `p-86.17`. | Функционального изменения нет | Код сетевой обработки не меняется. | Полный diff upstream-коммитов `9766c1933db9f9cc00526d856e35e3c7b7b7c20c..295257dafdc5853ceea550d9cc5871b4b4b685b2`. |

## p-86.16 sync review

- z2kOW source baseline: `main` at `64842d4b52896d74497efb37e2587e31cb2c8ff6`.
- Upstream base: `p-86.15`, seq `138`, commit `b90611f52ae5ba034d0181a3252efda6ecc95671`.
- Upstream target: `p-86.16`, seq `139`, commit `5a11ffd82d10578039487da2ef09210278eb06ff`.
- Complete source range: `b90611f..5a11ffd` (3 commits, 45 changed paths), including `d48ccca10b64f07fbb7953e62955c0c15cec6ef2` (remove strategy telemetry), `e91a3102cb1978e4f3f2d696d25d81d2b3136ce6` (add sponsor Кожевников), and the p-86.16 release commit.
- The pinned tag and live upstream manifest agree on p-86.16/139. Upstream `UPDATES.json` and its signature are intentionally excluded from the z2kOW source; device metadata remains controlled by the trusted OpenWrt release workflow.

| Material upstream change | Disposition | z2kOW implementation | Evidence |
|---|---|---|---|
| Remove `files/z2k-stats-upload.sh`, `webpanel/www/js/pages/telemetry.js`, `vps-stats/`, collector service, and stats receiver routes. | A — remove remote reporting end to end | Removed upload transport, notice and controls, API routes/fields, payload mapping, receiver, nginx routes, service, and collector monitoring. Historical release records remain intact. | `tests/test_strategy_telemetry_retired.sh`, API contract tests, rootfs payload checks, and VPS inventory review. |
| Remove `Z2K_STATS` / `Z2K_STATS_ACK`, menu `[C]`, the 03:00 shared scheduler entry, and remote-report UI. | A — portable behavior removal | Removed the config writer, CLI submenu, common task, panel toast, dashboard notice, and toggle. Config regeneration drops the retired keys from existing configs. | `tests/test_config_official.sh`, `tests/test_panel_frontend_contract.sh`, `tests/openwrt/test_ow_schedule.sh`, and `tests/test_strategy_telemetry_retired.sh`. |
| OpenWrt cron used a platform-owned `# z2k-stats-upload` row. | B — OpenWrt lifecycle adaptation | No replacement reporting job is created. Schedule install/remove continue to filter the retired marker so an old row disappears while unrelated crontab entries survive. | `tests/openwrt/test_ow_schedule.sh`. |
| Old router release may contain the uploader and its scheduler state under release-owned `/usr/lib/z2k` and `/opt/zapret2` paths. | B — OpenWrt release adaptation | Full payload convergence replaces those owned trees; regenerated config and cron convergence clear the other old controls. | `tests/openwrt/test_ow_unified_release.sh`, `tests/openwrt/test_ow_stage_rootfs.sh`, and `tests/test_config_official.sh`. |
| Add sponsor Кожевников to upstream acknowledgements. | B — preserve z2kOW credit ownership | Added the upstream acknowledgement to the upstream disclosure only; local README and CLI sponsor roster remain unchanged. | `tests/browser/credits-page.mjs` and `tests/test_sponsors_in_sync.sh`. |
| Clarify the difference between local strategy state and remote statistics in contributor/security documentation. | A — documentation parity | Removed the obsolete upload-risk instructions and state clearly that `telemetry.tsv` is local state with no remote reporting. | `CONTRIBUTING.md`, `SECURITY.md`, and the active-reference audit. |
| Upstream changes Keenetic init.d and NDM scheduler wiring; release metadata and cache-buster also advance. | C — platform-specific or controlled release surface | Do not port Keenetic init.d/NDM behavior. The OpenWrt scheduler remains owned by its adapter. The trusted OpenWrt release flow owns the controlled manifest, signature, artifact and staged asset cache-buster. | Full upstream path audit, `.github/workflows/release-openwrt.yml`, and OpenWrt rootfs staging tests. |
| Local autocircular state in `telemetry.tsv`. | C — keep local-only strategy memory | Preserve existing strategy rotation and diagnostics; no remote upload path consumes this file after the retirement. | Upstream diff does not modify the autocircular state code; local autocircular tests remain in the suite. |

## p-86.14 diagnostics parity review (historical)

- z2kOW diagnostic baseline: `740304002760fd4bd6b8eef7b0b2ff5b3e09f67b` (documentation-only spec commit on top of `origin/main` `a7ca0471adae5571f21d42304ee1b2aaf32885ba`).
- Upstream diagnostic contract: `necronicle/z2k` `z2k-enhanced` `p-86.14`, `5e058c1c3944e0f0362cf9665b84108fc6e9b3dc`.
- Compared the complete `files/z2k-diag.sh` files and inspected relevant full functions in both files. The full-file diff is broad because z2kOW contains platform hooks and OpenWrt additions; only portable diagnostic behavior is to be reused, never the upstream file wholesale.

| Material diagnostic behavior | Disposition | Implementation | Regression evidence |
|---|---|---|---|
| Common `ping_vps_rtt()`, `clock_skew_vs_relay()`, DNS snapshot parsing, error filtering, and address masking | A — portable common behavior | Reused the common ping/skew, DNS snapshot, error-window, and masking helpers; OpenWrt supplies its actual relay, tunnel-log, snapshot, and owned-log paths. | OpenWrt semantic fixtures plus source comparison against the pinned upstream functions. |
| Health versus network-path ownership for DNS snapshot, Insta/WhatsApp pins, and DNS backend | B — OpenWrt adaptation | Health keeps issue verdicts; network path owns DNS snapshot, OpenWrt Insta/dnsmasq records, and common AdGuard Home/DNS backend diagnostics. The same probes feed health and detailed verdicts. | Section-order and shared-verdict checks in `tests/openwrt/test_ow_diag.sh`, `tests/test_diag_dns_snapshot.sh`, and `tests/test_diag_agh_upstream.sh`. |
| Telegram live relay probes and log tail | B — OpenWrt adaptation | OpenWrt adapter proves the exact `:1443` process, then common tunnel output adds the upstream three-packet ping, loss, relay skew threshold, owned log path, and masked recent tail. | PID versus `:1444`, ping/loss, skew boundary, and log-tail assertions in `tests/openwrt/test_ow_diag.sh`. |
| Autocircular chosen-strategy rows | B — retain existing OpenWrt detection, restore common rendering | `_ow_autocircular_detect()` retains the active PID/runtime state path; rendering supports persistent/fallback/runtime override state and upstream full/report row caps without counting comments as entries. | State selection and full/report row semantics in `tests/openwrt/test_ow_diag_states.sh`. |
| Incoming/outgoing NFQUEUE proof and owned traffic counters | B — OpenWrt nftables adaptation | `z2k_ow_fw_verify()` remains the canonical table/set/hook/chain/qnum contract. Diagnostics prove reachable owned OUT/IN paths, exact queue consumer PID, and packets/bytes from only the owned queue rules. | Wrong qnum, foreign fw4, missing hook, owned counters, consumer, and zero-traffic coverage in `tests/openwrt/test_ow_diag_firewall.sh` and `tests/openwrt/test_ow_fw_check.sh`. |
| Live `nfqws2` PID/cmdline, strategy/pool counts, and procd state | C — equivalent already exists | Common/OpenWrt service diagnostics already inspect live process state and procd; preserve the existing `/proc` and override semantics rather than porting older process greps. | Existing `tests/openwrt/test_ow_diag_states.sh` and current service/runtime checks remain green. |
| Insta/WhatsApp managed-host pins and dnsmasq runtime attachment | C — equivalent probe exists; B — presentation | `platform/openwrt/diag.sh::print_insta()` keeps its registration, runtime addn-hosts, refresh, and user-disabled probes in `network path`; the records hook reads OpenWrt `ip host` output without Keenetic `ndmc`. | Registered/runtime-config/user-disabled/refresh and report order cases in `tests/openwrt/test_ow_diag.sh` and `tests/test_diag_agh_upstream.sh`. |
| AdGuard Home / DNS backend relationship to delivered pins | B — OpenWrt adaptation | Common `print_agh()` is called by OpenWrt network path and includes OpenWrt config locations; it evaluates the relevant upstream/rewrite/local-resolver paths without treating `rewrites=0` by itself as failure. | OpenWrt records hook and supported backend config cases in `tests/test_diag_agh_upstream.sh`. |
| WARP routing detail behind `route_ready` | B — OpenWrt adaptation; preserve existing readiness truth | `warp_status_routing_ready()` and detailed diagnostics consume the same `warp_status_routing_proofs()` result for TUN interface, nft mark, PBR rule/route, and owner record. Health reads the resulting `route_ready`. | Missing TUN/route/mark and complete-ready cases with matching health/details in `tests/openwrt/test_ow_diag_warp_route.sh` and `tests/openwrt/test_ow_warp_status.sh`. |
| All current OpenWrt subsystem logs through upstream aggregation | B — OpenWrt paths over common algorithm | Common bounded seven-day error filtering/masking remains shared; the OpenWrt defaults include current updater, list, Telegram, WARP, TCP16, Insta, WebPanel, RT proxy, and core logs without Keenetic-only paths. | Default log inventory and common aggregation regression fixtures; source inventory verified against OpenWrt subsystem paths. |
| Offload and OpenWrt platform evidence | C — equivalent already exists | Existing OpenWrt `print_offload()`/platform probes are separate from the portable firewall questions and must remain intact. | Existing OpenWrt offload and native diagnostics fixtures. |
