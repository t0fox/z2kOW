#!/bin/sh
# The portable DNS snapshot renderer preserves verdict and age semantics.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s: %s\n' "$1" "$2"; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-diag-dns.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
awk '/^print_dns_check_snapshot\(\) \{/,/^\}/' "$ROOT/files/z2k-diag.sh" > "$T/function.sh"
[ -s "$T/function.sh" ] || { no 'DNS snapshot renderer extracted' 'function missing'; exit 1; }

_now=$(date +%s)
printf '{"ts":%s,"results":[{"name":"A","verdict":"works"},{"name":"B","verdict":"spoof"},{"name":"Резолвер роутера","udp":"spoof","verdict":"silent"}]}' \
    "$_now" > "$T/fresh.json"
_fresh=$(Z2K_DIAG_DNS_CHECK_JSON="$T/fresh.json" sh -c '. "$1"; print_dns_check_snapshot' sh "$T/function.sh")
case "$_fresh" in
    *'серверов 3: честно 1, подмена 1, молчат 1; резолвер роутера подменяет ответы'*) ok 'fresh snapshot aggregates works/spoof/silent and router resolver verdict' ;;
    *) no 'fresh snapshot verdict semantics' "$_fresh" ;;
esac

printf '{"ts":1,"results":[{"name":"Резолвер роутера","udp":"works","verdict":"works"}]}' > "$T/stale.json"
_stale=$(Z2K_DIAG_DNS_CHECK_JSON="$T/stale.json" sh -c '. "$1"; print_dns_check_snapshot' sh "$T/function.sh")
case "$_stale" in *'СНИМОК УСТАРЕЛ'*) ok 'snapshot older than 48 hours is marked stale' ;; *) no 'stale snapshot age' "$_stale" ;; esac

_missing=$(Z2K_DIAG_DNS_CHECK_JSON="$T/missing.json" sh -c '. "$1"; print_dns_check_snapshot' sh "$T/function.sh")
case "$_missing" in *'не запускался'*) ok 'missing DNS snapshot is reported as not run' ;; *) no 'missing snapshot' "$_missing" ;; esac

printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
