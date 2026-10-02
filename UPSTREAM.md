# Upstream tracking

z2kOW adapts [necronicle/z2k](https://github.com/necronicle/z2k) for OpenWrt.
All project work stays on `main`; upstream release branches are read-only
inputs and never become router update sources.

## Release discovery and approval

`.github/workflows/sync-upstream.yml` checks the live `z2k-enhanced` branch
every 15 minutes. It bypasses caches, resolves the current commit, reads the
upstream `UPDATES.json`, and alerts when its sequence advances beyond the
controlled z2kOW manifest.

Discovery does not promote a release. For each new upstream release, review
the source diff, carry over common behavior, adapt platform-specific behavior
through the existing OpenWrt services, then run the release tests. The
controlled manifest changes only after that work is approved. No sync branch,
component release, or automatic publication is part of this process.

## One release authority

The repository-root [`UPDATES.json`](./UPDATES.json) on `main` is the sole
release manifest used by routers, CI decisions, and the WebPanel. It records
the approved upstream tag, sequence, immutable upstream commit, and append-only
release history. A production release adds the complete OpenWrt payload's
artifact URL, size, and SHA-256 to this same manifest.

The updater never reads the upstream manifest directly. Upstream metadata is
fetched only by the sync check and the controlled release builder. There is no
`UPSTREAM.json` file or second version authority. A newer upstream sequence
remains invisible to devices until its OpenWrt adaptation is tested, approved,
signed, and published.

## Installation

Fresh install and every update use the same convergence command:

```sh
install_release <upstream-tag>
```

The public bootstrap is
[`scripts/openwrt/install.sh`](./scripts/openwrt/install.sh). It verifies the
controlled manifest and full payload, then calls `install_release`. APK is
used only for real OpenWrt system dependencies. One-time migration reads old
z2kOW APK/feed ownership data, removes that ownership after a successful
installation, and leaves no parallel package deployment path.

## OpenWrt boundary

Carry upstream behavior through the existing OpenWrt adapters: `procd`,
`fw4`/nftables, hotplug, UCI, and the existing WARP, Telegram, RT proxy, and
WebPanel services. Do not run Keenetic lifecycle scripts or mutate LuCI's
entrypoint, static tree, `uhttpd` configuration, or ports 80/443.
