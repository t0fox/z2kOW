# OpenWrt release operations

This guide describes the device-facing install and update model. Maintainer publication policy is in [RELEASING.md](../RELEASING.md).

## Requirements

- root access;
- OpenWrt with `apk` package management;
- a supported target architecture;
- network access to the release source.

The bootstrap may install required system tools such as CA certificates, OpenSSL utilities, and JSON helpers through `apk`. z2kOW itself is delivered as a signed release payload, not as a set of user-managed component APKs.

## Install

```sh
wget -qO- https://raw.githubusercontent.com/t0fox/z2kOW/main/scripts/openwrt/install.sh | sh
```

or, when `curl` is already available:

```sh
curl -fsSL https://raw.githubusercontent.com/t0fox/z2kOW/main/scripts/openwrt/install.sh | sh
```

The bootstrap verifies the signed controlled manifest, validates the selected release and artifact binding, downloads the complete OpenWrt payload, checks size and SHA-256, and invokes `install_release`.

## Inspect and update

```sh
z2kow status
z2kow check
z2kow update
z2kow restart
```

`status` reads the canonical installed `tag + seq` state and the OpenWrt service state. `check` and `update` use the same controlled release authority as fresh installation.

Do not treat a running process as installed-release metadata. Installer, updater, CLI, WebPanel, and diagnostics must agree on the canonical release record.

## Data ownership

- `/etc/z2k` — operator configuration, user lists, identity, and persistent state.
- `/usr/lib/z2k` — replaceable z2kOW payload.
- `/tmp/z2k` — transient runtime state and logs.
- `platform/openwrt/owned-paths.txt` — replaceable integration paths owned by the release engine.

Release application must preserve user-owned data according to upstream z2k semantics.

## Recovery

The release engine stages the payload, validates paths and architecture, records the previous release-owned state, applies migration/convergence, restarts owned services, and commits the new release record only after the health gate.

On transaction failure it restores previous release-owned files and previous installed-release metadata as far as the recovery contract allows. The transaction journal is not a user backup.

## Removal

z2kOW is not owned by an `apk` package, so `apk del` is not an uninstall method.

The operator-facing removal flow must follow upstream z2k semantics for preservation versus destructive cleanup. The OpenWrt implementation is responsible for removing only z2kOW-owned procd, nftables, hotplug, scheduler, release metadata, and release-owned filesystem state while preserving or purging user data exactly as the corresponding upstream action requires.

If the installed release does not expose the removal action yet, do not substitute manual package removal for it.

## Release authority

The repository-root `UPDATES.json` is the only device-visible release authority. Upstream discovery never directly updates a router. Production metadata authenticates the selected immutable artifact by URL, size, and SHA-256.
