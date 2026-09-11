#!/bin/sh
# tests/openwrt/test_ow_immutable_ref.sh - §3-4: repo root + ref, не хардкод.
# Regression: fork-only ref НИКОГДА не обращается к necronicle/z2k/<ref>.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-immutable-ref"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/utils.sh" >/dev/null 2>&1 || exit 1
. "$REPO/lib/auto_update.sh" >/dev/null 2>&1 || exit 1

# Keenetic default: ref -> necronicle (без env — как раньше)
_got="$( ( unset Z2K_AU_RAW_BASE Z2K_AU_REPO_RAW; Z2K_AU_TARGET_REF=abc123; au_repo_base ) 2>/dev/null )"
assert_eq "keenetic ref" "https://raw.githubusercontent.com/necronicle/z2k/abc123" "$_got"

# OpenWrt: ref -> тот же repo (t0fox), НЕ necronicle
_got="$( ( Z2K_AU_RAW_BASE=https://raw.githubusercontent.com/t0fox/z2kOW; Z2K_AU_TARGET_REF=abc123; au_repo_base ) 2>/dev/null )"
assert_eq "openwrt ref" "https://raw.githubusercontent.com/t0fox/z2kOW/abc123" "$_got"
case "$_got" in
    *necronicle*) _t_bad "fork-only ref ушёл в necronicle: $_got" ;;
    *) _t_ok ;;
esac

# без ref — passthrough REPO_RAW в обоих мирах
_got="$( ( unset Z2K_AU_TARGET_REF Z2K_AU_RAW_BASE; Z2K_AU_REPO_RAW=https://example.invalid/x; au_repo_base ) 2>/dev/null )"
assert_eq "no-ref passthrough" "https://example.invalid/x" "$_got"

# reinstall-пин тоже через RAW_BASE (static): голый $VAR после necronicle/z2k/
# (без фигурных скобок) — это конкатенация ref, ей здесь не место. Дефолт
# necronicle/z2k/${Z2K_AU_BRANCH} ниже — легитимный keenetic-дефолт.
if grep -qE 'necronicle/z2k/\$[A-Za-z_]' "$REPO/lib/auto_update.sh"; then
    _t_bad "остался хардкод necronicle/z2k/<ref>"
else
    _t_ok
fi
# дефолты на месте (именно дефолты, не хардкод поведения)
assert_contains "RAW_BASE default" "$REPO/lib/auto_update.sh" 'Z2K_AU_RAW_BASE="${Z2K_AU_RAW_BASE:-https://raw.githubusercontent.com/necronicle/z2k}"'

_t_done
