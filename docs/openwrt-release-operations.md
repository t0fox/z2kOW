# OpenWrt release operations

This is the operator-facing source of truth for the OpenWrt install and update path. Root `UPDATES.json` is the only release authority; an unsigned CI candidate is not a production release.

## Audited release state

The approved target is upstream `p-86.13`, sequence `136`, tag commit `7f630a9d459052b9c9c9eded06298f1b8f7f0a22`, confirmed from the live `z2k-enhanced` branch on 2026-10-02. The trusted release workflow repeats that live check immediately before CI/build and fails closed if upstream advances.

## Device install and update

The public bootstrap is [`scripts/openwrt/install.sh`](../scripts/openwrt/install.sh):

```sh
curl -fsSL https://raw.githubusercontent.com/t0fox/z2kOW/main/scripts/openwrt/install.sh | sh
```

It requires root on OpenWrt, installs required system tools through OpenWrt `apk`, verifies the controlled manifest signature, validates the selected release metadata, downloads the complete `openwrt-rootfs.tar.gz`, checks its size and SHA-256, and invokes `install_release <tag>`. Updates use the same full-payload convergence command. There is no production component APK feed.

The OpenWrt implementation does not apply upstream `patch` history entries as file deltas. It installs the approved complete payload for both upstream `patch` and `reinstall` entries. Do not infer a delta update from the manifest's `type`, `steps`, or `full_install` fields.

## Trust and release authority

The repository-root [`UPDATES.json`](../UPDATES.json) on `main` is the only device-visible release authority. It preserves upstream tag, sequence, commit and append-only history, and adds one artifact record with filename, immutable release URL, byte size and SHA-256. Production publication signs this manifest; the device verifies that signature before trusting its artifact metadata. The artifact digest binds the complete rootfs, including bundled runtime binaries.

The single [`release-openwrt.yml`](../.github/workflows/release-openwrt.yml) workflow can initialize signing and publish releases. Initialization generates an Ed25519 keypair inside GitHub Actions, stores only its public key in the repository, and stores the private key only in the protected `openwrt-production` environment secret `Z2KOW_RELEASE_PRIVATE_KEY`. The bootstrap pins public-key fingerprints; installed releases carry the public keyring for updates and rotation. Release publication validates the live upstream tag/sequence, runs full CI, builds one complete rootfs, signs and verifies the exact controlled manifest, publishes the immutable release assets, downloads them again, and verifies their public bytes before committing `UPDATES.json` and its detached signature. Only a public-environment deployment approval may require a user click; no key material is handled by the user.

Ordinary CI also stages an unsigned candidate through [`scripts/openwrt/build-release.sh`](../scripts/openwrt/build-release.sh) and [`scripts/openwrt/stage-rootfs.sh`](../scripts/openwrt/stage-rootfs.sh). A CI artifact or local unsigned candidate is not installable through the production trust channel.

The zapret2 runtime source is pinned by URL and SHA-256 in [`platform/openwrt/runtime-pin`](../platform/openwrt/runtime-pin); the rootfs artifact hash then covers the staged bytes. Runtime provenance is not separately recorded as version/source/hash fields in the signed manifest.

## Ownership, preservation, and migration

The explicit replaceable path list is [`platform/openwrt/owned-paths.txt`](../platform/openwrt/owned-paths.txt). It covers product payload, CLI/entrypoint, init, hotplug, sysctl, and nft include paths. The rootfs excludes `/etc/z2k`; configuration, state, user lists and relay identity remain persistent across an ordinary payload update. Full purge is an explicit uninstall option.

`install_release` verifies the archive, validates paths and target architecture, stages replacements, journals owned paths and prior release state, applies OpenWrt bootstrap/migrations, restarts the owned services, runs health checks and commits the installed tag/sequence only after success. On ordinary failure it restores journaled paths and the previous release state, then attempts to restart the prior services. Its journal is transaction recovery, not a user-facing backup/restore archive.

The one-time migration handles ownership data from the retired z2kOW APK/feed layout and moves the former Telegram relay identity into persistent state. It removes legacy package ownership only after staging/transaction protection. These are OpenWrt migration steps, not a second ongoing package deployment path.

Local installed release state is `/etc/z2k/state/installed-release` (`tag` and `seq`). A repeated call for the current tag is a no-op except when a recognized migration or stale legacy-state reconciliation is needed.

## Upstream synchronization

The [`sync-upstream.yml`](../.github/workflows/sync-upstream.yml) workflow checks `necronicle/z2k` branch `z2k-enhanced` for a newer sequence. Discovery alerts maintainers; it does not publish or expose the new release to routers. Review common behavior, adapt platform integrations, build and review a complete candidate, then advance the controlled manifest and use the trusted signing/publication path.

The maintained documentation-diff review procedure is [`UPSTREAM-SYNC.md`](UPSTREAM-SYNC.md). Root [`ARCHITECTURE.md`](../ARCHITECTURE.md) describes the z2kOW/OpenWrt boundary. Root [`RELEASING.md`](../RELEASING.md) describes the separate inherited upstream tag/release tooling and is not the router artifact runbook.

## Evidence and limits

This guide describes the audited source at the committed baseline. Source and fixture tests do not establish successful installation on a live router or every filesystem's power-loss behavior. For feature-by-feature upstream comparison and remaining gaps, consult [`UPSTREAM-PARITY-MATRIX.md`](UPSTREAM-PARITY-MATRIX.md); for supported commands, use the installed `z2kow` CLI help.
