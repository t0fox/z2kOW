# z2kOW OpenWrt release operations

The production release entrypoint is `.github/workflows/release-openwrt.yml` with `workflow_dispatch`. The maintenance agent invokes that workflow through the GitHub Actions API; no one has to publish from the GitHub UI. Pushes, pull requests, upstream syncs, and green CI runs build or validate development snapshots only; they never create a stable tag or Release.

The canonical builder requires an explicit `--ci-snapshot` or `--release --product-version X.Y.Z` mode. The old Makefile-backed stable revision path is disabled so a normal build cannot emit a misleading `0.1.0-r79` package. The live router reports `z2k-adapter-0.1.0-r79` and `z2k-webpanel-0.1.0-r79`; because production packages reset their revision to `r1`, the first upgrade-safe product version is `0.1.1`. CI snapshots also use the next patch prerelease with revision `r1`, so an installed `0.1.0-r79` can accept a test update while the final `0.1.1-r1` production package still sorts above it. Release preflight and the canonical version helper reject `0.1.0` and any lower SemVer.

## Agent-owned release lifecycle

`CHANGELOG.md` is the canonical queue of user- and operator-visible changes. Add those changes under `## [Unreleased]`; omit tests-only work, refactors with no operator effect, CI plumbing, and package revision bumps. The agent batches entries and releases only when the batch is worth shipping. A green CI run by itself never starts a release.

The agent chooses the next SemVer from the accumulated changes: breaking behavior or API changes require a major bump, backward-compatible capabilities use a minor bump, and user- or operator-facing fixes use a patch bump. If there are no meaningful product changes, it waits. The first production bundle is `0.1.1` because it must upgrade the router's installed `0.1.0-r79` packages.

Before preparing a release commit, the agent checks the live acceptance record, the production signing key, upstream manifest pins, and other known release gates. When ready, it moves the accumulated notes into a dated version section and leaves a fresh `Unreleased` section at the top:

```sh
python3 scripts/openwrt/changelog-release.py promote \
  --changelog CHANGELOG.md --version "$VERSION" --date "$(date -u +%F)"
git add CHANGELOG.md
git commit -m "Prepare z2kOW v$VERSION release"
```

That release-preparation commit is pushed to `main`; its exact SHA must then have a completed successful CI run. The agent dispatches the unsigned candidate directly through the GitHub API, for example:

```sh
jq -n --arg version "$VERSION" --arg sha "$TARGET_SHA" \
  '{ref:"main",inputs:{version:$version,target_sha:$sha,confirm:("RELEASE v"+$version),dry_run:"true"}}' |
  gh api --method POST \
    repos/t0fox/z2kOW/actions/workflows/release-openwrt.yml/dispatches \
    --input -
```

After verifying and signing that exact candidate with the offline key, the agent sends a second API dispatch with `dry_run:"false"`, its `candidate_run_id`, and the base64 signature overlay. The publish job has no reviewer-gated GitHub Environment, so a valid API dispatch does not pause for routine UI approval:

```sh
signature_bundle_b64="$(base64 < z2k-release-signatures.tar.gz | tr -d '\n')"
jq -n --arg version "$VERSION" --arg sha "$TARGET_SHA" \
  --arg candidate "$CANDIDATE_RUN_ID" --arg signatures "$signature_bundle_b64" \
  '{ref:"main",inputs:{version:$version,target_sha:$sha,confirm:("RELEASE v"+$version),dry_run:"false",candidate_run_id:$candidate,signature_bundle_b64:$signatures}}' |
  gh api --method POST \
    repos/t0fox/z2kOW/actions/workflows/release-openwrt.yml/dispatches \
    --input -
unset signature_bundle_b64
```

`release-preflight.py` and the workflow both fail closed on stale SHAs, non-green exact-SHA CI, existing tags/releases, missing live evidence, missing key pins, invalid signatures, or incomplete assets. The agent records the resulting workflow run and verifies the final tag, Release, asset set, manifest, and checksums. It does not create a release for every commit, green CI run, or upstream sync.

## Dry run

Dispatch with a SemVer product version, the full commit SHA currently at `main`, the exact confirmation `RELEASE vX.Y.Z`, and `dry_run=true`. The workflow checks that the target is still current `main` and has a completed successful `CI` run for the exact SHA. It then invokes `scripts/openwrt/build-release.sh --release --product-version X.Y.Z`, prepares the four-package bundle, validates its manifest and checksums, extracts only the matching section from `CHANGELOG.md`, and uploads a short-retention Actions candidate artifact. A dry run creates no tag, GitHub Release, or stable assets.

## Offline signing and production dispatch

The Actions workflow must never receive a private signing key. The agent's offline signing step downloads the candidate artifact and uses the pinned OpenWrt SDK's `apk` tool plus the private feed key stored outside the checkout:

```sh
python3 scripts/openwrt/release-assets.py sign \
  --bundle candidate \
  --apk-tool /path/to/openwrt-sdk/staging_dir/host/bin/apk \
  --private-key /secure/offline/z2k-feed.key \
  --public-key package/openwrt/keys/z2k-feed.pem \
  --overlay-out z2k-release-signatures.tar.gz
```

The command refuses a key stored inside the repository or a private key that does not match the committed public-key pin. It signs the package index with OpenWrt APK tooling, updates the index hash in the release manifest and `SHA256SUMS`, signs `SHA256SUMS` with the same offline key, verifies both signatures, and emits an overlay containing only the four small finalized metadata files. The production dispatch supplies that overlay as `signature_bundle_b64` and the candidate run id as `candidate_run_id`; the workflow verifies its exact file list and size, restores the signed metadata over the exact-SHA candidate, and reruns all checks before creating the tag and Release.

The release helper expects the production public key at `package/openwrt/keys/z2k-feed.pem`. No public or private production key is currently present in this checkout. Until the public key is pinned and its private counterpart is provisioned offline, production signing and publication fail closed. Never substitute `~/.z2k-signing/z2k-update.key`: that key belongs to the payload updater trust domain.

## Live gates for v0.1.1

Before `dry_run=false` may publish the first release, record evidence in `docs/openwrt-release-acceptance.json` for:

- Cudy WBR3000UAX v1 acceptance, or a clearly described and explicitly accepted limitation;
- `WEB-LUCI-01` on the live router;
- `WEB-BLOCKER-01` using a blocker-enabled Chromium profile, including the identity and theme block cases.

The current acceptance record keeps these gates pending. The report that disabling a browser blocker made the live interface work confirms the client-side failure mechanism, but it does not replace the blocker-enabled Chromium regression or the remaining router acceptance evidence.

## Immutable publication rules

The publish job requires an absent `vX.Y.Z` tag and Release, exact current-main SHA, exact-SHA green CI, passing live gates, the pinned public key, signed `packages.adb`, signed checksums, and a complete exact artifact set. It creates the tag at the requested SHA and creates `z2kOW vX.Y.Z` with the corresponding version section from `CHANGELOG.md`. Existing version names are never overwritten. A package fix after publication requires a new product version.

If tag creation or draft asset upload fails, the version is reserved and cannot be retried by this workflow. Keep the failed draft unpublished, inspect its tag and uploaded assets against the exact candidate artifact, and record the failed run. Do not publish a partial draft or reuse the version; resolve the cause and prepare a new candidate under the next product SemVer.

The legacy `publish.yml` upstream promotion workflow is not the OpenWrt release path and is not called by this workflow.
