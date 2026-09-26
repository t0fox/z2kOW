#!/bin/sh
# Require explicit classifications when normative upstream contracts change.
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <base-ref> <target-ref>" >&2
    exit 2
fi

repo=${UPSTREAM_SYNC_REPO:-$(git rev-parse --show-toplevel)}
ledger=${UPSTREAM_SYNC_LEDGER:-$repo/docs/UPSTREAM-SYNC.tsv}
base=$1
target=$2

git -C "$repo" rev-parse --verify "$base^{commit}" >/dev/null
git -C "$repo" rev-parse --verify "$target^{commit}" >/dev/null
[ -r "$ledger" ] || { echo "upstream sync ledger missing: $ledger" >&2; exit 2; }

# Every Markdown contract/design/QA note plus normative workflow and lifecycle
# scripts. Binary/source-only changes are out of scope.
changed=$(git -C "$repo" diff --no-renames --name-only --diff-filter=ACDM "$base" "$target" -- \
    '*.md' '.github/workflows/*' 'scripts/ci_local.sh' 'scripts/release.sh' \
    'scripts/openwrt/audit-upstream-docs.sh' \
    'release.sh' 'tests/run_all.sh' 'tests/mutation.sh' \
    'lib/auto_update.sh' 'lib/install.sh' 'webpanel/install.sh')

if [ -z "$changed" ]; then
    echo "UPSTREAM_DOC_SYNC: no normative files changed ($base..$target)"
    exit 0
fi

paths=$(mktemp "${TMPDIR:-/tmp}/z2k-upstream-docs.XXXXXX") || exit 2
trap 'rm -f "$paths"' EXIT HUP INT TERM
printf '%s\n' "$changed" > "$paths"

bad=0
count=0
while IFS= read -r path; do
    [ -n "$path" ] || continue
    count=$((count + 1))
    base_blob=$(git -C "$repo" rev-parse "$base:$path" 2>/dev/null || printf '%s' '-')
    head_blob=$(git -C "$repo" rev-parse "$target:$path" 2>/dev/null || printf '%s' '-')
    result=$(awk -F '\t' -v p="$path" -v b="$base_blob" -v h="$head_blob" '
        $0 ~ /^#/ || NF == 0 { next }
        $1 == p && $2 == b && $3 == h {
            n++
            class = $4
            rationale = $5
        }
        END {
            allowed = class == "OPENWRT RELEVANT" || class == "KEENETIC ONLY" ||
                      class == "RETIRED/HISTORICAL" || class == "DOC ONLY"
            if (n == 1 && allowed && rationale != "") {
                print class "\t" rationale
            } else {
                exit 1
            }
        }
    ' "$ledger" 2>/dev/null) || result=
    if [ -z "$result" ]; then
        echo "UNCLASSIFIED: $path base=$base_blob head=$head_blob"
        bad=1
    else
        class=$(printf '%s\n' "$result" | cut -f1)
        rationale=$(printf '%s\n' "$result" | cut -f2-)
        echo "CLASSIFIED: $path [$class] $rationale"
    fi
done < "$paths"

if [ "$bad" -ne 0 ]; then
    echo "UPSTREAM_DOC_SYNC: $count changed normative file(s), classification required" >&2
    exit 1
fi
echo "UPSTREAM_DOC_SYNC: classified $count normative file(s)"
