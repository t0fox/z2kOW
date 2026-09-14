#!/bin/sh
# tests/openwrt/test_ow_rt_somark.sh - RT so-mark parity (p-84.17 / S96z2k-rt-proxy).
# Мост метит свои исходящие сокеты меткой desync-движка, иначе очереди NFQUEUE
# видят его соединения как обычную цель и движок заводит поиск обхода на
# собственный туннель. Рычаг OW: `meta mark and DESYNC_MARK == 0 ... jump`
# в common/nft.sh (все хуки, включая output) — помеченный пакет мимо очередей.
# Порядок значения: /etc/z2k/config DESYNC_MARK -> дефолт из файла runtime
# (динамически, не копия) -> встроенный дефолт. Паритет встроенного с файлом
# runtime доказывается настоящим tarball при Z2K_RT_TARBALL (секция 8).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-rt-somark"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
RT="$REPO/platform/openwrt/rt.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-rtsm.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

# --- функционал: сорсим rt.sh с фикстурами ---
export Z2K_RT_PORT=1445 Z2K_RT_TIMEOUT=15m Z2K_RT_BIN=/nonexistent/z2k-rt-proxy
export Z2K_CONFIG="$T/config" Z2K_RT_SOMARK_FNS="$T/functions"
# shellcheck disable=SC1090
. "$RT" || { echo "FAIL[ow-rt-somark]: rt.sh не сорсится" >&2; exit 1; }

# 1. конфиг побеждает всё.
printf 'ENABLED=1\nDESYNC_MARK=0x1234\n' > "$Z2K_CONFIG"
printf 'DESYNC_MARK=${DESYNC_MARK:-0x9999}\n' > "$Z2K_RT_SOMARK_FNS"
assert_eq "config wins" "0x1234" "$(_z2k_ow_rt_somark)"

# 2. без конфига — дефолт из файла runtime.
printf 'ENABLED=1\n' > "$Z2K_CONFIG"
assert_eq "runtime file fallback" "0x9999" "$(_z2k_ow_rt_somark)"

# 3. нет ни конфига, ни файла — builtin.
rm -f "$Z2K_RT_SOMARK_FNS"
assert_eq "builtin fallback" "0x40000000" "$(_z2k_ow_rt_somark)"

# 4. мусор в конфиге — не едет в argv, падает на runtime-дефолт.
printf 'ENABLED=1\nDESYNC_MARK=abc"def\n' > "$Z2K_CONFIG"
printf 'DESYNC_MARK=${DESYNC_MARK:-0x40000000}\n' > "$Z2K_RT_SOMARK_FNS"
assert_eq "garbage config falls back" "0x40000000" "$(_z2k_ow_rt_somark)"

# 5. валидация форматов.
for _v in 0x40000000 0X2D 45 0; do
    _z2k_ow_rt_somark_valid "$_v" && _t_ok || _t_bad "valid rejected: $_v"
done
for _v in 0x 0X 0xZZ "12 34" "abc" "-1"; do
    _z2k_ow_rt_somark_valid "$_v" && _t_bad "invalid accepted: [$_v]" || _t_ok
done
_z2k_ow_rt_somark_valid "" && _t_bad "invalid accepted: [empty]" || _t_ok

# 6. argv несёт --so-mark (точный флаг бинаря, parity с S96 MARK_ARG).
printf 'ENABLED=1\nDESYNC_MARK=0x40000000\n' > "$Z2K_CONFIG"
_got=""
_capture() { _got="$*"; }
z2k_ow_rt_with_argv _capture
assert_eq "argv exact" "/nonexistent/z2k-rt-proxy --listen=:1445 --timeout=15m --so-mark=0x40000000" "$_got"

# 7. decimal из конфига едет как есть (бинарь парсит base 0, как S96).
printf 'ENABLED=1\nDESYNC_MARK=45\n' > "$Z2K_CONFIG"
z2k_ow_rt_with_argv _capture
assert_eq "argv decimal passthrough" "/nonexistent/z2k-rt-proxy --listen=:1445 --timeout=15m --so-mark=45" "$_got"

# 8. паритет с настоящим runtime: builtin == дефолт из скачанного tarball.
# Без tarball — громкий SKIP (тот же контракт, что tarball layout в closure).
if [ -n "${Z2K_RT_TARBALL:-}" ] && [ -f "$Z2K_RT_TARBALL" ]; then
    _top="$(tar -tzf "$Z2K_RT_TARBALL" 2>/dev/null | sed -n 's|^\([^/]*\)/$|\1|p' | head -1)"
    _rf="$T/real-functions"
    if [ -n "$_top" ] && tar -xzOf "$Z2K_RT_TARBALL" "$_top/init.d/openwrt/functions" > "$_rf" 2>/dev/null; then
        _real="$(sed -n 's/^DESYNC_MARK=${DESYNC_MARK:-\(.*\)}.*/\1/p' "$_rf" | head -1)"
        _builtin="$(sed -n 's/^Z2K_RT_SOMARK_BUILTIN="[^"]*:-\(.*\)}"$/\1/p' "$RT" | head -1)"
        assert_eq "builtin == runtime default ($_real)" "$_real" "$_builtin"
        # и резолвер против настоящего файла даёт его дефолт
        printf 'ENABLED=1\n' > "$Z2K_CONFIG"
        Z2K_RT_SOMARK_FNS="$_rf" _z2k_ow_rt_somark_valid "$_real" \
            && assert_eq "resolver vs real file" "$_real" "$(Z2K_RT_SOMARK_FNS="$_rf" _z2k_ow_rt_somark)" \
            || _t_bad "real runtime default fails validation: [$_real]"
    else
        _t_bad "tarball без $_top/init.d/openwrt/functions"
    fi
else
    echo "SKIP[ow-rt-somark]: нет Z2K_RT_TARBALL (паритет builtin докажет CI)"
fi

_t_done
