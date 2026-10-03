# Documentation

This index points to the current source of truth for each topic. Dated investigation records and retired designs, when retained, are under [`archive/`](archive/README.md).

## Project and development

- [Architecture](../ARCHITECTURE.md): runtime boundaries, filesystem ownership, and service integration.
- [Contributing](../CONTRIBUTING.md): development conventions and local workflows.
- [Changelog](../CHANGELOG.md): user-visible changes by release.

## Releases and upstream

- [Release operations](openwrt-release-operations.md): install, update, recovery, and removal limits on OpenWrt.
- [Release policy](../RELEASING.md): maintainer responsibilities and trusted publication.
- [Upstream tracking](../UPSTREAM.md): upstream intake and the single router release authority.
- [Parity matrix](UPSTREAM-PARITY-MATRIX.md): upstream behavior mapped to OpenWrt implementation and status.
- [Documentation review ledger](UPSTREAM-SYNC.tsv): exact upstream document revisions classified by the audit helper.

## Security and platform contracts

- [Security](../SECURITY.md): trust boundaries, update verification, WebPanel exposure, and telemetry.
- [WebPanel contract](openwrt-webpanel-contract.md): panel capabilities, service ownership, and OpenWrt integration.
- [Telegram contract](openwrt-telegram-contract.md): Telegram transport and firewall ownership.
- [RT proxy contract](openwrt-rt-proxy-contract.md): RT proxy lifecycle and routing integration.
- [WARP contract](openwrt-warp-contract.md): WARP routing, marks, lists, and recovery.
