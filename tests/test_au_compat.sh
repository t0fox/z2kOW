#!/bin/sh
# tests/test_au_compat.sh — совместимость в обе стороны и выбор пути.
#
# Манифест без install_map (откат манифеста, ручная правка) НЕ должен приводить
# к тихому сдвигу версии: исполнитель обязан честно потребовать полную
# установку. Тихий сдвиг версии без доставки — авария, которую снаружи не
# опознать: тег новый, поведение старое, в логе успех.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d) || exit 1; trap 'rm -rf "$SB"' EXIT

# КОРЕНЬ УСТАНОВКИ — В ПЕСОЧНИЦУ, И ЭТО НЕ ФОРМАЛЬНОСТЬ.
#
# au_apply_patch/au_apply_converge пишут в ${ZAPRET2_DIR:-/opt/zapret2}: конфиг
# через regen-config и .z2k-installed-tag. Набор их звал, ничего не переопределив.
# На маке и в CI каталога /opt/zapret2 нет, поэтому записи молча проваливались и
# тест зеленел — а на роутере он ПЕРЕПИСАЛ ЖИВОЙ КОНФИГ (проверено 2026-08-27:
# в конфиг владельца уехал TMPDIR прогонного окружения). Тест, который трогает
# прод, опаснее бага, который он ищет.
ZAPRET2_DIR="$SB/zd"; CONFIG_FILE="$SB/zd/config"
Z2K_AU_INSTALLED_TAG_FILE="$SB/zd/.z2k-installed-tag"
export ZAPRET2_DIR CONFIG_FILE Z2K_AU_INSTALLED_TAG_FILE
mkdir -p "$SB/zd"

Z2K_AU_SOURCE_ONLY=1; export Z2K_AU_SOURCE_ONLY
# shellcheck disable=SC1091
. "$ROOT/lib/utils.sh" 2>/dev/null
# shellcheck disable=SC1091
. "$ROOT/lib/auto_update.sh" 2>/dev/null
Z2K_AU_TMP_DIR="$SB/tmp"; mkdir -p "$Z2K_AU_TMP_DIR"
au_log() { :; }

printf '{"current":"p-2","history":[\n{"v": "p-2", "type": "patch", "changed_files": ["files/lua/a.lua"]}\n]}\n' > "$SB/old.json"
printf '{"current":"p-2","install_map":{"files/lua/a.lua":["/x"]},"history":[\n{"v": "p-2", "type": "patch", "steps": ["restart-service"], "changed_files": ["files/lua/a.lua"]}\n]}\n' > "$SB/new.json"

assert_eq "манифест без карты опознан"  "1" "$(au_manifest_has_install_map "$SB/old.json"; echo $?)"
assert_eq "манифест с картой опознан"   "0" "$(au_manifest_has_install_map "$SB/new.json"; echo $?)"

# Старый манифест: патч обязан отказаться (rc 2), а не разложить наугад.
cp "$SB/old.json" "$Z2K_AU_TMP_DIR/UPDATES.json"
assert_eq "без карты патч отказывается, а не гадает" "2" \
    "$(au_apply_patch p-2 "files/lua/a.lua" >/dev/null 2>&1; echo $?)"

# Аварийный флаг релиза уводит на полную установку.
printf '{"current":"p-9","install_map":{},"history":[\n{"v": "p-9", "type": "reinstall", "full_install": true, "steps": [], "changed_files": []}\n]}\n' > "$SB/full.json"
_e=$(grep '^{"v"' "$SB/full.json")
assert_eq "full_install читается как булев флаг" "true" "$(au_entry_bool "$_e" full_install)"
_e2=$(grep '^{"v"' "$SB/new.json")
assert_eq "обычный релиз флага не несёт" "" "$(au_entry_bool "$_e2" full_install)"

# Старый апдейтер против нового манифеста: type и changed_files на месте, иначе
# он посчитает запись патчем без файлов и сдвинет версию, ничего не доставив.
assert_eq "новый манифест несёт type для старого апдейтера" "patch" "$(au_entry_field "$_e2" type)"
assert_eq "новый манифест несёт changed_files" "files/lua/a.lua" "$(au_entry_changed_files "$_e2" | tr '\n' ' ' | sed 's/ $//')"

# Развилка целиком: au_apply_converge доводит до отметки версии.
mkdir -p "$SB/zd"
printf 'новое\n' > "$SB/src.lua"
_sha=$(z2k_sha256_file "$SB/src.lua")
cat > "$Z2K_AU_TMP_DIR/UPDATES.json" <<EOF
{"current": "p-5",
 "install_map": {"files/lua/a.lua": ["$SB/zd/a.lua"]},
 "files_sha256": {"files/lua/a.lua": "$_sha"},
 "history": [
{"v": "p-5", "type": "patch", "steps": ["restart-service"], "changed_files": ["files/lua/a.lua"]}
]}
EOF
au_download_repo_file() { cp "$SB/src.lua" "$2"; }
: > "$SB/acts.log"
au_step_restart_service() { echo restart >> "$SB/acts.log"; }
au_snapshot_for_patch() { echo snapshot >> "$SB/acts.log"; return 0; }
au_rollback_patch() { echo rollback >> "$SB/acts.log"; return 0; }
au_health_check() { [ -f "$SB/sick" ] && return 1; return 0; }
Z2K_AU_INSTALLED_TAG_FILE="$SB/tag"; printf 'p-4\n' > "$Z2K_AU_INSTALLED_TAG_FILE"

assert_eq "успешный прогон" "0" "$(au_apply_converge p-5 restart-service; echo $?)"
assert_eq "файл доставлен" "новое" "$(cat "$SB/zd/a.lua" 2>/dev/null)"
assert_eq "порядок: снимок → шаги, отката нет" "snapshot restart" "$(tr '\n' ' ' < "$SB/acts.log" | sed 's/ $//')"
assert_eq "версия переставлена" "p-5" "$(cat "$SB/tag" | tr -d ' \t\r\n')"

# Повторный прогон: дерево уже совпало — только отметка, без шагов.
: > "$SB/acts.log"; printf 'p-4\n' > "$SB/tag"
assert_eq "идемпотентность: успех" "0" "$(au_apply_converge p-5; echo $?)"
assert_eq "идемпотентность: ничего не делалось" "" "$(tr '\n' ' ' < "$SB/acts.log" | sed 's/ $//')"
assert_eq "идемпотентность: версия всё равно отмечена" "p-5" "$(cat "$SB/tag" | tr -d ' \t\r\n')"

# Провал health-check: откат, версия НЕ двигается.
: > "$SB/acts.log"; printf 'p-4\n' > "$SB/tag"; touch "$SB/sick"; printf 'старое\n' > "$SB/zd/a.lua"
assert_eq "health-check провален — rc 1" "1" "$(au_apply_converge p-5 restart-service; echo $?)"
assert_eq "был откат" "yes" "$(grep -q rollback "$SB/acts.log" && echo yes || echo no)"
assert_eq "версия НЕ сдвинулась" "p-4" "$(cat "$SB/tag" | tr -d ' \t\r\n')"
rm -f "$SB/sick"

# Неизвестный шаг: rc 2 — наверх, за полной установкой; версия не двигается.
: > "$SB/acts.log"; printf 'p-4\n' > "$SB/tag"; printf 'старое\n' > "$SB/zd/a.lua"
assert_eq "неизвестный шаг — rc 2" "2" "$(au_apply_converge p-5 шаг-из-будущего; echo $?)"
assert_eq "неизвестный шаг: версия НЕ сдвинулась" "p-4" "$(cat "$SB/tag" | tr -d ' \t\r\n')"

# Старый release-level reset_state остаётся значимым и на адресном пути:
# прогоняем реальный au_run_apply на patch-entry с install_map и проверяем,
# что reset-state дошёл до исполнителя шагов. Сам destructive filesystem step
# отдельно покрыт au_step_reset_state/OpenWrt lifecycle suites.
mkdir -p "$SB/zd/lua"
printf 'уже актуально\n' > "$SB/zd/lua/a.lua"
_sha_current=$(z2k_sha256_file "$SB/zd/lua/a.lua")
cat > "$Z2K_AU_TMP_DIR/UPDATES.json" <<EOF
{
  "current": "p-7",
  "install_map": { "files/lua/a.lua": ["$SB/zd/lua/a.lua"] },
  "files_sha256": { "files/lua/a.lua": "$_sha_current" },
  "history": [
    {"v": "p-6", "type": "patch", "changed_files": [], "steps": []},
    {"v": "p-7", "type": "patch", "reset_state": true, "changed_files": [], "steps": []}
  ]
}
EOF
printf 'p-6\n' > "$SB/compat-tag"
Z2K_AU_INSTALLED_TAG_FILE="$SB/compat-tag"
export Z2K_AU_INSTALLED_TAG_FILE
: > "$SB/reset-actions.log"
au_fetch_manifest() { [ -s "$Z2K_AU_TMP_DIR/UPDATES.json" ]; }
au_lock_acquire() { return 0; }
au_lock_release() { :; }
au_nfqws_alive() { return 1; }
au_snapshot_services() { :; }
au_step_reset_state() { printf 'reset-state\n' >> "$SB/reset-actions.log"; }
au_apply_converge() {
    local _tag="$1"; shift
    au_run_steps "$@" || return $?
    au_write_installed_tag "$_tag"
}
au_step_cleanup_ip_hosts() { :; }
au_ensure_cli_link() { :; }
assert_eq "адресный patch с reset_state доходит до шага" "0" "$(au_run_apply >/dev/null 2>&1; echo $?)"
assert_eq "адресный patch исполнил reset-state" "reset-state" "$(cat "$SB/reset-actions.log")"
assert_eq "версия отмечена после шага" "p-7" "$(tr -d ' \t\r\n' < "$SB/compat-tag")"

# Контракт манифеста репозитория: у каждого шага в истории есть исполнитель.
unknown=""
for s in $(grep -o '"steps"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$ROOT/UPDATES.json" 2>/dev/null \
           | sed 's/.*\[//; s/\]//' | tr ',' '\n' | tr -d ' "' | grep -v '^$' | sort -u); do
    au_step_order | grep -qx "$s" || unknown="$unknown $s"
done
assert_eq "в манифесте нет шагов без исполнителя" "" "$unknown"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
