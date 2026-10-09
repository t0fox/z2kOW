# Upstream tracking and parity

z2kOW is an independently maintained OpenWrt port **and modification** of [necronicle/z2k](https://github.com/necronicle/z2k) `z2k-enhanced`. It preserves upstream semantics for inherited features while adding its own OpenWrt-specific functionality.

## Core rule

Upstream z2k is the source of truth **for behavior inherited from upstream**, not for features introduced by z2kOW. Inherited functionality should preserve, as closely as practical:

- feature set and user-visible behavior;
- configuration and strategy semantics;
- WebPanel behavior and actions;
- install, update, reinstall, migration, preservation, reset, and removal semantics;
- diagnostics and maintenance behavior;
- scheduler intent and runtime feature flow.

OpenWrt may use different platform mechanics, but a platform difference by itself is not a reason to redesign an inherited feature. Project-specific additions (for example DoH management, TikTok CDN fixes, and FLOWOFFLOAD diagnostics/benchmarking) may define their own behavior and lifecycle; they are not upstream parity requirements.

## Allowed platform differences

OpenWrt replaces Keenetic/Entware mechanisms with native owners:

- procd for process lifecycle;
- fw4/nftables for firewall state;
- netifd, ubus, UCI, and hotplug for network state and events;
- OpenWrt filesystem paths instead of Entware `/opt` ownership;
- OpenWrt scheduling and package management;
- OpenWrt-specific architecture and release delivery.

Keenetic-only capabilities with no meaningful OpenWrt equivalent may be marked `N/A`, but that decision must be explicit. A missing adapter is not the same thing as an unsupported capability.

## Upstream intake

`sync-upstream.yml` discovers upstream sequence changes. Discovery does not publish anything to routers.

For an upstream update:

1. Pin the upstream tag, sequence, and commit.
2. Review common behavior changes.
3. Reuse common upstream code where possible.
4. Adapt only platform-specific effects.
5. Update the [parity matrix](docs/UPSTREAM-PARITY-MATRIX.md).
6. Publish only through the z2kOW release pipeline.

The documentation-diff helper is:

```sh
sh scripts/openwrt/audit-upstream-docs.sh <base-ref> <target-ref>
```

`docs/UPSTREAM-SYNC.tsv` records reviewed upstream documentation revisions. It is an audit ledger, not a second product specification.

## Device release authority

Routers do not read upstream release metadata directly. The repository-root [`UPDATES.json`](UPDATES.json) is the sole device release authority for z2kOW. It records the approved upstream provenance and z2kOW artifact metadata and is authenticated by the z2kOW signing chain.

This separation lets z2kOW keep upstream behavior while using an OpenWrt-native, signed release lifecycle.

## Divergence rule

A common-code difference should be one of:

- an upstream change not yet synchronized;
- a minimal OpenWrt seam;
- project branding/presentation that does not change inherited product semantics;
- an explicitly documented z2kOW extension with its own behavior, ownership, and tests;
- a documented intentional difference with a concrete compatibility or platform reason.

Do not duplicate existing upstream features when they can be reused with a thin adapter. Keep z2kOW-only functionality isolated and documented so upstream updates can be integrated without silently overwriting either side.
