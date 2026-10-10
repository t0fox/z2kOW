#!/bin/sh
# tests/openwrt/test_ow_webpanel_cgi.sh - Stage 6 Layer C: настоящий api.sh +
# actions.sh в OpenWrt sysroot (WP-сценарии). Моки: init/procd, pidof, ip,
# nft-заглушка, lighttpd не нужен. Только subprocess-границы настоящие.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-webpanel-cgi"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-wpc.XXXXXX")" || exit 1
Z2K_JOB_DIR="$T/jobs"
export Z2K_JOB_DIR
mkdir -p "$Z2K_JOB_DIR"
trap 'for _j in $JOB_IDS; do rm -f "$Z2K_JOB_DIR/z2k-job-$_j.log" "$Z2K_JOB_DIR/z2k-job-$_j.pid" "$Z2K_JOB_DIR/z2k-job-$_j.exit"; done; rm -rf "$T"' EXIT INT TERM
JOB_IDS=""

# Директории autocircular подготовлены стартом демона, как в установленной системе.
mkdir -p "$T/bin" "$T/root/platform/openwrt" "$T/root/bin" "$T/root/lib" \
         "$T/root/webpanel/cgi" "$T/root/webpanel" "$T/etc/user-lists/warp" "$T/etc/state/warp" \
         "$T/etc/webpanel" "$T/etc/autocircular" "$T/tmp/z2k/autocircular" \
         "$T/tmp/z2k/runtime" "$T/proc/7777"
export PATH="$T/bin:$PATH"
export Z2K_PANEL_EXTRA_PATH="$T/bin"

# --- adapter farm (настоящие файлы слоя) ---
for _f in paths.sh env.sh arch.sh manifest.sh release_state.sh release.sh update.sh warp.sh tg.sh rt.sh firewall.sh customd.sh uci.sh schedule.sh uninstall.sh webpanel.sh panel.sh tiktok.sh doh.sh diag.sh offload-benchmark.sh offload-observe.sh; do
    ln -s "$REPO/platform/openwrt/$_f" "$T/root/platform/openwrt/$_f" 2>/dev/null
done
ln -s "$REPO/platform/openwrt/warp-proc.sh" "$T/root/platform/openwrt/warp-proc.sh" 2>/dev/null
# --- CGI: копии (как keenetic api_contract: проверяем именно эти файлы) ---
mkdir -p "$T/cgi"
cp "$REPO/webpanel/cgi/api.sh" "$REPO/webpanel/cgi/auth.sh" \
   "$REPO/webpanel/cgi/actions.sh" "$REPO/webpanel/cgi/platform.sh" "$T/cgi/"
cp "$REPO/webpanel/cgi/actions.sh" "$REPO/webpanel/cgi/platform.sh" \
   "$REPO/webpanel/cgi/api.sh" "$T/root/webpanel/cgi/"
mkdir -p "$T/root/share"
mkdir -p "$T/root/www"
cp "$REPO/webpanel/www/index.html" "$T/root/www/index.html"
cp "$REPO/webpanel/lighttpd.conf" "$T/root/webpanel/lighttpd.conf.in"
# --- stub lib (генератор/утилиты — как keenetic-сьют; сам CGI настоящий) ---
# Стаб пишет многострочный NFQWS2_OPT: strategy_validate вырезает опции
# sed-диапазоном /^NFQWS2_OPT="/,/^"$/, однострочник дал бы пустой opt.
cat > "$T/root/lib/config_official.sh" <<'EOF'
#!/bin/sh
create_official_config() {
    if [ -f "${OW_TEST_ROOT:-}/regen-fail" ]; then
        rm -f "${OW_TEST_ROOT}/regen-fail"
        return 1
    fi
    printf 'NFQWS2_OPT="\n--filter-tcp=80 --dpi-desync=fake\n"\n' >> "$1"
    echo "regen:$1" >> "${T_CGI_LOG:-/dev/null}"
    return 0
}
EOF
cat > "$T/root/lib/utils.sh" <<'EOF'
#!/bin/sh
safe_config_read() { return 1; }
z2k_fetch() {
    printf '%s\n' "$1" >> "${OW_TEST_FETCH_LOG:-/dev/null}"
    [ ! -f "${OW_TEST_FETCH_FAIL:-/dev/null}" ] || return 1
    case "$1" in
        *UPDATES.json.sig) cp "$OW_TEST_UPDATES_SIG" "$2" ;;
        *UPDATES.json*) cp "$OW_TEST_UPDATES" "$2" ;;
        *) return 1 ;;
    esac
}
EOF
cp "$REPO/lib/auto_update.sh" "$T/root/lib/auto_update.sh"
# --- mock init (procd): running по service-active, всё логирует ---
cat > "$T/mock-init" <<EOF
#!/bin/sh
echo "init:\$*" >> "$T/init.log"
case "\$1" in
    running) [ -f "$T/service-active" ] && exit 0; exit 1 ;;
    reload|restart|start|stop) exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$T/mock-init"
# --- process/network mocks ---
cat > "$T/bin/pidof" <<EOF
#!/bin/sh
cat "$T/pidof.out" 2>/dev/null
exit 0
EOF
chmod +x "$T/bin/pidof"
cat > "$T/bin/ip" <<EOF
#!/bin/sh
echo "ip:\$*" >> "$T/ip.log"
if [ "\$1" = "-4" ]; then
    cat "$T/ip-neigh" 2>/dev/null; exit 0
fi
if [ "\$1" = "link" ]; then
    [ -f "$T/link-\$4" ] && { echo "\$4: <UP>"; exit 0; }
    exit 1
fi
if [ "\$1" = "rule" ] && [ "\$2" = "show" ]; then
    cat "$T/ip-rules" 2>/dev/null; exit 0
fi
if [ "\$1" = "route" ] && [ "\$2" = "show" ]; then
    cat "$T/ip-route-\$4" 2>/dev/null; exit 0
fi
exit 0
EOF
chmod +x "$T/bin/ip"
cat > "$T/bin/nft" <<EOF
#!/bin/sh
echo "nft:\$*" >> "$T/nft.log"
if [ "\$1" = list ] && [ "\$2" = ruleset ]; then
    _mode=\$(sed -n 's/^FLOWOFFLOAD=//p' "$T/etc/config" | tail -1)
    case "\$_mode" in
        software) printf 'table inet zapret2 { flowtable ft { hook ingress priority filter; devices = { wan }; } chain flow_offload { jump flow_offload_zapret; } chain flow_offload_zapret { return comment "direct flow offloading exemption"; goto flow_offload_always; queue flags bypass to 200 counter packets 3 bytes 300; } chain flow_offload_always { flow add @ft; } }\n' ;;
        hardware) printf 'table inet zapret2 { flowtable ft { hook ingress priority filter; devices = { wan }; flags offload; } chain flow_offload { jump flow_offload_zapret; } chain flow_offload_zapret { return comment "direct flow offloading exemption"; goto flow_offload_always; queue flags bypass to 200 counter packets 3 bytes 300; } chain flow_offload_always { flow add @ft; } }\n' ;;
    esac
    exit 0
fi
if [ "\$1" = list ] && [ "\$2" = flowtable ]; then
    _mode=\$(sed -n 's/^FLOWOFFLOAD=//p' "$T/etc/config" | tail -1)
    case "\$_mode" in
        software) echo 'flowtable ft { hook ingress priority filter; devices = { wan }; }'; exit 0 ;;
        hardware) echo 'flowtable ft { flags offload; devices = { wan }; }'; exit 0 ;;
    esac
    exit 1
fi
if [ "\$1" = list ] && [ "\$2" = table ] && [ "\$4" = zapret2 ]; then
    _mode=\$(sed -n 's/^FLOWOFFLOAD=//p' "$T/etc/config" | tail -1)
    case "\$_mode" in
        none) exit 1 ;;
        software) printf 'table inet zapret2 { flowtable ft { hook ingress priority filter; devices = { wan }; } chain flow_offload { jump flow_offload_zapret; } chain flow_offload_zapret { return comment "direct flow offloading exemption"; goto flow_offload_always; queue flags bypass to 200 counter packets 3 bytes 300; } chain flow_offload_always { flow add @ft; } }\n'; exit 0 ;;
        hardware) printf 'table inet zapret2 { flowtable ft { hook ingress priority filter; devices = { wan }; flags offload; } chain flow_offload { jump flow_offload_zapret; } chain flow_offload_zapret { return comment "direct flow offloading exemption"; goto flow_offload_always; queue flags bypass to 200 counter packets 3 bytes 300; } chain flow_offload_always { flow add @ft; } }\n'; exit 0 ;;
    esac
fi
if [ "\$1" = list ] && [ "\$2" = chain ] && [ "\$4" = zapret2 ]; then
    case "\$5" in
        flow_offload) printf 'chain flow_offload { jump flow_offload_zapret; }\n' ;;
        flow_offload_zapret) printf 'chain flow_offload_zapret { return comment "direct flow offloading exemption"; goto flow_offload_always; queue flags bypass to 200 counter packets 3 bytes 300; }\n' ;;
        flow_offload_always) printf 'chain flow_offload_always { flow add @ft; }\n' ;;
        *) exit 1 ;;
    esac
    exit 0
fi
if [ "\$1" = list ] && [ "\$2" = table ] && [ "\$4" = fw4 ]; then exit 1; fi
exit 0
EOF
chmod +x "$T/bin/nft"
# BusyBox/OpenWrt jsonfilter subset for nested paths used by the CGI contract.
cat > "$T/bin/jsonfilter" <<'EOF'
#!/bin/sh
exec python3 - "$@" <<'PY'
import json, sys
args = sys.argv[1:]
path = None
source = None
while args:
    arg = args.pop(0)
    if arg == "-i": source = args.pop(0)
    elif arg == "-t": path = args.pop(0).removeprefix("@.").split("."); type_only = True
    elif arg == "-e": path = args.pop(0).removeprefix("@.").split(".")
    else: raise SystemExit(2)
value = json.load(open(source, encoding="utf-8"))
for key in path:
    value = value[key]
if locals().get("type_only", False): print({dict: "object", list: "array", str: "string", int: "number", float: "number", bool: "boolean", type(None): "null"}.get(type(value), "null"))
elif isinstance(value, bool): print("true" if value else "false")
elif value is not None: print(value)
PY
EOF
chmod +x "$T/bin/jsonfilter"
# --- fixtures ---
printf 'FLOWOFFLOAD=none\nGAME_WARP_ENABLED=0\nENABLED=1\n' > "$T/etc/config"
: > "$T/etc/user-lists/whitelist.txt"
: > "$T/pidof.out"; : > "$T/ip-rules"; : > "$T/init.log"
: > "$T/service-active"
printf '7777\n' > "$T/pidof.out"
printf 'z2k-warpd run --device x' | tr ' ' '\0' > "$T/proc/7777/cmdline"
printf '{"ready":true,"iface":"z2ktun0","transport":"wg"}\n' > "$T/tmp/z2k/warp-status.json"
: > "$T/link-z2ktun0"
printf '{"id":"mock-id","addr":"172.16.9.9"}\n' > "$T/etc/state/warp/device.json"
printf '192.168.7.1\n' > "$T/etc/webpanel/bind"
printf 'aa:bb:cc:dd:ee:ff\n' > "$T/etc/user-lists/warp/devices.txt"
printf '1721000000 aa:bb:cc:dd:ee:ff 192.168.7.50 myphone 01:aa:bb:cc:dd:ee:ff\n' > "$T/leases"
: > "$T/arp-empty"
printf '192.168.7.50 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE\n' > "$T/ip-neigh"
. "$REPO/platform/openwrt/arch.sh"
_warp_arch="$(z2k_ow_arch_name)" || exit 1
mkdir -p "$T/root/platform/openwrt/bin/linux-$_warp_arch"
cat > "$T/root/platform/openwrt/bin/linux-$_warp_arch/z2k-warpd" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/root/platform/openwrt/bin/linux-$_warp_arch/z2k-warpd"
# --- mock zapret2 runtime для strategy dry-run (WP9): движок-mock всегда
# парсит успешно; lib-стабы те же, что выше (теневая сборка их симлинчит) ---
mkdir -p "$T/zapret2/lib" "$T/zapret2/nfq2" "$T/zapret2/init.d/openwrt" "$T/root/platform/openwrt/custom.d"
cp "$REPO/files/z2k-warp-list-filter.awk" "$T/zapret2/z2k-warp-list-filter.awk"
cp "$REPO/platform/openwrt/custom.d/50-stun4all" "$REPO/platform/openwrt/custom.d/50-discord-media" \
   "$T/root/platform/openwrt/custom.d/"
chmod +x "$T/root/platform/openwrt/custom.d"/*
# The real zapret2 library is sourced by the OpenWrt capability probe while
# api.sh has set -u.  Keep an optional runtime variable here so this test
# catches a nounset abort inside the command substitution, not just a missing
# runner symbol.
printf '#!/bin/sh\n: "${Z2K_OPTIONAL_RUNTIME_VALUE}"\ncustom_runner() { :; }\n' > "$T/zapret2/init.d/openwrt/functions"
cat > "$T/zapret2/lib/utils.sh" <<'EOF'
#!/bin/sh
safe_config_read() { return 1; }
z2k_fetch() {
    printf '%s\n' "$1" >> "$OW_TEST_FETCH_LOG"
    [ ! -f "$OW_TEST_FETCH_FAIL" ] || return 1
    case "$1" in
        https://updates.example/controlled/UPDATES.json)
            cp "$OW_TEST_UPDATES" "$2" ;;
        https://updates.example/controlled/UPDATES.json.sig)
            cp "$OW_TEST_UPDATES_SIG" "$2" ;;
        *) return 1 ;;
    esac
    printf 'etag\n' > "$2.etag"
}
EOF
cp "$REPO/lib/auto_update.sh" "$T/zapret2/lib/auto_update.sh"
cat > "$T/zapret2/lib/config_official.sh" <<EOF
#!/bin/sh
create_official_config() {
    if [ -f "$T/regen-fail" ]; then
        rm -f "$T/regen-fail"
        return 1
    fi
    printf 'NFQWS2_OPT="\n--filter-tcp=80 --dpi-desync=fake\n"\n' >> "\$1"
    return 0
}
EOF
cat > "$T/zapret2/nfq2/nfqws2" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/zapret2/nfq2/nfqws2"
export Z2K_PLATFORM=openwrt Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_DOH_APK_BIN="$T/bin/false" Z2K_DOH_UCI_BIN="$T/bin/false" Z2K_DOH_PROC_NET_UDP_FILE="$T/no-udp"
export Z2K_CONFIG="$T/etc/config" Z2K_PROC_ROOT="$T/proc" Z2K_INIT="$T/mock-init"
export Z2K_BIN="$T/root/bin" INIT_SCRIPT="$T/mock-init" ZAPRET2_DIR="$T/zapret2" \
       Z2K_ZAPRET2_RUNTIME="$T/zapret2"
export Z2K_CRON_TAB="$T/etc/crontabs/root"
export WP_IP_BIN="$T/bin/ip"
export WARP_STATUS="$T/tmp/z2k/warp-status.json"
export WP_DHCP_LEASES="$T/leases" WP_ARP_PATH="$T/arp-empty"
export OW_TEST_ROOT="$T"

# Full TCP16 payload fixture in the canonical OpenWrt paths, present before
# /status projects feature capabilities.
mkdir -p "$T/root/lua" "$T/root/lists" "$T/root/bin" "$T/etc/state"
printf 'return {}\n' > "$T/root/lua/z2k-tcp16.lua"
printf 'T1\t1\t*\ttest\t192.0.2.1\t443\n' > "$T/root/lists/tcp16_targets.txt"
printf '1\t192.0.2.0/16\n' > "$T/root/lists/tcp16_nets.txt"
printf 'test.example\n' > "$T/root/lists/sni_wl_candidates.txt"
printf '#!/bin/sh\nprintf done > "%s/tcp16-probe-ran"\n' "$T" > "$T/root/z2k-tcp16-probe.sh"
chmod +x "$T/root/z2k-tcp16-probe.sh"
printf '#!/bin/sh\nexit 0\n' > "$T/root/bin/z2k-detect"
chmod +x "$T/root/bin/z2k-detect"

# --- CGI caller (как lighttpd; HTTP_X_Z2K_PANEL обязателен) ---
_cgi() { # <METHOD> <PATH> [QUERY] [bodyfile]
    _m="$1"; _p="$2"; _q="${3:-}"; _b="${4:-}"
    if [ -n "$_b" ]; then
        _cl=$(wc -c < "$_b" | tr -d ' ')
        env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="$_q" \
            HTTP_HOST="192.168.7.1" HTTP_X_Z2K_PANEL="1" CONTENT_LENGTH="$_cl" \
            Z2K_JOB_DIR="$Z2K_JOB_DIR" \
            Z2K_OW_TESTING=1 \
            sh "$T/cgi/api.sh" < "$_b" 2>/dev/null
    else
        env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="$_q" \
            HTTP_HOST="192.168.7.1" HTTP_X_Z2K_PANEL="1" CONTENT_LENGTH="0" \
            Z2K_JOB_DIR="$Z2K_JOB_DIR" \
            Z2K_OW_TESTING=1 \
            sh "$T/cgi/api.sh" < /dev/null 2>/dev/null
    fi
}
_cgi_body()    { awk 'blank{print} /^\r?$/{blank=1}'; }
_cgi_status()  { tr -d '\r' | awk 'NR==1{print; exit}'; }
_jget() {
    printf '%s' "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
v = eval(sys.argv[1], {"d": d})
if v is None: print("null")
elif v is True: print("true")
elif v is False: print("false")
else: print(v)
' "$2" 2>/dev/null
}
# poll job до done (до ~5с); id — через QUERY_STRING, как ждёт api.sh
_poll_job() { # $1 jobid -> печатает тело последнего опроса
    _i=0
    while [ "$_i" -lt 25 ]; do
        sleep 0.2
        _jr="$(_cgi GET /job "id=$1")"
        _jo="$(printf '%s\n' "$_jr" | _cgi_body)"
        if [ "$(_jget "$_jo" 'd["done"]')" = "true" ]; then
            if printf '%s' "$_jo" | grep -Fq 'parameter not set'; then
                _t_bad "async job $1 logs an unset-variable error"
                return 1
            fi
            printf '%s' "$_jo"
            return 0
        fi
        _i=$((_i + 1))
    done
    printf '%s' "$_jo"
    return 1
}
# poll job + проверка отказа (Keenetic-only действия на OpenWrt)
_poll_job_fail() { # $1 jobid, $2 ожидаемый фрагмент лога
    _jo="$(_poll_job "$1")" || { _t_bad "$2: job не завершился"; return 1; }
    assert_eq "$2: job done" "true" "$(_jget "$_jo" 'd["done"]')"
    if [ "$(_jget "$_jo" 'd["exit"]')" = "0" ]; then
        _t_bad "$2: job rc 0, ждали отказ"
    else
        _t_ok
    fi
}

# --- /status: форма + capabilities (WP19/WP20-контекст) ---
RAW="$(_cgi GET /status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "status: HTTP 200" "Status: 200 OK" "$(printf '%s\n' "$RAW" | _cgi_status)"
_status_json_ok=$(printf '%s\n' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin); print("true")' 2>/dev/null || printf 'false')
assert_eq "status: valid JSON with runtime probe" "true" "$_status_json_ok"
assert_eq "status: platform" "openwrt" "$(_jget "$OUT" 'd["platform"]')"
assert_eq "status: TikTok feed toggle defaults off" "0" "$(_jget "$OUT" 'd["toggles"]["tiktok_feed"]')"
assert_eq "status: TikTok diagnostics omitted while disabled" "null" "$(_jget "$OUT" 'd.get("tiktok_feed_status")')"
assert_eq "status: DoH is explicitly not installed on a clean OpenWrt setup" "not-installed" "$(_jget "$OUT" 'd["doh"]["state"]')"
assert_eq "status: DoH force DNS defaults off" "0" "$(_jget "$OUT" 'd["doh"]["force_lan_dns"]')"
assert_eq "status: DoH provider comes from package UCI, empty before install" "unknown" "$(_jget "$OUT" 'd["doh"]["provider"]')"
assert_eq "status: DoH exposes no inactive endpoint before install" "" "$(_jget "$OUT" 'd["doh"]["endpoint"]')"
assert_eq "status: DoH has no external config before install" "0" "$(_jget "$OUT" 'd["doh"]["external_config"]')"
_status_out="$OUT"
# Exercise the exact reported route: api.sh enables nounset, queues the action,
# and svc_action_async evaluates it in the background. With no saved active IP,
# switching the policy to auto leaves the optional probe row empty.
cp "$T/etc/config" "$T/config.before-tiktok-policy"
printf 'Z2K_TIKTOK_FEED_ENABLED=1\n' >> "$T/etc/config"
mkdir -p "$T/etc/state"
printf 'schema_version=2\n' > "$T/etc/state/tiktok-domains.state"
printf 'host=v77.tiktokcdn.com&policy=auto' > "$T/tiktok-policy-body"
RAW="$(
    export Z2K_STATE="$T/etc/state"
    export Z2K_TIKTOK_CONFIG="$T/etc/config"
    export Z2K_TIKTOK_DOMAIN_STATE_FILE="$T/etc/state/tiktok-domains.state"
    export Z2K_TIKTOK_STATE_FILE="$T/etc/state/tiktok-cdn.state"
    export Z2K_TIKTOK_ADDRESS_MARKER="$T/etc/state/.tiktok-address-owned"
    export Z2K_TIKTOK_UCI_BIN=true Z2K_TIKTOK_DNSMASQ_INIT=/bin/true
    export Z2K_TIKTOK_APPLY_LOCK="$T/tmp/z2k/runtime/tiktok-policy.lock"
    _cgi POST /tiktok/policy "" "$T/tiktok-policy-body"
)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
_tiktok_job="$(_jget "$OUT" 'd["job"]')"
assert_eq "TikTok policy route starts an async job" "true" "$([ -n "$_tiktok_job" ] && printf true || printf false)"
if [ -n "$_tiktok_job" ]; then
    JOB_IDS="$JOB_IDS $_tiktok_job"
    _tiktok_job_result="$(_poll_job "$_tiktok_job")" || _t_bad "TikTok policy async job completes under api.sh nounset"
    assert_eq "TikTok auto policy job exits successfully" "0" "$(_jget "$_tiktok_job_result" 'd["exit"]')"
    printf '%s' "$(_jget "$_tiktok_job_result" 'd["log"]')" > "$T/tiktok-policy-job.log"
    assert_not_contains "TikTok policy job has no nounset diagnostics" "$T/tiktok-policy-job.log" 'parameter not set'
    assert_eq "TikTok auto policy is persisted" "auto" "$(sed -n 's/^domain.v77.tiktokcdn.com.policy=//p' "$T/etc/state/tiktok-domains.state")"
fi
# В auto уже выбран адрес, но preferred_ip ещё пустой: проверяем путь UI.
cat > "$T/etc/state/tiktok-domains.state" <<'EOF_TIKTOK_STATE'
schema_version=2
domain.v77.tiktokcdn.com.policy=auto
domain.v77.tiktokcdn.com.preferred_ip=
domain.v77.tiktokcdn.com.selected_ip=203.0.113.77
domain.v77.tiktokcdn.com.selected_at_epoch=1
domain.v77.tiktokcdn.com.preferred_set_at_epoch=
domain.v77.tiktokcdn.com.health=transport-confirmed
domain.v77.tiktokcdn.com.last_verified_epoch=1
domain.v77.tiktokcdn.com.last_evaluation_epoch=1
domain.v77.tiktokcdn.com.dns_override_applied=1
EOF_TIKTOK_STATE
cat > "$T/bin/tiktok-policy-uci" <<'EOF_TIKTOK_UCI'
#!/bin/sh
case "$*" in
    "-q show dhcp.@dnsmasq[0]") printf '%s\n' "dhcp.@dnsmasq[0]='dnsmasq'" ;;
    "-q show dhcp") printf '%s\n' "dhcp.@dnsmasq[0].address='/v77.tiktokcdn.com/203.0.113.77'" ;;
    "commit dhcp") exit 0 ;;
    *) exit 2 ;;
esac
EOF_TIKTOK_UCI
cat > "$T/bin/tiktok-policy-nslookup" <<'EOF_TIKTOK_NSLOOKUP'
#!/bin/sh
printf 'Server: %s\nAddress: %s:53\n\nName: %s\nAddress: 203.0.113.77\n' "$2" "$2" "$1"
EOF_TIKTOK_NSLOOKUP
chmod +x "$T/bin/tiktok-policy-uci" "$T/bin/tiktok-policy-nslookup"
printf '%s\n' '/v77.tiktokcdn.com/203.0.113.77' > "$T/etc/state/.tiktok-address-owned"
printf '%s\n' 'address=/v77.tiktokcdn.com/203.0.113.77' > "$T/tiktok-dnsmasq.conf"
printf 'host=v77.tiktokcdn.com&policy=preferred' > "$T/tiktok-preferred-body"
RAW="$(
    export Z2K_STATE="$T/etc/state"
    export Z2K_TIKTOK_CONFIG="$T/etc/config"
    export Z2K_TIKTOK_DOMAIN_STATE_FILE="$T/etc/state/tiktok-domains.state"
    export Z2K_TIKTOK_STATE_FILE="$T/etc/state/tiktok-cdn.state"
    export Z2K_TIKTOK_ADDRESS_MARKER="$T/etc/state/.tiktok-address-owned"
    export Z2K_TIKTOK_UCI_BIN="$T/bin/tiktok-policy-uci" Z2K_TIKTOK_DNSMASQ_INIT=/bin/true
    export Z2K_TIKTOK_NSLOOKUP_BIN="$T/bin/tiktok-policy-nslookup"
    export Z2K_TIKTOK_EFFECTIVE_CONFIG="$T/tiktok-dnsmasq.conf"
    export Z2K_TIKTOK_APPLY_LOCK="$T/tmp/z2k/runtime/tiktok-policy.lock"
    _cgi POST /tiktok/policy "" "$T/tiktok-preferred-body"
)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
_tiktok_job="$(_jget "$OUT" 'd["job"]')"
assert_eq "панель запускает переключение авто-адреса в preferred" "true" "$([ -n "$_tiktok_job" ] && printf true || printf false)"
if [ -n "$_tiktok_job" ]; then
    JOB_IDS="$JOB_IDS $_tiktok_job"
    _tiktok_job_result="$(_poll_job "$_tiktok_job")" || _t_bad "задача переключения preferred завершается"
    _tiktok_policy_exit=$(_jget "$_tiktok_job_result" 'd["exit"]')
    if [ "$_tiktok_policy_exit" != 0 ]; then
        printf 'TikTok preferred job result: %s\n' "$_tiktok_job_result" >&2
    fi
    assert_eq "задача переключения preferred завершается без кода 1" "0" "$_tiktok_policy_exit"
    assert_eq "preferred_ip сохраняется через API панели" "203.0.113.77" \
        "$(sed -n 's/^domain.v77.tiktokcdn.com.preferred_ip=//p' "$T/etc/state/tiktok-domains.state")"
fi
cp "$T/config.before-tiktok-policy" "$T/etc/config"

printf '%s' 'value=1%3Btouch%20/tmp/z2k-doh-injection' > "$T/doh-invalid-body"
RAW="$(_cgi POST /doh/force-dns "" "$T/doh-invalid-body")"
assert_eq "DoH force DNS rejects injected values" "Status: 400 Bad Request" "$(printf '%s\n' "$RAW" | _cgi_status)"
printf '%s\n' 'provider=custom&endpoint=http%3A%2F%2Fresolver.example%2Fdns-query&bootstrap=1.1.1.1' > "$T/doh-provider-invalid-endpoint"
RAW="$(_cgi POST /doh/provider "" "$T/doh-provider-invalid-endpoint")"
assert_eq "DoH rejects a custom endpoint without HTTPS" "Status: 400 Bad Request" "$(printf '%s\n' "$RAW" | _cgi_status)"
printf '%s\n' 'provider=custom&endpoint=https%3A%2F%2Fresolver.example%2Fdns-query&bootstrap=127.0.0.1%2C999.1.1.1' > "$T/doh-provider-invalid-bootstrap"
RAW="$(_cgi POST /doh/provider "" "$T/doh-provider-invalid-bootstrap")"
assert_eq "DoH rejects invalid custom bootstrap DNS" "Status: 400 Bad Request" "$(printf '%s\n' "$RAW" | _cgi_status)"
printf '%s\n' 'provider=xbox&replace=2' > "$T/doh-provider-invalid-replace"
RAW="$(_cgi POST /doh/provider "" "$T/doh-provider-invalid-replace")"
assert_eq "DoH API rejects a non-boolean replace intent" "Status: 400 Bad Request" "$(printf '%s\n' "$RAW" | _cgi_status)"
printf '%s\n' 'confirm=2' > "$T/doh-uninstall-invalid-confirm"
RAW="$(_cgi POST /doh/uninstall "" "$T/doh-uninstall-invalid-confirm")"
assert_eq "DoH API rejects a non-boolean uninstall confirmation" "Status: 400 Bad Request" "$(printf '%s\n' "$RAW" | _cgi_status)"
printf '%s\n' 'provider=geohide_us&replace=1' > "$T/doh-provider-preset"
RAW="$(_cgi POST /doh/provider "" "$T/doh-provider-preset")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
_doh_job="$(_jget "$OUT" 'd["job"]')"
assert_eq "DoH API accepts the GeoHide US preset and replace intent" "true" "$([ -n "$_doh_job" ] && printf true || printf false)"
if [ -n "$_doh_job" ]; then
    JOB_IDS="$JOB_IDS $_doh_job"
    _poll_job_fail "$_doh_job" "valid preset API request reaches the adapter without bypassing package ownership"
fi
printf '%s\n' 'provider=custom&endpoint=https%3A%2F%2Fresolver.example%2Fdns-query&bootstrap=2606%3A4700%3A4700%3A%3A1111' > "$T/doh-provider-ipv6-bootstrap"
RAW="$(_cgi POST /doh/provider "" "$T/doh-provider-ipv6-bootstrap")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
_doh_job="$(_jget "$OUT" 'd["job"]')"
assert_eq "DoH API accepts an IPv6 custom bootstrap address" "true" "$([ -n "$_doh_job" ] && printf true || printf false)"
if [ -n "$_doh_job" ]; then
    JOB_IDS="$JOB_IDS $_doh_job"
    _poll_job_fail "$_doh_job" "valid IPv6 custom endpoint request reaches the adapter"
fi

# Exercise the production /doh/check -> svc_action_async -> eval -> actions.sh
# chain under api.sh's set -u. The DNS command is an ordinary PATH executable;
# the optional test override variables deliberately remain unset.
cat > "$T/bin/doh-apk" <<'EOF'
#!/bin/sh
[ "$#" -eq 3 ] && [ "$1" = info ] && [ "$2" = -e ] && [ "$3" = https-dns-proxy ]
EOF
chmod +x "$T/bin/doh-apk"
cat > "$T/bin/doh-uci" <<'EOF'
#!/bin/sh
[ "${1:-}" = -q ] && shift
case "${1:-}" in
    show)
        [ "${2:-}" = https-dns-proxy ] || exit 1
        cat <<'UCI'
https-dns-proxy.z2kow_doh='https-dns-proxy'
https-dns-proxy.z2kow_doh.resolver_url='https://dns.google/dns-query'
https-dns-proxy.z2kow_doh.listen_port='5053'
UCI
        ;;
    get)
        case "${2:-}" in
            https-dns-proxy.z2kow_doh) printf '%s\n' https-dns-proxy ;;
            https-dns-proxy.z2kow_doh.resolver_url) printf '%s\n' https://dns.google/dns-query ;;
            https-dns-proxy.z2kow_doh.listen_port) printf '%s\n' 5053 ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/doh-uci"
cat > "$T/bin/nslookup" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$OW_DOH_NSLOOKUP_LOG"
printf 'Server: 127.0.0.1\nAddress: 127.0.0.1#53\n\nName: example.com\nAddress: 203.0.113.88\n'
EOF
chmod +x "$T/bin/nslookup"
mkdir -p "$T/doh-dnsmasq-runtime"
printf 'server=127.0.0.1#5053\n' > "$T/doh-dnsmasq-runtime/dnsmasq.conf.fixture"
_doh_saved_apk_bin=$Z2K_DOH_APK_BIN
_doh_saved_uci_bin=$Z2K_DOH_UCI_BIN
_doh_saved_runtime_dir=${Z2K_DOH_DNSMASQ_RUNTIME_DIR:-}
export OW_DOH_NSLOOKUP_LOG="$T/doh-nslookup.calls"
unset Z2K_DOH_NSLOOKUP_BIN Z2K_DOH_HEALTH_HOST
export Z2K_DOH_APK_BIN="$T/bin/doh-apk" Z2K_DOH_UCI_BIN="$T/bin/doh-uci"
export Z2K_DOH_DNSMASQ_RUNTIME_DIR="$T/doh-dnsmasq-runtime"
# A DoH package installed by z2kOW can still have a pre-install config receipt.
# The adapter requests explicit confirmation on Remove, so /status must expose
# that fact to the browser even when the active resolver section is z2kOW-owned.
_doh_saved_state=${Z2K_STATE:-}
export Z2K_STATE="$T/etc/state"
mkdir -p "$Z2K_STATE"
printf 'z2kow_doh\n' > "$Z2K_STATE/.doh-uci-owned"
printf 'https-dns-proxy\n' > "$Z2K_STATE/.doh-package-owned"
printf 'preexisting config snapshot\n' > "$Z2K_STATE/.doh-config-backup"
printf 'present=1\n' > "$Z2K_STATE/.doh-preinstall-config-present"
RAW="$(_cgi GET /status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "status exposes confirmation required before removing a pre-existing DoH config" \
    "1" "$(_jget "$OUT" 'd["doh"]["confirm_remove"]')"
rm -f "$Z2K_STATE"/.doh-*
if [ -n "$_doh_saved_state" ]; then export Z2K_STATE="$_doh_saved_state"; else unset Z2K_STATE; fi
RAW="$(_cgi POST /doh/check)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
_doh_job="$(_jget "$OUT" 'd["job"]')"
assert_eq "DoH Check starts through the real API async route without test overrides" "true" "$([ -n "$_doh_job" ] && printf true || printf false)"
if [ -n "$_doh_job" ]; then
    JOB_IDS="$JOB_IDS $_doh_job"
    _doh_check_job="$(_poll_job "$_doh_job")" || _t_bad "DoH Check async job completes under set -u"
    assert_eq "DoH Check async job exits successfully" "0" "$(_jget "$_doh_check_job" 'd["exit"]')"
    printf '%s' "$(_jget "$_doh_check_job" 'd["log"]')" > "$T/doh-check-job.log"
    assert_contains "DoH Check reaches PATH nslookup with the production defaults" "$T/doh-nslookup.calls" 'example.com 127.0.0.1'
    assert_contains "DoH job log identifies the detected provider and endpoint" "$T/doh-check-job.log" 'provider=google endpoint=https://dns.google/dns-query'
    assert_contains "DoH job log includes the DNS answer and success" "$T/doh-check-job.log" 'answer=203.0.113.88 result=success'
    assert_not_contains "DoH job log has no nounset failure" "$T/doh-check-job.log" 'parameter not set'
fi
Z2K_DOH_APK_BIN=$_doh_saved_apk_bin
Z2K_DOH_UCI_BIN=$_doh_saved_uci_bin
export Z2K_DOH_APK_BIN Z2K_DOH_UCI_BIN
if [ -n "$_doh_saved_runtime_dir" ]; then
    Z2K_DOH_DNSMASQ_RUNTIME_DIR=$_doh_saved_runtime_dir
    export Z2K_DOH_DNSMASQ_RUNTIME_DIR
else
    unset Z2K_DOH_DNSMASQ_RUNTIME_DIR
fi

printf '%s\n' 'url=https%3A%2F%2Fevil.example%2Fdns-query&bootstrap=127.0.0.1' > "$T/doh-install-body"
RAW="$(_cgi POST /doh/install "" "$T/doh-install-body")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
_doh_job="$(_jget "$OUT" 'd["job"]')"
assert_eq "DoH install route returns an async job immediately" "true" "$([ -n "$_doh_job" ] && printf true || printf false)"
JOB_IDS="$JOB_IDS $_doh_job"
_poll_job_fail "$_doh_job" "DoH install runs in an async job and fails closed when optional apk is unavailable"
assert_not_contains "DoH install ignores browser-supplied resolver values" "$T/doh-install-body" 'https://evil.example/dns-query'
printf '%s\n' 'confirm=1' > "$T/doh-uninstall-confirm"
RAW="$(_cgi POST /doh/uninstall "" "$T/doh-uninstall-confirm")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
_doh_job="$(_jget "$OUT" 'd["job"]')"
assert_eq "DoH uninstall confirmation reaches an async job" "true" "$([ -n "$_doh_job" ] && printf true || printf false)"
if [ -n "$_doh_job" ]; then
    JOB_IDS="$JOB_IDS $_doh_job"
    _poll_job_fail "$_doh_job" "DoH uninstall does not claim success when optional package/DNS commands fail"
fi
_openwrt_platform="$Z2K_PLATFORM"
Z2K_PLATFORM=keenetic
RAW="$(_cgi POST /doh/install)"
Z2K_PLATFORM="$_openwrt_platform"
assert_eq "DoH action routes are not exposed on Keenetic" "Status: 404 Not Found" "$(printf '%s\n' "$RAW" | _cgi_status)"
OUT="$_status_out"
assert_eq "status: panel payload compatible" "true" "$(_jget "$OUT" 'd["payload_compatible"]')"
assert_eq "status: policy false" "false" "$(_jget "$OUT" 'd["capabilities"]["policy"]')"
assert_eq "status: ppe false" "false" "$(_jget "$OUT" 'd["capabilities"]["ppe"]')"
assert_eq "status: fastroute false" "false" "$(_jget "$OUT" 'd["capabilities"]["fastroute"]')"
assert_eq "status: fastroute backend" "Программный fastpath недоступен на OpenWrt: backend не обнаружен." "$(_jget "$OUT" 'd["toggles"]["fastroute_status"]')"
assert_eq "status: stock offload capability" "true" "$(_jget "$OUT" 'd["capabilities"]["offload"]')"
assert_eq "status: stock offload mode" "none" "$(_jget "$OUT" 'd["toggles"]["flowoffload"]')"
printf '%s\n' "$OUT" > "$T/status-output"
assert_contains "status: offload facts stay explicit" "$T/status-output" "flowtable_state=absent"
assert_contains "status: NFQUEUE remains independently observable while offload is disabled" "$T/status-output" "packet_visibility=inactive"
assert_contains "status: circular comes from runtime observer" "$T/status-output" "circular_state=disabled"
assert_not_contains "status: packet visibility is never hardcoded unknown" "$T/status-output" "packet_visibility=unknown"
assert_not_contains "status: circular is never hardcoded unknown" "$T/status-output" "circular_state=unknown"
Z2K_ROOT="$T/root" Z2K_CONFIG="$T/etc/config" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp/z2k" \
    Z2K_STATE="$T/etc/state" Z2K_RUN="$T/run" Z2K_BIN="$T/bin" sh "$REPO/platform/openwrt/diag.sh" offload \
    > "$T/diag-status" 2>&1
assert_contains "diag and status use the same disabled-mode packet state" "$T/diag-status" "packet visibility  : inactive"
assert_contains "diag and status use the same circular state" "$T/diag-status" "circular           : disabled"
assert_eq "status: tcp16 true when full feature is shipped" "true" "$(_jget "$OUT" 'd["capabilities"]["tcp16"]')"
assert_eq "status: Telegram TCP tunnel reports its own matching process probe" "false" "$(_jget "$OUT" 'd["tunnel"]["running"]')"
assert_eq "status: diagnostics capability" "true" "$(_jget "$OUT" 'd["capabilities"]["diag"]')"
assert_eq "status: customd true" "true" "$(_jget "$OUT" 'd["capabilities"]["customd"]')"
assert_eq "status: warp true" "true" "$(_jget "$OUT" 'd["capabilities"]["warp"]')"
assert_eq "status: telegram true" "true" "$(_jget "$OUT" 'd["capabilities"]["telegram"]')"
assert_eq "status: canonical uninstall capability" "true" "$(_jget "$OUT" 'd["capabilities"]["uninstall"]')"
assert_eq "status: core running via init" "true" "$(_jget "$OUT" 'd["running"]')"
assert_eq "status: running service without canonical release is not installed" "false" "$(_jget "$OUT" 'd["installed"]')"
assert_eq "status: missing canonical release is an explicit state error" "error" "$(_jget "$OUT" 'd["installed_state"]')"

# --- Stock selective FLOWOFFLOAD selector: no adapter flowtable/PPE ---
printf 'mode=software' > "$T/body.txt"
RAW="$(_cgi POST /offload "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "offload: POST accepted" "true" "$(_jget "$OUT" 'd["ok"]')"
JOB_IDS="$JOB_IDS $(_jget "$OUT" 'd["job"]')"
_JO="$(_poll_job "$(_jget "$OUT" 'd["job"]')")"
assert_eq "offload: software job done" "true" "$(_jget "$_JO" 'd["done"]')"
assert_eq "offload: software applied" "software" "$(grep '^FLOWOFFLOAD=' "$T/etc/config" | tail -1 | cut -d= -f2-)"
RAW="$(_cgi GET /status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "offload: status follows config" "software" "$(_jget "$OUT" 'd["toggles"]["flowoffload"]')"
printf '%s\n' "$OUT" > "$T/offload-status-output"
assert_contains "offload: diagnostics report the selected mode" "$T/offload-status-output" "mode=software"

printf 'mode=invalid' > "$T/body.txt"
RAW="$(_cgi POST /offload "" "$T/body.txt")"
assert_eq "offload: invalid mode rejected" "Status: 400 Bad Request" "$(printf '%s\n' "$RAW" | _cgi_status)"

# A failed regeneration must restore the prior mode; the one-shot failure lets
# the rollback regeneration succeed and proves this is not just a UI revert.
touch "$T/regen-fail"
printf 'mode=hardware' > "$T/body.txt"
RAW="$(_cgi POST /offload "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
JOB_IDS="$JOB_IDS $(_jget "$OUT" 'd["job"]')"
_poll_job_fail "$(_jget "$OUT" 'd["job"]')" "offload: failed apply rollback"
assert_eq "offload: failed apply restored software" "software" "$(grep '^FLOWOFFLOAD=' "$T/etc/config" | tail -1 | cut -d= -f2-)"

# The browser-originated comparison has dedicated status/result/action routes.
# Start and cooperatively stop it before the mock browser submits any traffic;
# this exercises the async lifecycle and proves the transaction restores mode.
RAW="$(_cgi GET /offload/benchmark "view=status")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "benchmark status route available" "true" "$(_jget "$OUT" 'd["ok"]')"
assert_eq "benchmark status idle before start" "false" "$(_jget "$OUT" 'd["active"]')"
assert_eq "benchmark result does not invent metrics" "null" "$(_jget "$OUT" 'd["result"]')"
assert_eq "benchmark has no fabricated last-success timestamp" "" "$(_jget "$OUT" 'd["last_success_timestamp"]')"
printf 'action=start&provider=cloudflare' > "$T/body.txt"
RAW="$(_cgi POST /offload/benchmark "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "benchmark start accepted" "true" "$(_jget "$OUT" 'd["ok"]')"
_benchmark_job="$(_jget "$OUT" 'd["job"]')"
JOB_IDS="$JOB_IDS $_benchmark_job"
printf 'action=stop' > "$T/stop-body.txt"
RAW="$(_cgi POST /offload/benchmark "" "$T/stop-body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "benchmark cooperative stop accepted" "true" "$(_jget "$OUT" 'd["stopping"]')"
_benchmark_out="$(_poll_job "$_benchmark_job")"
assert_eq "benchmark stop job completes with stopped transaction" "1" "$(_jget "$_benchmark_out" 'd["exit"]')"
RAW="$(_cgi GET /offload/benchmark "view=status")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "benchmark stop restores original configured FLOWOFFLOAD" "software" "$(grep '^FLOWOFFLOAD=' "$T/etc/config" | tail -1 | cut -d= -f2-)"
assert_eq "benchmark stop exposes terminal status" "stopped" "$(_jget "$OUT" 'd["status"]')"
assert_file "benchmark stop saves structured result" "$T/etc/state/flowoffload-benchmark/last-result.json"
RAW="$(_cgi GET /offload/benchmark "view=last-success")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "stopped benchmark is not reported as a successful history item" "null" "$(printf '%s' "$OUT" | tr -d '\n')"

# --- Host allowlist с LAN bind (WP25-контекст) ---
RAW="$(env REQUEST_METHOD="GET" PATH_INFO="/status" QUERY_STRING="" \
    HTTP_HOST="evil.example.com" HTTP_X_Z2K_PANEL="1" CONTENT_LENGTH="0" \
    sh "$T/cgi/api.sh" < /dev/null 2>/dev/null)"
assert_eq "status: чужой Host 403" "Status: 403 Forbidden" "$(printf '%s\n' "$RAW" | _cgi_status)"

# --- whitelist roundtrip (WP10) ---
printf 'domain=example.org' > "$T/body.txt"
RAW="$(_cgi POST /whitelist/add "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "whitelist add ok" "true" "$(_jget "$OUT" 'd["ok"]')"
RAW="$(_cgi GET /whitelist)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "whitelist list" "example.org" "$(_jget "$OUT" 'd["domains"][0]')"

# --- exclusions: файл да, ipset нет (WP11) ---
printf 'entry=9.9.9.9' > "$T/body.txt"
RAW="$(_cgi POST /exclude/add "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "exclude add ok" "true" "$(_jget "$OUT" 'd["ok"]')"
assert_contains "exclude файл" "$T/etc/user-lists/exclude.txt" "9.9.9.9"

# --- TG disable/enable через Stage-3 контракт (WP12) ---
: > "$T/init.log"
RAW="$(_cgi POST /tunnel/disable)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "tg disable: job" "true" "$(_jget "$OUT" 'd["ok"]')"
JOB_IDS="$JOB_IDS $(_jget "$OUT" 'd["job"]')"
_i=0
while [ "$_i" -lt 25 ]; do
    sleep 0.2
    grep -q '^TG_PROXY_USER_DISABLED=1' "$T/etc/config" 2>/dev/null && break
    _i=$((_i + 1))
done
assert_eq "TG flag=1 в конфиге" "1" "$(grep -m1 '^TG_PROXY_USER_DISABLED=' "$T/etc/config" | cut -d= -f2)"
assert_contains "TG disable: init reload" "$T/init.log" "reload"
: > "$T/init.log"
RAW="$(_cgi POST /tunnel/enable)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "tg enable: job" "true" "$(_jget "$OUT" 'd["ok"]')"
JOB_IDS="$JOB_IDS $(_jget "$OUT" 'd["job"]')"
_i=0
while [ "$_i" -lt 25 ]; do
    sleep 0.2
    grep -q '^TG_PROXY_USER_DISABLED=0' "$T/etc/config" 2>/dev/null && break
    _i=$((_i + 1))
done
assert_eq "TG flag=0 в конфиге" "0" "$(grep -m1 '^TG_PROXY_USER_DISABLED=' "$T/etc/config" | cut -d= -f2)"
if grep -q 'S98tg-tunnel\|S97z2k-http' "$T/init.log" 2>/dev/null; then
    _t_bad "TG: дёрнули Keenetic-иниты"
else
    _t_ok
fi

# --- WARP status + list save (WP14/WP15) ---
RAW="$(_cgi GET /warp/status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "warp: installed" "true" "$(_jget "$OUT" 'd["installed"]')"
assert_eq "warp: transport из движка" "wg" "$(_jget "$OUT" 'd["transport"]')"
printf '7.7.7.0/24\nnot-an-ip\n' > "$T/body.txt"
RAW="$(_cgi POST /warp/list/save "name=mine&mode=replace" "$T/body.txt")"
OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "warp list: saved 1" "1" "$(_jget "$OUT" 'd["saved"]')"
assert_contains "warp list: файл" "$T/etc/user-lists/warp/mine.txt" "7.7.7.0/24"

# --- neighbors без Keenetic-API (WP16) ---
RAW="$(_cgi GET /warp/neighbors)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "neighbors: mac виден" "aa:bb:cc:dd:ee:ff" "$(_jget "$OUT" 'd["devices"][0]["mac"]')"
assert_eq "neighbors: on=1" "true" "$(_jget "$OUT" 'd["devices"][0]["on"]')"

# --- dashboard and apply share one signed, controlled OpenWrt manifest (WP17) ---
cat > "$T/controlled-UPDATES.json" <<'EOF'
{
  "schema": 1,
  "branch": "main",
  "platform": "openwrt",
  "seq": 134,
  "current": "p-86.11",
  "upstream": {
    "repository": "necronicle/z2k",
    "branch": "z2k-enhanced",
    "tag": "p-86.11",
    "commit": "09228b68984b6a489612608d90f63c227708fdba"
  },
  "history": [
    {"v":"p-86.2","type":"patch","ts":"2026-09-30T00:00:00Z","desc":"previous release"},
    {"v":"r-86.3","type":"reinstall","ts":"2026-09-30T01:00:00Z","desc":"release history"},
    {"v":"r-86.4","type":"reinstall","ts":"2026-09-30T02:00:00Z","desc":"release history"},
    {"v":"p-86.6","type":"patch","ts":"2026-09-30T03:00:00Z","desc":"release history"},
    {"v":"p-86.11","type":"patch","ts":"2026-10-01T19:01:37Z","desc":"current release"}
  ],
  "artifact": {
    "filename": "openwrt-rootfs.tar.gz",
    "url": "https://github.com/t0fox/z2kOW/releases/download/openwrt-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/openwrt-rootfs.tar.gz",
    "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "size_bytes": 23
  }
}
EOF
python3 - "$T/controlled-UPDATES.json" <<'PY'
import json, sys
path = sys.argv[1]
manifest = json.load(open(path, encoding="utf-8"))
legacy = manifest.pop("artifact")
manifest["artifacts"] = {}
for index, arch in enumerate(("arm64", "arm", "x86_64", "x86", "mips", "mipsel", "riscv64")):
    manifest["artifacts"][arch] = {
        "filename": f"openwrt-rootfs-{arch}.tar.gz",
        "url": legacy["url"].rsplit("/", 1)[0] + f"/openwrt-rootfs-{arch}.tar.gz",
        "sha256": str(index + 1) * 64,
        "size_bytes": legacy["size_bytes"] + index,
        "unpacked_size_bytes": 1024 + index,
    }
json.dump(manifest, open(path, "w", encoding="utf-8"))
PY
EXPECTED_ARM64_SHA="$(python3 -c 'print("1" * 64)')"
openssl genpkey -algorithm ed25519 -out "$T/controlled-test.key"
openssl pkey -in "$T/controlled-test.key" -pubout -out "$T/controlled-test.pub"
_test_key_id="$(openssl pkey -pubin -in "$T/controlled-test.pub" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
mkdir -p "$T/root/platform/openwrt/release-keys"
cp "$T/controlled-test.pub" "$T/root/platform/openwrt/release-keys/$_test_key_id.pub"
python3 - "$REPO" "$T/controlled-UPDATES.json" "$_test_key_id" <<'PY'
import json, sys
from pathlib import Path
repo, path, key_id = sys.argv[1:]
sys.path.insert(0, str(Path(repo) / "scripts" / "openwrt"))
from controlled_release import render_manifest
manifest = json.load(open(path, encoding="utf-8"))
manifest["signing"] = {"key_id": key_id}
Path(path).write_text(render_manifest(manifest), encoding="utf-8")
PY
openssl pkeyutl -sign -rawin -inkey "$T/controlled-test.key" -in "$T/controlled-UPDATES.json" -out "$T/controlled-UPDATES.json.sig"
export OW_TEST_FETCH_LOG="$T/update-fetch.log"
export OW_TEST_FETCH_FAIL="$T/fail-controlled-fetch"
export OW_TEST_UPDATES="$T/controlled-UPDATES.json"
export OW_TEST_UPDATES_SIG="$T/controlled-UPDATES.json.sig"
export Z2K_AU_PUBKEY="$T/controlled-test.pub"
export Z2K_AU_REPO_RAW="https://updates.example/controlled"
export Z2K_AU_MANIFEST_URL="$Z2K_AU_REPO_RAW/UPDATES.json"
export Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release" Z2K_AU_TMP_DIR="$T/update-tmp"
printf "DISTRIB_ARCH='aarch64_cortex-a53'\n" > "$T/openwrt_release"
mkdir -p "$Z2K_AU_TMP_DIR"
export AU_MANIFEST_CACHE="$T/manifest.json"
export AU_MANIFEST_FAIL_STAMP="$T/manifest.json.fail"
mkdir -p "$T/etc/state"
printf 'tag=p-86.2\nseq=127\n' > "$T/etc/state/installed-release"
export AU_TAG_FILE="$T/etc/state/installed-release"
RAW="$(_cgi GET /status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "status: canonical release state marks installed" "true" "$(_jget "$OUT" 'd["installed"]')"
assert_eq "status: installed tag comes from canonical state" "p-86.2" "$(_jget "$OUT" 'd["installed_release"]')"
assert_eq "status: installed seq comes from canonical state" "127" "$(_jget "$OUT" 'd["installed_seq"]')"
_api_tag="$(_jget "$OUT" 'd["installed_release"]')"
_api_seq="$(_jget "$OUT" 'd["installed_seq"]')"
_cli_status="$(env Z2K_RELEASE_STATE_LIB="$REPO/platform/openwrt/release_state.sh" \
    Z2K_OW_INSTALLED_RELEASE_FILE="$AU_TAG_FILE" Z2K_INIT="$T/mock-init" \
    sh "$REPO/platform/openwrt/z2kow.sh" status 2>&1)"; _cli_rc=$?
assert_eq "CLI reads the same canonical release tag as WebPanel API" "$_api_tag" "$(printf '%s\n' "$_cli_status" | sed -n 's/^installed_release=//p')"
assert_eq "CLI reads the same canonical sequence as WebPanel API" "$_api_seq" "$(printf '%s\n' "$_cli_status" | sed -n 's/^installed_seq=//p')"
assert_eq "CLI reads the shared API release record successfully" "0" "$_cli_rc"
RAW="$(_cgi GET /update/status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "update: installed payload truth" "p-86.2" "$(_jget "$OUT" 'd["installed"]')"
assert_eq "update: exposes server epoch for relative event age" "true" "$(_jget "$OUT" 'isinstance(d.get("server_now_epoch"), int) and d["server_now_epoch"] > 0')"
assert_eq "update: installed sequence comes from canonical release state" "127" "$(_jget "$OUT" 'd["installed_seq"]')"
assert_eq "update: controlled sequence comes from UPDATES.json" "134" "$(_jget "$OUT" 'd["available_seq"]')"
assert_not_contains "update: no package/snapshot versions leak into the one release API" "$OUT" "_package"
assert_not_contains "update: payload/seed metadata is not a user update version" "$OUT" '"seed"'
assert_eq "update: available comes from signed controlled release" "p-86.11" "$(_jget "$OUT" 'd["available"]')"
assert_eq "update: same-version reinstall is exposed only on OpenWrt" "true" "$(_jget "$OUT" 'd["reinstall_supported"]')"
assert_eq "update: signed manifest is cached with controlled authority" "controlled" "$(cat "$AU_MANIFEST_CACHE.authority")"
assert_eq "update: no fetch failure for valid controlled signature" "false" "$(_jget "$OUT" 'd["fetch_failed"]')"
assert_contains "update: requests controlled manifest" "$T/update-fetch.log" "https://updates.example/controlled/UPDATES.json"
assert_contains "update: requests controlled signature" "$T/update-fetch.log" "https://updates.example/controlled/UPDATES.json.sig"
# The same tag with an older installed sequence is not current. The installer
# already converges sequence drift through install_release; the WebPanel must
# expose that same decision instead of hiding it behind a tag-only comparison.
printf 'tag=p-86.11\nseq=133\n' > "$T/etc/state/installed-release"
RAW="$(_cgi GET /update/status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "update: same tag with stale sequence requests convergence" "1" "$(_jget "$OUT" 'd["behind"]')"
assert_eq "update: same tag sequence drift is explicit" "true" "$(_jget "$OUT" 'd["release_seq_mismatch"]')"
printf 'tag=p-86.11\nseq=135\n' > "$T/etc/state/installed-release"
RAW="$( _cgi GET /update/status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "update: installed sequence ahead of controlled release fails closed" "Status: 503 Service Unavailable" "$(printf '%s\n' "$RAW" | _cgi_status)"
assert_eq "update: future local sequence is not presented as current or downgraded" "false" "$(_jget "$OUT" 'd["ok"]')"
printf 'tag=p-86.2\nseq=127\n' > "$T/etc/state/installed-release"
# A syntactically valid release absent from controlled history cannot be
# reported as current; upstream also refuses to compare unknown history tags.
printf 'tag=p-99.99\nseq=999\n' > "$T/etc/state/installed-release"
RAW="$(_cgi GET /update/status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "update: unlisted installed release is not treated as current" "Status: 503 Service Unavailable" "$(printf '%s\n' "$RAW" | _cgi_status)"
assert_eq "update: unlisted installed release returns an error response" "false" "$(_jget "$OUT" 'd["ok"]')"
printf 'tag=p-86.2\nseq=127\n' > "$T/etc/state/installed-release"
printf '{"current":"p-86.12","history":[{"v":"p-86.12"}]}' > "$T/zapret2/UPDATES.json"
assert_not_contains "update: newer upstream-only release stays hidden" "$OUT" "p-86.12"
assert_eq "update: temporary etag sidecars are removed" "" "$(find "$T" -name '*.etag' -print -quit)"

# An unknown/corrupt canonical record must be an explicit API error, never a zero-behind result.
printf 'tag=unknown\nseq=127\n' > "$T/etc/state/installed-release"
RAW="$(_cgi GET /status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "status: corrupt release metadata stays uninstalled" "false" "$(_jget "$OUT" 'd["installed"]')"
assert_eq "status: corrupt release metadata is an explicit error" "error" "$(_jget "$OUT" 'd["installed_state"]')"
RAW="$(_cgi GET /update/status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
printf '%s\n' "$RAW" > "$T/update-unknown.out"
assert_eq "update: unknown installed version returns HTTP state error" "Status: 503 Service Unavailable" "$(printf '%s\n' "$RAW" | _cgi_status)"
assert_eq "update: unknown installed version is not a successful update response" "false" "$(_jget "$OUT" 'd["ok"]')"
assert_contains "update: неизвестная установленная версия объясняет, где ошибка записи выпуска" "$T/update-unknown.out" "запись установленного выпуска"
rm -f "$T/etc/state/installed-release"
RAW="$(_cgi GET /update/status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "update: missing installed metadata returns HTTP state error" "Status: 503 Service Unavailable" "$(printf '%s\n' "$RAW" | _cgi_status)"
assert_eq "update: missing installed metadata is not treated as current" "false" "$(_jget "$OUT" 'd["ok"]')"
printf 'tag=p-86.2\nseq=127\n' > "$T/etc/state/installed-release"
cp "$T/controlled-UPDATES.json" "$T/controlled-UPDATES.complete.json"
python3 - "$T/controlled-UPDATES.json" <<'PY'
import json, sys
path = sys.argv[1]
manifest = json.load(open(path, encoding="utf-8"))
manifest["artifacts"].pop("arm64", None)
manifest["artifact"] = {
    "filename": "openwrt-rootfs.tar.gz",
    "url": "https://github.com/t0fox/z2kOW/releases/download/openwrt-" + "a" * 40 + "/openwrt-rootfs.tar.gz",
    "sha256": "c" * 64,
    "size_bytes": 23,
}
json.dump(manifest, open(path, "w", encoding="utf-8"))
PY
openssl pkeyutl -sign -rawin -inkey "$T/controlled-test.key" \
    -in "$T/controlled-UPDATES.json" -out "$T/controlled-UPDATES.json.sig"
rm -f "$AU_MANIFEST_CACHE" "$AU_MANIFEST_CACHE.authority" "$AU_MANIFEST_FAIL_STAMP"
RAW="$(_cgi GET /update/status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "update: signed manifest missing local arch record is rejected" "" "$(_jget "$OUT" 'd["available"]')"
assert_eq "update: local arch record failure reports fetch failure despite legacy fallback" "true" "$(_jget "$OUT" 'd["fetch_failed"]')"
mv -f "$T/controlled-UPDATES.complete.json" "$T/controlled-UPDATES.json"
openssl pkeyutl -sign -rawin -inkey "$T/controlled-test.key" \
    -in "$T/controlled-UPDATES.json" -out "$T/controlled-UPDATES.json.sig"
cp "$T/controlled-UPDATES.json.sig" "$T/controlled-UPDATES.valid.sig"
printf 'invalid signature\n' > "$T/controlled-UPDATES.json.sig"
rm -f "$AU_MANIFEST_CACHE" "$AU_MANIFEST_CACHE.authority" "$AU_MANIFEST_FAIL_STAMP"
RAW="$(_cgi GET /update/status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "update: invalid controlled signature is not available" "" "$(_jget "$OUT" 'd["available"]')"
assert_eq "update: invalid controlled signature is a fetch failure" "true" "$(_jget "$OUT" 'd["fetch_failed"]')"
[ ! -e "$AU_MANIFEST_CACHE.authority" ] && _t_ok || _t_bad "update: invalid signature must not gain controlled cache authority"
mv -f "$T/controlled-UPDATES.valid.sig" "$T/controlled-UPDATES.json.sig"

# /update/history is the same controlled release history as the Dashboard banner.
cat > "$T/root/UPDATES.json" <<'EOF'
{
  "current": "p-86.12",
  "history": [
    {"v": "p-86.12", "type": "patch", "ts": "2026-10-01T20:00:00Z", "desc": "upstream only, not approved"}
  ]
}
EOF
cp "$T/controlled-UPDATES.json" "$AU_MANIFEST_CACHE"
cp "$T/controlled-UPDATES.json.sig" "$AU_MANIFEST_CACHE.sig"
printf 'controlled\n' > "$AU_MANIFEST_CACHE.authority"
RAW="$(_cgi GET /update/history "offset=0&limit=1")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "history: controlled newest first" "p-86.11" "$(_jget "$OUT" 'd["history"][0]["v"]')"
assert_not_contains "history: newer upstream-only release stays hidden" "$OUT" "p-86.12"
rm -f "$AU_MANIFEST_CACHE" "$AU_MANIFEST_CACHE.sig" "$AU_MANIFEST_CACHE.authority"
touch "$OW_TEST_FETCH_FAIL" "$AU_MANIFEST_FAIL_STAMP"
RAW="$(_cgi GET /update/history "offset=0&limit=1")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "history: no snapshot payload fallback" "0" "$(_jget "$OUT" 'd["total"]')"
assert_not_contains "history: upstream-only entry stays hidden when controlled manifest is unavailable" "$OUT" "p-86.12"
[ ! -e "$REPO/webpanel/cgi/api-openwrt.sh" ] && _t_ok || _t_bad "forbidden api-openwrt.sh exists"
[ ! -e "$REPO/webpanel/cgi/update-openwrt.js" ] && _t_ok || _t_bad "forbidden update-openwrt.js exists"

# Common webpanel route persists the selected hour and invokes the OpenWrt
# platform seam, which converges the existing updater marker in cron.  Start
# with a deliberately old seam (the mixed-version state seen during a live
# upgrade): api.sh must still bind the route to the package scheduler.
awk '
    skip { if ($0 ~ /^fi$/) skip=0; next }
    /# The common \/update\/schedule route calls this seam/ { skip=1; next }
    { print }
' "$T/cgi/platform.sh" > "$T/cgi/platform.sh.old" && mv "$T/cgi/platform.sh.old" "$T/cgi/platform.sh"
printf 'hour=11' > "$T/body.txt"
RAW="$(_cgi POST /update/schedule "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "schedule API: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
assert_eq "schedule API: config hour" "11" "$(grep -m1 '^Z2K_AU_HOUR=' "$T/etc/config" | cut -d= -f2)"
assert_contains "schedule API: cron converged" "$Z2K_CRON_TAB" "17 11 * * * $Z2K_ROOT/platform/openwrt/update.sh apply # z2k-updater"

# --- отказы Keenetic-only (WP19/WP20/WP34-контекст): маршруты async, отказ
# падает в job (rc != 0), немедленный ответ — только job id ---
printf 'name=x&exclude=0' > "$T/body.txt"
RAW="$(_cgi POST /policy/save "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
_jid="$(_jget "$OUT" 'd["job"]')"
JOB_IDS="$JOB_IDS $_jid"
_poll_job_fail "$_jid" "policy save: отказ"
printf 'value=1' > "$T/body.txt"
RAW="$(_cgi POST /toggle/ppe "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
_jid="$(_jget "$OUT" 'd["job"]')"
JOB_IDS="$JOB_IDS $_jid"
_poll_job_fail "$_jid" "ppe toggle: отказ"
printf 'value=1' > "$T/body.txt"
RAW="$(_cgi POST /toggle/fastroute "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
_jid="$(_jget "$OUT" 'd["job"]')"
JOB_IDS="$JOB_IDS $_jid"
_poll_job_fail "$_jid" "fastroute toggle: backend unavailable"
printf 'confirm=X' > "$T/body.txt"
RAW="$(_cgi POST /uninstall "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "uninstall: сервер отклоняет запрос без подтверждения" "false" "$(_jget "$OUT" 'd["ok"]')"

# --- customd parity: async enable/disable route mutates the inverse flag ---
printf 'value=1' > "$T/body.txt"
RAW="$(_cgi POST /toggle/customd "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "toggle: job выдан" "true" "$(_jget "$OUT" 'd["ok"]')"
_jid="$(_jget "$OUT" 'd["job"]')"
JOB_IDS="$JOB_IDS $_jid"
_jo="$(_poll_job "$_jid")" || _t_bad "customd enable: job timeout"
assert_eq "customd enable: job success" "0" "$(_jget "$_jo" 'd["exit"]')"
assert_eq "customd enable: inverse flag" "0" "$(grep -m1 '^DISABLE_CUSTOM=' "$T/etc/config" | cut -d= -f2)"
assert_contains "customd enable: service restart" "$T/init.log" "restart"
printf 'value=0' > "$T/body.txt"
RAW="$(_cgi POST /toggle/customd "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
_jid="$(_jget "$OUT" 'd["job"]')"
JOB_IDS="$JOB_IDS $_jid"
_jo="$(_poll_job "$_jid")" || _t_bad "customd disable: job timeout"
assert_eq "customd disable: job success" "0" "$(_jget "$_jo" 'd["exit"]')"
assert_eq "customd disable: inverse flag" "1" "$(grep -m1 '^DISABLE_CUSTOM=' "$T/etc/config" | cut -d= -f2)"
assert_contains "customd disable: clean stop" "$T/init.log" "stop"

# --- strategy pool save (WP9) ---
mkdir -p "$T/etc/user-lists/custom-strategies"
export CUSTOM_STRAT_DIR="$T/etc/user-lists/custom-strategies"
printf 'line1\n' > "$T/body.txt"
RAW="$(_cgi POST /strategy/pool/save "pool=rkn_tcp" "$T/body.txt")"
OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "pool save ok" "true" "$(_jget "$OUT" 'd["ok"]')"
assert_contains "pool файл" "$T/etc/user-lists/custom-strategies/rkn_tcp.txt" "line1"

# --- update apply вызывает существующий updater (WP18) ---
cat > "$T/fake-apply" <<EOF
#!/bin/sh
echo "apply-args:\$*" >> "$T/apply.log"
echo "manual=\$Z2K_AU_MANUAL" >> "$T/apply.log"
"$REPO/platform/openwrt/update.sh" "\$@" >> "$T/updater.log" 2>&1
_rc=\$?
echo "update-rc:\$_rc" >> "$T/apply.log"
exit "\$_rc"
EOF
chmod +x "$T/fake-apply"
export AU_SCRIPT="$T/fake-apply"
cat > "$T/bin/install_release" <<'EOF'
#!/bin/sh
. "$Z2K_ROOT/platform/openwrt/manifest.sh"
arch="$(z2k_ow_manifest_local_arch)" || exit 1
manifest="${Z2K_AU_TMP_DIR}/UPDATES.json"
z2k_ow_manifest_select_artifact "$manifest" "$arch" || exit 1
printf 'install-args:%s arch=%s filename=%s sha=%s\n' \
    "$*" "$arch" "$Z2K_OW_ARTIFACT_FILENAME" "$Z2K_OW_ARTIFACT_SHA256" >> "$OW_TEST_INSTALL_LOG"
EOF
chmod +x "$T/bin/install_release"
export Z2K_INSTALL_RELEASE_BIN="$T/bin/install_release" OW_TEST_INSTALL_LOG="$T/install-artifacts.log"

# Reinstall is pinned to the release already installed on the device. The
# operation obtains a fresh signed production manifest before it can enqueue
# the canonical update adapter.
rm -f "$OW_TEST_FETCH_FAIL" "$AU_MANIFEST_FAIL_STAMP"
printf 'tag=p-86.2\nseq=127\n' > "$T/etc/state/installed-release"
: > "$T/apply.log"
RAW="$(_cgi POST /update/reinstall)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "reinstall preflight: newer controlled release is a successful state response" "Status: 200 OK" "$(printf '%s\n' "$RAW" | _cgi_status)"
assert_eq "reinstall preflight: response state is update_available" "update_available" "$(_jget "$OUT" 'd["state"]')"
assert_eq "reinstall preflight: old installed tag is identified" "p-86.2" "$(_jget "$OUT" 'd["installed"]')"
assert_eq "reinstall preflight: only the fresh controlled tag is offered" "p-86.11" "$(_jget "$OUT" 'd["available"]')"
assert_eq "reinstall preflight: changed manifest does not launch any installer job" "" "$(cat "$T/apply.log")"
assert_contains "reinstall preflight: re-fetches production manifest" "$T/update-fetch.log" "https://updates.example/controlled/UPDATES.json"

# Even a valid cached manifest is insufficient when a fresh fetch fails. The
# strict preflight must fail closed and preserve the no-install guarantee.
printf 'tag=p-86.11\nseq=134\n' > "$T/etc/state/installed-release"
touch "$OW_TEST_FETCH_FAIL"
RAW="$(_cgi POST /update/reinstall)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "reinstall preflight: unavailable fresh manifest fails closed" "Status: 503 Service Unavailable" "$(printf '%s\n' "$RAW" | _cgi_status)"
assert_eq "reinstall preflight: stale manifest never launches install" "" "$(cat "$T/apply.log")"
rm -f "$OW_TEST_FETCH_FAIL"

# A current, equal tag+seq may launch only the shared manual reinstall action.
RAW="$(_cgi POST /update/reinstall)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "reinstall: current release launches a job" "true" "$(_jget "$OUT" 'd["ok"]')"
assert_eq "reinstall: response identifies reinstalling state" "reinstalling" "$(_jget "$OUT" 'd["state"]')"
_jid="$(_jget "$OUT" 'd["job"]')"
JOB_IDS="$JOB_IDS $_jid"
_jo="$(_poll_job "$_jid")" || _t_bad "reinstall: job не завершился"
assert_eq "reinstall: shared update adapter succeeds" "0" "$(_jget "$_jo" 'd["exit"]')"
assert_contains "reinstall: invokes same update adapter with manual reinstall action" "$T/apply.log" "apply-args:reinstall"
assert_contains "reinstall: preserves explicit manual flag" "$T/apply.log" "manual=1"
assert_contains "reinstall: routes through the selected local architecture record" "$T/install-artifacts.log" \
    "install-args:--reinstall p-86.11 arch=arm64 filename=openwrt-rootfs-arm64.tar.gz sha=$EXPECTED_ARM64_SHA"

printf 'tag=p-86.2\nseq=127\n' > "$T/etc/state/installed-release"
RAW="$(_cgi POST /update/apply)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "apply: job выдан" "true" "$(_jget "$OUT" 'd["ok"]')"
_jid="$(_jget "$OUT" 'd["job"]')"
JOB_IDS="$JOB_IDS $_jid"
_jo="$(_poll_job "$_jid")" || _t_bad "apply: job не завершился"
assert_eq "apply: shared update adapter succeeds" "0" "$(_jget "$_jo" 'd["exit"]')"
assert_contains "apply: updater still uses ordinary update action" "$T/apply.log" "apply-args:apply"
assert_contains "apply: manual флаг" "$T/apply.log" "manual=1"
assert_contains "apply: ordinary update uses the same selected local architecture artifact" "$T/install-artifacts.log" \
    "install-args:p-86.11 arch=arm64 filename=openwrt-rootfs-arm64.tar.gz sha=$EXPECTED_ARM64_SHA"

# --- WP-MATRIX (webpanel parity, п.4/п.5): каждый frontend GET/POST ---
# Карта вкладок → вызовов → endpoints сверена с source (58 вызовов / 75
# кейсов). Здесь regression-гейт: HTTP + shape + controlled-отказ, всё
# внутри fixture (nft/ip/init — моки, сеть не трогается).
_mg() { # $1 label $2 path [$3 query] — проверяет 200, печатает тело
    _mr="$(_cgi GET "$2" "${3:-}")"
    assert_eq "$1: HTTP 200" "Status: 200 OK" "$(printf '%s\n' "$_mr" | _cgi_status)"
    printf '%s\n' "$_mr" | _cgi_body
}
_poll_job_ok() { # $1 jobid $2 label — done + exit 0
    _jo="$(_poll_job "$1")" || { _t_bad "$2: job не завершился"; return 1; }
    assert_eq "$2: job done" "true" "$(_jget "$_jo" 'd["done"]')"
    assert_eq "$2: job rc 0" "0" "$(_jget "$_jo" 'd["exit"]')"
}

# GET /toggles: единственный вызов без кейса (404 был на обеих платформах).
OUT="$(_mg "toggles" /toggles)"
assert_eq "toggles: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
assert_eq "toggles: game_warp из конфига" "0" "$(_jget "$OUT" 'd["game_warp"]')"
assert_eq "toggles: retired stats fields are absent" "0" "$(printf '%s' "$OUT" | grep -Ec '"stats(_ack)?"' || true)"
printf 'GAME_WARP_ENABLED=0\nENABLED=1\nDISABLE_CUSTOM=1\n' > "$T/etc/config"

# Остальные frontend GET: статус + по одному ключевому полю shape.
OUT="$(_mg "exclude" /exclude)"
assert_eq "exclude: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
OUT="$(_mg "extra-domains" /extra-domains)"
assert_eq "extra-domains: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
OUT="$(_mg "autohostlist-domains" /autohostlist-domains)"
assert_eq "autohostlist-domains: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
OUT="$(_mg "dns-check" /dns/check)"
assert_eq "dns-check: own пуст" "" "$(_jget "$OUT" 'd["own"]')"
OUT="$(_mg "strategy-pick" /strategy/pick)"
assert_eq "strategy-pick: result null" "null" "$(_jget "$OUT" 'd["result"]')"
OUT="$(_mg "strategy-pools" /strategy/pools)"
assert_eq "strategy-pools: 5 пулов" "5" "$(_jget "$OUT" 'len(d["pools"])')"
OUT="$(_mg "warp-games" /warp/games)"
assert_eq "warp-games: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
OUT="$(_mg "warp-lists" /warp/lists)"
assert_eq "warp-lists: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
RAW="$(_cgi GET /warp/list "name=nosuch")"
assert_eq "warp-list missing: 404 controlled" "Status: 404 Not Found" "$(printf '%s\n' "$RAW" | _cgi_status)"
RAW="$(_cgi GET /warp/devices)"
assert_eq "warp-devices: text/plain" "Content-Type: text/plain; charset=utf-8" "$(printf '%s\n' "$RAW" | _cgi_status)"
assert_contains "warp-devices: тело" "$T/etc/user-lists/warp/devices.txt" "aa:bb:cc:dd:ee:ff"
OUT="$(_mg "tcp16" /tcp16)"
assert_eq "tcp16: running false" "false" "$(_jget "$OUT" 'd["running"]')"
printf '1\n' > "$T/etc/state/tcp16.flag"
date +%s > "$T/etc/state/tcp16.flag.ts"
printf '7\n' > "$T/etc/state/tcp16.duration"
printf '24940\n' > "$T/etc/state/tcp16_asn.txt"
printf '24940\ttest.example\n' > "$T/etc/state/tcp16_sni.txt"
OUT="$(_mg "tcp16" /tcp16)"
assert_eq "tcp16 API reads canonical persistent verdict" "1" "$(_jget "$OUT" 'd["measured"]')"
assert_eq "tcp16 API reads canonical duration" "7" "$(_jget "$OUT" 'd["duration"]')"
assert_eq "tcp16 API counts canonical SNI map" "1" "$(_jget "$OUT" 'd["names"]')"
OUT="$(_mg "state" /state)"
assert_eq "state: entries пусты" "0" "$(_jget "$OUT" 'len(d["entries"])')"
OUT="$(_mg "pools" /pools)"
assert_eq "pools: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
OUT="$(_mg "policy-status" /policy/status)"
assert_eq "policy-status: exists 0" "0" "$(_jget "$OUT" 'd["exists"]')"
OUT="$(_mg "auth-state" /auth/state)"
assert_eq "auth-state: required false" "false" "$(_jget "$OUT" 'd["required"]')"
OUT="$(_mg "debug" /debug)"
assert_eq "debug: enabled 0" "0" "$(_jget "$OUT" 'd["enabled"]')"
OUT="$(_mg "diag" /diag)"
assert_eq "diag: ok (контент честный)" "true" "$(_jget "$OUT" 'd["ok"]')"
RAW="$(_cgi GET /diag/download)"
assert_eq "diag-download: 200" "Status: 200 OK" "$(printf '%s\n' "$RAW" | _cgi_status)"
RAW="$(_cgi POST /probe/run)"
assert_eq "probe/run: 410 Gone" "Status: 410 Gone" "$(printf '%s\n' "$RAW" | _cgi_status)"
RAW="$(_cgi GET /strategy/pool "pool=rkn_tcp")"
assert_eq "pool missing: text/plain пусто" "Content-Type: text/plain; charset=utf-8" "$(printf '%s\n' "$RAW" | _cgi_status)"

# Долгие POST toggles: каждый job доходит до done/rc 0, флаг — в конфиге.
# Статистика и автообновление проверяются отдельно ниже как быстрые sync writes.
for _tg in "dynamic-ttl:Z2K_DYNAMIC_TTL:1" "autohostlist:Z2K_AUTOHOSTLIST:1" "tiktok-feed:Z2K_TIKTOK_FEED_ENABLED:1"; do
    _tn="${_tg%%:*}"; _rest="${_tg#*:}"; _tk="${_rest%%:*}"; _tv="${_rest##*:}"
    printf 'value=%s' "$_tv" > "$T/body.txt"
    RAW="$(_cgi POST /toggle/$_tn "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
    assert_eq "toggle $_tn: job выдан" "true" "$(_jget "$OUT" 'd["ok"]')"
    _jid="$(_jget "$OUT" 'd["job"]')"
    JOB_IDS="$JOB_IDS $_jid"
    _poll_job_ok "$_jid" "toggle $_tn"
    assert_eq "toggle $_tn: флаг $_tk=$_tv" "$_tv" "$(grep -m1 "^$_tk=" "$T/etc/config" | cut -d= -f2)"
done
RAW="$(_cgi GET /status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "TikTok feed toggle state follows the persistent config flag" "1" "$(_jget "$OUT" 'd["toggles"]["tiktok_feed"]')"
cat > "$T/etc/state/tiktok-cdn.state" <<'EOF'
state=healthy
selected_ip=203.0.113.9
latency_ms=84
last_verified_epoch=1780550000
selected_at_epoch=1780549950
failure_count=0
selected_source_domain=www.tiktokcdn.com
selected_mode=verified
selected_provenance=resolver+tls
selected_cname=edge.example.net
last_failover_epoch=1780549900
last_failover_from=203.0.113.8
last_failover_to=203.0.113.9
last_failover_reason=consecutive-probe-failures
candidate_verified=1
dns_override_applied=1
candidate_pool=203.0.113.9|v77.tiktokcdn.com|direct|1.1.1.1|system-wan||Amsterdam|resolver+tls|1|0|0
probe_observations=203.0.113.9|84|15|25|400|ams||edge|ok|ok|verified
reason=healthy
EOF
printf 'Z2K_TIKTOK_MODE=manual\nZ2K_TIKTOK_MANUAL_IP=203.0.113.9\n' >> "$T/etc/config"
RAW="$(_cgi GET /status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "status: TikTok diagnostics project current state" "healthy" "$(_jget "$OUT" 'd["tiktok_feed_status"]["state"]')"
assert_eq "status: TikTok diagnostics project selected CDN" "203.0.113.9" "$(_jget "$OUT" 'd["tiktok_feed_status"]["selected_ip"]')"
assert_eq "status: TikTok current selection timestamp is projected" "1780549950" "$(_jget "$OUT" 'd["tiktok_feed_status"]["selected_at_epoch"]')"
assert_eq "status: TikTok diagnostics project source domain" "www.tiktokcdn.com" "$(_jget "$OUT" 'd["tiktok_feed_status"]["selected_source_domain"]')"
assert_eq "status: TikTok diagnostics project failover reason" "consecutive-probe-failures" "$(_jget "$OUT" 'd["tiktok_feed_status"]["last_failover_reason"]')"
assert_eq "status: TikTok mode is projected" "manual" "$(_jget "$OUT" 'd["tiktok_feed_status"]["mode"]')"
assert_eq "status: TikTok manual IP is projected" "203.0.113.9" "$(_jget "$OUT" 'd["tiktok_feed_status"]["manual_ip"]')"
assert_eq "status: TikTok discovery pool is projected" "203.0.113.9|v77.tiktokcdn.com|direct|1.1.1.1|system-wan||Amsterdam|resolver+tls|1|0|0" "$(_jget "$OUT" 'd["tiktok_feed_status"]["candidate_pool"]')"
assert_eq "status: TikTok probe observations are projected" "203.0.113.9|84|15|25|400|ams||edge|ok|ok|verified" "$(_jget "$OUT" 'd["tiktok_feed_status"]["probe_observations"]')"
assert_eq "status: TikTok reports effective DNS proof" "1" "$(_jget "$OUT" 'd["tiktok_feed_status"]["dns_override_applied"]')"
printf 'value=0' > "$T/body.txt"
RAW="$(_cgi POST /toggle/tiktok-feed "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
_jid="$(_jget "$OUT" 'd["job"]')"; JOB_IDS="$JOB_IDS $_jid"
_poll_job_ok "$_jid" "toggle tiktok-feed off"
assert_eq "TikTok feed toggle disable persists 0" "0" "$(grep -m1 '^Z2K_TIKTOK_FEED_ENABLED=' "$T/etc/config" | cut -d= -f2)"
RAW="$(_cgi GET /status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "status: TikTok diagnostics disappear when disabled" "null" "$(_jget "$OUT" 'd.get("tiktok_feed_status")')"
printf 'ip=not-an-ip' > "$T/body.txt"
RAW="$(_cgi POST /tiktok/select "" "$T/body.txt")"
assert_eq "TikTok selection rejects a non-IPv4 value" "Status: 400 Bad Request" "$(printf '%s\n' "$RAW" | _cgi_status)"
RAW="$(_cgi POST /tiktok/probe-all)"
assert_eq "TikTok candidate probing requires the feature to be enabled" "Status: 409 Conflict" "$(printf '%s\n' "$RAW" | _cgi_status)"
RAW="$(_cgi POST /tiktok/auto)"
assert_eq "TikTok auto mode action requires the feature to be enabled" "Status: 409 Conflict" "$(printf '%s\n' "$RAW" | _cgi_status)"
printf 'value=0' > "$T/body.txt"
RAW="$(_cgi POST /toggle/stats "" "$T/body.txt")"
assert_eq "retired stats toggle route returns 404" "Status: 404 Not Found" "$(printf '%s\n' "$RAW" | _cgi_status)"
printf 'value=0' > "$T/body.txt"
RAW="$(_cgi POST /toggle/auto-update "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "quick auto-update toggle completes synchronously without a job modal" "null" "$(_jget "$OUT" 'd.get("job")')"
assert_eq "quick auto-update toggle persists its value" "0" "$(grep -m1 '^Z2K_AUTO_UPDATE_ENABLED=' "$T/etc/config" | cut -d= -f2)"

# Service controls: job + эффект через mock-init.
for _svc in start stop restart; do
    : > "$T/init.log"
    RAW="$(_cgi POST /service/$_svc)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
    assert_eq "service $_svc: job выдан" "true" "$(_jget "$OUT" 'd["ok"]')"
    _jid="$(_jget "$OUT" 'd["job"]')"
    JOB_IDS="$JOB_IDS $_jid"
    _poll_job_ok "$_jid" "service $_svc"
    assert_contains "service $_svc: init $_svc" "$T/init.log" "$_svc"
done

# Tunnel enable: job rc 0 (disable покрыт выше).
RAW="$(_cgi POST /tunnel/enable)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "tunnel enable: job выдан" "true" "$(_jget "$OUT" 'd["ok"]')"
_jid="$(_jget "$OUT" 'd["job"]')"
JOB_IDS="$JOB_IDS $_jid"
_poll_job_ok "$_jid" "tunnel enable"

# Strategy pick: плохой домен — 400 сразу; хороший — job с быстрым
# контролируемым отказом (rc 3: нет модуля замера в fixture).
printf 'domain=bad!host&mode=tcp13' > "$T/body.txt"
RAW="$(_cgi POST /strategy/pick "" "$T/body.txt")"
assert_eq "pick bad domain: 400" "Status: 400 Bad Request" "$(printf '%s\n' "$RAW" | _cgi_status)"
printf 'domain=example.com&mode=tcp13' > "$T/body.txt"
RAW="$(_cgi POST /strategy/pick "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "pick: job выдан" "true" "$(_jget "$OUT" 'd["ok"]')"
_jid="$(_jget "$OUT" 'd["job"]')"
JOB_IDS="$JOB_IDS $_jid"
_jo="$(_poll_job "$_jid")" || _t_bad "pick: job не завершился"
assert_eq "pick: job done" "true" "$(_jget "$_jo" 'd["done"]')"
if [ "$(_jget "$_jo" 'd["exit"]')" = "0" ]; then
    _t_bad "pick: job rc 0 без модуля замера"
else
    _t_ok
fi

# DNS: own сохраняется в fixture; check — job с быстрым отказом (нет скрипта).
printf 'my-own\n8.8.8.8' > "$T/body.txt"
RAW="$(_cgi POST /dns/own "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "dns own: saved" "8.8.8.8" "$(cat "$T/etc/user-lists/dns-check.txt" 2>/dev/null | head -1)"
RAW="$(_cgi POST /dns/check)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "dns check: job выдан" "true" "$(_jget "$OUT" 'd["ok"]')"
_jid="$(_jget "$OUT" 'd["job"]')"
JOB_IDS="$JOB_IDS $_jid"
_jo="$(_poll_job "$_jid")" || _t_bad "dns check: job не завершился"
assert_eq "dns check: job done" "true" "$(_jget "$_jo" 'd["done"]')"

RAW="$(_cgi POST /stats/ack)"
assert_eq "retired stats acknowledgement route returns 404" "Status: 404 Not Found" "$(printf '%s\n' "$RAW" | _cgi_status)"

# The clean OpenWrt payload has only the canonical Discord list.  The panel's
# duplicate-domain check must inspect that effective source, not require the
# Keenetic compatibility mirror TCP_Discord.txt.
mkdir -p "$T/zapret2/extra_strats/TCP/RKN"
printf 'discord.com\n' > "$T/zapret2/extra_strats/TCP/RKN/Discord.txt"
rm -f "$T/zapret2/extra_strats/TCP_Discord.txt"
printf 'domain=discord.com' > "$T/body.txt"
RAW="$(_cgi POST /extra-domains/add "" "$T/body.txt")"
assert_eq "extra-domains canonical Discord: 400" "Status: 400 Bad Request" \
    "$(printf '%s\n' "$RAW" | _cgi_status)"
OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
printf '%s\n' "$OUT" > "$T/canonical-discord-response"
assert_contains "extra-domains canonical Discord: named source" \
    "$T/canonical-discord-response" "Discord"

# AutoHostList has two intentionally different files on OpenWrt:
#   state/autohostlist-domains.txt — persistent discovered-domain ledger shown
#   by the panel and used for duplicate detection;
#   state/zapret-hosts-auto.txt — live --hostlist-auto file owned by nfqws2.
# The payload lists/autohostlist-domains.txt must not be consulted here.
mkdir -p "$T/root/lists" "$T/etc/state"
printf 'found-by-autohostlist.example\n' > "$T/etc/state/autohostlist-domains.txt"
printf 'engine-only.example\n' > "$T/etc/state/zapret-hosts-auto.txt"
printf 'payload-only.example\n' > "$T/root/lists/autohostlist-domains.txt"
OUT="$(_mg "autohostlist effective state" /autohostlist-domains)"
printf '%s\n' "$OUT" > "$T/autohostlist-effective-response"
assert_contains "autohostlist state survives a new CGI process" \
    "$T/autohostlist-effective-response" "found-by-autohostlist.example"
printf 'domain=found-by-autohostlist.example' > "$T/body.txt"
RAW="$(_cgi POST /extra-domains/add "" "$T/body.txt")"
assert_eq "extra-domains effective autohostlist: 400" \
    "Status: 400 Bad Request" "$(printf '%s\n' "$RAW" | _cgi_status)"
OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
printf '%s\n' "$OUT" > "$T/autohostlist-duplicate-response"
assert_contains "extra-domains effective autohostlist: named source" \
    "$T/autohostlist-duplicate-response" "автохостлист"

for _ah_free in engine-only.example payload-only.example absent.example; do
    printf 'domain=%s' "$_ah_free" > "$T/body.txt"
    RAW="$(_cgi POST /extra-domains/add "" "$T/body.txt")"
    assert_eq "extra-domains not duplicate: $_ah_free" \
        "Status: 200 OK" "$(printf '%s\n' "$RAW" | _cgi_status)"
    grep -qxF "$_ah_free" "$T/etc/user-lists/extra-domains.txt" \
        && _t_ok || _t_bad "домен $_ah_free ошибочно не сохранён в user list"
    RAW="$(_cgi POST /extra-domains/delete "" "$T/body.txt")"
    assert_eq "extra-domains cleanup: $_ah_free" \
        "Status: 200 OK" "$(printf '%s\n' "$RAW" | _cgi_status)"
done

# A second read after the mutations models reboot/update CGI re-entry: the
# persistent ledger remains visible, while the engine-only file is still not a
# duplicate source.
OUT="$(_mg "autohostlist persistent re-read" /autohostlist-domains)"
printf '%s\n' "$OUT" > "$T/autohostlist-reread-response"
assert_contains "autohostlist persistent ledger" \
    "$T/autohostlist-reread-response" "found-by-autohostlist.example"

# WARP install/remove — через стаб (сеть не трогаем); reregister — без
# device-файла быстрый rc 0 по коду («и так отсутствует»).
cat > "$T/warp-stub.sh" <<EOF
#!/bin/sh
echo "warp-stub:\$*" >> "$T/warp-stub.log"
case "\$1" in
    status) echo 'installed=1 enabled=0 ready=0 transport= endpoint= iface= addr= entries=0 devices=1 error= mem=0 wdtt=0' ;;
    ipset) [ ! -f "$T/fail-warp-ipset" ] ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$T/warp-stub.sh"
export WARP_SCRIPT="$T/warp-stub.sh"
: > "$T/warp-stub.log"
for _wa in install remove; do
    RAW="$(_cgi POST /warp/$_wa)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
    assert_eq "warp $_wa: job выдан" "true" "$(_jget "$OUT" 'd["ok"]')"
    _jid="$(_jget "$OUT" 'd["job"]')"
    JOB_IDS="$JOB_IDS $_jid"
    _poll_job_ok "$_jid" "warp $_wa"
done
assert_contains "warp: стаб вызывался" "$T/warp-stub.log" "warp-stub:install"
mv "$T/etc/state/warp/device.json" "$T/device.json.bak"
RAW="$(_cgi POST /warp/reregister)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "warp reregister: job выдан" "true" "$(_jget "$OUT" 'd["ok"]')"
_jid="$(_jget "$OUT" 'd["job"]')"
JOB_IDS="$JOB_IDS $_jid"
_poll_job_ok "$_jid" "warp reregister без записи"
mv "$T/device.json.bak" "$T/etc/state/warp/device.json"

# Device selection uses the real API/actions path. Its live adapter call must
# request rule reconciliation, and an adapter failure must reach the API.
printf 'GAME_WARP_ENABLED=1\nENABLED=1\n' > "$T/etc/config"
printf 'mac=aa:bb:cc:dd:ee:ff&value=1' > "$T/body.txt"
RAW="$(_cgi POST /warp/devices/toggle "" "$T/body.txt")"
assert_eq "warp device toggle: successful apply is 200" "Status: 200 OK" "$(printf '%s\n' "$RAW" | _cgi_status)"
assert_contains "warp device toggle: asks adapter for canonical rule reconciliation" "$T/warp-stub.log" \
    "warp-stub:ipset --reconcile-rules"

touch "$T/fail-warp-ipset"
cp "$T/etc/user-lists/warp/devices.txt" "$T/devices-before-failed-toggle"
printf 'mac=aa:bb:cc:dd:ee:ff&value=0' > "$T/body.txt"
RAW="$(_cgi POST /warp/devices/toggle "" "$T/body.txt")"
assert_eq "warp device toggle: adapter failure is not reported as success" "Status: 400 Bad Request" "$(printf '%s\n' "$RAW" | _cgi_status)"
assert_eq "warp device toggle: failed apply restores selection" "0" "$(cmp -s "$T/etc/user-lists/warp/devices.txt" "$T/devices-before-failed-toggle"; echo $?)"
printf '192.168.1.111\n' > "$T/body.txt"
RAW="$(_cgi POST /warp/devices/save "" "$T/body.txt")"
assert_eq "warp device save: apply failure is not reported as success" "Status: 400 Bad Request" "$(printf '%s\n' "$RAW" | _cgi_status)"
assert_eq "warp device save: failed apply restores selection" "0" "$(cmp -s "$T/etc/user-lists/warp/devices.txt" "$T/devices-before-failed-toggle"; echo $?)"

# WDTT matches upstream: it is off by default, persists through the ordinary
# config path, and applies OpenWrt nft rules transactionally while WARP is on.
rm -f "$T/fail-warp-ipset"
RAW="$(_cgi GET /warp/status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "warp status exposes WDTT default off" "false" "$(_jget "$OUT" 'd["wdtt_enabled"]')"
_warp_config_enabled=$(grep -m1 '^GAME_WARP_ENABLED=' "$T/etc/config" | cut -d= -f2)
assert_eq "warp status keeps enabled as its own config value" "$_warp_config_enabled" "$(_jget "$OUT" 'd["enabled"]')"
printf 'value=1' > "$T/body.txt"
RAW="$(_cgi POST /warp/wdtt "" "$T/body.txt")"
assert_eq "warp WDTT enable is accepted" "Status: 200 OK" "$(printf '%s\n' "$RAW" | _cgi_status)"
assert_eq "warp WDTT flag is persisted" "1" "$(grep -m1 '^Z2K_WARP_WDTT=' "$T/etc/config" | cut -d= -f2)"
assert_contains "warp WDTT enable reconciles OpenWrt rules" "$T/warp-stub.log" \
    "warp-stub:ipset --reconcile-rules"
RAW="$(_cgi GET /warp/status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "warp status reports WDTT enabled" "true" "$(_jget "$OUT" 'd["wdtt_enabled"]')"
touch "$T/fail-warp-ipset"
_wdtt_apply_before=$(grep -c '^warp-stub:ipset --reconcile-rules$' "$T/warp-stub.log")
printf 'value=0' > "$T/body.txt"
RAW="$(_cgi POST /warp/wdtt "" "$T/body.txt")"
assert_eq "warp WDTT apply failure reaches API" "Status: 500 Internal Server Error" "$(printf '%s\n' "$RAW" | _cgi_status)"
assert_eq "warp WDTT apply failure restores prior flag" "1" "$(grep -m1 '^Z2K_WARP_WDTT=' "$T/etc/config" | cut -d= -f2)"
_wdtt_apply_after=$(grep -c '^warp-stub:ipset --reconcile-rules$' "$T/warp-stub.log")
assert_eq "warp WDTT apply failure attempts rollback reconciliation" "2" "$((_wdtt_apply_after - _wdtt_apply_before))"
rm -f "$T/fail-warp-ipset"
printf 'value=maybe' > "$T/body.txt"
RAW="$(_cgi POST /warp/wdtt "" "$T/body.txt")"
assert_eq "warp WDTT rejects invalid state" "Status: 400 Bad Request" "$(printf '%s\n' "$RAW" | _cgi_status)"
rm -f "$T/fail-warp-ipset"
unset WARP_SCRIPT

# Остальные мутации: controlled-контракты без побочных эффектов хоста.
printf 'name=x&value=1' > "$T/body.txt"
RAW="$(_cgi POST /warp/games/toggle "" "$T/body.txt")"
assert_eq "games toggle nosuch: 400" "Status: 400 Bad Request" "$(printf '%s\n' "$RAW" | _cgi_status)"
printf 'name=nosuch' > "$T/body.txt"
RAW="$(_cgi POST /warp/list/delete "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "warp list delete nosuch: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
printf 'key=rkn_tcp&host=h.example&strategy=2&mode=auto' > "$T/body.txt"
RAW="$(_cgi POST /state/set "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "state set: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
printf 'key=rkn_tcp&host=h.example' > "$T/body.txt"
RAW="$(_cgi POST /state/delete "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "state delete: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
RAW="$(_cgi POST /state/clear)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "state clear: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
printf 'domain=gone.example' > "$T/body.txt"
RAW="$(_cgi POST /whitelist/delete "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "whitelist delete missing: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
printf 'domain=foo.example' > "$T/body.txt"
RAW="$(_cgi POST /extra-domains/add "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "extra-domains add: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
RAW="$(_cgi POST /extra-domains/delete "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "extra-domains delete: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
RAW="$(_cgi POST /autohostlist-domains/delete "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "autohostlist delete: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
printf -- '--filter-tcp=80\n' > "$T/body.txt"
RAW="$(_cgi POST /strategy/pool/validate "pool=rkn_tcp" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "pool validate: движок fixture валидирует" "true" "$(_jget "$OUT" 'd["valid"]')"
printf 'value=1' > "$T/body.txt"
RAW="$(_cgi POST /debug "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "debug set: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
printf 'value=0' > "$T/body.txt"
RAW="$(_cgi POST /debug "" "$T/body.txt")" >/dev/null
RAW="$(_cgi POST /auth/challenge)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "auth challenge без пароля: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
RAW="$(_cgi POST /auth/logout)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "auth logout: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
printf 'domain=example.com' > "$T/body.txt"
Z2K_DETECT_BIN="$T/missing-detector"; export Z2K_DETECT_BIN
RAW="$(_cgi POST /diag/probe "" "$T/body.txt")"
assert_eq "diag probe без модуля: 503" "Status: 503 Service Unavailable" "$(printf '%s\n' "$RAW" | _cgi_status)"
unset Z2K_DETECT_BIN
RAW="$(_cgi POST /tcp16/probe)"
assert_eq "tcp16 probe uses installed probe" "Status: 200 OK" "$(printf '%s\n' "$RAW" | _cgi_status)"
_i=0
while [ "$_i" -lt 20 ] && [ ! -f "$T/tcp16-probe-ran" ]; do sleep 0.1; _i=$((_i + 1)); done
[ -f "$T/tcp16-probe-ran" ] && _t_ok || _t_bad "tcp16 WebPanel action reaches the installed probe"

# Positive uninstall API path: keep the real CGI and async helper, replace only
# the fixture worker body so this test proves the accepted request starts the
# same canonical script entry with its server-side confirmation token.
rm -f "$T/root/platform/openwrt/uninstall.sh"
cat > "$T/root/platform/openwrt/uninstall.sh" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--worker" ]; then
    printf '%s|%s\n' "${Z2K_UNINSTALL_CONFIRMED:-}" "$1" > "$Z2K_UNINSTALL_WORKER_MARKER"
    exit 0
fi
. "$Z2K_UNINSTALL_LIBRARY"
EOF
chmod +x "$T/root/platform/openwrt/uninstall.sh"
export Z2K_UNINSTALL_LIBRARY="$REPO/platform/openwrt/uninstall.sh"
export Z2K_UNINSTALL_WORKER_MARKER="$T/uninstall-worker-ran"
printf 'confirm=УДАЛИТЬ' > "$T/body.txt"
RAW="$(_cgi POST /uninstall "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "uninstall: confirmed request launches job" "Status: 200 OK" "$(printf '%s\n' "$RAW" | _cgi_status)"
_jid="$(_jget "$OUT" 'd["job"]')"
assert_eq "uninstall: job id is returned" "true" "$([ -n "$_jid" ] && echo true || echo false)"
JOB_IDS="$JOB_IDS $_jid"
_jo="$(_poll_job "$_jid")" || _t_bad "uninstall: async job reaches completion"
assert_file "uninstall: canonical worker stores its exit code in the configured job directory" \
    "$Z2K_JOB_DIR/z2k-job-$_jid.exit"
assert_eq "uninstall: canonical worker succeeds" "0" "$(_jget "$_jo" 'd["exit"]')"
assert_contains "uninstall: same worker receives explicit confirmation" \
    "$Z2K_UNINSTALL_WORKER_MARKER" '1|--worker'

# --- FRESH INSTALL (п.8): ни конфига, ни списков, ни state, ни WARP-файлов ---
# Панель обязана открываться и читать initial state; отсутствие optional
# state — не "panel unavailable". Отдельный минимальный fixture T2.
T2="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-wpfresh.XXXXXX")" || exit 1
trap 'for _j in $JOB_IDS; do rm -f "$Z2K_JOB_DIR/z2k-job-$_j.log" "$Z2K_JOB_DIR/z2k-job-$_j.pid" "$Z2K_JOB_DIR/z2k-job-$_j.exit"; done; rm -rf "$T" "$T2"' EXIT INT TERM
mkdir -p "$T2/bin" "$T2/root/platform/openwrt" "$T2/root/bin" "$T2/root/lib" \
         "$T2/etc" "$T2/tmp/z2k/runtime" "$T2/jobs"
for _f in paths.sh env.sh manifest.sh release_state.sh warp.sh tg.sh rt.sh firewall.sh customd.sh uci.sh schedule.sh uninstall.sh webpanel.sh offload-benchmark.sh offload-observe.sh panel.sh; do
    ln -s "$REPO/platform/openwrt/$_f" "$T2/root/platform/openwrt/$_f" 2>/dev/null
done
ln -s "$REPO/platform/openwrt/warp-proc.sh" "$T2/root/platform/openwrt/warp-proc.sh" 2>/dev/null
mkdir -p "$T2/cgi" "$T2/root/webpanel/cgi" "$T2/root/share"
cp "$REPO/webpanel/cgi/api.sh" "$REPO/webpanel/cgi/auth.sh" \
   "$REPO/webpanel/cgi/actions.sh" "$REPO/webpanel/cgi/platform.sh" "$T2/cgi/"
cp "$REPO/webpanel/cgi/actions.sh" "$REPO/webpanel/cgi/platform.sh" \
   "$REPO/webpanel/cgi/api.sh" "$T2/root/webpanel/cgi/"
mkdir -p "$T2/root/www"
cp "$REPO/webpanel/www/index.html" "$T2/root/www/index.html"
cp "$REPO/webpanel/lighttpd.conf" "$T2/root/webpanel/lighttpd.conf.in"
printf '#!/bin/sh\nsafe_config_read() { return 1; }\n' > "$T2/root/lib/utils.sh"
cat > "$T2/mock-init" <<EOF
#!/bin/sh
case "\$1" in
    running) exit 1 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$T2/mock-init"
cat > "$T2/bin/pidof" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T2/bin/pidof"
: > "$T2/leases"; : > "$T2/arp-empty"
_cgi2() { # тот же контракт, что _cgi, но на пустом T2 (Z2K_CONFIG нет!)
    _m="$1"; _p="$2"; _q="${3:-}"; _b="${4:-}"
    if [ -n "$_b" ]; then
        _cl=$(wc -c < "$_b" | tr -d ' ')
        env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="$_q" \
            HTTP_HOST="192.168.1.1" HTTP_X_Z2K_PANEL="1" CONTENT_LENGTH="$_cl" \
            Z2K_PLATFORM=openwrt Z2K_ROOT="$T2/root" Z2K_ETC="$T2/etc" Z2K_TMP="$T2/tmp" \
            Z2K_JOB_DIR="$T2/jobs" \
            Z2K_OW_TESTING=1 \
            Z2K_CONFIG="$T2/etc/config" Z2K_PROC_ROOT="$T2/proc" Z2K_INIT="$T2/mock-init" \
            Z2K_BIN="$T2/root/bin" INIT_SCRIPT="$T2/mock-init" ZAPRET2_DIR="$T2/zapret2" \
            WP_IP_BIN="$T2/bin/ip" WP_DHCP_LEASES="$T2/leases" WP_ARP_PATH="$T2/arp-empty" \
            PATH="$T2/bin:/usr/bin:/bin" \
            sh "$T2/cgi/api.sh" < "$_b" 2>"$T2/last.err"
    else
        env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="$_q" \
            HTTP_HOST="192.168.1.1" HTTP_X_Z2K_PANEL="1" CONTENT_LENGTH="0" \
            Z2K_PLATFORM=openwrt Z2K_ROOT="$T2/root" Z2K_ETC="$T2/etc" Z2K_TMP="$T2/tmp" \
            Z2K_JOB_DIR="$T2/jobs" \
            Z2K_OW_TESTING=1 \
            Z2K_CONFIG="$T2/etc/config" Z2K_PROC_ROOT="$T2/proc" Z2K_INIT="$T2/mock-init" \
            Z2K_BIN="$T2/root/bin" INIT_SCRIPT="$T2/mock-init" ZAPRET2_DIR="$T2/zapret2" \
            WP_IP_BIN="$T2/bin/ip" WP_DHCP_LEASES="$T2/leases" WP_ARP_PATH="$T2/arp-empty" \
            PATH="$T2/bin:/usr/bin:/bin" \
            sh "$T2/cgi/api.sh" < /dev/null 2>"$T2/last.err"
    fi
}
_fresh() { # $1 label $2 path [$3 query] — 200 + валидный JSON + пустой stderr
    _fr="$(_cgi2 GET "$2" "${3:-}")"
    assert_eq "fresh $1: HTTP 200" "Status: 200 OK" "$(printf '%s\n' "$_fr" | _cgi_status)"
    _fb="$(printf '%s\n' "$_fr" | _cgi_body)"
    assert_eq "fresh $1: валидный JSON" "1" "$(printf '%s' "$_fb" | python3 -c 'import json,sys; json.load(sys.stdin); print(1)' 2>/dev/null || echo 0)"
    if [ -s "$T2/last.err" ]; then
        _t_bad "fresh $1: stderr не пуст: $(head -c 200 "$T2/last.err" | tr '\n' '|')"
    else
        _t_ok
    fi
    printf '%s' "$_fb"
}
OUT="$(_fresh "status" /status)"
assert_eq "fresh status: installed false" "false" "$(_jget "$OUT" 'd["installed"]')"
assert_eq "fresh status: toggles defaults" "1" "$(_jget "$OUT" 'd["toggles"]["dynamic_ttl"]')"
assert_eq "fresh status: caps openwrt" "openwrt" "$(_jget "$OUT" 'd["platform"]')"
OUT="$(_fresh "toggles" /toggles)"
assert_eq "fresh toggles: retired stats fields are absent" "0" "$(printf '%s' "$OUT" | grep -Ec '"stats(_ack)?"' || true)"
OUT="$(_fresh "whitelist" /whitelist)"
assert_eq "fresh whitelist: пуст" "0" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["domains"]))' 2>/dev/null)"
OUT="$(_fresh "exclude" /exclude)"
assert_eq "fresh exclude: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
OUT="$(_fresh "extra-domains" /extra-domains)"
assert_eq "fresh extra-domains: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
OUT="$(_fresh "warp-status" /warp/status)"
assert_eq "fresh warp-status: installed false" "false" "$(_jget "$OUT" 'd["installed"]')"
assert_eq "fresh warp-status: WDTT defaults off" "false" "$(_jget "$OUT" 'd["wdtt_enabled"]')"
OUT="$(_fresh "warp-neighbors" /warp/neighbors)"
assert_eq "fresh neighbors: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
OUT="$(_fresh "state" /state)"
assert_eq "fresh state: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
OUT="$(_fresh "strategy-pools" /strategy/pools)"
assert_eq "fresh strategy-pools: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
OUT="$(_fresh "auth-state" /auth/state)"
assert_eq "fresh auth-state: required false" "false" "$(_jget "$OUT" 'd["required"]')"
OUT="$(_fresh "tcp16" /tcp16)"
assert_eq "fresh tcp16: ok" "true" "$(_jget "$OUT" 'd["ok"]')"

_t_done
