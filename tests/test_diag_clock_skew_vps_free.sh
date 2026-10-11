#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/z2k-diag-clock.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

awk '/^clock_skew_vs_relay\(\) \{/,/^\}/' \
    "$ROOT/files/z2k-diag.sh" > "$TMP/function.sh"
printf 'DISTRIB_ARCH=x86_64\n' > "$TMP/openwrt_release"

awk '/^ping_vps_rtt\(\) \{/,/^\}/' \
    "$ROOT/files/z2k-diag.sh" > "$TMP/ping-vps-function.sh"
result=$(FUNCTION_FILE="$TMP/ping-vps-function.sh" PING_LOG="$TMP/openwrt-ping.log" sh -c '
    set -u
    . "$FUNCTION_FILE"
    Z2K_PLATFORM=openwrt
    VPS_IP=213.176.74.63
    ping() { printf "called\n" >> "$PING_LOG"; return 0; }
    ping_vps_rtt
') || result=ERROR
case "$result" in "-- --") ok "OpenWrt пропускает ping собственного VPS" ;; *) bad "OpenWrt VPS ping result: $result" ;; esac
[ ! -s "$TMP/openwrt-ping.log" ] && ok "OpenWrt не отправляет ICMP на VPS" || bad "OpenWrt вызвал ping VPS"

result=$(FUNCTION_FILE="$TMP/function.sh" OPENWRT_FILE="$TMP/openwrt_release" \
    CURL_LOG="$TMP/openwrt-curl.log" sh -c '
        . "$FUNCTION_FILE"
        curl() {
            printf "%s\n" "$*" >> "$CURL_LOG"
            printf "HTTP/1.1 200 OK\r\nDate: Wed, 21 Oct 2015 07:28:00 GMT\r\n\r\n"
        }
        date() { printf "1445412480\n"; }
        Z2K_DIAG_OPENWRT_RELEASE_FILE="$OPENWRT_FILE"
        clock_skew_vs_relay
    ')
case "$result" in 0) ok "OpenWrt получает прямой HTTPS Date и вычисляет расхождение" ;; *) bad "OpenWrt clock skew result: $result" ;; esac
if grep -q -- --resolve "$TMP/openwrt-curl.log"; then bad "OpenWrt не должен закреплять старый VPS endpoint"; else ok "OpenWrt не использует --resolve старого VPS"; fi
if grep -qF 'https://www.cloudflare.com/' "$TMP/openwrt-curl.log"; then ok "OpenWrt использует независимый HTTPS origin"; else bad "нет прямого HTTPS origin"; fi

result=$(FUNCTION_FILE="$TMP/function.sh" CURL_LOG="$TMP/keenetic-curl.log" TMP_DIR="$TMP" \
    VPS_IP=198.51.100.25 sh -c '
        . "$FUNCTION_FILE"
        curl() {
            printf "%s\n" "$*" >> "$CURL_LOG"
            printf "HTTP/1.1 200 OK\r\nDate: Wed, 21 Oct 2015 07:28:00 GMT\r\n\r\n"
        }
        date() { printf "1445412480\n"; }
        Z2K_DIAG_OPENWRT_RELEASE_FILE="$TMP_DIR/no-openwrt-release"
        clock_skew_vs_relay
    ')
case "$result" in 0) ok "Keenetic clock skew probe сохранён" ;; *) bad "Keenetic clock skew result: $result" ;; esac
if grep -qF -- '--resolve 198.51.100.25.nip.io:443:198.51.100.25' "$TMP/keenetic-curl.log"; then ok "Keenetic сохраняет прежний relay path"; else bad "Keenetic relay path изменён"; fi

printf '\ntest_diag_clock_skew_vps_free.sh: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
