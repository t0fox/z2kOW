#!/bin/sh
# tests/openwrt/test_ow_release_map.sh - §3: platform-aware release mapping.
#   1. Keenetic-регрессия: каждое назначение из install_map подписанного
#      UPDATES.json побайтово совпадает с z2k_install_paths_for keenetic
#      (дефолт z2k_install_paths — тоже keenetic).
#   2. OpenWrt-полнота: обязательные deliverables имеют назначения под
#      разрешёнными корнями; неизвестная платформа — пусто (fail-safe).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-release-map"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/release_map.sh" || { echo "FAIL[ow-release-map]: release_map" >&2; exit 1; }

# --- 1. keenetic: сверка с подписанным манифестом ---
_mapdump="$(mktemp)" || exit 1
trap 'rm -f "$_mapdump"' EXIT INT TERM
awk '
    /"install_map"[[:space:]]*:[[:space:]]*\{/ {inmap=1; next}
    inmap && /^[[:space:]]*\},?/ {inmap=0}
    inmap {
        line=$0
        if (match(line, /"[^"]+"[[:space:]]*:[[:space:]]*\[/)) {
            key=substr(line, RSTART+1)
            sub(/"[[:space:]]*:.*/, "", key)
            rest=substr(line, RSTART+RLENGTH)
            sub(/\].*/, "", rest)
            gsub(/",[[:space:]]*"/, "\n", rest)
            gsub(/^"/, "", rest); gsub(/"$/, "", rest)
            n=split(rest, arr, "\n")
            for (i=1; i<=n; i++) printf "%s\t%s\n", key, arr[i]
        }
    }' "$REPO/UPDATES.json" >"$_mapdump"
_n=0; _bad=""
_prev=""; _want=" "
_check_key() {
    [ -n "$_prev" ] || return 0
    _n=$((_n + 1))
    _got="$(ZAPRET2_DIR=/opt/zapret2 Z2K_PLATFORM=keenetic z2k_install_paths "$_prev" 2>/dev/null | LC_ALL=C sort | tr '\n' '|')"
    _w="$(printf '%s\n' "$_want" | LC_ALL=C sort | tr '\n' '|')"
    [ "$_got" = "$_w" ] || _bad="$_bad $_prev"
}
while IFS="$(printf '\t')" read -r _k _v; do
    [ -n "$_k" ] || continue
    if [ "$_k" != "$_prev" ]; then
        _check_key
        _prev="$_k"; _want="$_v"
    else
        _want="$_want
$_v"
    fi
done <"$_mapdump"
_check_key
[ "$_n" -gt 50 ] && _t_ok || _t_bad "install_map беден для регрессии: $_n"
[ -z "$_bad" ] && _t_ok || _t_bad "keenetic-расхождение:$((_bad))"

# дефолт без Z2K_PLATFORM — keenetic
unset Z2K_PLATFORM
assert_eq "дефолт=keenetic" "$(z2k_install_paths files/lua/z2k-alert.lua)" "/opt/zapret2/lua/z2k-alert.lua"

# --- 2. openwrt: updater-доставляемое имеет назначения под /usr/lib/z2k ---
_ow() { Z2K_PLATFORM=openwrt z2k_install_paths "$1" 2>/dev/null; }
assert_eq "lib" "/usr/lib/z2k/lib/utils.sh" "$(_ow lib/utils.sh)"
assert_eq "lua" "/usr/lib/z2k/lua/z2k-alert.lua" "$(_ow files/lua/z2k-alert.lua)"
assert_eq "fake" "/usr/lib/z2k/fake/stun.bin" "$(_ow files/fake/stun.bin)"
assert_eq "validator" "/usr/lib/z2k/z2k-config-validator.sh" "$(_ow files/z2k-config-validator.sh)"
assert_eq "manifest tcp" "/usr/lib/z2k/strats_new2.txt" "$(_ow strats_new2.txt)"
assert_eq "manifest quic" "/usr/lib/z2k/quic_strats.ini" "$(_ow quic_strats.ini)"
assert_eq "pem" "/usr/lib/z2k/etc/z2k-update-pub.pem" "$(_ow files/etc/z2k-update-pub.pem)"
assert_eq "pool list" "/usr/lib/z2k/extra_strats/TCP/RKN/List.txt" "$(_ow files/lists/extra_strats/TCP/RKN/List.txt)"
# p-84.21/22 domain delivery: extra-domains едет updater'ом под openwrt-корень
# (soundcloud.cloud, amazonaws.com, cloudfront.net — см. seed-тест).
if _ow files/lists/extra-domains.txt 2>/dev/null | grep -qxF '/usr/lib/z2k/lists/extra-domains.txt'; then _t_ok
else _t_bad "extra-domains без openwrt-назначения"; fi

# Model A (§4): package-owned НЕ имеет updater-маппингов (только opkg)
assert_eq "adapter sh без маппинга" "" "$(_ow platform/openwrt/paths.sh)"
assert_eq "service без маппинга" "" "$(_ow package/openwrt/files/etc/init.d/z2k)"
assert_eq "hotplug без маппинга" "" "$(_ow package/openwrt/files/etc/hotplug.d/iface/90-z2k)"
assert_eq "config template без маппинга" "" "$(_ow package/openwrt/files/etc/z2k/config.default)"
assert_eq "adapter без шагов" "" "$(z2k_steps_for platform/openwrt/paths.sh)"

# keenetic-only на openwrt пусты (не теряются молча — их держит drift-тест)
assert_eq "S99 без маппинга" "" "$(_ow files/S99zapret2.new)"
assert_eq "ndm без маппинга" "" "$(_ow files/ndm/90-z2k-tg-redirect.sh)"

# --- 3. fail-safe: неизвестная платформа — пусто ---
[ -z "$(z2k_install_paths_for mars platform/openwrt/paths.sh 2>/dev/null)" ] \
    && _t_ok || _t_bad "неизвестная платформа даёт назначения"
[ -z "$(z2k_install_paths_for mars files/lua/z2k-alert.lua 2>/dev/null)" ] \
    && _t_ok || _t_bad "неизвестная платформа даёт keenetic-адреса"

_t_done
