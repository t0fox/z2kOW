# OpenWrt adapter contract

`z2kOW` keeps the common upstream z2k behavior and runs it through the existing OpenWrt backends. Upstream Keenetic lifecycle is not copied into OpenWrt: procd owns services, fw4/nftables owns firewall integration, and OpenWrt hotplug handles interface events.

## Existing OpenWrt implementations

Keep these backends as the platform boundary and adapt upstream behavior through them:

- `platform/openwrt/warp.sh`, `tg.sh`, `rt.sh`, `firewall.sh`, `webpanel.sh`, and `update.sh`;
- procd init scripts under `platform/openwrt/files/etc/init.d/`;
- fw4/nftables integration and interface hotplug hooks.

No parallel component updater or runtime package path is supported.

## Filesystem and user data

```text
/etc/z2k/            user config, installed-release record, relay identity,
                     runtime state and user lists
/usr/lib/z2k/        complete z2kOW payload and OpenWrt adapter
/opt/zapret2/        pinned zapret2 runtime delivered in the same payload
/tmp/z2k/            transient locks, logs, downloads and generated files
```

The complete release payload excludes `/etc/z2k` user data. The one installed-release record is `/etc/z2k/state/installed-release`, containing the controlled upstream `tag` and `seq`. It is written atomically only after bootstrap and health checks. Telegram's per-install identity and p-86.8 relay assignment share `/etc/z2k/state/relay-id.json`; the old identity at `/opt/zapret2/.z2k-relay-id` is copied there once before replacing the old runtime tree.

## Update and install

`UPDATES.json` at repository root on `main` is the only device-visible release authority. It carries current upstream tag/seq, provenance and the append-only upstream history. A signed production version of the same manifest includes the complete `openwrt-rootfs.tar.gz` artifact URL, byte count and SHA-256. `UPSTREAM.json` and component manifests are not used.

The common upstream updater supplies `au_decide` semantics. For every approved target, OpenWrt runs the same full-payload convergence command:

```sh
install_release <upstream-tag>
```

The shared `au_decide` reads upstream history and decides whether there is an update. The OpenWrt adapter collapses both `patch` and `reinstall` decisions into the same complete-payload `install_release` path. It does not execute upstream `history[].steps` or `full_install` semantics. These fields are therefore not migration hooks in the current OpenWrt deployment path; see the [parity audit](UPSTREAM-PARITY-MATRIX.md). A successful install advances the single local state; the next check returns `none`.

The transaction verifies the signature, artifact length and SHA-256, validates archive member paths, extracts to staging, and atomically replaces the owned paths. It journals the old paths with same-filesystem renames and restores them if application or health checks fail. User configuration/state is preserved. See `platform/openwrt/owned-paths.txt` for the release ownership list.

## One-time legacy APK migration

OpenWrt `apk` is retained for system dependencies and for reading legacy z2kOW ownership during migration. Legacy component APKs may be inspected to learn their owned files; before removing them, `install_release` backs up the owned paths. The one-time path removes z2kOW package/feed ownership and installs the complete approved payload. No component APK builder, feed, or update path remains after migration.

## Protected system boundary

z2kOW must never own or mutate:

- `/www/cgi-bin/luci`;
- `/www/luci-static`;
- `/etc/config/uhttpd`;
- LuCI/uhttpd ports 80 and 443.

The WebPanel refuses 80/443. Rootfs staging, archive validation, install-path contracts and LuCI regression tests enforce this boundary.

## Runtime compatibility

The installed common z2k code continues to call the existing OpenWrt adapters. OpenWrt-only behavior stays in `platform/openwrt/`; common changes carry upstream semantics without importing `ndmc`, NDM hooks, Keenetic init scripts or `/opt/etc` lifecycle behavior into the router.

The trusted release workflow runs full CI, builds the pinned zapret2 runtime plus architecture-specific Telegram and WARP binaries, stages one complete rootfs, signs the controlled manifest in a protected environment, and verifies the immutable public assets. The ordinary candidate CI job remains unsigned and cannot be installed through the production trust path. No live router result may be claimed from fixture or CI simulation alone.
