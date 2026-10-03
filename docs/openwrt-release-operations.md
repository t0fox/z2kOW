# OpenWrt release operations

This guide describes the operator interface for installing, updating, inspecting, and recovering a z2kOW installation on OpenWrt. Maintainer publication policy is in [RELEASING.md](../RELEASING.md).

## Requirements

Install and update require root on OpenWrt with `apk`, a supported target architecture, and working network access. The bootstrap uses `apk` to install `ca-bundle`, `openssl-util`, and `jsonfilter`; it downloads with `wget` or `curl`.

## Install

Run the bootstrap on the router as root:

```sh
wget -qO- https://raw.githubusercontent.com/t0fox/z2kOW/main/scripts/openwrt/install.sh | sh
```

Alternatively, fetch it with `curl -fsSL https://raw.githubusercontent.com/t0fox/z2kOW/main/scripts/openwrt/install.sh | sh` when curl is installed.

The bootstrap verifies the signed repository-root `UPDATES.json`, validates the release metadata and artifact binding, downloads the complete `openwrt-rootfs.tar.gz`, checks its size and SHA-256, then invokes `install_release` for the controlled release. It does not install a z2kOW component package or feed.

## Inspect and update

Use the installed CLI:

```sh
z2kow status
z2kow check
z2kow update
```

`check` reports the controlled release available to the device. `update` applies that release through the same full-payload installer used for a fresh installation. Upstream history may label an entry `patch` or `reinstall`; OpenWrt currently installs the complete approved payload for either type. It does not execute upstream per-file patch steps.

The WebPanel also provides a release check and update action when its capability is available. The panel and CLI use the same controlled manifest and installed release state.

## Recovery and retained data

The installer validates the archive paths and target architecture, stages the owned payload, journals replaced paths, applies bootstrap and migration steps, restarts owned services, runs its health gate, and updates the installed release record after success. A failed transaction attempts to restore the previous owned paths and release state and restart the previous services.

Configuration, user lists, persistent strategy state, and relay identity are kept under `/etc/z2k`, outside the replaceable payload. The release transaction journal is for failure recovery; it is not a user backup. Make a separate backup before manual filesystem work.

## Remove

The current public `z2kow` CLI and WebPanel do not expose an uninstall action. The installed tree is a complete rootfs payload rather than an `apk` package, so `apk del` does not remove z2kOW. The release includes internal cleanup logic, but it is not currently a supported operator command. Do not invoke that internal function as a substitute for an uninstall interface.

This means the current release has no supported one-command removal procedure. The installer preserves `/etc/z2k`; a full purge would also remove user configuration, lists, and state and must be treated as a separate destructive operation.

## Release ownership

`platform/openwrt/owned-paths.txt` is the source of truth for replaceable product paths. `/etc/z2k` is persistent operator data. OpenWrt `apk` is used for system dependencies and one-time inspection/removal of legacy z2kOW package ownership; there is no ongoing component package feed.

The repository-root `UPDATES.json` is the only device-visible release authority. Its production signature authenticates release metadata; the signed artifact record binds the complete rootfs archive by URL, byte size, and SHA-256. Upstream sequence discovery does not publish a device update. See [upstream tracking](../UPSTREAM.md) and the [parity matrix](UPSTREAM-PARITY-MATRIX.md).
