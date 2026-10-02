# z2kOW architecture

z2kOW adapts the shared [z2k](https://github.com/necronicle/z2k) application to OpenWrt. Common strategy, configuration, updater, runtime and WebPanel behavior stays in the shared tree where possible. Platform effects belong in `platform/openwrt/`, OpenWrt init/hotplug files, or explicit OpenWrt branches in shared integration points.

For the audited upstream comparison and current gaps, see [`docs/UPSTREAM-PARITY-MATRIX.md`](docs/UPSTREAM-PARITY-MATRIX.md). The device install/update contract is in [`docs/openwrt-release-operations.md`](docs/openwrt-release-operations.md).

## Runtime boundaries

| Responsibility | z2kOW location | OpenWrt owner |
|---|---|---|
| Common CLI, config, strategies, updater and menu | `z2k.sh`, `lib/` | Shared z2k logic with OpenWrt path/service adapters |
| Runtime scripts and default data | `files/` | Shared behavior plus OpenWrt-specific integration files |
| Platform paths, environment and bootstrap | `platform/openwrt/paths.sh`, `env.sh`, `bootstrap.sh` | `/etc/z2k` persistent config/state and `/usr/lib/z2k` payload |
| Service lifecycle | `files/init.d/`, `platform/openwrt/` | procd |
| Firewall and interface events | `platform/openwrt/firewall.sh`, `hotplug/`, `files/hotplug.d/` | fw4/nftables and netifd/hotplug |
| WebPanel | `webpanel/`, `platform/openwrt/webpanel.sh` | CGI/lighttpd integration owned by z2kOW; LuCI/uhttpd remain outside the boundary |
| Release payload | `scripts/openwrt/`, `platform/openwrt/release.sh` | One signed full-rootfs artifact and `install_release <tag>` |
| Architecture-specific binaries | `platform/openwrt/arch.sh`, staged `bin/linux-*` trees | OpenWrt target metadata with fail-closed mapping |

Keenetic `ndmc`, NDM hooks, Entware init/service management, and device policy APIs do not run on OpenWrt. Their user-facing purpose is retained only where an OpenWrt owner exists; the platform mechanism is supplied by procd, fw4/netifd, UCI and `/etc`/`/usr` paths.

## Install and update flow

```text
controlled UPDATES.json + signature
                 |
                 v
      verify metadata and artifact
                 |
                 v
       stage full rootfs archive
                 |
                 v
 install_release <upstream-tag>
                 |
                 v
 migrate/bootstrap -> service health -> commit
                 |
          failure: rollback
```

The device bootstrap is `scripts/openwrt/install.sh`. The single device-visible manifest is repository-root `UPDATES.json`; it binds the complete `openwrt-rootfs.tar.gz` by URL, byte size and SHA-256 under its signature. CI stages an unsigned candidate; trusted signing and publication are separate. The OpenWrt install engine currently applies the full payload for both upstream `patch` and `reinstall` history entries. See the operations guide for ownership, state preservation, migration and rollback details.

## Persistent state and ownership

The release payload does not own `/etc/z2k`. That tree holds operator config, user lists and persistent state. Replaceable integration/payload paths are listed in `platform/openwrt/owned-paths.txt`. The release engine journals paths it replaces and previous release metadata to recover from a failed or interrupted transaction. User-requested backup/restore is a separate feature and must not be inferred from that transaction journal.

Runtime inputs are pinned during the build in `platform/openwrt/runtime-pin`; the signed rootfs digest covers the final bundled bytes. The signed manifest does not currently expose a distinct runtime version/source/hash record.

## Contributor rule

Before changing common code, compare it with the pinned upstream implementation. Keep common behavior common; add or change an adapter only for a real OpenWrt platform boundary or a documented parity gap. Keep release instructions in [`RELEASING.md`](RELEASING.md) scoped to upstream tag tooling and the OpenWrt operator runbook linked above scoped to router installation.
