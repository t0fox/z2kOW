#!/bin/sh
# tests/openwrt/test_ow_env.sh - мост env.sh перенаправляет upstream-имена.
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/fixture.sh"
_t_plan "ow-env"
ow_fixture_init || { echo "FAIL[ow-env]: fixture" >&2; exit 1; }
trap ow_fixture_done EXIT INT TERM

AD="$REPO/platform/openwrt"
Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_ROOT Z2K_ETC Z2K_TMP
. "$AD/paths.sh"
. "$AD/env.sh"

assert_eq "ZAPRET2_DIR -> payload" "$T/root" "$ZAPRET2_DIR"
assert_eq "CONFIG_DIR -> etc/conf" "$T/etc/conf" "$CONFIG_DIR"
assert_eq "LISTS_DIR -> payload lists" "$T/root/lists" "$LISTS_DIR"
assert_eq "ZAPRET_CONFIG -> canonical" "$T/etc/config" "$ZAPRET_CONFIG"
assert_eq "STATE override -> etc/state" "$T/etc/state" "$Z2K_STATE_DIR_OVERRIDE"
assert_eq "TCP16_ASN -> state" "$T/etc/state/tcp16_asn.txt" "$Z2K_TCP16_ASN"
assert_eq "TCP16_NETS -> payload lists" "$T/root/lists/tcp16_nets.txt" "$Z2K_TCP16_NETS"
assert_eq "SNI_PIN default (shipped lists)" "$T/root/lists/sni_wl_pin.txt" "$Z2K_SNI_PIN"
assert_eq "FWTYPE nftables" "nftables" "$FWTYPE"
assert_eq "OPENWRT_LAN default" "lan" "$OPENWRT_LAN"
assert_eq "INIT_SCRIPT procd" "/etc/init.d/z2k" "$INIT_SCRIPT"
assert_eq "Z2K_CONFIG_FILE canonical" "$T/etc/config" "$Z2K_CONFIG_FILE"
assert_eq "Z2K_AU_SBIN payload bin" "$T/root/bin" "$Z2K_AU_SBIN"
assert_eq "STATE_FILE persistent" "$T/etc/state/state.tsv" "$STATE_FILE"
assert_eq "merge shipped payload" "$T/root/lists/extra-domains.txt" "$Z2K_EXTRA_DOMAINS_SHIPPED"
assert_eq "merge runtime user-lists" "$T/etc/user-lists/extra-domains.txt" "$Z2K_EXTRA_DOMAINS_RUNTIME"

# §15: manifest repo == payload repo — один origin везде, без necronicle
assert_eq "BRANCH production" "z2k-enhanced-openwrt" "$Z2K_AU_BRANCH"
assert_eq "REPO_RAW origin" "https://raw.githubusercontent.com/t0fox/z2kOW/z2k-enhanced-openwrt" "$Z2K_AU_REPO_RAW"
assert_eq "RAW_BASE origin" "https://raw.githubusercontent.com/t0fox/z2kOW" "$Z2K_AU_RAW_BASE"
assert_eq "GITHUB_RAW origin" "https://raw.githubusercontent.com/t0fox/z2kOW/z2k-enhanced-openwrt" "$GITHUB_RAW"
case "$Z2K_AU_REPO_RAW $Z2K_AU_RAW_BASE $GITHUB_RAW" in
    *necronicle*) _t_bad "канал ссылается на necronicle" ;;
    *) _t_ok ;;
esac

# предвыставленное окружение не затирается
( ZAPRET2_DIR=/keep CONFIG_DIR=/keep2 LISTS_DIR=/keep3 OPENWRT_LAN="lan9"
  Z2K_ROOT=/y Z2K_ETC=/x Z2K_TMP=/t
  . "$AD/paths.sh" >/dev/null; . "$AD/env.sh" >/dev/null
  [ "$ZAPRET2_DIR" = "/keep" ] && [ "$CONFIG_DIR" = "/keep2" ] && \
  [ "$LISTS_DIR" = "/keep3" ] && [ "$OPENWRT_LAN" = "lan9" ] ) \
    && _t_ok || _t_bad "env.sh затирает предвыставленные переменные"

_t_done
