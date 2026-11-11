#!/bin/sh
# NAT для повторного IPv4 SYN, который отправляет Lua-проверка Googlevideo.

Z2K_PREFLIGHT_TABLE="${Z2K_PREFLIGHT_TABLE:-z2k_preflight}"

z2k_ow_preflight_wanted() {
    [ "${Z2K_GV_SERVER_REPLY2:-0}" = 1 ] \
        && [ "${Z2K_CATEGORY_YOUTUBE:-1}" != 0 ]
}

z2k_ow_preflight_remove() {
    nft delete table inet "$Z2K_PREFLIGHT_TABLE" >/dev/null 2>&1 || true
}

z2k_ow_preflight_apply() {
    local _mark="${DESYNC_MARK:-0x40000000}" _mark_hex
    if ! z2k_ow_preflight_wanted; then
        z2k_ow_preflight_remove
        return $?
    fi
    [ "${INIT_APPLY_FW:-1}" = 1 ] || return 1
    case "$_mark" in 0x[0-9a-fA-F]*) ;; *) return 1 ;; esac
    _mark_hex=${_mark#0x}
    case "$_mark_hex" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
    [ "${#_mark_hex}" -le 8 ] || return 1
    if nft list chain inet "$Z2K_PREFLIGHT_TABLE" postrouting >/dev/null 2>&1; then
        nft -f - <<EOF_PREFLIGHT
flush chain inet $Z2K_PREFLIGHT_TABLE postrouting
add rule inet $Z2K_PREFLIGHT_TABLE postrouting meta nfproto ipv4 meta mark & $_mark == $_mark tcp dport 443 masquerade comment "z2k-openwrt: googlevideo preflight"
EOF_PREFLIGHT
        return $?
    fi
    if nft list table inet "$Z2K_PREFLIGHT_TABLE" >/dev/null 2>&1; then
        nft -f - <<EOF_PREFLIGHT
add chain inet $Z2K_PREFLIGHT_TABLE postrouting { type nat hook postrouting priority srcnat - 1; policy accept; }
add rule inet $Z2K_PREFLIGHT_TABLE postrouting meta nfproto ipv4 meta mark & $_mark == $_mark tcp dport 443 masquerade comment "z2k-openwrt: googlevideo preflight"
EOF_PREFLIGHT
        return $?
    fi
    nft -f - <<EOF_PREFLIGHT
add table inet $Z2K_PREFLIGHT_TABLE
add chain inet $Z2K_PREFLIGHT_TABLE postrouting { type nat hook postrouting priority srcnat - 1; policy accept; }
add rule inet $Z2K_PREFLIGHT_TABLE postrouting meta nfproto ipv4 meta mark & $_mark == $_mark tcp dport 443 masquerade comment "z2k-openwrt: googlevideo preflight"
EOF_PREFLIGHT
}
