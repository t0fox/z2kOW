#!/bin/sh
# Blob-pinned classification of upstream normative-document changes.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-upstream-docs-sync"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-docsync.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
FIX="$T/repo"
LEDGER="$T/ledger.tsv"
mkdir -p "$FIX/docs" "$FIX/.github/workflows" "$FIX/src"
git -C "$FIX" init -q
git -C "$FIX" config user.email test@example.invalid
git -C "$FIX" config user.name fixture
printf 'QA v1\n' > "$FIX/docs/QA.md"
printf 'name: CI\n' > "$FIX/.github/workflows/ci.yml"
printf 'package v1\n' > "$FIX/src/main.go"
git -C "$FIX" add .
git -C "$FIX" commit -qm base
BASE=$(git -C "$FIX" rev-parse HEAD)
printf 'QA v2\n' > "$FIX/docs/QA.md"
printf 'name: CI\n# release gate\n' > "$FIX/.github/workflows/ci.yml"
printf 'package v2\n' > "$FIX/src/main.go"
git -C "$FIX" add .
git -C "$FIX" commit -qm target
HEAD=$(git -C "$FIX" rev-parse HEAD)
SCRIPT="$REPO/scripts/openwrt/audit-upstream-docs.sh"
printf '# path\tbase_blob\thead_blob\tclassification\trationale\n' > "$LEDGER"

set +e
UPSTREAM_SYNC_REPO="$FIX" UPSTREAM_SYNC_LEDGER="$LEDGER" sh "$SCRIPT" "$BASE" "$HEAD" > "$T/unclassified.out" 2>&1
rc=$?
set -e
assert_eq "unclassified normative edits fail" "1" "$rc"
grep -q '^UNCLASSIFIED: .github/workflows/ci.yml ' "$T/unclassified.out" && _t_ok || _t_bad "CI workflow change was not reported"
grep -q '^UNCLASSIFIED: docs/QA.md ' "$T/unclassified.out" && _t_ok || _t_bad "QA contract change was not reported"
! grep -q 'src/main.go' "$T/unclassified.out" && _t_ok || _t_bad "source-only edit entered normative audit"

QA_BASE=$(git -C "$FIX" rev-parse "$BASE:docs/QA.md")
QA_HEAD=$(git -C "$FIX" rev-parse "$HEAD:docs/QA.md")
CI_BASE=$(git -C "$FIX" rev-parse "$BASE:.github/workflows/ci.yml")
CI_HEAD=$(git -C "$FIX" rev-parse "$HEAD:.github/workflows/ci.yml")
printf 'docs/QA.md\t%s\t%s\tOPENWRT RELEVANT\tfixture tests OpenWrt quality gate\n' "$QA_BASE" "$QA_HEAD" >> "$LEDGER"
printf '.github/workflows/ci.yml\t%s\t%s\tDOC ONLY\tfixture CI wiring note\n' "$CI_BASE" "$CI_HEAD" >> "$LEDGER"
UPSTREAM_SYNC_REPO="$FIX" UPSTREAM_SYNC_LEDGER="$LEDGER" sh "$SCRIPT" "$BASE" "$HEAD" > "$T/classified.out" 2>&1
assert_eq "exact blob classifications pass" "0" "$?"
grep -q 'UPSTREAM_DOC_SYNC: classified 2 normative file(s)' "$T/classified.out" && _t_ok || _t_bad "classified summary missing"

sed 's/OPENWRT RELEVANT/INVALID/' "$LEDGER" > "$T/invalid.tsv"
set +e
UPSTREAM_SYNC_REPO="$FIX" UPSTREAM_SYNC_LEDGER="$T/invalid.tsv" sh "$SCRIPT" "$BASE" "$HEAD" >/dev/null 2>&1
rc=$?
set -e
assert_eq "unknown classification fails closed" "1" "$rc"

CODE_ONLY=$(git -C "$FIX" rev-parse HEAD)
printf 'package v3\n' > "$FIX/src/main.go"
git -C "$FIX" add src/main.go
git -C "$FIX" commit -qm code-only
CODE_HEAD=$(git -C "$FIX" rev-parse HEAD)
UPSTREAM_SYNC_REPO="$FIX" UPSTREAM_SYNC_LEDGER="$LEDGER" sh "$SCRIPT" "$CODE_ONLY" "$CODE_HEAD" > "$T/code-only.out" 2>&1
assert_eq "source-only diff needs no doc classification" "0" "$?"
grep -q 'no normative files changed' "$T/code-only.out" && _t_ok || _t_bad "source-only summary missing"

printf 'new normative contract\n' > "$FIX/docs/ADDED.md"
git -C "$FIX" add docs/ADDED.md
git -C "$FIX" commit -qm added-normative-file
ADDED_HEAD=$(git -C "$FIX" rev-parse HEAD)
ADDED_BLOB=$(git -C "$FIX" rev-parse "$ADDED_HEAD:docs/ADDED.md")
set +e
UPSTREAM_SYNC_REPO="$FIX" UPSTREAM_SYNC_LEDGER="$LEDGER" sh "$SCRIPT" "$CODE_HEAD" "$ADDED_HEAD" > "$T/added-unclassified.out" 2>&1
rc=$?
set -e
assert_eq "added normative file needs explicit classification" "1" "$rc"
grep -q "^UNCLASSIFIED: docs/ADDED.md base=- head=$ADDED_BLOB" "$T/added-unclassified.out" && _t_ok || _t_bad "added-file blob identity was not reported"
printf 'docs/ADDED.md\t-\t%s\tOPENWRT RELEVANT\tnew normative contract has OpenWrt behavior\n' "$ADDED_BLOB" >> "$LEDGER"
UPSTREAM_SYNC_REPO="$FIX" UPSTREAM_SYNC_LEDGER="$LEDGER" sh "$SCRIPT" "$CODE_HEAD" "$ADDED_HEAD" > "$T/added-classified.out" 2>&1
assert_eq "added normative file exact classification passes" "0" "$?"
grep -q 'UPSTREAM_DOC_SYNC: classified 1 normative file(s)' "$T/added-classified.out" && _t_ok || _t_bad "added-file classified summary missing"

_t_done
