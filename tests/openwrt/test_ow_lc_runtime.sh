#!/bin/sh
# tests/openwrt/test_ow_lc_runtime.sh - Level C: disabled/tag-states/userdata.
# S15 здесь через настоящий update.sh in-process (а не только au_run_apply):
# доказывает, что весь launcher-путь уважает ENABLED=0.
# S17-rest: tag empty/corrupt/unknown/newer — безопасное поведение каждого.
# S20-fail: user-data переживает failed update + retry.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-lc-runtime"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LC_REPO="$REPO"; export LC_REPO
. "$(dirname "$0")/lc_harness.sh"
lc_init || { echo "FAIL[ow-lc-runtime]: init" >&2; exit 1; }
trap 'rm -rf "$LC_T"' EXIT INT TERM

# --- S15: ENABLED=0 сквозь настоящий launcher ---
lc_fresh_sysroot || { echo "FAIL[ow-lc-runtime]: sysroot s15" >&2; exit 1; }
SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
# disabled-service witness
Z2K_LC_S15B=1
EOF
printf 'p-84.0|patch|ref840|lib/utils.sh|restart-service|false|false\n%s|patch|ref847|lib/utils.sh|restart-service|false|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
printf 'p-84.0\n' > "$Z2K_AU_INSTALLED_TAG_FILE"
printf 'ENABLED=0\n' > "$Z2K_ETC/config"
rm -f "$LC_T/daemon-alive"
: > "$LC_T/calls-init"
lc_begin; lc_snap s15-before
( export Z2K_ROOT Z2K_ETC Z2K_TMP Z2K_AU_MANUAL=1 Z2K_AU_NO_JITTER=1
  export Z2K_AU_PUBKEY=/nonexistent-pubkey.pem
  < /dev/null . "$Z2K_ROOT/platform/openwrt/update.sh" apply >/dev/null 2>&1 )
assert_eq "S15 launcher rc" "0" "$?"
assert_eq "S15 tag двинулся" "$SEEDTAG" "$(lc_tag)"
assert_contains "S15 payload новый" "$Z2K_ROOT/lib/utils.sh" "Z2K_LC_S15B=1"
assert_eq "S15 демон не поднят" "0" "$([ -f "$LC_T/daemon-alive" ] && echo 1 || echo 0)"
if grep -q "init:start" "$LC_T/calls-init" 2>/dev/null || grep -q "init:restart" "$LC_T/calls-init" 2>/dev/null; then
    _t_bad "S15 launcher дёрнул сервис при ENABLED=0"
else
    _t_ok
fi
lc_snap s15-after
lc_mutlog s15-before s15-after "S15 disabled full launcher"

# --- S17-rest: состояния tag (decide-уровень + fetch-отказ) ---
lc_fresh_sysroot || { echo "FAIL[ow-lc-runtime]: sysroot s17" >&2; exit 1; }
SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"
printf 'p-84.0|patch|ref840|lib/utils.sh||false|false\n%s|patch|ref847|lib/utils.sh||false|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
# NOTE: au_decide — чистая функция (манифест из origin, tag вручную).
_d() { au_decide "$1" "$LC_ORIGIN/manifest.json" 2>/dev/null | head -1 | awk '{print $1}'; }
assert_eq "S17 empty -> none" "none" "$(_d "")"
assert_eq "S17 unknown -> none" "none" "$(_d "p-00.0")"
assert_eq "S17 newer -> none" "none" "$(_d "p-99.99")"
assert_eq "S17 garbage -> none" "none" "$(_d 'p-84.0
GARBAGE')"
assert_eq "S17 current -> none" "none" "$(_d "$SEEDTAG")"
assert_eq "S17 behind -> patch" "patch" "$(_d "p-84.0")"

# --- S20-fail: user-data переживает failed update, retry чинит ---
lc_fresh_sysroot || { echo "FAIL[ow-lc-runtime]: sysroot s20" >&2; exit 1; }
SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
# s20 witness (arrives only on retry)
Z2K_LC_S20=1
EOF
printf 'p-84.0|patch|ref840|lib/utils.sh||false|false\n%s|patch|ref847|lib/utils.sh||false|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
printf 'p-84.0\n' > "$Z2K_AU_INSTALLED_TAG_FILE"
printf 'user-s20.example\n' >> "$Z2K_ETC/user-lists/whitelist.txt"
printf 'Z2K_DYNAMIC_TTL=0\n' >> "$Z2K_ETC/config"
export LC_FETCH_FAIL="lib/utils.sh"
lc_begin; lc_snap s20-before
lc_apply
unset LC_FETCH_FAIL
assert_eq "S20 fail rc" "1" "$LC_RC"
assert_eq "S20 tag стоит" "p-84.0" "$(lc_tag)"
assert_contains "S20 whitelist цел" "$Z2K_ETC/user-lists/whitelist.txt" "user-s20.example"
assert_contains "S20 флаг цел" "$Z2K_ETC/config" "Z2K_DYNAMIC_TTL=0"
lc_apply
assert_eq "S20 retry rc" "0" "$LC_RC"
assert_eq "S20 tag двинулся" "$SEEDTAG" "$(lc_tag)"
assert_contains "S20 payload новый" "$Z2K_ROOT/lib/utils.sh" "Z2K_LC_S20=1"
assert_contains "S20 whitelist после retry" "$Z2K_ETC/user-lists/whitelist.txt" "user-s20.example"
lc_snap s20-after
lc_mutlog s20-before s20-after "S20 fail+retry user-data"

_t_done
