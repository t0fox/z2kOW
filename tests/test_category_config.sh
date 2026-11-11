#!/bin/sh
# Category combinations and persistence in the real config generator.
# Run: sh tests/test_category_config.sh
# POSIX sh compatible (busybox ash).

TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf "[PASS] %s\n" "$desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf "[FAIL] %s: expected '%s', got '%s'\n" "$desc" "$expected" "$actual"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            TESTS_PASSED=$((TESTS_PASSED + 1))
            printf "[PASS] %s\n" "$desc"
            ;;
        *)
            TESTS_FAILED=$((TESTS_FAILED + 1))
            printf "[FAIL] %s: output does not contain '%s'\n" "$desc" "$needle"
            ;;
    esac
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            TESTS_FAILED=$((TESTS_FAILED + 1))
            printf "[FAIL] %s: output unexpectedly contains '%s'\n" "$desc" "$needle"
            ;;
        *)
            TESTS_PASSED=$((TESTS_PASSED + 1))
            printf "[PASS] %s\n" "$desc"
            ;;
    esac
}

# ==============================================================================
# SETUP: mock filesystem in /tmp to avoid touching /opt/zapret2
# ==============================================================================

MOCK_DIR="/tmp/z2k_test_config_$$"
MOCK_ZAPRET2="${MOCK_DIR}/opt/zapret2"
MOCK_CONFIG_DIR="${MOCK_DIR}/opt/etc/zapret2"
MOCK_EXTRA_STRATS="${MOCK_ZAPRET2}/extra_strats"
MOCK_LISTS="${MOCK_ZAPRET2}/lists"

mkdir -p "$MOCK_EXTRA_STRATS/TCP/YT" \
         "$MOCK_EXTRA_STRATS/TCP/YT_GV" \
         "$MOCK_EXTRA_STRATS/TCP/RKN" \
         "$MOCK_EXTRA_STRATS/UDP/YT" \
         "$MOCK_EXTRA_STRATS/cache/autocircular" \
         "$MOCK_LISTS" \
         "$MOCK_CONFIG_DIR" \
         "$MOCK_ZAPRET2/nfq2"

# Create mock hostlist files (non-empty so profiles are included)
echo "youtube.com" > "$MOCK_EXTRA_STRATS/TCP/YT/List.txt"
printf 'googlevideo.com\nc.youtube.com\n' > "$MOCK_EXTRA_STRATS/TCP/YT_GV/List.txt"
echo "youtube.com" > "$MOCK_EXTRA_STRATS/UDP/YT/List.txt"
echo "rutracker.org" > "$MOCK_EXTRA_STRATS/TCP/RKN/List.txt"
echo "whitelisted.example.com" > "$MOCK_LISTS/whitelist.txt"

# Create sample strategy files
echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6:strategy=1" > "$MOCK_EXTRA_STRATS/TCP/RKN/Strategy.txt"
echo "--filter-tcp=443 --filter-l7=tls --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=4" > "$MOCK_EXTRA_STRATS/TCP/YT/Strategy.txt"
echo "--filter-tcp=443 --filter-l7=tls --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=4" > "$MOCK_EXTRA_STRATS/TCP/YT_GV/Strategy.txt"
echo "--filter-udp=443 --filter-l7=quic --lua-desync=circular:fails=3:time=60:key=quic --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=3:strategy=1" > "$MOCK_EXTRA_STRATS/UDP/YT/Strategy.txt"

# Create mock config (no Austerus)
echo "ENABLED=1" > "$MOCK_ZAPRET2/config"

# Source utils.sh first (provides safe_config_read, print_*, etc.)
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$SCRIPT_DIR/lib/utils.sh"

# Restore paths after sourcing (utils.sh sets global ZAPRET2_DIR etc.)
ZAPRET2_DIR="$MOCK_ZAPRET2"
CONFIG_DIR="$MOCK_CONFIG_DIR"
LISTS_DIR="$MOCK_LISTS"

# ==============================================================================
trap 'rm -rf "$MOCK_DIR"' EXIT
. "$SCRIPT_DIR/lib/config_official.sh"
for templates in 0 1; do
for yt in 0 1; do
 for rkn in 0 1; do
  for voice in 0 1; do
   printf 'Z2K_CATEGORY_YOUTUBE=%s\nZ2K_CATEGORY_RKN=%s\nZ2K_CATEGORY_DISCORD_VOICE=%s\nZ2K_AUTOHOSTLIST=1\nZ2K_NFQWS2_TEMPLATES=%s\n' "$yt" "$rkn" "$voice" "$templates" > "$MOCK_ZAPRET2/config"
   output=$(generate_nfqws2_opt_from_strategies)
   if [ "$yt" = 0 ]; then
    if [ "$rkn" = 1 ]; then
     assert_contains "YT off: broad profiles exclude Googlevideo" "--hostlist-exclude=$MOCK_EXTRA_STRATS/TCP/YT_GV/List.txt" "$output"
    fi
    assert_not_contains "YT off: no TCP YT"  '--hostlist='"$MOCK_EXTRA_STRATS/TCP/YT/" "$output"
    assert_not_contains "YT off: no GV"  '--hostlist='"$MOCK_EXTRA_STRATS/TCP/YT_GV/" "$output"
    assert_not_contains "YT off: no QUIC YT" '--hostlist='"$MOCK_EXTRA_STRATS/UDP/YT/" "$output"
   else
    assert_contains "YT on"  '--hostlist='"$MOCK_EXTRA_STRATS/TCP/YT/" "$output"
   fi
   if [ "$rkn" = 0 ]; then
    assert_not_contains "RKN off: TLS" 'key=rkn_tcp' "$output"
    assert_not_contains "RKN off: HTTP" 'key=http_rkn' "$output"
    assert_not_contains "RKN off: lists" '--hostlist='"$MOCK_EXTRA_STRATS/TCP/RKN/" "$output"
    assert_not_contains "RKN off: discovery" '--hostlist-auto=' "$output"
   else
    assert_contains "RKN on" 'key=rkn_tcp' "$output"
   fi
   if [ "$voice" = 0 ]; then
    assert_not_contains "voice off: STUN" 'stun' "$output"
    assert_not_contains "voice off: Discord UDP" 'key=discord_udp' "$output"
   else
    assert_contains "voice on" 'key=discord_udp' "$output"
   fi
   if [ "$yt$rkn" = 00 ]; then
    assert_not_contains "both off: no QUIC" 'key=quic' "$output"
   else
    assert_contains "remaining category keeps QUIC" 'key=quic' "$output"
   fi
   assert_contains "WhatsApp remains independent" '--filter-tcp=5222' "$output"
   assert_contains "UDP whitelist bypass is present" "--filter-udp=1-65535 --hostlist=$MOCK_LISTS/whitelist.txt --new" "$output"
   _bypass_line=$(printf '%s\n' "$output" | grep -n -F -- "--filter-udp=1-65535 --hostlist=$MOCK_LISTS/whitelist.txt" | head -1 | cut -d: -f1)
   if [ "$voice" = 1 ]; then
    _voice_line=$(printf '%s\n' "$output" | grep -n -F -- 'key=discord_udp' | head -1 | cut -d: -f1)
    [ -n "$_bypass_line" ] && [ -n "$_voice_line" ] && [ "$_bypass_line" -lt "$_voice_line" ] \
     && assert_eq "UDP whitelist precedes Discord voice" 1 1 \
     || assert_eq "UDP whitelist precedes Discord voice" 1 0
   fi
  done
 done
done
done

# Первый совпавший профиль определяет набор стратегий: c.youtube.com и его
# поддомены должны попасть в отдельный GV-пул раньше youtube.com.
printf 'ENABLED=1\nZ2K_CATEGORY_YOUTUBE=1\nZ2K_CATEGORY_RKN=1\nZ2K_REFACTOR_PHASE3=0\n' > "$MOCK_ZAPRET2/config"
output=$(generate_nfqws2_opt_from_strategies)
_gv_line=$(printf '%s\n' "$output" | grep -n -F -- '/TCP/YT_GV/List.txt' | head -1 | cut -d: -f1)
_yt_line=$(printf '%s\n' "$output" | grep -n -F -- '/TCP/YT/List.txt' | head -1 | cut -d: -f1)
if [ -n "$_gv_line" ] && [ -n "$_yt_line" ] && [ "$_gv_line" -lt "$_yt_line" ]; then
 assert_eq "GV-профиль предшествует вложенным доменам YouTube" 1 1
else
 assert_eq "GV-профиль предшествует вложенным доменам YouTube" 1 0
fi
assert_contains "YouTube исключает домены GV" "--hostlist-exclude=$MOCK_EXTRA_STRATS/TCP/YT_GV/List.txt" "$output"

# QUIC-переключатели должны поставить drop перед рабочим профилем, уважая
# whitelist; выбор «только YouTube» не действует при выключенной категории.
printf 'ENABLED=1\nZ2K_CATEGORY_YOUTUBE=1\nZ2K_CATEGORY_RKN=1\nZ2K_YT_QUIC_OFF=1\n' > "$MOCK_ZAPRET2/config"
output=$(generate_nfqws2_opt_from_strategies)
assert_contains "YouTube без QUIC: свой hostlist" "--hostlist=$MOCK_EXTRA_STRATS/UDP/YT/List.txt --filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=drop --new" "$output"
assert_contains "YouTube без QUIC: whitelist исключён" "--hostlist-exclude=$MOCK_LISTS/whitelist.txt --hostlist=$MOCK_EXTRA_STRATS/UDP/YT/List.txt" "$output"
_drop_line=$(printf '%s\n' "$output" | grep -n -F -- '--payload=quic_initial --lua-desync=drop --new' | head -1 | cut -d: -f1)
_quic_line=$(printf '%s\n' "$output" | grep -n -F -- 'key=quic' | head -1 | cut -d: -f1)
[ -n "$_drop_line" ] && [ -n "$_quic_line" ] && [ "$_drop_line" -lt "$_quic_line" ] \
 && assert_eq "QUIC drop precedes обходной профиль" 1 1 \
 || assert_eq "QUIC drop precedes обходной профиль" 1 0
printf 'ENABLED=1\nZ2K_CATEGORY_YOUTUBE=1\nZ2K_QUIC_OFF=1\nZ2K_YT_QUIC_OFF=1\n' > "$MOCK_ZAPRET2/config"
output=$(generate_nfqws2_opt_from_strategies)
assert_contains "Весь QUIC: один общий профиль" "--hostlist-exclude=$MOCK_LISTS/whitelist.txt --filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=drop --new" "$output"
printf 'ENABLED=1\nZ2K_CATEGORY_YOUTUBE=0\nZ2K_YT_QUIC_OFF=1\n' > "$MOCK_ZAPRET2/config"
output=$(generate_nfqws2_opt_from_strategies)
assert_not_contains "YouTube выключен: профиль drop не ставится" '--payload=quic_initial --lua-desync=drop --new' "$output"

# Missing flags keep the previous default behavior.
printf 'ENABLED=1\n' > "$MOCK_ZAPRET2/config"
output=$(generate_nfqws2_opt_from_strategies)
assert_contains "default YT" "--hostlist=$MOCK_EXTRA_STRATS/TCP/YT/List.txt" "$output"
assert_contains "default RKN" "key=rkn_tcp" "$output"
assert_contains "default voice" "key=discord_udp" "$output"
# Full regeneration must preserve switches, including a second regeneration.
printf 'ENABLED=0\nDISABLE_IPV6=1\nZ2K_CATEGORY_YOUTUBE=0\nZ2K_CATEGORY_RKN=0\nZ2K_CATEGORY_DISCORD_VOICE=0\nZ2K_QUIC_OFF=1\nZ2K_YT_QUIC_OFF=1\n' > "$MOCK_ZAPRET2/config"
for pass in 1 2; do
 create_official_config "$MOCK_ZAPRET2/config" >/dev/null 2>&1
 for key in YOUTUBE RKN DISCORD_VOICE; do
  assert_eq "preserve $key on regeneration $pass" 0 "$(safe_config_read "Z2K_CATEGORY_$key" "$MOCK_ZAPRET2/config" missing)"
 done
 assert_eq "stopped service remains stopped" 0 "$(safe_config_read ENABLED "$MOCK_ZAPRET2/config" missing)"
 assert_eq "preserve QUIC off on regeneration $pass" 1 "$(safe_config_read Z2K_QUIC_OFF "$MOCK_ZAPRET2/config" missing)"
 assert_eq "preserve YouTube QUIC off on regeneration $pass" 1 "$(safe_config_read Z2K_YT_QUIC_OFF "$MOCK_ZAPRET2/config" missing)"
done
printf '\nPASSED: %s FAILED: %s\n' "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" = 0 ]
