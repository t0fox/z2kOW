#!/bin/sh
# tests/openwrt/test_ow_drift.sh - §9: upstream drift guard.
# Моделирует "чистый baseline + адаптер" и проверяет:
#   1. все openwrt-назначения — под разрешёнными корнями;
#   2. keenetic-доставляемый файл без openwrt-маппинга — только из явного
#      OPENWRT_EXCLUDED с причиной (новый upstream-файл без маппинга = FAIL,
#      а не skip);
#   3. package/updater-конфликтов нет (перекрёстная проверка с ownership.map);
#   4. seed покрывает весь updater-payload (что упустил make-seed = FAIL).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-drift"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/release_map.sh" || { echo "FAIL[ow-drift]: release_map" >&2; exit 1; }

# Keenetic-доставляемые классы без openwrt-назначения. Формат "glob|причина".
# Новый upstream-файл, не подпадающий ни под что здесь, роняет тест: молча
# терять доставку запрещено (тогда добавляем либо маппинг, либо строку сюда).
OPENWRT_EXCLUDED='
UPDATES.json|манифест возит установщик/апдейтер отдельно, не раскладка
z2k.sh|точка входа keenetic-установки (opkg вместо неё на openwrt)
files/000-zapret2.sh|NDM netfilter.d хук (nft на openwrt владеет zapret2)
files/S99zapret2.new|Keenetic init (openwrt: /etc/init.d/z2k из пакета)
files/init.d/S*|Keenetic S-сервисы (TG/RT/WARP/detect/scheduler — будущие слои)
files/ndm/*|NDM-хуки (redirect/deoffload/watchdog — будущие слои)
files/z2k-*.sh|Keenetic service-скрипты (scheduler/diag/warp/... — будущие слои)
files/z2k-warp-list-filter.awk|OpenWrt helper поставляется адаптер-пакетом; updater не владеет package-owned файлом
webpanel/*|вебпанель целиком — будущий слой (out of scope этапа)
lib/install.sh|Keenetic-установщик (openwrt: opkg + bootstrap)
lib/menu.sh|Keenetic-меню (не доставляется и не исполняется на openwrt)
'

_excluded() {
    # $1 — repo-path; 0 если покрыт OPENWRT_EXCLUDED
    local _pat _rest="$OPENWRT_EXCLUDED" _line
    while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        _pat="${_line%%|*}"
        # Паттерны НАМЕРЕННО globs (см. OPENWRT_EXCLUDED выше:
        # files/init.d/S*, files/ndm/*); кавычки превратили бы их в литералы.
        # shellcheck disable=SC2254
        case "$1" in
            $_pat) return 0 ;;
        esac
    done <<EOF
$_rest
EOF
    return 1
}

_filelist="$(mktemp)" || exit 1
_seedlist="$(mktemp)" || exit 1
trap 'rm -f "$_filelist" "$_seedlist"' EXIT INT TERM
( cd "$REPO" && git ls-files --cached --others --exclude-standard ) >"$_filelist" 2>/dev/null

_n_ow=0; _bad_root=""; _bad_lost=""; _bad_seed=""
# Явный sh: .sh в индексе лежат 100644 (Windows-наследие) — прямой запуск
# работает только там, где FS рисует fake +x (локальный drvfs), а в честном
# Linux-чекауте (CI) падает Permission denied с пустым seedlist.
sh "$REPO/package/openwrt/make-seed.sh" --list "$REPO" 2>/dev/null | awk -F'\t' '{print $1}' \
    | LC_ALL=C sort -u >"$_seedlist"
while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    _k="$(ZAPRET2_DIR=/opt/zapret2 Z2K_PLATFORM=keenetic z2k_install_paths "$_f" 2>/dev/null)"
    _o="$(Z2K_PLATFORM=openwrt z2k_install_paths "$_f" 2>/dev/null)"
    if [ -n "$_o" ]; then
        _n_ow=$((_n_ow + 1))
        # 1. корни
        printf '%s\n' "$_o" | grep -qvE '^/(usr/lib/z2k|etc)(/|$)' \
            && _bad_root="$_bad_root $_f"
        # 4. seed покрывает (кроме package-owned — их ставит Makefile напрямую;
        #    список package-owned — из ownership.map)
        _in_seed=0; _is_pkg=0
        grep -qxF "$_f" "$_seedlist" && _in_seed=1
        while IFS= read -r _d; do
            grep -qxF "$_d package" "$REPO/package/openwrt/ownership.map" 2>/dev/null \
                && _is_pkg=1
        done <<EOF2
$_o
EOF2
        { [ "$_in_seed" = "1" ] || [ "$_is_pkg" = "1" ]; } \
            || _bad_seed="$_bad_seed $_f"
    elif [ -n "$_k" ]; then
        # 2. keenetic-доставляемый без openwrt-назначения — только из списка
        _excluded "$_f" || _bad_lost="$_bad_lost $_f"
    fi
done <"$_filelist"

# OpenWrt-payload осознанно мал (без webpanel/service-скриптов): lib + lua +
# fake + lists + manifests + validator + etc. Порог — санитарный минимум,
# точные обязательные deliverables держит test_ow_release_map.
[ "$_n_ow" -ge 40 ] && _t_ok || _t_bad "openwrt-доставляемых мало: $_n_ow"
[ -z "$_bad_root" ] && _t_ok || _t_bad "назначения вне корней:$_bad_root"
[ -z "$_bad_lost" ] && _t_ok || _t_bad "молча теряются (нет маппинга и не в EXCLUDED):$_bad_lost"
[ -z "$_bad_seed" ] && _t_ok || _t_bad "вне seed и не package-owned:$_bad_seed"

# 3. конфликты — перекрёстно с ownership-тестом (здесь короткая форма)
_conf=""
while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    Z2K_PLATFORM=openwrt z2k_install_paths "$_f" 2>/dev/null | while IFS= read -r _d; do
        [ -n "$_d" ] || continue
        if grep -qxF "$_d package" "$REPO/package/openwrt/ownership.map" 2>/dev/null; then
            printf 'CONFLICT %s\n' "$_f->$_d"
        fi
    done
done <"$_filelist" >"$_filelist.conflicts" 2>/dev/null
[ -s "$_filelist.conflicts" ] && _conf="$(cat "$_filelist.conflicts")"
rm -f "$_filelist.conflicts"
[ -z "$_conf" ] && _t_ok || _t_bad "PACKAGE_UPDATER_OWNERSHIP_CONFLICT: $_conf"

_t_done
