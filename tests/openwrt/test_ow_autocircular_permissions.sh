#!/bin/sh
# Проверка отдельного каталога состояния autocircular и прав nfqws2.
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/fixture.sh"
_t_plan "ow-autocircular-permissions"
ow_fixture_init || { echo "FAIL[ow-autocircular-permissions]: fixture" >&2; exit 1; }
_OW_PERMISSION_TEST_TMP="${T:?fixture did not create a temporary directory}"
_ow_permission_test_cleanup() {
    if [ "$(id -u)" = 0 ]; then
        ow_fixture_done
    elif command -v sudo >/dev/null 2>&1; then
        sudo -n rm -rf "$_OW_PERMISSION_TEST_TMP"
    else
        ow_fixture_done
    fi
}
trap _ow_permission_test_cleanup EXIT INT TERM

AD="$REPO/platform/openwrt"
WS_USER=nobody
export WS_USER
. "$AD/paths.sh"
. "$AD/env.sh"
. "$AD/state.sh"

mkdir -p "$Z2K_STATE" "$Z2K_TMP" || exit 1
chmod 755 "$T" "$Z2K_ETC" "$Z2K_TMP" || exit 1
chmod 755 "$Z2K_STATE" || exit 1
_root_state_call() {
    _action="$1"
    if [ "$(id -u)" = 0 ]; then
        "$_action"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -n env \
            WS_USER="$WS_USER" Z2K_ETC="$Z2K_ETC" Z2K_STATE="$Z2K_STATE" \
            Z2K_TMP="$Z2K_TMP" Z2K_AUTOCIRCULAR_DIR="$Z2K_AUTOCIRCULAR_DIR" \
            Z2K_AUTOCIRCULAR_FALLBACK_DIR="$Z2K_AUTOCIRCULAR_FALLBACK_DIR" \
            Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE="$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE" \
            Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE="$Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE" \
            Z2K_ZAPRET2_RUNTIME="$Z2K_ZAPRET2_RUNTIME" STATE_FILE="$STATE_FILE" \
            STATE_FILE_FALLBACK="$STATE_FILE_FALLBACK" \
            sh -c '. "$1"; "$2"' sh "$AD/state.sh" "$_action"
    else
        return 1
    fi
}
if [ "$(id -u)" = 0 ]; then
    chown root:root "$T" "$Z2K_ETC" "$Z2K_STATE" "$Z2K_TMP" || exit 1
elif command -v sudo >/dev/null 2>&1; then
    sudo -n chown root:root "$T" "$Z2K_ETC" "$Z2K_STATE" "$Z2K_TMP" || exit 1
fi
_parent_meta="$(stat -c '%a:%u:%g' "$Z2K_STATE" 2>/dev/null)"
assert_eq "общий каталог состояния root-owned" "0" "$(stat -c '%u' "$Z2K_STATE" 2>/dev/null)"

assert_eq "отдельный каталог autocircular" "$Z2K_ETC/autocircular" "$Z2K_AUTOCIRCULAR_DIR"
assert_eq "Lua и оболочка используют один файл" "$Z2K_AUTOCIRCULAR_DIR/state.tsv" "$STATE_FILE"
assert_eq "запасной файл живёт отдельно в tmpfs" \
    "$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE/z2k-autocircular-state.tsv" "$STATE_FILE_FALLBACK"

# Имитируем старые пути OpenWrt и переносим обе копии в новый постоянный файл.
_old_primary="$Z2K_STATE/state.tsv"
_old_fallback="$Z2K_TMP/z2k-autocircular-state.tsv"
_legacy_fallback="$T/legacy/z2k-autocircular-state.tsv"
Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE="$_legacy_fallback"
export Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE
mkdir -p "$(dirname "$_legacy_fallback")" || exit 1
printf '# прежний primary\nyt_tcp\tyoutube.com|4\t5\t1700000000\tfrozen\told.youtube.com\n' > "$_old_primary"
printf '# прежний fallback\nquic\tgooglevideo.com|4\t3\t1700000001\tauto\n' > "$_old_fallback"
printf 'rkn_tcp\tlegacy.example|4\t2\t1700000002\tauto\n' > "$_legacy_fallback"
chmod 640 "$_old_primary" "$_old_fallback" "$_legacy_fallback"

if _root_state_call z2k_ow_prepare_autocircular_storage; then _t_ok; else _t_bad "каталог autocircular подготовлен"; fi
if _root_state_call z2k_ow_migrate_autocircular_state; then _t_ok; else _t_bad "старое состояние перенесено"; fi

_tab="$(printf '\t')"
assert_contains "сохранён закреплённый YouTube" "$STATE_FILE" "yt_tcp${_tab}youtube.com|4${_tab}5${_tab}1700000000${_tab}frozen${_tab}old.youtube.com"
assert_contains "сохранён QUIC из старого fallback" "$STATE_FILE" "quic${_tab}googlevideo.com|4${_tab}3${_tab}1700000001${_tab}auto"
assert_contains "сохранён прежний запасной файл" "$STATE_FILE" "rkn_tcp${_tab}legacy.example|4${_tab}2${_tab}1700000002${_tab}auto"
_backup_dir="$Z2K_STATE/autocircular-migration-backup"
assert_file "резервная копия прежнего primary" "$_backup_dir/legacy-primary.tsv"
assert_file "резервная копия прежнего fallback" "$_backup_dir/legacy-tmp.tsv"
assert_eq "резервная копия недоступна nfqws2 на запись" "700" "$(stat -c '%a' "$_backup_dir" 2>/dev/null)"
assert_eq "каталог резервных копий остаётся root-owned" "0" "$(stat -c '%u' "$_backup_dir" 2>/dev/null)"
assert_eq "общий каталог state не менял права/владельца" "$_parent_meta" "$(stat -c '%a:%u:%g' "$Z2K_STATE" 2>/dev/null)"
assert_eq "новый каталог принадлежит WS_USER" "$(id -u "$WS_USER")" "$(stat -c '%u' "$Z2K_AUTOCIRCULAR_DIR" 2>/dev/null)"
assert_eq "файл стратегии принадлежит WS_USER" "$(id -u "$WS_USER")" "$(stat -c '%u' "$STATE_FILE" 2>/dev/null)"

if command -v lua5.3 >/dev/null 2>&1; then
    _run_unprivileged() {
        if [ "$(id -u)" = 0 ] && command -v runuser >/dev/null 2>&1; then
            runuser -u "$WS_USER" -- "$@"
        elif command -v sudo >/dev/null 2>&1; then
            sudo -n -u "$WS_USER" -- "$@"
        else
            return 77
        fi
    }
    if _run_unprivileged env \
        Z2K_STATE_DIR_OVERRIDE="$Z2K_AUTOCIRCULAR_DIR" \
        Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE="$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE" \
        lua5.3 "$REPO/tests/openwrt/autocircular_permissions.lua" write; then
        _t_ok
        assert_contains "nfqws2 записал новую стратегию в primary" "$STATE_FILE" \
            "yt_tcp${_tab}youtube.com${_tab}7"
    else
        _t_bad "nfqws2-пользователь записал новую стратегию"
    fi
    if _run_unprivileged env \
        Z2K_STATE_DIR_OVERRIDE="$Z2K_AUTOCIRCULAR_DIR" \
        Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE="$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE" \
        lua5.3 "$REPO/tests/openwrt/autocircular_permissions.lua" restore; then
        _t_ok
    else
        _t_bad "новая стратегия восстановилась после перезапуска Lua"
    fi
else
    echo "SKIP[ow-autocircular-permissions]: нет lua5.3" >&2
fi

# Проверяем настоящий GET /state с OpenWrt-картой путей, а не чтение файла в тесте.
Z2K_PLATFORM=openwrt Z2K_ROOT="$Z2K_ROOT" Z2K_ETC="$Z2K_ETC" \
    Z2K_TMP="$Z2K_TMP" WS_USER="$WS_USER" \
    HTTP_HOST=192.168.1.1 HTTP_SEC_FETCH_SITE=same-origin \
    REQUEST_METHOD=GET PATH_INFO=/state \
    sh "$REPO/webpanel/cgi/api.sh" 2>/dev/null | tail -1 > "$T/api.json"
assert_contains "GET /state показывает запись из нового каталога" \
    "$T/api.json" '"host":"youtube.com","strategy":"7"'

# Корневой процесс не должен проходить по ссылке из каталога, доступного демону.
_root_target="$T/root-owned-target"
printf 'не менять\n' > "$_root_target"
rm -f "$STATE_FILE"
ln -s "$_root_target" "$STATE_FILE" || exit 1
if _root_state_call z2k_ow_prepare_autocircular_storage; then
    _t_bad "подготовка состояния отклоняет ссылку на root-owned файл"
else
    _t_ok
fi
assert_eq "цель ссылки не меняет владельца" "0" "$(stat -c '%u' "$_root_target" 2>/dev/null)"
assert_eq "цель ссылки не меняет содержимое" 'не менять' "$(cat "$_root_target" 2>/dev/null)"

_t_done
