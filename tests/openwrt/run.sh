#!/bin/sh
# tests/openwrt/run.sh — POSIX acceptance-runner; локально запускает весь набор.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

PASS=0
FAIL=0
FAILED=""
STRICT="${OW_STRICT:-0}"
SKIPPED=""
SHARD_COUNT="${OW_SHARD_COUNT:-1}"
SHARD_INDEX="${OW_SHARD_INDEX:-0}"
case "$SHARD_COUNT" in ''|*[!0-9]*|0) echo "invalid OW_SHARD_COUNT" >&2; exit 2 ;; esac
case "$SHARD_INDEX" in ''|*[!0-9]*) echo "invalid OW_SHARD_INDEX" >&2; exit 2 ;; esac
[ "$SHARD_INDEX" -lt "$SHARD_COUNT" ] || { echo "shard index out of range" >&2; exit 2; }

_selected_tests="$(python3 tests/openwrt/shard_tests.py --count "$SHARD_COUNT" --index "$SHARD_INDEX")" \
    || { echo "не удалось построить OpenWrt test-shard" >&2; exit 2; }
_selected=0

if [ "${OW_SKIP_SYNTAX_CHECK:-0}" != "1" ]; then
    _syntax_out="$(sh tests/openwrt/check_syntax.sh 2>&1)"
    _syntax_rc=$?
    printf '%s\n' "$_syntax_out"
    _syntax_pass="$(printf '%s\n' "$_syntax_out" | sed -n 's/^OPENWRT-SYNTAX: pass=\([0-9]*\) fail=.*/\1/p')"
    _syntax_fail="$(printf '%s\n' "$_syntax_out" | sed -n 's/^OPENWRT-SYNTAX: pass=[0-9]* fail=\([0-9]*\)/\1/p')"
    PASS=$((PASS + ${_syntax_pass:-0}))
    FAIL=$((FAIL + ${_syntax_fail:-1}))
    [ "$_syntax_rc" -eq 0 ] || FAILED="$FAILED syntax-check"
fi

_now_ns() {
    _value="$(date +%s%N 2>/dev/null)"
    case "$_value" in *N*|*[!0-9]*) printf '%s000000000' "$(date +%s)" ;; *) printf '%s' "$_value" ;; esac
}

# Тяжёлые тесты идут первыми, чтобы не оставлять длинный хвост в конце shard.
while IFS= read -r _t; do
    [ -n "$_t" ] || continue
    [ -f "$_t" ] || { echo "план указал отсутствующий тест: $_t" >&2; FAIL=$((FAIL + 1)); continue; }
    _selected=$((_selected + 1))
    _suite_started="$(_now_ns)"
    case "$_t" in
        *.sh)
            _out="$(sh "$_t" 2>&1)"
            _suite_rc=$?
            printf '%s\n' "$_out" | grep -E '^(SUITE|FAIL|SKIP)' || true
            if [ "$_suite_rc" -ne 0 ]; then
                printf 'OPENWRT-TEST-OUTPUT: %s\n' "${_t##*/}" >&2
                printf '%s\n' "$_out" >&2
            fi
            if printf '%s\n' "$_out" | grep -q '^SKIP'; then
                SKIPPED="$SKIPPED ${_t##*/}"
            fi
            _passed="$(printf '%s\n' "$_out" | sed -n 's/^SUITE\[.*\]: pass=\([0-9]*\) fail=.*/\1/p')"
            _failed="$(printf '%s\n' "$_out" | sed -n 's/^SUITE\[.*\]: pass=[0-9]* fail=\([0-9]*\)/\1/p')"
            if [ -z "$_failed" ]; then
                if [ "$_suite_rc" -eq 0 ]; then
                    [ -n "$_passed" ] || _passed=1
                    _failed=0
                else
                    _failed=1
                fi
            fi
            if [ "$_suite_rc" -ne 0 ] && [ "$_failed" = "0" ]; then
                _failed=1
            fi
            PASS=$((PASS + ${_passed:-0}))
            FAIL=$((FAIL + ${_failed:-1}))
            { [ "$_suite_rc" -eq 0 ] && [ "${_failed:-1}" = "0" ]; } || FAILED="$FAILED ${_t##*/}"
            ;;
        *.py)
            if python3 "$_t"; then
                _suite_rc=0
                PASS=$((PASS + 1))
            else
                _suite_rc=1
                FAIL=$((FAIL + 1))
                FAILED="$FAILED ${_t##*/}"
            fi
            ;;
        *)
            echo "неподдерживаемый тип OpenWrt-теста: $_t" >&2
            _suite_rc=1
            FAIL=$((FAIL + 1))
            FAILED="$FAILED ${_t##*/}"
            ;;
    esac
    _suite_finished="$(_now_ns)"
    printf 'OPENWRT-SUITE-TIME: %s elapsed_milliseconds=%s status=%s\n' \
        "${_t##*/}" "$(( (_suite_finished - _suite_started) / 1000000 ))" \
        "$([ "$_suite_rc" -eq 0 ] && printf pass || printf fail)"
done <<EOF
$_selected_tests
EOF

echo "OPENWRT: pass=$PASS fail=$FAIL"
echo "OPENWRT-SHARD: index=$SHARD_INDEX total=$SHARD_COUNT selected=$_selected"
[ "$_selected" -gt 0 ] || { echo "empty OpenWrt test shard" >&2; FAIL=$((FAIL + 1)); }
[ -n "$FAILED" ] && echo "FAILED:$FAILED" >&2
if [ "$STRICT" = "1" ] && [ -n "$SKIPPED" ]; then
    echo "STRICT-SKIP:$SKIPPED" >&2
    FAIL=$((FAIL + 1))
fi
[ "$FAIL" -eq 0 ]
