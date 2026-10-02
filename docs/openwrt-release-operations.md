# OpenWrt release operations

OpenWrt users install and update the upstream z2k release selected by the one controlled `UPDATES.json` on `main`. Upstream releases are inputs to adaptation; detecting an upstream sequence does not expose it to routers.

The controlled candidate adapts upstream `p-86.12`, seq `135`; the root manifest records commit `3b1ee437cfc58c7427e5a4ccb5de312ff0f76335`.

## Canonical flows

Fresh-install bootstrap:

```sh
curl -fsSL https://raw.githubusercontent.com/t0fox/z2kOW/main/scripts/openwrt/install.sh | sh
```

The bootstrap requires root on OpenWrt, uses OpenWrt `apk` only for system dependencies, verifies the signed controlled manifest, downloads the complete `openwrt-rootfs.tar.gz`, checks byte count and SHA-256, and calls the payload's `install_release <tag>` entrypoint.

Canonical convergence command, used by both fresh install and update:

```sh
install_release <upstream-tag>
```

The updater first applies upstream `au_decide` history semantics. Whether an entry says `patch` or `reinstall`, OpenWrt installs the complete approved payload through the same command. Type and `full_install` fields may inform state migrations/hooks; they never select a second deployment engine.

## Controlled manifest

The only release authority is repository-root `UPDATES.json` on `main`. Its schema is upstream-compatible history plus OpenWrt provenance:

- `schema`, `branch`, `platform`, `seq`, `current`;
- `upstream.repository`, `upstream.branch`, `upstream.tag`, `upstream.commit`;
- append-only `history` with the original upstream release entries;
- on a signed production release, `artifact.filename`, `artifact.url`, `artifact.sha256`, and `artifact.size_bytes` for the complete rootfs archive.

The build candidate attaches artifact fields to the same manifest. There is no runtime `UPSTREAM.json`, component manifest, snapshot authority, or separate installed component version. Devices verify the manifest signature before acting. Until trusted signing and publication occur, the unsigned candidate is not installable from the production channel.

`.github/workflows/sync-upstream.yml` checks the live `z2k-enhanced` branch every 15 minutes with cache-busting, resolves its immutable commit, and compares the upstream `seq` to controlled `UPDATES.json`. A newer sequence fails the check and needs adaptation/review. It is not copied to the controlled manifest automatically.

## Install transaction and migration

`install_release` downloads and verifies the complete transport artifact, validates archive paths and the protected LuCI boundary, stages files, journals only owned paths that it replaces, and makes same-filesystem replacements. On failure it restores the prior files and installed-release state. User config/state under `/etc/z2k` is excluded from the payload and preserved. The single local release record is `/etc/z2k/state/installed-release`:

```text
tag=<upstream-tag>
seq=<upstream-seq>
```

The record is committed only after bootstrap and health checks. A second check after a successful install returns `none`. The Telegram client stores its per-install key and optional relay assignment at `/etc/z2k/state/relay-id.json`; a one-time migration copies the former `/opt/zapret2/.z2k-relay-id` there before the payload replaces that tree.

Legacy `z2k-adapter`, `z2k-webpanel`, runtime APKs and their feed/key entries are read only during one-time ownership migration. Before `apk del --no-scripts`, the transaction renames the owned trees and explicit integration files that the complete release replaces. Migration refuses any legacy package claiming LuCI, uhttpd, or another path outside the known z2kOW ownership boundary. A successful full-payload install removes the old package/feed ownership. No component APK/feed builder or installer remains.

z2kOW owns paths listed in `platform/openwrt/owned-paths.txt`. It never owns or mutates `/www/cgi-bin/luci`, `/www/luci-static`, `/etc/config/uhttpd`, or LuCI ports 80/443. The panel rejects ports 80/443.

## Candidate verification and publication

CI runs the OpenWrt regression suite and builds one unsigned `openwrt-rootfs.tar.gz` plus its controlled manifest. The archive contains the complete product tree, including architecture-specific Telegram and WARP binaries. The candidate is an internal artifact, not a router release. Production key material is not needed for implementation or CI. A separate trusted signing/publishing operation must sign the reviewed manifest and publish the complete artifact before routers can see the release.

No router is attached to this development environment. Shell fixture tests cover fresh install, legacy migration, update, hash failure, rollback, repeated check, and reboot-state simulation. Real device, traffic, and reboot acceptance must be recorded only after an actual router run.
