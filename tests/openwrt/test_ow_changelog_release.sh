#!/bin/sh
# Changelog release preparation promotes only the accumulated Unreleased notes.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-changelog-release"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$REPO/scripts/openwrt/changelog-release.py"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-changelog.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

cat > "$T/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

### Исправлено

- Пользовательское исправление.

## [1.2.2] - 2026-09-20

### Добавлено

- Предыдущая версия.
EOF

python3 "$TOOL" promote --changelog "$T/CHANGELOG.md" --version 1.2.3 \
    --date 2026-09-28 >"$T/promote.log" 2>&1
_rc=$?
if [ "$_rc" -ne 0 ]; then cat "$T/promote.log" >&2; fi
assert_eq "promote changelog rc" 0 "$_rc"
assert_eq "fresh Unreleased section is first" "## [Unreleased]" "$(sed -n '3p' "$T/CHANGELOG.md")"
assert_contains "release section carries an ISO date" "$T/CHANGELOG.md" "## [1.2.3] - 2026-09-28"
assert_contains "promoted section retains user-facing notes" "$T/CHANGELOG.md" "Пользовательское исправление."
assert_contains "older dated release remains intact" "$T/CHANGELOG.md" "## [1.2.2] - 2026-09-20"
sed -n '3,/^## \[1\.2\.3\]/{ /^## \[1\.2\.3\]/!p; }' "$T/CHANGELOG.md" >"$T/fresh-unreleased.md"
assert_not_contains "fresh Unreleased section does not duplicate old notes" \
    "$T/fresh-unreleased.md" "Пользовательское исправление\."

cp "$T/CHANGELOG.md" "$T/empty-before.md"
python3 "$TOOL" promote --changelog "$T/CHANGELOG.md" --version 1.2.4 \
    --date 2026-09-28 >"$T/empty.log" 2>&1
_rc=$?
assert_eq "empty Unreleased section is rejected" 1 "$( [ "$_rc" -ne 0 ] && echo 1 || echo 0 )"
assert_eq "rejected empty promotion leaves changelog unchanged" \
    "$(sha256sum "$T/empty-before.md" | awk '{print $1}')" \
    "$(sha256sum "$T/CHANGELOG.md" | awk '{print $1}')"

cp "$T/CHANGELOG.md" "$T/old-version-before.md"
python3 "$TOOL" promote --changelog "$T/CHANGELOG.md" --version 1.2.2 \
    --date 2026-09-28 >"$T/old-version.log" 2>&1
_rc=$?
assert_eq "version not newer than history is rejected" 1 "$( [ "$_rc" -ne 0 ] && echo 1 || echo 0 )"
assert_eq "rejected old version leaves changelog unchanged" \
    "$(sha256sum "$T/old-version-before.md" | awk '{print $1}')" \
    "$(sha256sum "$T/CHANGELOG.md" | awk '{print $1}')"

python3 "$TOOL" promote --changelog "$T/CHANGELOG.md" --version 1.2.4 \
    --date 2026-02-30 >"$T/date.log" 2>&1
_rc=$?
assert_eq "invalid calendar date is rejected" 1 "$( [ "$_rc" -ne 0 ] && echo 1 || echo 0 )"

cat > "$T/misordered.md" <<'EOF'
# Changelog

## [1.2.2] - 2026-09-20

- Previous release.

## [Unreleased]

- New change.
EOF
cp "$T/misordered.md" "$T/misordered-before.md"
python3 "$TOOL" promote --changelog "$T/misordered.md" --version 1.2.3 \
    --date 2026-09-28 >"$T/misordered.log" 2>&1
_rc=$?
assert_eq "Unreleased must precede dated versions" 1 "$( [ "$_rc" -ne 0 ] && echo 1 || echo 0 )"
assert_eq "rejected misordered promotion leaves changelog unchanged" \
    "$(sha256sum "$T/misordered-before.md" | awk '{print $1}')" \
    "$(sha256sum "$T/misordered.md" | awk '{print $1}')"

_t_done
