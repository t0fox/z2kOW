#!/bin/sh
# Shared WAN discovery for the firewall and its periodic repair. Read-only:
# never change provider priorities, policy rules or the user's WAN_IFACE.
z2k_wan_ifaces() {
    local family="$1" override="${2:-}" routes candidates dev
    if [ -n "$override" ]; then
        printf '%s\n' "$override" | tr ',' ' ' | awk '{for(i=1;i<=NF;i++) if(!seen[$i]++) print $i}' | xargs
        return 0
    fi
    # Keenetic places secondary ISP defaults in policy tables, not necessarily
    # in main. Some old ip builds cannot dump all tables: retain main fallback.
    routes=$(ip "$family" route show table all 2>/dev/null) ||
        routes=$(ip "$family" route show default 2>/dev/null) || return 0
    candidates=$(printf '%s\n' "$routes" | awk '
        function emit(d,bad) {
            if(d!="" && !bad && !seen[d]++) print d
        }
        function devices( i,d,bad) {
            for(i=1;i<=NF;i++) {
                if($i=="nexthop") {emit(d,bad); d=""; bad=0}
                if($i=="dev") d=$(i+1)
                if($i=="dead" || $i=="linkdown") bad=1
            }
            emit(d,bad)
        }
        # iproute2 can put ECMP nexthops on continuation lines. Only retain
        # those belonging to a usable default; never a LAN or blackhole route.
        $1=="nexthop" {if(active) devices(); next}
        {
            active=($1=="default" || $1=="0.0.0.0/0" || $1=="::/0")
            if($0 ~ /(^|[[:space:]])table (988|989)([[:space:]]|$)/) active=0
            if(active) devices()
        }
    ')
    for dev in $candidates; do
        case "$dev" in lo|br[0-9]*|z2ktg*|z2ktun*) continue ;; esac
        # Do not query netlink link state: it can block on a broken VPN driver.
        [ ! -d "${Z2K_NET_CLASS:-/sys/class/net}/$dev/bridge" ] || continue
        printf '%s\n' "$dev"
    done | xargs
}
