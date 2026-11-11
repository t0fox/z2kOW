#!/bin/sh
# Проверка OpenWrt nftables-моста для Lua-проверки Googlevideo.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-preflight"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-preflight.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/tmp"
cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NFT_CALLS"
case "$*" in
    "list chain inet z2k_preflight postrouting") [ "${NFT_HAS_CHAIN:-0}" = 1 ] ;;
    "list table inet z2k_preflight") [ "${NFT_HAS_TABLE:-0}" = 1 ] ;;
    "-f -") cat > "$NFT_BATCH"; exit "${NFT_BATCH_RC:-0}" ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$T/bin/nft"
export PATH="$T/bin:/usr/bin:/bin" NFT_CALLS="$T/calls" NFT_BATCH="$T/batch"
export Z2K_TMP="$T/tmp" DESYNC_MARK=0x40000000 INIT_APPLY_FW=1
. "$REPO/platform/openwrt/paths.sh"
. "$REPO/platform/openwrt/preflight.sh"

Z2K_GV_SERVER_REPLY2=0 Z2K_CATEGORY_YOUTUBE=1
export Z2K_GV_SERVER_REPLY2 Z2K_CATEGORY_YOUTUBE
z2k_ow_preflight_apply && _t_ok || _t_bad "выключенная проверка удаляет свою таблицу"
assert_contains "отключение чистит только таблицу preflight" "$NFT_CALLS" \
    'delete table inet z2k_preflight'
assert_not_contains "отключение не меняет fw4 таблицу" "$NFT_CALLS" 'inet fw4'

: > "$NFT_CALLS"; rm -f "$NFT_BATCH"
Z2K_GV_SERVER_REPLY2=1; export Z2K_GV_SERVER_REPLY2
z2k_ow_preflight_apply && _t_ok || _t_bad "создание таблицы preflight"
assert_contains "таблица создаётся под собственным именем" "$NFT_BATCH" \
    'add table inet z2k_preflight'
assert_contains "hook выполняется перед NAT fw4" "$NFT_BATCH" \
    'priority srcnat - 1'
assert_contains "NAT ограничен mark движка и TCP 443" "$NFT_BATCH" \
    'meta nfproto ipv4 meta mark & 0x40000000 == 0x40000000 tcp dport 443 masquerade'
assert_contains "NAT помечен владельцем OpenWrt" "$NFT_BATCH" \
    'comment "z2k-openwrt: googlevideo preflight"'

NFT_HAS_CHAIN=1; NFT_HAS_TABLE=1; export NFT_HAS_CHAIN NFT_HAS_TABLE
: > "$NFT_CALLS"; rm -f "$NFT_BATCH"
z2k_ow_preflight_apply && _t_ok || _t_bad "обновление существующей таблицы"
assert_contains "повторная настройка атомарно очищает только свою цепь" "$NFT_BATCH" \
    'flush chain inet z2k_preflight postrouting'
assert_not_contains "повторная настройка не создаёт чужую цепь" "$NFT_BATCH" 'add chain inet fw4'

DESYNC_MARK='0x40000000; add rule inet fw4 input accept'
export DESYNC_MARK
: > "$NFT_CALLS"; rm -f "$NFT_BATCH"
z2k_ow_preflight_apply && _t_bad "недоверенная метка принята" || _t_ok
assert_not_contains "невалидная метка не попадает в nft batch" "$NFT_CALLS" '"-f -"'

DESYNC_MARK=0x40000000; Z2K_CATEGORY_YOUTUBE=0
export DESYNC_MARK Z2K_CATEGORY_YOUTUBE
: > "$NFT_CALLS"
z2k_ow_preflight_apply && _t_ok || _t_bad "категория YouTube снимает preflight"
assert_contains "выключенная категория удаляет только свою таблицу" "$NFT_CALLS" \
    'delete table inet z2k_preflight'

assert_contains "Lua-модуль загружается из OpenWrt payload" \
    "$REPO/platform/openwrt/optbase.sh" 'z2k-preflight'
assert_contains "основная служба подключает nft adapter" \
    "$REPO/platform/openwrt/files/etc/init.d/z2k" 'preflight.sh'
assert_contains "firewall apply восстанавливает NAT-правило" \
    "$REPO/platform/openwrt/firewall.sh" 'z2k_ow_preflight_apply'

_t_done
