# OpenWrt release policy

This document defines maintainer policy. Device commands and recovery are in [docs/openwrt-release-operations.md](docs/openwrt-release-operations.md).

## Release authority

Upstream `necronicle/z2k` is an input. Routers read only the controlled z2kOW `UPDATES.json` on `main`.

A release must identify the approved upstream tag, sequence, and commit and bind the OpenWrt artifact by immutable URL, byte size, and SHA-256. Production metadata is signed with the protected z2kOW release key.

## Build model

The OpenWrt release is a complete staged payload. Build and staging logic lives under `scripts/openwrt/`. Device application converges through `install_release` and the OpenWrt release engine.

Do not publish mutable files from `main` as production runtime dependencies. A release must be reproducible from a fixed repository state and fixed upstream provenance.

## Trusted publication

The trusted workflow is `.github/workflows/release-openwrt.yml`. It is responsible for:

1. validating requested upstream provenance;
2. building the candidate from the selected repository state;
3. producing final release metadata;
4. signing the controlled manifest with the protected production key;
5. publishing immutable release assets;
6. verifying the published artifact binding;
7. advancing `UPDATES.json` and its signature.

Do not overwrite an immutable published release. Publish a new release to correct a defect.

## Release review

Before production publication:

- confirm the intended upstream tag, sequence, and commit;
- review upstream behavior changes and platform adaptations;
- keep the parity matrix current;
- confirm user-owned data remains outside release-owned payload paths;
- confirm architecture-specific runtime selection is deterministic;
- review the exact manifest and artifact references to be signed;
- keep the changelog limited to user-visible changes.

Release policy must not depend on temporary agent reports, one-off local paths, or test-run transcripts stored in documentation.
