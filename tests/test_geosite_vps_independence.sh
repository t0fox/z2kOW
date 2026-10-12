#!/bin/sh
# Проверка, что OpenWrt отключает Layer 0 VPS и в отдельном geosite fetch.
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '[FAIL] %s (ожидалось %s, получено %s)\n' "$1" "$2" "$3"; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/z2k-geosite-vps-free.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/bin" "$TMP/etag" "$TMP/tmp"

cat > "$TMP/bin/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CURL_LOG"
resolve=0 out= hdr= save= url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --resolve) resolve=1; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        -D) hdr="$2"; shift 2 ;;
        --etag-save) save="$2"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
# Прямой origin недоступен, первое зеркало отвечает 503, второе отдаёт список.
# В этом сценарии не допускается запрос с --resolve на старый VPS.
[ "$resolve" = 0 ] || { printf '000 0.000000'; exit 7; }
case "$url" in
    *ghproxy.net*) printf '503 0.010000'; exit 0 ;;
    *gh-proxy.com*) ;;
    *) printf '000 0.000000'; exit 7 ;;
esac
[ -z "$out" ] || printf 'проверенный список\n' > "$out"
[ -z "$hdr" ] || printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
[ -z "$save" ] || printf '"test-etag"' > "$save"
printf '200 0.020000'
STUB
chmod 0755 "$TMP/bin/curl"

awk '/^(fetch_to_tmp|z2k_uint|z2k_connfail)\(\) \{/,/^\}/' \
    "$ROOT/files/z2k-geosite.sh" > "$TMP/functions.sh"

result=$(env -i PATH="$TMP/bin:$Z2K_TEST_PATH" HOME="$TMP" \
    CURL_LOG="$TMP/curl.log" FUNCTIONS="$TMP/functions.sh" \
    ETAG_DIR="$TMP/etag" TMP_DIR="$TMP/tmp" \
    "$Z2K_TEST_SH" -c '
        . "$FUNCTIONS"
        RELEASE_BASE=https://github.com/t0fox/z2kOW/releases/latest/download
        Z2K_PLATFORM=openwrt
        Z2K_FETCH_DIRECT_FIRST=1
        Z2K_FETCH_VPS_OUT=1
        _z2k_vps_gh_resolve() { printf " --resolve github.com:443:203.0.113.9"; }
        log() { :; }
        if fetch_to_tmp openwrt-release-operations.md; then rc=0; else rc=$?; fi
        v=$(grep -c -- --resolve "$CURL_LOG" 2>/dev/null); [ -n "$v" ] || v=0
        d=$(grep -v -E -- "--resolve|ghproxy[.]net|gh-proxy[.]com" "$CURL_LOG" | wc -l | tr -d " "); [ -n "$d" ] || d=0
        m1=$(grep -c ghproxy.net "$CURL_LOG" 2>/dev/null); [ -n "$m1" ] || m1=0
        m2=$(grep -c gh-proxy.com "$CURL_LOG" 2>/dev/null); [ -n "$m2" ] || m2=0
        printf "rc=%s vps=%s direct=%s mirror1=%s mirror2=%s body=%s" "$rc" "$v" "$d" "$m1" "$m2" \
            "$(cat "$TMP_DIR/openwrt-release-operations.md" 2>/dev/null)"
    ')

case "$result" in
    'rc=0 vps=0 direct=1 mirror1=1 mirror2=1 body=проверенный список')
        ok "OpenWrt geosite использует прямой путь и проверяет независимые зеркала без VPS" ;;
    *)
        no "OpenWrt geosite отключает Layer 0 и переходит на зеркала" \
            'rc=0 vps=0 direct=1 mirror1=1 mirror2=1' "$result" ;;
esac

show_rc=0
env -i PATH="$TMP/bin:$Z2K_TEST_PATH" HOME="$TMP" \
    CURL_LOG="$TMP/show-curl.log" Z2K_PLATFORM=openwrt Z2K_FETCH_VPS_OUT=1 \
    ZAPRET2_DIR="$TMP/show-zapret" \
    RELEASE_BASE=https://github.com/t0fox/z2kOW/releases/latest/download \
    sh "$ROOT/files/z2k-geosite.sh" show openwrt-release-operations.md \
    > "$TMP/show.out" 2> "$TMP/show.err" || show_rc=$?
if [ "$show_rc" = 0 ] \
   && [ "$(cat "$TMP/show.out")" = "проверенный список" ] \
   && grep -q 'gh-proxy.com' "$TMP/show-curl.log" \
   && ! grep -q -- '--resolve' "$TMP/show-curl.log"; then
    ok "show печатает список через mirror после отказа origin без обращения к VPS"
else
    no "show поддерживает mirror fallback без VPS" \
        'rc=0 body=проверенный список mirror=gh-proxy.com vps=0' \
        "rc=$show_rc body=$(cat "$TMP/show.out" 2>/dev/null) calls=$(cat "$TMP/show-curl.log" 2>/dev/null)"
fi

# Keenetic сохраняет прежний порядок: прямой запрос, затем VPS; OpenWrt mirrors
# не должны появляться в общей функции для остальных платформ.
mkdir -p "$TMP/keenetic-bin"
mkdir -p "$TMP/keenetic-etag" "$TMP/keenetic-tmp"
cat > "$TMP/keenetic-bin/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CURL_LOG"
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --resolve) shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    *ghproxy.net*|*gh-proxy.com*) printf 'зеркала доступны только в OpenWrt\n'; exit 0 ;;
    *) printf '000 0.010000'; exit 7 ;;
esac
STUB
chmod 0755 "$TMP/keenetic-bin/curl"
keenetic_result=$(env -i PATH="$TMP/keenetic-bin:$Z2K_TEST_PATH" HOME="$TMP" \
    CURL_LOG="$TMP/keenetic-fetch.log" FUNCTIONS="$TMP/functions.sh" \
    ETAG_DIR="$TMP/keenetic-etag" TMP_DIR="$TMP/keenetic-tmp" \
    "$Z2K_TEST_SH" -c '
        . "$FUNCTIONS"
        RELEASE_BASE=https://github.com/t0fox/z2kOW/releases/latest/download
        Z2K_PLATFORM=keenetic
        Z2K_FETCH_DIRECT_FIRST=1
        _z2k_vps_gh_resolve() { printf " --resolve github.com:443:203.0.113.9"; }
        log() { :; }
        if fetch_to_tmp openwrt-release-operations.md; then rc=0; else rc=$?; fi
        v=$(grep -c -- --resolve "$CURL_LOG" 2>/dev/null); [ -n "$v" ] || v=0
        m=$(grep -Ec "ghproxy[.]net|gh-proxy[.]com" "$CURL_LOG" 2>/dev/null); [ -n "$m" ] || m=0
        printf "rc=%s vps=%s mirrors=%s" "$rc" "$v" "$m"
    ')
case "$keenetic_result" in
    'rc=1 vps=2 mirrors=0')
        ok "Keenetic geosite сохраняет VPS fallback без новых mirror путей" ;;
    *)
        no "Keenetic geosite не использует OpenWrt mirrors" \
            'rc=1 vps=2 mirrors=0' "$keenetic_result" ;;
esac

keenetic_show_rc=0
env -i PATH="$TMP/keenetic-bin:$Z2K_TEST_PATH" HOME="$TMP" \
    CURL_LOG="$TMP/keenetic-show-curl.log" Z2K_PLATFORM=keenetic \
    ZAPRET2_DIR="$TMP/keenetic-show-zapret" \
    RELEASE_BASE=https://github.com/t0fox/z2kOW/releases/latest/download \
    sh "$ROOT/files/z2k-geosite.sh" show openwrt-release-operations.md \
    > "$TMP/keenetic-show.out" 2> "$TMP/keenetic-show.err" || keenetic_show_rc=$?
if [ "$keenetic_show_rc" -ne 0 ] \
   && ! grep -Eq 'ghproxy[.]net|gh-proxy[.]com|--resolve' "$TMP/keenetic-show-curl.log"; then
    ok "Keenetic show сохраняет прямой запрос без новых transport слоёв"
else
    no "Keenetic show сохраняет прежний прямой transport" \
        'rc!=0 mirror=0 vps=0' \
        "rc=$keenetic_show_rc calls=$(cat "$TMP/keenetic-show-curl.log" 2>/dev/null)"
fi

printf '\ntest_geosite_vps_independence.sh: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
