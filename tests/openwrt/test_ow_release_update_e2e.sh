#!/bin/sh
# tests/openwrt/test_ow_release_update_e2e.sh - Stage 7: update.sh end-to-end.
# Production entrypoint в субпроцессе: настоящий curl (file://), настоящий
# openssl-verify, настоящий Ed25519-ключ фикстуры, pin preset. R7 apply,
# R10 bad signature, R12 API-too-old (apply+check), статусы check (§57).
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/lc_harness.sh"
_t_plan "ow-release-update-e2e"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-rue2e.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
LC_REPO="$REPO"

command -v openssl >/dev/null 2>&1 || { echo "FAIL[ow-release-update-e2e]: нет openssl" >&2; exit 1; }
openssl genpkey -algorithm ed25519 -out /dev/null >/dev/null 2>&1 \
    || { echo "FAIL[ow-release-update-e2e]: openssl без ed25519" >&2; exit 1; }

lc_init || { echo "FAIL[ow-release-update-e2e]: init" >&2; exit 1; }
lc_fresh_sysroot || exit 1
SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"

# test CA: ключ фикстуры вместо production-ключа (только sysroot)
openssl genpkey -algorithm ed25519 -out "$T/upd.key" 2>/dev/null || exit 1
openssl pkey -in "$T/upd.key" -pubout -out "$T/upd.pub" 2>/dev/null || exit 1
cp -f "$T/upd.pub" "$Z2K_ROOT/etc/z2k-update-pub.pem" || exit 1
mkdir -p "$(dirname "$Z2K_AU_TRUST_PIN")" || exit 1
: > "$Z2K_AU_TRUST_PIN"
# транспорт — настоящий HTTP тем же кодом, что прод (z2k_fetch → curl):
# python http.server раздаёт $LC_ORIGIN/files на loopback; refs пустые
# (иначе доставка искала бы ref-префикс).
_srv_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -m http.server "$_srv_port" --bind 127.0.0.1 --directory "$LC_ORIGIN/files" >/dev/null 2>&1 &
_SRV_PID=$!
trap 'kill "$_SRV_PID" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
_i=0
while [ "$_i" -lt 25 ]; do
    curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$_srv_port/" >/dev/null 2>&1 && break
    sleep 0.2
    _i=$((_i + 1))
done
export Z2K_AU_REPO_RAW="http://127.0.0.1:$_srv_port" Z2K_AU_RAW_BASE="http://127.0.0.1:$_srv_port"
export Z2K_AU_MANIFEST_URL="http://127.0.0.1:$_srv_port/UPDATES.json"
export Z2K_AU_SIG_URL="http://127.0.0.1:$_srv_port/UPDATES.json.sig"
export Z2K_AU_MANUAL=1
export PATH="/usr/bin:/bin"
_resign() {
    openssl pkeyutl -sign -rawin -inkey "$T/upd.key" \
        -in "$LC_ORIGIN/files/UPDATES.json" \
        -out "$LC_ORIGIN/files/UPDATES.json.sig" 2>/dev/null
}
_mkmanifest() {
    # $1 oldv $2 newv-or-empty(extra api-min "2" when $3=api2)
    lc_origin_put "lib/utils.sh" <<EOF
#!/bin/sh
# E2E witness $2
E2E_UTILS=1
EOF
    if [ "$3" = "api2" ]; then
        printf '%s|patch||lib/utils.sh||false|false\n%s|patch||lib/utils.sh||false|false\n' \
            "$1" "$2" | lc_manifest "$2" || return 1
        # api-поле — через awk с -v (без вложенных кавычек sed: читаемо
        # и одинаково на GNU/BusyBox; sed -i там разный).
        awk -v v="$2" '{ if (index($0, "\"v\": \"" v "\"") > 0) sub(/}$/, ", \"openwrt_adapter_api_min\": \"2\"}"); print }' \
            "$LC_ORIGIN/manifest.json" > "$LC_ORIGIN/manifest.json.new" \
            && mv -f "$LC_ORIGIN/manifest.json.new" "$LC_ORIGIN/manifest.json" \
            && cp -f "$LC_ORIGIN/manifest.json" "$LC_ORIGIN/files/UPDATES.json" || return 1
    else
        printf '%s|patch||lib/utils.sh||false|false\n%s|patch||lib/utils.sh||false|false\n' \
            "$1" "$2" | lc_manifest "$2" || return 1
    fi
    _resign || return 1
}
_run_check() { sh "$REPO/platform/openwrt/update.sh" check < /dev/null 2>&1; }
_run_apply() { sh "$REPO/platform/openwrt/update.sh" apply < /dev/null 2>&1; }

# --- check UP_TO_DATE ---
_mkmanifest "p-84.0" "$SEEDTAG" || exit 1
_out="$(_run_check)"; _rc=$?
assert_eq "check up-to-date rc" "0" "$_rc"
case "$_out" in
    *"Обновлений нет"*) _t_ok ;;
    *) _t_bad "check up-to-date без вердикта" ;;
esac

# --- check PAYLOAD_UPDATE_AVAILABLE ---
lc_set_version "p-84.0" || exit 1
_out="$(_run_check)"; _rc=$?
assert_eq "check available rc" "0" "$_rc"
case "$_out" in
    *"Доступно обновление"*) _t_ok ;;
    *) _t_bad "check available без вердикта" ;;
esac

# --- check ADAPTER_UPDATE_REQUIRED (§57) ---
_mkmanifest "p-84.0" "$SEEDTAG" "api2" || exit 1
lc_set_version "p-84.0" || exit 1
_out="$(_run_check)"; _rc=$?
assert_eq "check adapter-required rc" "2" "$_rc"
case "$_out" in
    *"ADAPTER_UPDATE_REQUIRED"*) _t_ok ;;
    *) _t_bad "check без ADAPTER_UPDATE_REQUIRED" ;;
esac

# --- R7: apply end-to-end production entrypoint ---
_mkmanifest "p-84.0" "$SEEDTAG" || exit 1
lc_set_version "p-84.0" || exit 1
_out="$(_run_apply)"; _rc=$?
assert_eq "R7 apply rc" "0" "$_rc"
assert_eq "R7 tag" "$SEEDTAG" "$(lc_tag)"
assert_contains "R7 payload новый" "$Z2K_ROOT/lib/utils.sh" "E2E_UTILS=1"
lc_invariant "R7e2e" || _t_bad "R7 invariant"

# --- R10: битая подпись — отказ до применения ---
_mkmanifest "p-84.0" "$SEEDTAG" || exit 1
lc_set_version "p-84.0" || exit 1
_before_utils="$(sha256sum "$Z2K_ROOT/lib/utils.sh" | awk '{print $1}')"
printf ' ' >> "$LC_ORIGIN/files/UPDATES.json"
_out="$(_run_apply)"; _rc=$?
assert_eq "R10 rc" "1" "$_rc"
assert_eq "R10 tag стоит" "p-84.0" "$(lc_tag)"
assert_eq "R10 файл цел" "$_before_utils" "$(sha256sum "$Z2K_ROOT/lib/utils.sh" | awk '{print $1}')"

# --- R12 apply: API too old — отказ до мутаций ---
_mkmanifest "p-84.0" "$SEEDTAG" "api2" || exit 1
lc_set_version "p-84.0" || exit 1
_before_utils2="$(sha256sum "$Z2K_ROOT/lib/utils.sh" | awk '{print $1}')"
_out="$(_run_apply)"; _rc=$?
assert_eq "R12 rc" "1" "$_rc"
case "$_out" in
    *"z2k-adapter"*) _t_ok ;;
    *) _t_bad "R12 без package-инструкции" ;;
esac
assert_eq "R12 tag стоит" "p-84.0" "$(lc_tag)"
assert_eq "R12 файл цел" "$_before_utils2" "$(sha256sum "$Z2K_ROOT/lib/utils.sh" | awk '{print $1}')"

_t_done
