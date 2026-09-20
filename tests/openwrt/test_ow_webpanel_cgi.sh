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
         "$T/root/webpanel/cgi" "$T/root/webpanel" "$T/etc/user-lists/warp" "$T/etc/state/warp" \
         "$T/etc/webpanel" "$T/tmp/z2k/runtime" "$T/proc/7777"
export PATH="$T/bin:/usr/bin:/bin"

# --- adapter farm (настоящие файлы слоя) ---
for _f in paths.sh env.sh warp.sh tg.sh rt.sh firewall.sh customd.sh uci.sh schedule.sh uninstall.sh webpanel.sh panel.sh; do
    ln -s "$REPO/platform/openwrt/$_f" "$T/root/platform/openwrt/$_f" 2>/dev/null
done
ln -s "$REPO/platform/openwrt/warp-proc.sh" "$T/root/platform/openwrt/warp-proc.sh" 2>/dev/null
# --- CGI: копии (как keenetic api_contract: проверяем именно эти файлы) ---
mkdir -p "$T/cgi"
cp "$REPO/webpanel/cgi/api.sh" "$REPO/webpanel/cgi/auth.sh" \
   "$REPO/webpanel/cgi/actions.sh" "$REPO/webpanel/cgi/platform.sh" "$T/cgi/"
cp "$REPO/webpanel/cgi/actions.sh" "$REPO/webpanel/cgi/platform.sh" "$T/root/webpanel/cgi/"
cp "$REPO/package/openwrt/PANEL_API" "$T/root/share.panel.api"
mkdir -p "$T/root/share"
mv "$T/root/share.panel.api" "$T/root/share/panel.api"
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
# Package/version provenance fixture.  The payload is already p-84.26 while
# the adapter packages are r28: the panel must report the payload truth and expose
# the package release separately instead of presenting the seed/tag mismatch
# as an installed upstream version.
cat > "$T/bin/apk" <<'EOF'
#!/bin/sh
case "$*" in
    *z2k-adapter*) echo 'z2k-adapter-0.1.0-r28 aarch64_cortex-a53 [installed]' ;;
    *z2k-webpanel*) echo 'z2k-webpanel-0.1.0-r28 aarch64_cortex-a53 [installed]' ;;
    *z2k-zapret2-runtime*) echo 'z2k-zapret2-runtime-1.0.5.1-r4 aarch64_cortex-a53 [installed]' ;;
esac
EOF
chmod +x "$T/bin/apk"
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
mkdir -p "$T/zapret2/lib" "$T/zapret2/nfq2" "$T/zapret2/init.d/openwrt" "$T/root/platform/openwrt/custom.d"
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
EOF
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
export Z2K_CONFIG="$T/etc/config" Z2K_PROC_ROOT="$T/proc" Z2K_INIT="$T/mock-init"
export Z2K_BIN="$T/root/bin" INIT_SCRIPT="$T/mock-init" ZAPRET2_DIR="$T/zapret2" \
       Z2K_ZAPRET2_RUNTIME="$T/zapret2"
export Z2K_APK_BIN="$T/bin/apk"
export Z2K_CRON_TAB="$T/etc/crontabs/root"
export WP_IP_BIN="$T/bin/ip"
export WARP_STATUS="$T/tmp/z2k/warp-status.json"
export WP_DHCP_LEASES="$T/leases" WP_ARP_PATH="$T/arp-empty"
export OW_TEST_ROOT="$T"

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
_status_json_ok=$(printf '%s\n' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin); print("true")' 2>/dev/null || printf 'false')
assert_eq "status: valid JSON with runtime probe" "true" "$_status_json_ok"
assert_eq "status: platform" "openwrt" "$(_jget "$OUT" 'd["platform"]')"
assert_eq "status: panel payload compatible" "true" "$(_jget "$OUT" 'd["payload_compatible"]')"
assert_eq "status: policy false" "false" "$(_jget "$OUT" 'd["capabilities"]["policy"]')"
assert_eq "status: ppe false" "false" "$(_jget "$OUT" 'd["capabilities"]["ppe"]')"
assert_eq "status: fastroute false" "false" "$(_jget "$OUT" 'd["capabilities"]["fastroute"]')"
assert_eq "status: fastroute backend" "Программный fastpath недоступен на OpenWrt: backend не обнаружен." "$(_jget "$OUT" 'd["toggles"]["fastroute_status"]')"
assert_eq "status: stock offload capability" "true" "$(_jget "$OUT" 'd["capabilities"]["offload"]')"
assert_eq "status: stock offload mode" "none" "$(_jget "$OUT" 'd["toggles"]["flowoffload"]')"
printf '%s\n' "$OUT" > "$T/status-output"
assert_contains "status: offload facts stay explicit" "$T/status-output" "flowtable=absent"
assert_contains "status: packet proof stays unknown" "$T/status-output" "packet_visibility=unknown"
assert_eq "status: tcp16 false" "false" "$(_jget "$OUT" 'd["capabilities"]["tcp16"]')"
assert_eq "status: diag false" "false" "$(_jget "$OUT" 'd["capabilities"]["diag"]')"
assert_eq "status: customd true" "true" "$(_jget "$OUT" 'd["capabilities"]["customd"]')"
assert_eq "status: warp true" "true" "$(_jget "$OUT" 'd["capabilities"]["warp"]')"
assert_eq "status: telegram true" "true" "$(_jget "$OUT" 'd["capabilities"]["telegram"]')"
assert_eq "status: uninstall false" "false" "$(_jget "$OUT" 'd["capabilities"]["uninstall"]')"
assert_eq "status: core running via init" "true" "$(_jget "$OUT" 'd["running"]')"

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
{"current":"p-84.26","platform":"openwrt","install_map":{},"files_sha256":{},"history":[]}
EOF
export AU_MANIFEST_CACHE="$T/manifest.json"
mkdir -p "$T/root/share"
printf 'platform=openwrt\ntag=p-84.26\nref=f161e1d\n' > "$T/root/share/seed.meta"
printf 'platform=openwrt\ntag=p-84.26\nref=f161e1d\n' > "$T/root/share/payload.meta"
printf 'p-84.23\n' > "$T/etc/state/installed-tag"
export AU_TAG_FILE="$T/etc/state/installed-tag"
RAW="$(_cgi GET /update/status)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "update: installed payload truth" "p-84.26" "$(_jget "$OUT" 'd["installed"]')"
assert_eq "update: payload" "p-84.26" "$(_jget "$OUT" 'd["payload"]')"
assert_eq "update: seed" "p-84.26" "$(_jget "$OUT" 'd["seed"]')"
assert_eq "update: adapter release stays explicit" "z2k-adapter-0.1.0-r28" "$(_jget "$OUT" 'd["adapter_package"]')"
assert_eq "update: webpanel release stays explicit" "z2k-webpanel-0.1.0-r28" "$(_jget "$OUT" 'd["webpanel_package"]')"
assert_eq "update: runtime release stays explicit" "z2k-zapret2-runtime-1.0.5.1-r4" "$(_jget "$OUT" 'd["runtime_package"]')"
assert_eq "update: available" "p-84.26" "$(_jget "$OUT" 'd["available"]')"

# /update/history is bound to the OpenWrt channel.  A payload manifest may be
# used as the cold-cache fallback, but a similarly present Keenetic /opt
# manifest must never become the source.
cat > "$T/root/UPDATES.json" <<'EOF'
{
  "current": "ow-payload",
  "history": [
    {"v": "ow-payload", "type": "patch", "ts": "2026-09-16T01:00:00Z", "desc": "openwrt"}
  ]
}
EOF
cat > "$T/manifest.json" <<'EOF'
{
  "current": "ow-cache",
  "history": [
    {"v": "ow-cache-1", "type": "patch", "ts": "2026-09-16T02:00:00Z", "desc": "cache"},
    {"v": "ow-cache-2", "type": "patch", "ts": "2026-09-16T03:00:00Z", "desc": "cache-new"}
  ]
}
EOF
RAW="$(_cgi GET /update/history "offset=0&limit=1")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "history: cache newest first" "ow-cache-2" "$(_jget "$OUT" 'd["history"][0]["v"]')"
rm -f "$T/manifest.json"
RAW="$(_cgi GET /update/history "offset=0&limit=1")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "history: payload fallback" "ow-payload" "$(_jget "$OUT" 'd["history"][0]["v"]')"
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
assert_eq "uninstall: отказ без package manager" "false" "$(_jget "$OUT" 'd["ok"]')"

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
assert_eq "toggles: stats_ack default 1" "1" "$(_jget "$OUT" 'd["stats_ack"]')"
assert_eq "toggles: game_warp из конфига" "0" "$(_jget "$OUT" 'd["game_warp"]')"
printf 'GAME_WARP_ENABLED=0\nENABLED=1\nZ2K_STATS_ACK=0\n' > "$T/etc/config"
OUT="$(_mg "toggles ack=0" /toggles)"
assert_eq "toggles: stats_ack=0 доезжает (telemetry)" "0" "$(_jget "$OUT" 'd["stats_ack"]')"
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

# POST toggles: каждый job доходит до done/rc 0, флаг — в конфиге.
for _tg in "dynamic-ttl:Z2K_DYNAMIC_TTL:1" "stats:Z2K_STATS:1" "auto-update:Z2K_AUTO_UPDATE_ENABLED:1" "autohostlist:Z2K_AUTOHOSTLIST:1"; do
    _tn="${_tg%%:*}"; _rest="${_tg#*:}"; _tk="${_rest%%:*}"; _tv="${_rest##*:}"
    printf 'value=%s' "$_tv" > "$T/body.txt"
    RAW="$(_cgi POST /toggle/$_tn "" "$T/body.txt")"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
    assert_eq "toggle $_tn: job выдан" "true" "$(_jget "$OUT" 'd["ok"]')"
    _jid="$(_jget "$OUT" 'd["job"]')"
    JOB_IDS="$JOB_IDS $_jid"
    _poll_job_ok "$_jid" "toggle $_tn"
    assert_eq "toggle $_tn: флаг $_tk=$_tv" "$_tv" "$(grep -m1 "^$_tk=" "$T/etc/config" | cut -d= -f2)"
done
printf 'value=9' > "$T/body.txt"
RAW="$(_cgi POST /toggle/stats "" "$T/body.txt")"
assert_eq "toggle bad value: 400" "Status: 400 Bad Request" "$(printf '%s\n' "$RAW" | _cgi_status)"

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

# Stats ack: флаг в конфиге.
RAW="$(_cgi POST /stats/ack)"; OUT="$(printf '%s\n' "$RAW" | _cgi_body)"
assert_eq "stats ack: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
assert_eq "stats ack: флаг 1" "1" "$(grep -m1 '^Z2K_STATS_ACK=' "$T/etc/config" | cut -d= -f2)"

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
assert_contains "autohostlist state survives a new CGI process" \
    "$T/etc/state/autohostlist-domains.txt" "found-by-autohostlist.example"
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
assert_contains "autohostlist persistent ledger" \
    "$T/etc/state/autohostlist-domains.txt" "found-by-autohostlist.example"

# WARP install/remove — через стаб (сеть не трогаем); reregister — без
# device-файла быстрый rc 0 по коду («и так отсутствует»).
cat > "$T/warp-stub.sh" <<EOF
#!/bin/sh
echo "warp-stub:\$*" >> "$T/warp-stub.log"
case "\$1" in
    status) echo 'installed=1 enabled=0 ready=0 transport= endpoint= iface= addr= entries=0 devices=1 error= mem=0' ;;
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
RAW="$(_cgi POST /diag/probe "" "$T/body.txt")"
assert_eq "diag probe без модуля: 503" "Status: 503 Service Unavailable" "$(printf '%s\n' "$RAW" | _cgi_status)"
RAW="$(_cgi POST /tcp16/probe)"
assert_eq "tcp16 probe без пробы: 503" "Status: 503 Service Unavailable" "$(printf '%s\n' "$RAW" | _cgi_status)"

# --- FRESH INSTALL (п.8): ни конфига, ни списков, ни state, ни WARP-файлов ---
# Панель обязана открываться и читать initial state; отсутствие optional
# state — не "panel unavailable". Отдельный минимальный fixture T2.
T2="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-wpfresh.XXXXXX")" || exit 1
trap 'rm -rf "$T" "$T2"; for _j in $JOB_IDS; do rm -f "/tmp/z2k-job-$_j.log" "/tmp/z2k-job-$_j.pid" "/tmp/z2k-job-$_j.exit"; done' EXIT INT TERM
mkdir -p "$T2/bin" "$T2/root/platform/openwrt" "$T2/root/bin" "$T2/root/lib" \
         "$T2/etc" "$T2/tmp/z2k/runtime"
for _f in paths.sh env.sh warp.sh tg.sh rt.sh firewall.sh customd.sh uci.sh schedule.sh uninstall.sh webpanel.sh panel.sh; do
    ln -s "$REPO/platform/openwrt/$_f" "$T2/root/platform/openwrt/$_f" 2>/dev/null
done
ln -s "$REPO/platform/openwrt/warp-proc.sh" "$T2/root/platform/openwrt/warp-proc.sh" 2>/dev/null
mkdir -p "$T2/cgi" "$T2/root/webpanel/cgi" "$T2/root/share"
cp "$REPO/webpanel/cgi/api.sh" "$REPO/webpanel/cgi/auth.sh" \
   "$REPO/webpanel/cgi/actions.sh" "$REPO/webpanel/cgi/platform.sh" "$T2/cgi/"
cp "$REPO/webpanel/cgi/actions.sh" "$REPO/webpanel/cgi/platform.sh" "$T2/root/webpanel/cgi/"
cp "$REPO/package/openwrt/PANEL_API" "$T2/root/share/panel.api"
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
            Z2K_CONFIG="$T2/etc/config" Z2K_PROC_ROOT="$T2/proc" Z2K_INIT="$T2/mock-init" \
            Z2K_BIN="$T2/root/bin" INIT_SCRIPT="$T2/mock-init" ZAPRET2_DIR="$T2/zapret2" \
            WP_IP_BIN="$T2/bin/ip" WP_DHCP_LEASES="$T2/leases" WP_ARP_PATH="$T2/arp-empty" \
            PATH="$T2/bin:/usr/bin:/bin" \
            sh "$T2/cgi/api.sh" < "$_b" 2>"$T2/last.err"
    else
        env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="$_q" \
            HTTP_HOST="192.168.1.1" HTTP_X_Z2K_PANEL="1" CONTENT_LENGTH="0" \
            Z2K_PLATFORM=openwrt Z2K_ROOT="$T2/root" Z2K_ETC="$T2/etc" Z2K_TMP="$T2/tmp" \
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
assert_eq "fresh toggles: stats_ack default" "1" "$(_jget "$OUT" 'd["stats_ack"]')"
OUT="$(_fresh "whitelist" /whitelist)"
assert_eq "fresh whitelist: пуст" "0" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["domains"]))' 2>/dev/null)"
OUT="$(_fresh "exclude" /exclude)"
assert_eq "fresh exclude: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
OUT="$(_fresh "extra-domains" /extra-domains)"
assert_eq "fresh extra-domains: ok" "true" "$(_jget "$OUT" 'd["ok"]')"
OUT="$(_fresh "warp-status" /warp/status)"
assert_eq "fresh warp-status: installed false" "false" "$(_jget "$OUT" 'd["installed"]')"
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
