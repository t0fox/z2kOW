#!/bin/sh
. "$(dirname "$0")/helper.sh"
_t_plan "ow-bootstrap-download-validation"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-bootstrap-download.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
printf 'abc' > "$T/payload"
awk '/^download_verified_artifact\(\) \{/,/^\}/' \
    "$REPO/scripts/openwrt/install.sh" > "$T/function.sh"

_run_download() {
    _expected_size="$1"
    _expected_sha="$2"
    _out="$3"
    _dest="${_out%.err}-dest"
    DEST_FILE="$_dest" PAYLOAD_FILE="$T/payload" FUNCTION_FILE="$T/function.sh" \
        EXPECTED_SIZE="$_expected_size" EXPECTED_SHA="$_expected_sha" \
        sh -c '
        . "$FUNCTION_FILE"
        download() { cp "$PAYLOAD_FILE" "$2"; }
        download_verified_artifact http://origin.invalid/release.tar.gz \
            "$DEST_FILE" "$EXPECTED_SIZE" "$EXPECTED_SHA"
    ' 2>"$_out"
}

ACTUAL_SHA="$(sha256sum "$T/payload" | awk '{print $1}')"
if _run_download 4 "$ACTUAL_SHA" "$T/size.err"; then
    _t_bad "недоверенный размер принят"
else
    _t_ok
fi
assert_contains "неверный размер имеет точную диагностику" "$T/size.err" \
    'размер архива файлов роутера не совпал'
if [ ! -e "$T/size-dest" ]; then _t_ok "частичный архив не устанавливается"; else _t_bad "частичный архив не устанавливается"; fi

if _run_download 3 "$(printf '%064d' 0)" "$T/sha.err"; then
    _t_bad "неверный SHA-256 принят"
else
    _t_ok
fi
assert_contains "неверный SHA-256 имеет точную диагностику" "$T/sha.err" \
    'SHA-256 архива файлов роутера не совпал'
if [ ! -e "$T/sha-dest" ]; then _t_ok "архив с неверным хешем не устанавливается"; else _t_bad "архив с неверным хешем не устанавливается"; fi

if DEST_FILE="$T/good-dest" PAYLOAD_FILE="$T/payload" \
    FUNCTION_FILE="$T/function.sh" EXPECTED_SIZE=3 EXPECTED_SHA="$ACTUAL_SHA" \
    sh -c '
        . "$FUNCTION_FILE"
        download() { cp "$PAYLOAD_FILE" "$2"; }
        download_verified_artifact http://origin.invalid/release.tar.gz \
            "$DEST_FILE" "$EXPECTED_SIZE" "$EXPECTED_SHA"
    ' 2>"$T/good.err"; then
    _t_ok
else
    _t_bad "проверенный архив отклонён: $(cat "$T/good.err")"
fi
assert_eq "после проверки опубликованы ожидаемые байты" abc "$(cat "$T/good-dest" 2>/dev/null)"

_t_done
