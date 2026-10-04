# Upstream parity matrix

This matrix tracks material product differences between z2kOW and the pinned upstream z2k baseline. It is a design/status ledger, not a test report.

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
| Scheduled maintenance | Upstream schedules updates, list refresh, TCP16, telemetry, and feature maintenance. | OpenWrt cron adapter owns equivalent scheduled jobs. | ADAPTED |
| Main list refresh | Upstream geosite/list helpers refresh managed domain data. | Common list/geosite logic is shipped with OpenWrt path and service adapters. | ADAPTED |
| Strategy telemetry | Upstream uploader is controlled by `Z2K_STATS`. | Common uploader is scheduled through the OpenWrt scheduler with OpenWrt paths. | ADAPTED |
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

## p-86.14 sync review

- z2kOW base: `10f6940b51f66b9450ade16c673c030dcd084d95`.
- Upstream base: `7f630a9d459052b9c9c9eded06298f1b8f7f0a22`.
- Upstream target: `p-86.14`, seq `137`, commit `5e058c1c3944e0f0362cf9665b84108fc6e9b3dc`.
- Live `z2k-enhanced/UPDATES.json` and the peeled `p-86.14` tag were checked before implementation; both identify p-86.14/137 and the tag commit above.

| Material upstream change | Disposition | z2kOW implementation | Evidence |
|---|---|---|---|
| `lib/wan.sh`: a main-table default on a bridge is a WAN; only `lo` is excluded; policy-only routes remain excluded. | A — portable common behavior | Kept the common route parser and removed bridge-name/sysfs exclusions. The same helper is used by firewall WAN selection and OpenWrt NFQUEUE self-heal. | `tests/test_wan_detect.sh`; `tests/test_nfqueue_selfheal.sh`; final rootfs staging check. |
| `webpanel/www/index.html`: release cache-buster moves with the upstream release. | B — preserve branded source, adapt release staging | Keep the local branded panel source intact. Stamp staged HTML/JS/CSS asset URLs from the controlled root `UPDATES.json` during the one rootfs build. No separate manifest or payload version is introduced. | `tests/test_cachebuster_declared.sh` with candidate p-86.14; `tests/openwrt/test_ow_stage_rootfs.sh` against the final tarball. |
| Upstream `UPDATES.json` and signature advance to p-86.14/137. | B — controlled release metadata | The trusted `upstream-release` pipeline derives one controlled manifest from the pinned upstream manifest and commit, then signs/publishes it; repository production `UPDATES.json` remains unchanged until that workflow publishes successfully. | `tests/openwrt/test_ow_release_workflow.py`; trusted workflow live/pinned source checks. |

## p-86.14 diagnostics parity review

- z2kOW diagnostic baseline: `740304002760fd4bd6b8eef7b0b2ff5b3e09f67b` (documentation-only spec commit on top of `origin/main` `a7ca0471adae5571f21d42304ee1b2aaf32885ba`).
- Upstream diagnostic contract: `necronicle/z2k` `z2k-enhanced` `p-86.14`, `5e058c1c3944e0f0362cf9665b84108fc6e9b3dc`.
- Compared the complete `files/z2k-diag.sh` files and inspected relevant full functions in both files. The full-file diff is broad because z2kOW contains platform hooks and OpenWrt additions; only portable diagnostic behavior is to be reused, never the upstream file wholesale.

| Material diagnostic behavior | Disposition | Existing implementation / gap before this fix | Evidence to close the gap |
|---|---|---|---|
| Common `ping_vps_rtt()`, `clock_skew_vs_relay()`, DNS snapshot parsing, error filtering, and address masking | A — portable common behavior | Portable functions remain in `files/z2k-diag.sh`, but OpenWrt hook paths bypass common tunnel/network presentation; verify exact parity and connect them to OpenWrt paths without duplicate parsers. | New semantic OpenWrt fixtures plus comparison against the pinned upstream functions. |
| Health versus network-path ownership for DNS snapshot, Insta/WhatsApp pins, and DNS backend | B — OpenWrt adaptation | `files/z2k-diag.sh::print_health()` prints snapshot and Insta output; `platform/openwrt/diag.sh::print_netpath()` currently omits them. | Full report section-order fixture and health/detail verdict assertions. |
| Telegram live relay probes and log tail | B — OpenWrt adaptation | Common tunnel output has upstream ping, skew, and log semantics; OpenWrt `print_tunnel()` currently stops at binary/process/listener/state and must use the actual OpenWrt log path and exact `:1443` process. | Telegram fixtures for PID, ping/loss, skew boundaries, and meaningful log lines/masking. |
| Autocircular chosen-strategy rows | B — retain existing OpenWrt detection, restore common rendering | `_ow_autocircular_detect()` correctly derives runtime PID and state paths; `print_autocircular()` reports state/path/count but not upstream-style rows. | Runtime override, fallback, comment/header, and 10/40-row semantic fixtures. |
| Incoming/outgoing NFQUEUE proof and owned traffic counters | B — OpenWrt nftables adaptation | `z2k_ow_fw_verify()` defines the table/set/hook/queue contract; `print_firewall()` currently counts global textual queue matches/counters instead of reachable owned paths and packet/byte traffic. | Owned/foreign table, queue, jump, consumer, counter, and zero-traffic fixtures. |
| Live `nfqws2` PID/cmdline, strategy/pool counts, and procd state | C — equivalent already exists | Common/OpenWrt service diagnostics already inspect live process state and procd; preserve the existing `/proc` and override semantics rather than porting older process greps. | Existing `tests/openwrt/test_ow_diag_states.sh` and current service/runtime checks remain green. |
| Insta/WhatsApp managed-host pins and dnsmasq runtime attachment | C — equivalent probe exists; B — presentation | `platform/openwrt/diag.sh::print_insta()` already checks registration, record count, managed hostnames, runtime dnsmasq config, and refresh; move it to network path and keep its OpenWrt evidence. | Registered/runtime-config/user-disabled/refresh fixtures and report section-order checks. |
| AdGuard Home / DNS backend relationship to delivered pins | B — OpenWrt adaptation | Common `print_agh()` is not called by the current OpenWrt `netpath` hook; inspect supported OpenWrt paths and show whether clients can receive the pins without treating `rewrites=0` alone as failure. | Backend path/config fixtures and no-false-verdict cases. |
| WARP routing detail behind `route_ready` | B — OpenWrt adaptation; preserve existing readiness truth | `platform/openwrt/warp.sh::warp_status_routing_ready()` and `warp_status()` already establish `route_ready`; adapter detail is too coarse for route-level triage. | Missing TUN/route/nft and all-ready cases with matching health and detailed verdicts. |
| All current OpenWrt subsystem logs through upstream aggregation | B — OpenWrt paths over common algorithm | Common aggregation implements the bounded/error/masking semantics; confirm and supply the complete current z2kOW OpenWrt log list without Keenetic-only paths. | Log inventory plus seven-day/date/noise/truncation/repeat/masking fixtures. |
| Offload and OpenWrt platform evidence | C — equivalent already exists | Existing OpenWrt `print_offload()`/platform probes are separate from the portable firewall questions and must remain intact. | Existing OpenWrt offload and native diagnostics fixtures. |
