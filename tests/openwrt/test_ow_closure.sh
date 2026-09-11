#!/bin/sh
# tests/openwrt/test_ow_closure.sh - Step 9: dependency closure одной сборки.
# На СГЕНЕРИРОВАННОМ конфиге + СОБРАННОМ argv доказывает:
#   1. каждое имя (failure_detector/success_detector/hostkey/fool) определено
#      function-определением в lua, которые optbase РЕАЛЬНО грузит
#      (методология tests/test_detector_names_resolvable.sh, усиленная:
#      проверяем загружаемое множество, а не весь files/lua);
#   2. каждый blob=NAME имеет --blob=NAME:@path в argv и файл на диске;
#   3. каждый --import=NAME объявлен предшествующим --template=NAME
#      (правило движка из комментария lib/config_official.sh).
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/fixture.sh"
_t_plan "ow-closure"
ow_fixture_init || { echo "FAIL[ow-closure]: fixture" >&2; exit 1; }
trap ow_fixture_done EXIT INT TERM

AD="$REPO/platform/openwrt"
. "$AD/paths.sh"
. "$AD/env.sh"
# shellcheck disable=SC1090,SC1091
. "$Z2K_LIB/utils.sh" >/dev/null 2>&1 || exit 1
. "$Z2K_LIB/strategies.sh" >/dev/null 2>&1 || exit 1
. "$Z2K_LIB/config_official.sh" >/dev/null 2>&1 || exit 1
. "$AD/materialize.sh"
. "$AD/bootstrap.sh"
. "$AD/generate.sh"
. "$AD/optbase.sh"

z2k_ow_materialize "$Z2K_MANIFESTS_DIR" >/dev/null 2>&1 || exit 1
z2k_ow_bootstrap >/dev/null 2>&1 || exit 1
z2k_ow_generate >/dev/null 2>&1 || exit 1
# shellcheck disable=SC1090
. "$Z2K_CONFIG" || exit 1

BASE="$(z2k_ow_optbase)" || exit 1
FULL="--qnum=${QNUM:-200} $BASE $NFQWS2_OPT"
printf '%s' "$FULL" >"$T/full.argv"

# множество РЕАЛЬНО загружаемых z2k-lua
mkdir -p "$T/loaded"
echo "$BASE" | grep -oE -- "--lua-init=@$T/root/lua/[a-z0-9-]+\.lua" \
    | sed 's/.*@//' >"$T/loaded.list"
[ -s "$T/loaded.list" ] && _t_ok || _t_bad "пустое множество загружаемых lua"

# 1. имена резолвятся в загружаемом множестве
NAMES=$(printf '%s' "$NFQWS2_OPT" | tr ' :' '\n\n' \
    | grep -oE '^(failure_detector|success_detector|hostkey|fool)=[A-Za-z_][A-Za-z0-9_]*' \
    | cut -d= -f2 | sort -u)
[ -n "$NAMES" ] || _t_bad "в конфиге нет ссылок по имени — проверка потеряла смысл"
for _n in $NAMES; do
    case "$_n" in
        standard_*) _t_ok; continue ;;
    esac
    _found=0
    while IFS= read -r _lf; do
        grep -qE "^(local )?function ${_n}[[:space:]]*\\(" "$_lf" 2>/dev/null && _found=1
    done <"$T/loaded.list"
    [ "$_found" = "1" ] && _t_ok || _t_bad "$_n не определён в загружаемых lua"
done

# 2. blob-ссылки резолвятся (семантика tests/test_blob_identifiers.sh,
#    применённая к СГЕНЕРИРОВАННОМУ конфигу + СОБРАННОМУ argv):
#    ссылка = (blob|seqovl_pattern|pattern|fallback)=Имя из NFQWS2_OPT;
#    встроенные fake_default_* существуют без регистрации;
#    z2k_real_* производит tls_client_hello_clone/z2k_*-инстанс в том же OPT;
#    остальное обязано иметь --blob=Имя:@path в argv и файл на диске.
_ref=$(printf '%s' "$NFQWS2_OPT" | grep -oE '(blob|seqovl_pattern|pattern|fallback)=[A-Za-z_][A-Za-z0-9_]*' \
    | sed 's/.*=//' | sort -u)
[ -n "$_ref" ] || _t_bad "в конфиге нет blob-ссылок — проверка потеряла смысл"
_runtime=$(printf '%s' "$NFQWS2_OPT" | grep -oE -- '--lua-desync=(z2k_[A-Za-z0-9_]*|tls_client_hello_clone):[^ ]*blob=[A-Za-z_][A-Za-z0-9_]*' \
    | sed 's/.*blob=//; s/:.*//' | sort -u)
for _b in $_ref; do
    case "$_b" in
        fake_default_tls|fake_default_quic|fake_default_http) _t_ok; continue ;;
    esac
    if printf '%s\n' "$_runtime" | grep -qx "$_b"; then _t_ok; continue; fi
    _reg=$(printf '%s' "$FULL" | grep -oE -- "--blob=${_b}:@[^ ]+" | sed 's/.*:@//')
    if [ -z "$_reg" ]; then
        _t_bad "blob=$_b: нет регистрации в argv"
    elif [ -f "$_reg" ]; then
        _t_ok
    else
        _t_bad "blob=$_b зарегистрирован в никуда: $_reg"
    fi
done

# 2b. идентификаторы регистраций примет движок (буква/_ в начале)
_badids=""
for _id in $(printf '%s' "$FULL" | grep -oE -- '--blob=[A-Za-z0-9_]+:' | sed 's/--blob=//; s/:$//' | sort -u); do
    case "$_id" in [A-Za-z_]*) ;; *) _badids="$_badids $_id" ;; esac
done
[ -z "$_badids" ] && _t_ok || _t_bad "блобы с невалидным именем:$_badids"

# 3. template-before-import
TMPLS=$(printf '%s' "$NFQWS2_OPT" | grep -oE -- '--template=[A-Za-z0-9_]+' | cut -d= -f2 | sort -u)
for _i in $(printf '%s' "$NFQWS2_OPT" | grep -oE -- '--import=[A-Za-z0-9_]+' | cut -d= -f2 | sort -u); do
    echo "$TMPLS" | grep -qx "$_i" && _t_ok || _t_bad "--import=$_i без предшествующего --template"
done

_t_done
