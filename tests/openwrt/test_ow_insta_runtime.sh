#!/bin/sh
. "$(dirname "$0")/helper.sh"
_t_plan "ow-insta-runtime"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-insta.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/etc/state"
export UCI_TEST_DB="$T/uci.db" UCI_TEST_LOG="$T/uci.log" DNSMASQ_TEST_LOG="$T/dnsmasq.log"
export Z2K_INSTA_HOSTS_FILE="$T/etc/state/insta-hosts"
export Z2K_INSTA_UCI_MARKER="$T/etc/state/.insta-addnhosts-owned"
export Z2K_INSTA_DNSMASQ_INIT="$T/dnsmasq-init"
export PATH="$T/bin:$PATH"
printf "dhcp.cfg0001='dnsmasq'\ndhcp.@dnsmasq[0].nohosts='0'\n" > "$UCI_TEST_DB"

cat > "$T/bin/uci" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$UCI_TEST_LOG"
case "$*" in
    "-q show dhcp.@dnsmasq[0]") grep -q "dnsmasq" "$UCI_TEST_DB" ;;
    "-q show dhcp") cat "$UCI_TEST_DB" ;;
    "commit dhcp") exit 0 ;;
    "add_list dhcp.@dnsmasq[0].addnhosts="*)
        _path=${2#dhcp.@dnsmasq[0].addnhosts=}
        printf "dhcp.@dnsmasq[0].addnhosts='%s'\n" "$_path" >> "$UCI_TEST_DB"
        ;;
    "del_list dhcp.@dnsmasq[0].addnhosts="*)
        _path=${2#dhcp.@dnsmasq[0].addnhosts=}
        awk -v path="$_path" 'index($0, ".addnhosts=\047" path "\047") == 0' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"
        mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"
        ;;
    *) exit 2 ;;
esac
STUB
cat > "$Z2K_INSTA_DNSMASQ_INIT" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$DNSMASQ_TEST_LOG"
[ "${1:-}" = reload ]
STUB
chmod 0755 "$T/bin/uci" "$Z2K_INSTA_DNSMASQ_INIT"

. "$REPO/platform/openwrt/insta-ip.sh"
z2k_ow_insta_prepare || _t_bad "register the owned dnsmasq host file"
assert_contains "dnsmasq addnhosts path is persistent and scoped" "$UCI_TEST_DB" "$Z2K_INSTA_HOSTS_FILE"
assert_file "adapter records its own UCI reference for uninstall" "$Z2K_INSTA_UCI_MARKER"

z2k_ow_insta_add_host instagram.com 57.144.245.32 || _t_bad "add Instagram address"
z2k_ow_insta_add_host www.whatsapp.com 57.144.245.32 || _t_bad "add WhatsApp address"
assert_contains "host include uses dnsmasq /etc/hosts syntax" "$Z2K_INSTA_HOSTS_FILE" '57.144.245.32 instagram.com'
assert_contains "show-config preserves upstream host/IP field order" "$Z2K_INSTA_HOSTS_FILE" '57.144.245.32'
_config=$(z2k_ow_insta_show_running_config)
case "$_config" in
    *"ip host instagram.com 57.144.245.32"*"ip host www.whatsapp.com 57.144.245.32"*) _t_ok ;;
    *) _t_bad "OpenWrt records translate to upstream ip host lines" ;;
esac

z2k_ow_insta_remove_host instagram.com 57.144.245.32 || _t_bad "remove stale Instagram address"
assert_not_contains "remove affects only the exact managed hostname" "$Z2K_INSTA_HOSTS_FILE" 'instagram\.com'
assert_contains "unrelated managed hostname survives removal" "$Z2K_INSTA_HOSTS_FILE" 'www.whatsapp.com'
z2k_ow_insta_commit || _t_bad "commit records and reload dnsmasq"
assert_contains "changed records reload dnsmasq" "$DNSMASQ_TEST_LOG" 'reload'

z2k_ow_insta_uninstall || _t_bad "remove only the UCI reference owned by z2k"
assert_not_contains "uninstall removes the z2k addnhosts reference" "$UCI_TEST_DB" 'insta-hosts'
[ ! -e "$Z2K_INSTA_HOSTS_FILE" ] && _t_ok || _t_bad "uninstall removes the owned host file"
[ ! -e "$Z2K_INSTA_UCI_MARKER" ] && _t_ok || _t_bad "uninstall clears the ownership marker"

_t_done
