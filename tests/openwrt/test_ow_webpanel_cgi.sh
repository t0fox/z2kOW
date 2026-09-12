#!/bin/sh
# tests/openwrt/test_ow_webpanel_cgi.sh - Stage 6 Layer C: настоящий api.sh +
# actions.sh в OpenWrt sysroot (WP-сценарии). Моки: init/procd, pidof, ip,
# nft-заглушка, lighttpd не нужен. Только subprocess-границы настоящие.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-webpanel-cgi"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-wpc.XXXXXX")" || exit 1
trap 'rm -rf "$T"; for _j in $JOB_IDS; do rm -f "/tmp/z2k-job-$_j.log" "/tmp/z2k-job-$_j.pid" "/tmp/z2k-job-$_j.exit"; done' EXIT INT TERM
JOB_IDS=""

mkdir -p "$T/bin" "$T/root/platform/openwrt" "$T/root/bin" "$T/root/lib" \
         "$T/root/webpanel" "$T/etc/user-lists/warp" "$T/etc/state/warp" \
         "$T/etc/webpanel" "$T/tmp/z2k/runtime" "$T/proc/7777"
export PATH="$T/bin:/usr/bin:/bin"

# --- adapter farm (настоящие файлы слоя) ---
for _f in paths.sh env.sh warp.sh tg.sh rt.sh firewall.sh uci.sh schedule.sh uninstall.sh webpanel.sh; do
    ln -s "$REPO/platform/openwrt/$_f" "$T/root/platform/openwrt/$_f" 2>/dev/null
done
ln -s "$REPO/platform/openwrt/warp-proc.sh" "$T/root/platform/openwrt/warp-proc.sh" 2>/dev/null
# --- CGI: копии (как keenetic api_contract: проверяем именно эти файлы) ---
mkdir -p "$T/cgi"
cp "$REPO/webpanel/cgi/api.sh" "$REPO/webpanel/cgi/auth.sh" \
   "$REPO/webpanel/cgi/actions.sh" "$REPO/webpanel/cgi/platform.sh" "$T/cgi/"
# --- stub lib (генератор/утилиты — как keenetic-сьют; сам CGI настоящий) ---
# Стаб пишет многострочный NFQWS2_OPT: strategy_validate вырезает опции
# sed-диапазоном /^NFQWS2_OPT="/,/^"$/, однострочник дал бы пустой opt.
cat > "$T/root/lib/config_official.sh" <<'EOF'
#!/bin/sh
create_official_config() { printf 'NFQWS2_OPT="\n--filter-tcp=80 --dpi-desync=fake\n"\n' >> "$1"; echo "regen:$1" >> "${T_CGI_LOG:-/dev/null}"; return 0; }
EOF
cat > "$T/root/lib/utils.sh" <<'EOF'
#!/bin/sh
safe_config_read() { return 1; }
EOF
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
exit 0
EOF
chmod +x "$T/bin/nft"
# --- fixtures ---
printf 'GAME_WARP_ENABLED=0\nENABLED=1\n' > "$T/etc/config"
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
cat > "$T/root/bin/z2k-warpd" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/root/bin/z2k-warpd"
# --- mock zapret2 runtime для strategy dry-run (WP9): движок-mock всегда
# парсит успешно; lib-стабы те же, что выше (теневая сборка их симлинчит) ---
mkdir -p "$T/zapret2/lib" "$T/zapret2/nfq2"
cat > "$T/zapret2/lib/utils.sh" <<'EOF'
#!/bin/sh
safe_config_read() { return 1; }
EOF
cat > "$T/zapret2/lib/config_official.sh" <<'EOF'
#!/bin/sh
create_official_config() { printf 'NFQWS2_OPT="\n--filter-tcp=80 --dpi-desync=fake\n"\n' >> "$1"; return 0; }
EOF
cat > "$T/zapret2/nfq2/nfqws2" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/zapret2/nfq2/nfqws2"
export Z2K_PLATFORM=openwrt Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_CONFIG="$T/etc/config" Z2K_PROC_ROOT="$T/proc" Z2K_INIT="$T/mock-init"
export Z2K_BIN="$T/root/bin" INIT_SCRIPT="$T/mock-init" ZAPRET2_DIR="$T/zapret2"
export WP_IP_BIN="$T/bin/ip"
export WARP_STATUS="$T/tmp/z2k/warp-status.json"
export WP_DHCP_LEASES="$T/leases" WP_ARP_PATH="$T/arp-empty"

# --- CGI caller (как lighttpd; HTTP_X_Z2K_PANEL обязателен) ---
_cgi() { # <METHOD> <PATH> [QUERY] [bodyfile]
    _m="$1"; _p="$2"; _q="${3:-}"; _b="${4:-}"
    if [ -n "$_b" ]; then
        _cl=$(wc -c < "$_b" | tr -d ' ')
        env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="$_q" \
            HTTP_HOST="192.168.7.1" HTTP_X_Z2K_PANEL="1" CONTENT_LENGTH="$_cl" \
            sh "$T/cgi/api.sh" < "$_b" 2>/dev/null
    else
        env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="$_q" \
            HTTP_HOST="192.168.7.1" HTTP_X_Z2K_PANEL="1" CONTENT_LENGTH="0" \
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
        [ "$(_jget "$_jo" 'd["done"]')" = "true" ] && { printf '%s' "$_jo"; return 0; }
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
assert_eq "status: platform" "openwrt" "$(_jget "$OUT" 'd["platform"]')"
assert_eq "status: policy false" "false" "$(_jget "$OUT" 'd["capabilities"]["policy"]')"
assert_eq "status: ppe false" "false" "$(_jget "$OUT" 'd["capabilities"]["ppe"]')"
assert_eq "status: tcp16 false" "false" "$(_jget "$OUT" 'd["capabilities"]["tcp16"]')"
assert_eq "status: diag false" "false" "$(_jget "$OUT" 'd["capabilities"]["diag"]')"
assert_eq "status: warp true" "true" "$(_jget "$OUT" 'd["capabilities"]["warp"]')"
assert_eq "status: telegram true" "true" "$(_jget "$OUT" 'd["capabilities"]["telegram"]')"
assert_eq "status: uninstall false" "false" "$(_jget "$OUT" 'd["capabilities"]["uninstall"]')"
assert_eq "status: core running via init" "true" "$(_jget "$OUT" 'd["running"]')"

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

# --- update status с OpenWrt-канала (WP17) ---
cat > "$T/manifest.json" <<'EOF'
{"current":"p-84.7","platform":"openwrt","install_map":{},"files_sha256":{},"history":[]}
EOF
export AU_MANIFEST_CACHE="$T/manifest.json"
printf 'p-84.7\n' > "$T/etc/state/installed-tag"
export AU_TAG_FILE="$T/etc/state/installed-tag"
RAW="$(_cgi GET /update/status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "update: installed" "p-84.7" "$(_jget "$OUT" 'd["installed"]')"
assert_eq "update: available" "p-84.7" "$(_jget "$OUT" 'd["available"]')"

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
printf 'confirm=X' > "$T/body.txt"
RAW="$(_cgi POST /uninstall "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "uninstall: отказ без package manager" "false" "$(_jget "$OUT" 'd["ok"]')"

# --- customd toggle end-to-end (WP8): флаг + генератор + рестарт ---
printf 'value=1' > "$T/body.txt"
RAW="$(_cgi POST /toggle/customd "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "toggle: job выдан" "true" "$(_jget "$OUT" 'd["ok"]')"
_jid="$(_jget "$OUT" 'd["job"]')"
JOB_IDS="$JOB_IDS $_jid"
_jo="$(_poll_job "$_jid")" || _t_bad "toggle: job не завершился"
assert_eq "toggle: job done" "true" "$(_jget "$_jo" 'd["done"]')"
assert_eq "toggle: job rc 0" "0" "$(_jget "$_jo" 'd["exit"]')"
assert_eq "toggle: флаг в конфиге" "0" "$(grep -m1 '^DISABLE_CUSTOM=' "$T/etc/config" | cut -d= -f2)"

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
exit 0
EOF
chmod +x "$T/fake-apply"
export AU_SCRIPT="$T/fake-apply"
RAW="$(_cgi POST /update/apply)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "apply: job выдан" "true" "$(_jget "$OUT" 'd["ok"]')"
_jid="$(_jget "$OUT" 'd["job"]')"
JOB_IDS="$JOB_IDS $_jid"
_jo="$(_poll_job "$_jid")" || _t_bad "apply: job не завершился"
assert_contains "apply: updater вызван" "$T/apply.log" "apply-args:apply"
assert_contains "apply: manual флаг" "$T/apply.log" "manual=1"

_t_done
