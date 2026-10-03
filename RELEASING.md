# OpenWrt release policy

This document defines maintainer policy for adapting upstream z2k releases and publishing the OpenWrt payload. Device installation and recovery instructions belong in the [OpenWrt release operations guide](docs/openwrt-release-operations.md).

## Release source and approval

The upstream `necronicle/z2k` `z2k-enhanced` branch is an input, not a device update source. Review new upstream code and documentation, carry over shared behavior, adapt platform integrations, and update the [parity matrix](docs/UPSTREAM-PARITY-MATRIX.md) before approving a release. A newly discovered upstream sequence is not visible to routers until the controlled z2kOW manifest is advanced and published.

The repository root `UPDATES.json` is the only release authority read by routers. It records the approved upstream tag, sequence, commit and history, plus the complete OpenWrt artifact URL, size and SHA-256. Do not publish a release by moving an upstream branch or publishing an individual package.

## Build and publication

The normal CI workflow builds an unsigned candidate through `scripts/openwrt/build-release.sh` and `scripts/openwrt/stage-rootfs.sh`. Candidates support maintainer review; the device bootstrap rejects an unsigned manifest.

The trusted release workflow is `.github/workflows/release-openwrt.yml`. It runs from `main`, checks the requested tag and sequence against upstream, runs the CI gate, builds one complete rootfs, signs the controlled manifest with the protected production key, publishes immutable assets, verifies the public artifacts, and updates `UPDATES.json` and its signature. Keep the private signing key in the protected GitHub environment; never add it to the repository or candidate artifacts.

Do not overwrite an already published artifact or manifest for a release. Correct a published defect with a new release. Use the workflow's retry-publication operation only for an already validated candidate when publication needs to be retried.

## Release review

Before requesting production publication:

- Confirm the upstream tag, sequence and commit are the intended baseline.
- Review upstream behavior changes and update the parity matrix and any affected platform contracts.
- Ensure the payload contains the required architecture-specific runtime files and preserves the `/etc/z2k` user-data boundary.
- Review the exact candidate and release metadata; confirm that the signed manifest refers to the intended immutable artifact.
- Keep user-facing changelog entries limited to changes users can observe.

The [upstream tracking guide](UPSTREAM.md) covers release intake and the documentation-diff ledger. The [documentation index](docs/README.md) lists the canonical project documents.
