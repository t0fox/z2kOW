#!/bin/sh
. "$(dirname "$0")/helper.sh"
_t_plan "ow-bootstrap-manifest-mirrors"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-bootstrap-manifest.XXXXXX")" || exit 1
FUNCTION_FILE="$T/function.sh"
export T FUNCTION_FILE
trap 'rm -rf "$T"' EXIT HUP INT TERM

awk '/^fetch_verified_manifest\(\) \{/,/^\}/' \
    "$REPO/scripts/openwrt/install.sh" > "$T/function.sh"
if [ ! -s "$T/function.sh" ]; then
    _t_bad "извлекаемая функция проверяет пару manifest/signature с зеркала"
    _t_done
    exit 1
fi

openssl genpkey -algorithm ED25519 -out "$T/test.key" 2>/dev/null || exit 1
openssl pkey -in "$T/test.key" -pubout -out "$T/test.pub" 2>/dev/null || exit 1
KEY_ID="$(openssl pkey -pubin -in "$T/test.pub" -outform DER 2>/dev/null \
    | sha256sum | awk '{print $1}')"
printf '{"schema":1,"signing":{"key_id":"%s"},"source":"origin"}\n' "$KEY_ID" \
    > "$T/origin.json"
printf '{"schema":1,"signing":{"key_id":"%s"},"source":"mirror"}\n' "$KEY_ID" \
    > "$T/mirror.json"
openssl pkeyutl -sign -rawin -inkey "$T/test.key" -in "$T/mirror.json" \
    -out "$T/mirror.sig" 2>/dev/null || exit 1
openssl pkeyutl -sign -rawin -inkey "$T/test.key" -in "$T/origin.json" \
    -out "$T/origin.sig" 2>/dev/null || exit 1
printf 'invalid-signature' > "$T/invalid.sig"

_run_manifest_case() {
    _mode="$1"
    _trusted_ids="${2:-$KEY_ID}"
    _work="$T/$_mode"
    mkdir -p "$_work"
    T="$T" MODE="$_mode" BASE=https://origin.invalid/z2kOW/main \
        TMP="$_work" BOOTSTRAP_TRUSTED_KEY_IDS="$_trusted_ids" \
        sh -c '
            MANIFEST="$TMP/UPDATES.json"
            SIGNATURE="$TMP/UPDATES.json.sig"
            PUBKEY="$TMP/z2k-update-pub.pem"
            value() {
                sed -n "s/.*\"key_id\":\"\([0-9a-f]*\)\".*/\1/p" "$MANIFEST"
            }
            download() {
                printf "%s\n" "$1" >> "$TMP/sources.log"
                case "$1" in
                    https://origin.invalid/z2kOW/main/UPDATES.json)
                        cp "$T/origin.json" "$2" ;;
                    https://origin.invalid/z2kOW/main/scripts/openwrt/release-keys/*)
                        cp "$T/test.pub" "$2" ;;
                    https://origin.invalid/z2kOW/main/UPDATES.json.sig)
                        if [ "$MODE" = direct ]; then cp "$T/origin.sig" "$2"; else cp "$T/invalid.sig" "$2"; fi ;;
                    https://cdn.jsdelivr.net/gh/t0fox/z2kOW@main/UPDATES.json)
                        if [ "$MODE" = direct ]; then return 1; else cp "$T/mirror.json" "$2"; fi ;;
                    https://cdn.jsdelivr.net/gh/t0fox/z2kOW@main/scripts/openwrt/release-keys/*)
                        cp "$T/test.pub" "$2" ;;
                    https://cdn.jsdelivr.net/gh/t0fox/z2kOW@main/UPDATES.json.sig)
                        if [ "$MODE" = reject ]; then cp "$T/invalid.sig" "$2"; else cp "$T/mirror.sig" "$2"; fi ;;
                    *) return 1 ;;
                esac
            }
            . "$FUNCTION_FILE"
            fetch_verified_manifest
        '
}

if _run_manifest_case mirror; then
    _t_ok "подпись прямого источника отклонена, зеркало выбрано"
else
    _t_bad "подпись прямого источника отклонена, зеркало выбрано"
fi
assert_eq "сначала запрашивается быстрое зеркало" "https://cdn.jsdelivr.net/gh/t0fox/z2kOW@main/UPDATES.json" "$(head -n 1 "$T/mirror/sources.log")"
assert_eq "в выбранном манифесте байты подписанного зеркала" \
    "$(cat "$T/mirror.json")" "$(cat "$T/mirror/UPDATES.json")"
assert_contains "манифест привязан к подтверждённому зеркалу" \
    "$T/mirror/sources.log" "https://cdn.jsdelivr.net/gh/t0fox/z2kOW@main/UPDATES.json.sig"

if _run_manifest_case direct; then
    _t_ok "при отказе CDN принят подписанный raw-origin"
else
    _t_bad "при отказе CDN принят подписанный raw-origin"
fi
assert_eq "raw-origin fallback сохранил подписанный manifest" \
    "$(cat "$T/origin.json")" "$(cat "$T/direct/UPDATES.json")"
assert_contains "raw-origin fallback скачал подпись" \
    "$T/direct/sources.log" "https://origin.invalid/z2kOW/main/UPDATES.json.sig"

if _run_manifest_case reject; then
    _t_bad "отклоняются неподписанные пары со всех источников"
else
    _t_ok "отклоняются неподписанные пары со всех источников"
fi
if [ ! -e "$T/reject/UPDATES.json" ]; then
    _t_ok "непроверенный manifest не публикуется"
else
    _t_bad "непроверенный manifest не публикуется"
fi

if _acceptance_source=1 _run_manifest_case override; then
    _t_ok "явный приёмочный источник проверяется первым"
else
    _t_bad "явный приёмочный источник проверяется первым"
fi
assert_eq "явный источник сохраняет приоритет" \
    "https://origin.invalid/z2kOW/main/UPDATES.json" \
    "$(head -n 1 "$T/override/sources.log")"

_untrusted_id="$(printf '%064d' 0)"
if _run_manifest_case untrusted "$_untrusted_id"; then
    _t_bad "открытый ключ вне закреплённого списка отклоняется"
else
    _t_ok "открытый ключ вне закреплённого списка отклоняется"
fi
if [ ! -e "$T/untrusted/UPDATES.json" ]; then
    _t_ok "манифест незакреплённого ключа не публикуется"
else
    _t_bad "манифест незакреплённого ключа не публикуется"
fi

_t_done
