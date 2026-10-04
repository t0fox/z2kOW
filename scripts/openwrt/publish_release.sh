#!/usr/bin/env bash
# Publish a tested candidate as an immutable technical payload and, only for a
# real upstream version advance, one user-facing Product Release.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
POLICY="$ROOT/scripts/openwrt/publication_policy.py"
CANDIDATE="${1:?usage: publish_release.sh CANDIDATE_DIR}"
REPOSITORY="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
SOURCE_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["source_sha"])' "$CANDIDATE/candidate.json")"
OPERATION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["operation"])' "$CANDIDATE/candidate.json")"
TECHNICAL_TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["technical_tag"])' "$CANDIDATE/candidate.json")"
TECHNICAL_TITLE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["technical_title"])' "$CANDIDATE/candidate.json")"
PRODUCT_TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("product_tag") or "")' "$CANDIDATE/candidate.json")"
PRODUCT_TITLE="${PRODUCT_TAG:+z2kOW $PRODUCT_TAG}"
RETRY="${Z2KOW_RETRY_PUBLISH:-false}"
MANIFEST="$CANDIDATE/UPDATES.json"
SIGNATURE="$CANDIDATE/UPDATES.json.sig"
ARTIFACT="$CANDIDATE/openwrt-rootfs.tar.gz"
TECHNICAL_NOTES="$CANDIDATE/technical-release-notes.md"
PRODUCT_NOTES="$CANDIDATE/product-release-notes.md"

[[ "$REPOSITORY" == "t0fox/z2kOW" ]]
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$TECHNICAL_TAG" == "openwrt-$SOURCE_SHA" ]]
[[ "$OPERATION" == "hotfix" || "$OPERATION" == "upstream-release" ]]
test -s "$MANIFEST"
test -s "$SIGNATURE"
test -s "$ARTIFACT"
test -s "$TECHNICAL_NOTES"
if [[ "$OPERATION" == "upstream-release" ]]; then
    test "$PRODUCT_TAG" = "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["tag"])' "$CANDIDATE/candidate.json")"
    test -s "$PRODUCT_NOTES"
else
    test -z "$PRODUCT_TAG"
fi

policy() { python3 "$POLICY" "$@"; }
manifest_state="$(policy manifest-state --manifest "$ROOT/UPDATES.json" --candidate "$CANDIDATE/candidate.json")"
if [[ "$RETRY" != true && "$manifest_state" != baseline ]]; then
    echo "new publication must start from its production manifest baseline (found $manifest_state)" >&2
    exit 1
fi

python3 "$ROOT/scripts/openwrt/check_immutable_releases.py" "$REPOSITORY"
git fetch --quiet origin main
test "$(git rev-parse origin/main)" = "$GITHUB_SHA" \
    || { echo 'main moved after the release was prepared; use retry-publish for the exact candidate.' >&2; exit 1; }

RELEASE_TAGS="$RUNNER_TEMP/z2kow-release-tags.txt"
gh api --paginate --jq '.[].tag_name' "repos/$REPOSITORY/releases?per_page=100" > "$RELEASE_TAGS"

release_exists() {
    grep -Fqx -- "$1" "$RELEASE_TAGS"
}

read_release_state() {
    local tag="$1" title="$2" target="$3" prerelease="$4" latest="$5" notes="$6" record="$7"
    gh release view "$tag" \
        --json tagName,name,targetCommitish,isDraft,isPrerelease,isImmutable,isLatest,body > "$record"
    policy check-release --record "$record" --tag "$tag" --title "$title" \
        --target-commit "$target" --prerelease "$prerelease" --latest "$latest" \
        --notes "$notes"
}

check_existing_tag_target() {
    local tag="$1" target="$2" refs resolved
    refs="$(git ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}")"
    if [[ -z "$refs" ]]; then
        return 0
    fi
    resolved="$(printf '%s\n' "$refs" | awk -v peeled="refs/tags/$tag^{}" -v direct="refs/tags/$tag" '$2 == peeled {print $1; found=1} END {if (!found) exit 1}')" \
        || resolved="$(printf '%s\n' "$refs" | awk -v direct="refs/tags/$tag" '$2 == direct {print $1; found=1} END {if (!found) exit 1}')"
    [[ "$resolved" == "$target" ]] \
        || { echo "Git tag $tag already points to $resolved, expected $target; refusing to reuse it." >&2; return 1; }
}

download_and_compare_assets() {
    local tag="$1" destination
    destination="$(mktemp -d "$RUNNER_TEMP/z2kow-release-assets.XXXXXX")"
    gh release download "$tag" --dir "$destination" \
        --pattern openwrt-rootfs.tar.gz --pattern UPDATES.json --pattern UPDATES.json.sig
    cmp -s "$ARTIFACT" "$destination/openwrt-rootfs.tar.gz" \
        || { echo "published rootfs for $tag differs from this verified candidate." >&2; return 1; }
    cmp -s "$MANIFEST" "$destination/UPDATES.json" \
        || { echo "published manifest for $tag differs from this verified candidate." >&2; return 1; }
    cmp -s "$SIGNATURE" "$destination/UPDATES.json.sig" \
        || { echo "published signature for $tag differs from this verified candidate." >&2; return 1; }
}

artifact_state=missing
artifact_record="$RUNNER_TEMP/z2kow-technical-release.json"
if release_exists "$TECHNICAL_TAG"; then
    artifact_state="$(read_release_state "$TECHNICAL_TAG" "$TECHNICAL_TITLE" "$SOURCE_SHA" true false \
        "$TECHNICAL_NOTES" "$artifact_record")"
    if [[ "$RETRY" != true ]]; then
        echo "technical release $TECHNICAL_TAG already exists; use retry-publish with its verified candidate." >&2
        exit 1
    fi
fi

if [[ "$artifact_state" == missing ]]; then
    check_existing_tag_target "$TECHNICAL_TAG" "$SOURCE_SHA"
    gh release create "$TECHNICAL_TAG" --draft --prerelease --latest=false \
        --target "$SOURCE_SHA" --title "$TECHNICAL_TITLE" --notes-file "$TECHNICAL_NOTES"
    artifact_state=draft
fi

if [[ "$artifact_state" == draft ]]; then
    gh release upload "$TECHNICAL_TAG" "$ARTIFACT" "$MANIFEST" "$SIGNATURE" --clobber
    download_and_compare_assets "$TECHNICAL_TAG"
    gh release edit "$TECHNICAL_TAG" --draft=false --prerelease --latest=false
else
    download_and_compare_assets "$TECHNICAL_TAG"
fi
read_release_state "$TECHNICAL_TAG" "$TECHNICAL_TITLE" "$SOURCE_SHA" true false \
    "$TECHNICAL_NOTES" "$artifact_record" | grep -Fxq published

public_assets="$(mktemp -d "$RUNNER_TEMP/z2kow-public-assets.XXXXXX")"
release_url="https://github.com/$REPOSITORY/releases/download/$TECHNICAL_TAG"
for asset in openwrt-rootfs.tar.gz UPDATES.json UPDATES.json.sig; do
    curl --fail --location --silent --show-error \
        "$release_url/$asset?nocache=$(date +%s%N)" -o "$public_assets/$asset"
done
cmp -s "$ARTIFACT" "$public_assets/openwrt-rootfs.tar.gz"
cmp -s "$MANIFEST" "$public_assets/UPDATES.json"
cmp -s "$SIGNATURE" "$public_assets/UPDATES.json.sig"
python3 "$ROOT/scripts/openwrt/sign_release.py" verify \
    --manifest "$public_assets/UPDATES.json" \
    --artifact "$public_assets/openwrt-rootfs.tar.gz" \
    --signature "$public_assets/UPDATES.json.sig" \
    --public-key "$ROOT/scripts/openwrt/release-keys/$RELEASE_KEY_ID.pub"

if [[ -n "$PRODUCT_TAG" ]]; then
    product_state=missing
    product_record="$RUNNER_TEMP/z2kow-product-release.json"
    if release_exists "$PRODUCT_TAG"; then
        product_state="$(read_release_state "$PRODUCT_TAG" "$PRODUCT_TITLE" "$SOURCE_SHA" false true \
            "$PRODUCT_NOTES" "$product_record")"
        if [[ "$RETRY" != true ]]; then
            echo "Product Release $PRODUCT_TAG already exists; refusing duplicate publication." >&2
            exit 1
        fi
    fi

    if [[ "$product_state" == missing ]]; then
        check_existing_tag_target "$PRODUCT_TAG" "$SOURCE_SHA"
        gh release create "$PRODUCT_TAG" --draft --target "$SOURCE_SHA" \
            --title "$PRODUCT_TITLE" --notes-file "$PRODUCT_NOTES" --latest
        product_state=draft
    fi

    if [[ "$product_state" == draft ]]; then
        gh release edit "$PRODUCT_TAG" --draft=false --latest
    fi
    read_release_state "$PRODUCT_TAG" "$PRODUCT_TITLE" "$SOURCE_SHA" false true \
        "$PRODUCT_NOTES" "$product_record" | grep -Fxq published
fi

manifest_state="$(policy manifest-state --manifest "$ROOT/UPDATES.json" --candidate "$CANDIDATE/candidate.json")"
if [[ "$manifest_state" == baseline ]]; then
    git -C "$ROOT" fetch --quiet origin main
    test "$(git -C "$ROOT" rev-parse origin/main)" = "$GITHUB_SHA" \
        || { echo 'main moved during publication; verified releases remain available for retry-publish.' >&2; exit 1; }
    cp "$MANIFEST" "$ROOT/UPDATES.json"
    cp "$SIGNATURE" "$ROOT/UPDATES.json.sig"
    git -C "$ROOT" add -- UPDATES.json UPDATES.json.sig
    if ! git -C "$ROOT" diff --cached --quiet; then
        git -C "$ROOT" config user.name "t0fox"
        git -C "$ROOT" config user.email "t0fox@yandex.ru"
        if [[ -n "$PRODUCT_TAG" ]]; then
            git -C "$ROOT" commit -m "release(openwrt): $PRODUCT_TAG"
        else
            git -C "$ROOT" commit -m "release(openwrt): hotfix $TECHNICAL_TAG"
        fi
        git -C "$ROOT" push origin HEAD:main
    fi
elif [[ "$manifest_state" != published ]]; then
    echo "production manifest changed while publishing (found $manifest_state); refusing stale commit." >&2
    exit 1
fi

raw_url="https://raw.githubusercontent.com/$REPOSITORY/main"
attempt=1
while [[ "$attempt" -le 30 ]]; do
    nonce="$(date +%s%N)"
    if curl --fail --location --silent --show-error "$raw_url/UPDATES.json?nocache=$nonce" \
        -o "$RUNNER_TEMP/public-main-UPDATES.json" \
        && curl --fail --location --silent --show-error "$raw_url/UPDATES.json.sig?nocache=$nonce" \
        -o "$RUNNER_TEMP/public-main-UPDATES.json.sig"; then
        if cmp -s "$MANIFEST" "$RUNNER_TEMP/public-main-UPDATES.json" \
            && cmp -s "$SIGNATURE" "$RUNNER_TEMP/public-main-UPDATES.json.sig"; then
            break
        fi
    fi
    sleep 2
    attempt=$((attempt + 1))
done
cmp -s "$MANIFEST" "$RUNNER_TEMP/public-main-UPDATES.json"
cmp -s "$SIGNATURE" "$RUNNER_TEMP/public-main-UPDATES.json.sig"
python3 "$ROOT/scripts/openwrt/sign_release.py" verify \
    --manifest "$RUNNER_TEMP/public-main-UPDATES.json" \
    --artifact "$public_assets/openwrt-rootfs.tar.gz" \
    --signature "$RUNNER_TEMP/public-main-UPDATES.json.sig" \
    --public-key "$ROOT/scripts/openwrt/release-keys/$RELEASE_KEY_ID.pub"
sha256sum "$public_assets/openwrt-rootfs.tar.gz" >> "$GITHUB_STEP_SUMMARY"
printf '\nPublished and verified payload: %s\n' "$release_url" >> "$GITHUB_STEP_SUMMARY"
if [[ -n "$PRODUCT_TAG" ]]; then
    printf 'Product Release: %s\n' "$PRODUCT_TAG" >> "$GITHUB_STEP_SUMMARY"
else
    printf 'Hotfix for unchanged upstream version: %s / seq %s\n' \
        "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["tag"])' "$CANDIDATE/candidate.json")" \
        "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["seq"])' "$CANDIDATE/candidate.json")" \
        >> "$GITHUB_STEP_SUMMARY"
fi
