#!/bin/sh
# /opt/etc/ndm/netfilter.d/90-z2k-tg-redirect.sh
#
# Keenetic NDM hook. NDM invokes every script in this directory after
# regenerating netfilter rules (boot, WAN up/down, tunnel up/down, hotplug,
# DHCP renew, etc.) and wipes non-NDM rules in the process. We re-install the
# Telegram-DC REDIRECT here.
#
# NDM passes two env vars:  type (iptables|ip6tables), table (filter|nat|...).
# IPv4 NAT and IPv6 filter are rebuilt independently; restore each family.
#
# The actual rule logic lives in the shared lib so the hook, the watchdog and
# the S98 init script install the identical (ipset-based, -w-locked) rule
# shape — see /opt/zapret2/z2k-tg-redirect.sh for the why (ipset survives NDM
# wipes; -w avoids the silent lock-race rule drop that caused intermittent
# TG outages).

export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

case "${type:-iptables}:${table:-}" in
    iptables:nat|iptables:mangle|iptables:filter|ip6tables:filter|ip6tables:mangle|ip6tables:nat) ;;
    *) exit 0 ;;
esac

# Respect explicit user disable (backstop for a stale process during upgrade).
CONFIG_FILE="/opt/zapret2/config"
if [ -f "$CONFIG_FILE" ]; then
    user_disabled=$(awk -F= '/^TG_PROXY_USER_DISABLED=/ {gsub(/[" ]/,"",$2); print $2; exit}' "$CONFIG_FILE")
    if [ "$user_disabled" = "1" ]; then
        exit 0
    fi
fi

# Only insert if the tunnel is actually running — otherwise leave iptables
# clean so traffic falls back to the direct path instead of a dead REDIRECT.
pidof tg-mtproxy-client >/dev/null 2>&1 || exit 0

LIB="/opt/zapret2/z2k-tg-redirect.sh"
[ -r "$LIB" ] || exit 0   # graceful: watchdog/S98 cover if the lib is missing
. "$LIB"

z2k_tg_udp_ensure
[ "${table:-}" = mangle ] && exit 0
[ "${type:-}:${table:-}" = ip6tables:nat ] && exit 0
[ "${type:-}:${table:-}" = iptables:filter ] && exit 0

if [ "${type:-}" = ip6tables ]; then
    z2k_tg_ensure_rules6
    exit $?
fi

z2k_tg_remove_legacy_rules   # migrate off pre-ipset per-CIDR rules (cheap no-op after first run)
z2k_tg_ensure_rules          # ipset + 2 REDIRECT rules, -w-locked, verify-retry
z2k_tg_flush_conntrack       # smartphones pick up the restored path immediately

exit 0
