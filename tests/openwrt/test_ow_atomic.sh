#!/bin/sh
# tests/openwrt/test_ow_atomic.sh - §7: атомарность бинарной подмены.
# Upstream-логика нетронута; тест сторожит паттерн целиком:
# refresh-binaries: tmp-рядом -> sha-check ДО mv -> mv атомарно;
#   sha mismatch/download fail -> rm tmp, continue, старый бинарник цел;
# au_apply_patch: cp в target.z2k-au.$$ -> chmod -> mv (никакой записи в цель).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-atomic"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
AU="$REPO/lib/auto_update.sh"

# вырезаем тело au_step_refresh_binaries целиком (от заголовка до /^}$/)
_body="$(sed -n '/^au_step_refresh_binaries()/,/^}/p' "$AU")"
[ -n "$_body" ] && _t_ok || _t_bad "au_step_refresh_binaries не найдена"

# порядок: sha-проверка tmp РАНЬШЕ mv (иначе непроверенное въезжает в прод)
_sha_line="$(printf '%s' "$_body" | grep -n 'z2k_sha256_file "$_rb_tmp"' | head -1 | cut -d: -f1)"
_mv_line="$(printf '%s' "$_body" | grep -n 'mv -f "$_rb_tmp" "$_rb_dest"' | head -1 | cut -d: -f1)"
[ -n "$_sha_line" ] && [ -n "$_mv_line" ] && [ "$_sha_line" -lt "$_mv_line" ] \
    && _t_ok || _t_bad "sha-check tmp ($_sha_line) не раньше mv ($_mv_line)"

# провал sha: tmp удаляется, mv нет, идём дальше (старый бинарник цел)
printf '%s' "$_body" | grep -q 'sha не сошлась.*рабочий бинарник не трогаю' \
    && _t_ok || _t_bad "нет ветки sha-mismatch с сохранением старого"
printf '%s' "$_body" | grep -q 'rm -f "$_rb_tmp"; echo 1 >> "$fail"; continue' \
    && _t_ok || _t_bad "нет rm-tmp-and-continue на провале"

# провал скачивания: то же
printf '%s' "$_body" | grep -q 'не скачался.*rm -f "$_rb_tmp"' \
    && _t_ok || _t_bad "нет rm-tmp на провале скачивания"

# au_apply_patch: staging tmp + rename, без записи напрямую в цель
# (паттерны уникальны для функции — границы извлекаем широко).
_pbody="$(sed -n '/^au_apply_patch()/,/^au_write_installed_tag()/p' "$AU")"
printf '%s' "$_pbody" | grep -q '_au_tmp="${target}.z2k-au.\$\$"' \
    && _t_ok || _t_bad "нет staging-tmp в au_apply_patch"
printf '%s' "$_pbody" | grep -q 'mv -f "$_au_tmp" "$target"' \
    && _t_ok || _t_bad "нет atomic rename в au_apply_patch"
# тег двигается только после успешной раскладки (fail до него = return)
printf '%s' "$_pbody" | grep -q 'тег НЕ продвигаем' \
    && _t_ok || _t_bad "нет fail-before-tag инварианта"

_t_done
