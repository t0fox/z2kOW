# z2kOW architecture

z2kOW is an OpenWrt port of upstream z2k, not a separate product design. The default rule is simple: keep upstream product behavior common, and replace only platform effects that depend on Keenetic or Entware.

See [UPSTREAM.md](UPSTREAM.md) for the upstream policy and [docs/UPSTREAM-PARITY-MATRIX.md](docs/UPSTREAM-PARITY-MATRIX.md) for known differences.

## Layers

| Layer | Responsibility | Main locations |
|---|---|---|
| Common z2k | Config, strategies, runtime logic, lists, diagnostics, WebPanel behavior, update semantics | `z2k.sh`, `lib/`, `files/`, `webpanel/` |
| OpenWrt adapter | Service, firewall, networking, scheduling, paths, architecture, platform probes | `platform/openwrt/` |
| OpenWrt integration files | procd services, hotplug integration, platform-owned system hooks | `platform/openwrt/files/` |
| Release tooling | Build, stage, sign, publish, install, rollback | `scripts/openwrt/`, `platform/openwrt/release.sh` |

Common code may contain a small explicit platform seam when moving the effect into `platform/openwrt/` is not practical. Platform-specific behavior must not silently fall back to Keenetic paths or commands.

## OpenWrt ownership

| Purpose | Path / owner |
|---|---|
| Persistent configuration and user data | `/etc/z2k` |
| Replaceable product payload | `/usr/lib/z2k` |
| Transient runtime state and logs | `/tmp/z2k` |
| Core service | procd via `/etc/init.d/z2k` |
| WebPanel service | procd via `/etc/init.d/z2k-webpanel` |
| Firewall | fw4/nftables |
| Network events | netifd/ubus and hotplug |
| Scheduled maintenance | OpenWrt cron adapter |

LuCI/uhttpd, unrelated UCI sections, and unrelated firewall state are outside z2kOW ownership.

## Install and update

```text
controlled UPDATES.json + signature
              |
              v
verify release metadata and artifact
              |
              v
stage immutable release payload
              |
              v
install_release <tag>
              |
              v
migrate / converge / restart / health gate
              |
       commit or rollback
```

`scripts/openwrt/install.sh` is the device bootstrap. `install_release` is the canonical OpenWrt convergence operation for fresh installation and release application. The release payload is bound by signed metadata, byte size, and SHA-256.

Upstream release semantics such as preservation, migration, reset behavior, and user-visible update behavior should be retained even when OpenWrt uses a different artifact-delivery mechanism.

## Product state

`/etc/z2k/state/installed-release` is the canonical installed release record. CLI, WebPanel, updater, and diagnostics must interpret the same state. A running process alone does not establish that a release is installed.

Release-owned and user-owned data are separate. Updating or reinstalling replaces release-owned content and preserves user-owned content according to upstream semantics.

## Feature adapters

OpenWrt adapters replace platform mechanisms, not product meaning:

- Keenetic init/supervision → procd.
- iptables/ipset and NDM hooks → fw4/nftables and hotplug.
- `ndmc` network/device operations → ubus, UCI, netifd, and native routing.
- Entware `/opt` ownership → `/etc/z2k`, `/usr/lib/z2k`, and `/tmp/z2k`.
- Keenetic scheduling → OpenWrt cron/procd triggers.
- Keenetic acceleration controls → OpenWrt flow-offload capability where applicable.

Telegram, RT proxy, WARP, TCP16, diagnostics, scheduled list refresh, and other upstream features should keep upstream semantics while using these OpenWrt owners.

## Removal

Removal is also a parity feature. Its user-visible preservation and purge semantics must follow upstream z2k; only the cleanup mechanism is OpenWrt-native. OpenWrt cleanup must remove z2kOW-owned procd, nftables, hotplug, scheduler, and release-owned filesystem state without touching unrelated system configuration.

## Contributor rule

Before changing common code, compare the change with the pinned upstream implementation. Prefer an existing platform hook or a small new adapter over a parallel OpenWrt implementation of the same feature.
