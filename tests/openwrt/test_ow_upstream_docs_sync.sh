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
fixture_git() {
    (
        unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE
        git "$@"
    )
}
fixture_audit() {
    _ledger="$1"; shift
    (
        unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE
        UPSTREAM_SYNC_REPO="$FIX" UPSTREAM_SYNC_LEDGER="$_ledger" sh "$SCRIPT" "$@"
    )
}
fixture_git -C "$FIX" init -q
fixture_git -C "$FIX" config user.email test@example.invalid
fixture_git -C "$FIX" config user.name fixture
printf 'QA v1\n' > "$FIX/docs/QA.md"
printf 'name: CI\n' > "$FIX/.github/workflows/ci.yml"
printf 'package v1\n' > "$FIX/src/main.go"
fixture_git -C "$FIX" add .
fixture_git -C "$FIX" commit -qm base
BASE=$(fixture_git -C "$FIX" rev-parse HEAD)
printf 'QA v2\n' > "$FIX/docs/QA.md"
printf 'name: CI\n# release gate\n' > "$FIX/.github/workflows/ci.yml"
printf 'package v2\n' > "$FIX/src/main.go"
fixture_git -C "$FIX" add .
fixture_git -C "$FIX" commit -qm target
HEAD=$(fixture_git -C "$FIX" rev-parse HEAD)
SCRIPT="$REPO/scripts/openwrt/audit-upstream-docs.sh"
printf '# path\tbase_blob\thead_blob\tclassification\trationale\n' > "$LEDGER"

set +e
fixture_audit "$LEDGER" "$BASE" "$HEAD" > "$T/unclassified.out" 2>&1
rc=$?
set -e
assert_eq "unclassified normative edits fail" "1" "$rc"
grep -q '^UNCLASSIFIED: .github/workflows/ci.yml ' "$T/unclassified.out" && _t_ok || _t_bad "CI workflow change was not reported"
grep -q '^UNCLASSIFIED: docs/QA.md ' "$T/unclassified.out" && _t_ok || _t_bad "QA contract change was not reported"
! grep -q 'src/main.go' "$T/unclassified.out" && _t_ok || _t_bad "source-only edit entered normative audit"

QA_BASE=$(fixture_git -C "$FIX" rev-parse "$BASE:docs/QA.md")
QA_HEAD=$(fixture_git -C "$FIX" rev-parse "$HEAD:docs/QA.md")
CI_BASE=$(fixture_git -C "$FIX" rev-parse "$BASE:.github/workflows/ci.yml")
CI_HEAD=$(fixture_git -C "$FIX" rev-parse "$HEAD:.github/workflows/ci.yml")
printf 'docs/QA.md\t%s\t%s\tOPENWRT RELEVANT\tfixture tests OpenWrt quality gate\n' "$QA_BASE" "$QA_HEAD" >> "$LEDGER"
printf '.github/workflows/ci.yml\t%s\t%s\tDOC ONLY\tfixture CI wiring note\n' "$CI_BASE" "$CI_HEAD" >> "$LEDGER"
fixture_audit "$LEDGER" "$BASE" "$HEAD" > "$T/classified.out" 2>&1
assert_eq "exact blob classifications pass" "0" "$?"
grep -q 'UPSTREAM_DOC_SYNC: classified 2 normative file(s)' "$T/classified.out" && _t_ok || _t_bad "classified summary missing"

sed 's/OPENWRT RELEVANT/INVALID/' "$LEDGER" > "$T/invalid.tsv"
set +e
fixture_audit "$T/invalid.tsv" "$BASE" "$HEAD" >/dev/null 2>&1
rc=$?
set -e
assert_eq "unknown classification fails closed" "1" "$rc"

CODE_ONLY=$(fixture_git -C "$FIX" rev-parse HEAD)
printf 'package v3\n' > "$FIX/src/main.go"
fixture_git -C "$FIX" add src/main.go
fixture_git -C "$FIX" commit -qm code-only
CODE_HEAD=$(fixture_git -C "$FIX" rev-parse HEAD)
fixture_audit "$LEDGER" "$CODE_ONLY" "$CODE_HEAD" > "$T/code-only.out" 2>&1
assert_eq "source-only diff needs no doc classification" "0" "$?"
grep -q 'no normative files changed' "$T/code-only.out" && _t_ok || _t_bad "source-only summary missing"

_t_done
