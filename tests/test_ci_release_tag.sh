#!/bin/sh
# Exercise the exact tag resolver used by CI against a controlled manifest.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RESOLVER="$ROOT/scripts/ci/resolve-release-tag.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '[FAIL] %s: %s\n' "$1" "$2"; }

if [ ! -f "$RESOLVER" ]; then
    no "CI resolver reads the controlled manifest" "missing $RESOLVER"
    printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
    exit 1
fi

mkdir -p "$TMP/workspace"
printf '{"current":"p-42.7","seq":1}\n' > "$TMP/workspace/UPDATES.json"

# A normal main-branch CI run must resolve from this repository's controlled
# manifest, even if upstream has moved on.
GITHUB_WORKSPACE="$TMP/workspace" GITHUB_ENV="$TMP/main.env" \
GITHUB_REF=refs/heads/main INPUT_CANDIDATE='' \
    bash "$RESOLVER"
if grep -Fqx 'Z2K_RELEASE_CANDIDATE_VERSION=p-42.7' "$TMP/main.env"; then
    ok "main CI uses the controlled UPDATES.json tag"
else
    no "main CI uses the controlled UPDATES.json tag" "expected p-42.7"
fi

# A release workflow candidate intentionally overrides the checked-in current
# tag so its panel cache-buster is validated against the candidate being built.
GITHUB_WORKSPACE="$TMP/workspace" GITHUB_ENV="$TMP/candidate.env" \
GITHUB_REF=refs/heads/main INPUT_CANDIDATE=p-43.1 \
    bash "$RESOLVER"
if grep -Fqx 'Z2K_RELEASE_CANDIDATE_VERSION=p-43.1' "$TMP/candidate.env"; then
    ok "explicit release candidate takes precedence"
else
    no "explicit release candidate takes precedence" "expected p-43.1"
fi

# Other branches without an explicit candidate leave this main-only check unset.
GITHUB_WORKSPACE="$TMP/workspace" GITHUB_ENV="$TMP/branch.env" \
GITHUB_REF=refs/heads/feature INPUT_CANDIDATE='' \
    bash "$RESOLVER"
if [ ! -s "$TMP/branch.env" ]; then
    ok "non-main CI does not set a release candidate"
else
    no "non-main CI does not set a release candidate" "unexpected candidate written"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
