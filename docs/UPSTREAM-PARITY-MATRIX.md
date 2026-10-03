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
| Firewall / WAN events | Keenetic uses NDM, iptables/ipset, and device policy APIs. | OpenWrt uses fw4/nftables, netifd/ubus/UCI, and hotplug. | ADAPTED |
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
