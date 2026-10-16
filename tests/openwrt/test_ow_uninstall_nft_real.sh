#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"

if [ "${1:-}" = --inside ]; then
    . "${Z2K_OW_UNINSTALL_SOURCE:-$ROOT/platform/openwrt/uninstall.sh}"
    T="$2"
    _fw4_created=0
    _zapret2_created=0
    cleanup() {
        [ "$_zapret2_created" = 0 ] || nft delete table inet zapret2 2>/dev/null || true
        [ "$_fw4_created" = 0 ] || nft delete table inet fw4 2>/dev/null || true
    }
    trap cleanup EXIT HUP INT TERM

    if nft list table inet zapret2 >/dev/null 2>&1; then
        echo "таблица inet zapret2 уже существует; тест требует чистого QEMU" >&2
        exit 1
    fi
    if ! nft list table inet fw4 >/dev/null 2>&1; then
        nft add table inet fw4
        _fw4_created=1
    fi
    nft add table inet zapret2
    _zapret2_created=1
    nft add flowtable inet zapret2 ft '{ hook ingress priority filter; devices = { lo }; }'
    nft add chain inet zapret2 flow_offload
    nft add chain inet zapret2 flow_offload_zapret
    nft add chain inet zapret2 flow_offload_always
    nft add chain inet zapret2 forward_hook
    nft add chain inet zapret2 postnat_hook
    nft add chain inet zapret2 prenat_hook
    nft add chain inet zapret2 postnat
    nft add chain inet zapret2 prenat
    nft add chain inet zapret2 forward
    nft add chain inet zapret2 input
    nft add chain inet zapret2 output
    if ! Z2K_OW_NFT_BIN=nft _z2k_ow_uninstall_zapret2_table; then
        echo "не удалось удалить штатные flowtable и цепочки zapret2" >&2
        exit 1
    fi
    _zapret2_created=0
    if nft list table inet zapret2 >/dev/null 2>&1; then
        echo "штатные flowtable и цепочки zapret2 пережили полное удаление" >&2
        exit 1
    fi

    nft add table inet zapret2
    _zapret2_created=1
    nft add set inet zapret2 zapret '{ type ipv4_addr; }'
    nft add set inet zapret2 ipban '{ type ipv4_addr; }'
    nft add set inet zapret2 nozapret '{ type ipv4_addr; }'
    nft add set inet zapret2 zapret6 '{ type ipv6_addr; }'
    nft add set inet zapret2 ipban6 '{ type ipv6_addr; }'
    nft add set inet zapret2 nozapret6 '{ type ipv6_addr; }'
    nft add set inet zapret2 wanif '{ type ifname; }'
    nft add set inet zapret2 wanif6 '{ type ifname; }'
    nft add set inet zapret2 lanif '{ type ifname; }'
    nft add element inet zapret2 zapret '{ 192.0.2.1 }'

    if ! Z2K_OW_NFT_BIN=nft _z2k_ow_uninstall_zapret2_table; then
        echo "не удалось удалить штатные наборы zapret2" >&2
        exit 1
    fi
    _zapret2_created=0
    if nft list table inet zapret2 >/dev/null 2>&1; then
        echo "принадлежащая таблица zapret2 пережила полное удаление" >&2
        exit 1
    fi
    nft list table inet fw4 >/dev/null
    Z2K_OW_NFT_BIN=nft _z2k_ow_uninstall_zapret2_table

    nft add table inet zapret2
    _zapret2_created=1
    nft add set inet zapret2 foreign '{ type ipv4_addr; }'
    if Z2K_OW_NFT_BIN=nft _z2k_ow_uninstall_zapret2_table; then
        echo "неизвестный набор принят за принадлежащий z2kOW" >&2
        exit 1
    fi
    nft list set inet zapret2 foreign >/dev/null

    nft delete table inet zapret2
    _zapret2_created=0
    nft add table inet zapret2
    _zapret2_created=1
    nft add chain inet zapret2 foreign
    if Z2K_OW_NFT_BIN=nft _z2k_ow_uninstall_zapret2_table; then
        echo "чужая цепочка принята за принадлежащую z2kOW" >&2
        exit 1
    fi
    nft list chain inet zapret2 foreign >/dev/null

    if Z2K_OW_NFT_BIN="$T/missing-nft" _z2k_ow_uninstall_zapret2_table; then
        echo "ошибка чтения nft принята за подтверждение очистки" >&2
        exit 1
    fi
    nft list chain inet zapret2 foreign >/dev/null
    printf 'SUITE[ow-uninstall-real-nft]: pass\n'
    exit 0
fi

for tool in unshare nft; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "требуется настоящий инструмент $tool" >&2
        exit 1
    }
done
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-uninstall-nft.XXXXXX")"
trap 'rm -rf "$T"' EXIT HUP INT TERM
if [ "${Z2K_WARP_ROOT_NETNS:-0}" = 1 ]; then
    if [ "$(id -u)" -eq 0 ]; then
        unshare -n sh "$0" --inside "$T"
    else
        sudo -n env Z2K_OW_UNINSTALL_SOURCE="${Z2K_OW_UNINSTALL_SOURCE:-$ROOT/platform/openwrt/uninstall.sh}" \
            unshare -n sh "$0" --inside "$T"
    fi
else
    unshare -Urn sh "$0" --inside "$T"
fi
