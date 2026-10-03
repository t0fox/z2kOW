# Upstream tracking

z2kOW adapts [necronicle/z2k](https://github.com/necronicle/z2k) for OpenWrt. The upstream `z2k-enhanced` branch is a read-only input; device updates use only the controlled z2kOW release manifest on `main`.

## Intake and release authority

The `sync-upstream.yml` workflow checks for upstream sequence changes and alerts maintainers. Discovery does not adapt or publish a release. For an approved update, review the upstream source and documentation changes, carry over shared behavior, adapt platform behavior to OpenWrt, update the [parity matrix](docs/UPSTREAM-PARITY-MATRIX.md), and review affected platform contracts.

The repository-root [`UPDATES.json`](UPDATES.json) is the only release authority read by routers. It records the approved upstream tag, sequence, commit, and append-only history. A production release adds the complete OpenWrt artifact URL, byte size, and SHA-256 to that manifest and signs it. Devices do not read the upstream manifest directly, and a newly discovered upstream release remains unavailable until z2kOW adapts and publishes it.

## Review upstream documentation changes

Run the documentation audit against explicit base and target refs:

```sh
sh scripts/openwrt/audit-upstream-docs.sh <base-ref> <target-ref>
```

For each changed normative document, record the exact path, base and head blob IDs, classification, and rationale in [`docs/UPSTREAM-SYNC.tsv`](docs/UPSTREAM-SYNC.tsv). The helper checks changed Markdown contracts and selected workflow, release, and lifecycle files. Classifications are `OPENWRT RELEVANT`, `KEENETIC ONLY`, `RETIRED/HISTORICAL`, and `DOC ONLY`. Existing ledger rows apply only to the blob IDs they name; add a new row when the reviewed blob changes.

## OpenWrt boundary

Carry common upstream behavior through the existing OpenWrt adapters: procd, fw4/nftables, hotplug, UCI, and the platform services documented in [architecture](ARCHITECTURE.md). Do not run Keenetic lifecycle scripts or change LuCI/uhttpd files and ports. Device installation and publication are described in the [release operations guide](docs/openwrt-release-operations.md) and [release policy](RELEASING.md).
