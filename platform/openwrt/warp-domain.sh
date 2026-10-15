#!/bin/sh
# OpenWrt entrypoints для пассивного DNS observer WARP.
# Чтение списков, состояние доменов и nft-операции принадлежат Rust-контроллеру.

WARP_DOMAIN_SET="${WARP_DOMAIN_SET:-z2k_warp_domain4}"
WARP_DOMAIN_RULES="${WARP_DOMAIN_RULES:-${Z2K_WARP_DOMAIN_RULES:-${Z2K_WARP_TMP:-/tmp/z2k-warp}/domains.v1}}"
WARP_DOMAIN_SNAPSHOT="${WARP_DOMAIN_SNAPSHOT:-/tmp/z2k-warp/domain-pairs.v1}"
WARP_DOMAIN_STATUS="${WARP_DOMAIN_STATUS:-/tmp/z2k-warp/domain-status.json}"
WARP_DOMAIN_ERROR="${WARP_DOMAIN_ERROR:-/tmp/z2k-warp/domain-setup-error}"
WARP_DOMAIN_NFT_FAMILY="${WARP_DOMAIN_NFT_FAMILY:-inet}"
WARP_DOMAIN_NFT_TABLE="${WARP_DOMAIN_NFT_TABLE:-z2k_warp_dns}"
WARP_DOMAIN_NFT_OUT="${WARP_DOMAIN_NFT_OUT:-z2k_dns_output}"
WARP_DOMAIN_NFT_FWD="${WARP_DOMAIN_NFT_FWD:-z2k_dns_forward}"
WARP_DOMAIN_NFLOG_GROUP="${WARP_DOMAIN_NFLOG_GROUP:-189}"
_warp_domain_adapter="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}"
[ -r "$_warp_domain_adapter/arch.sh" ] && . "$_warp_domain_adapter/arch.sh"
WARP_DOMAIN_RUNTIME_BIN="${WARP_DOMAIN_RUNTIME_BIN:-$(z2k_ow_warp_bin_path "$_warp_domain_adapter" 2>/dev/null || printf '%s' "$_warp_domain_adapter/bin/linux-unsupported/z2k-warpd")}"

warp_domain_rules_load() {
    _warp_controller domains-sync "$WARP_LISTS_DIR" "$WARP_GAMES_DIR" \
        "$WARP_ENABLED_FILE" "$WARP_DOMAIN_RULES" "$WARP_DOMAIN_ERROR"
}

# procd владеет процессом; состояние доменного backend проверяет контроллер.
warp_domain_observer_procd_ready() {
    _warp_controller domain-procd-ready "$WARP_DOMAIN_RUNTIME_BIN" "$WARP_BIN"
}
