# Documentation

z2kOW keeps a small set of canonical documents. Historical investigations belong under [`archive/`](archive/README.md), not in the active documentation set.

## Start here

- [Project README](../README.md) — public technical overview, release model, WebPanel, and basic commands.
- [Legal and use policy](../LEGAL.md) — project scope, operator responsibility, third-party references, donations, and public documentation policy.
- [Architecture](../ARCHITECTURE.md) — common/upstream layer, OpenWrt boundary, ownership, and lifecycle.
- [Upstream policy](../UPSTREAM.md) — how z2kOW stays aligned with upstream z2k.
- [Parity matrix](UPSTREAM-PARITY-MATRIX.md) — current material differences from upstream.

## Releases and security

- [Release policy](../RELEASING.md) — maintainer rules for building and publishing releases.
- [OpenWrt release operations](openwrt-release-operations.md) — device install, update, state, and recovery.
- [Security](../SECURITY.md) — trust boundaries, signatures, WebPanel exposure, and telemetry.

## OpenWrt feature contracts

These documents describe only platform-specific invariants that are not obvious from upstream z2k:

- [WebPanel](openwrt-webpanel-contract.md)
- [Telegram transport](openwrt-telegram-contract.md)
- [RT proxy](openwrt-rt-proxy-contract.md)
- [WARP](openwrt-warp-contract.md)

## Development records

- [Contributing](../CONTRIBUTING.md) — development conventions.
- [`UPSTREAM-SYNC.tsv`](UPSTREAM-SYNC.tsv) — reviewed upstream documentation revisions used by the sync audit.
- [`archive/`](archive/) — historical notes that are not current contracts.

Active documentation should describe the current contract, not CI transcripts, elapsed times, temporary implementation stages, or one-off test reports.
