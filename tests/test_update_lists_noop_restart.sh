#!/bin/sh
# Старый маркер применения списков не должен вызывать ночной рестарт при 304.
TESTS_PASSED=0
TESTS_FAILED=0
assert_eq() {
    if [ "$2" = "$3" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf '[PASS] %s\n' "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf '[FAIL] %s: expected [%s] got [%s]\n' "$1" "$2" "$3"
    fi
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${1:-${Z2K_UPDATE_LISTS_UNDER_TEST:-$ROOT/files/z2k-update-lists.sh}}"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
[ -r "$SCRIPT" ] || { printf '[FAIL] источник недоступен: %s\n' "$SCRIPT" >&2; exit 2; }

Z2K_UL_SOURCE_ONLY=1
export Z2K_UL_SOURCE_ONLY
# shellcheck disable=SC1090
. "$SCRIPT"

ZAPRET2_DIR="$SB/opt/zapret2"
LOG_FILE="$SB/update-lists.log"
mkdir -p "$ZAPRET2_DIR/lists/warp/games"
cat > "$ZAPRET2_DIR/z2k-geosite.sh" <<'EOF'
#!/bin/sh
echo '[2026-10-27 02:15:00] rkn: 304 Not Modified (ETag match)'
exit 0
EOF
chmod 0755 "$ZAPRET2_DIR/z2k-geosite.sh"

INDEX="$SB/sources.json"
printf '{"output":{"games_dir":"games"},"game_map":{},"domain_game_hints":{}}\n' > "$INDEX"
z2k_fetch() {
    Z2K_FETCH_ALL_404=0
    Z2K_FETCH_AUTH_404=0
    case "$1" in
        *sources.json) cp -f "$INDEX" "$2" 2>/dev/null; return 0 ;;
        *) return 1 ;;
    esac
}

INIT_SCRIPT="$SB/S99zapret2"
cat > "$INIT_SCRIPT" <<EOF
#!/bin/sh
printf '%s\\n' "\$1" > "$SB/restarted"
EOF
chmod 0755 "$INIT_SCRIPT"
printf '[2026-10-26 02:15:00] [geosite] rkn: applied, 50000 domains\n' > "$LOG_FILE"

main >/dev/null 2>&1
assert_eq "старый маркер не вызывает рестарт при 304" "0" "$([ -f "$SB/restarted" ] && echo 1 || echo 0)"
assert_eq "записано unchanged (ETag match)" "1" "$(grep -c 'geosite: all assets unchanged (ETag match)' "$LOG_FILE")"

printf '\nPASSED: %s\nFAILED: %s\n' "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
