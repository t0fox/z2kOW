#!/bin/sh
# platform/openwrt/reinstall.sh - Stage 7: adapter API gate + full payload reinstall.
#
# Package-owned platform layer; common (lib/auto_update.sh) НЕ меняется —
# используются только существующие примитивы: verified fetch манифеста,
# snapshot/rollback, converge download+lay, steps (доставленным кодом),
# meta/tag writers. Сорсится из platform/openwrt/update.sh после common libs.
#
#   z2k_ow_adapter_gate <apply|check> — API-гейт ДО любой payload mutation.
#   z2k_ow_payload_reinstall <tag> <reset> — исполнитель для
#     Z2K_AU_REINSTALL_EXECUTOR (зовёт au_apply_reinstall после verified fetch).

# --- adapter API -------------------------------------------------------------
# Source of truth в пакете: package/openwrt/ADAPTER_API. В payload лежит
# /usr/lib/z2k/share/adapter.api (ставит Makefile; updater/installer/
# reinstall его НИКОГДА не перезаписывают — иначе детект «пакет слишком
# стар» сломался бы первым же обновлением).

# z2k_ow_adapter_api_installed — установленный API (stdout). Нет файла
# (pre-API пакет) = API 1. Битый файл — fail closed (версию доказать нечем).
z2k_ow_adapter_api_installed() {
    local _f="${Z2K_ROOT:-/usr/lib/z2k}/share/adapter.api" _n _v
    if [ ! -f "$_f" ]; then printf '1\n'; return 0; fi
    _n=$(grep -cE '^[[:space:]]*[0-9]+[[:space:]]*$' "$_f" 2>/dev/null)
    [ "${_n:-0}" = "1" ] || {
        echo "z2k-openwrt: adapter.api не содержит ровно одну версию: $_f" >&2
        return 1
    }
    _v=$(grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' "$_f" 2>/dev/null | tr -d ' \t\r\n')
    case "$_v" in
        ''|*[!0-9]*) echo "z2k-openwrt: adapter.api бит: $_f" >&2; return 1 ;;
    esac
    [ "$_v" -ge 1 ] 2>/dev/null && [ "$_v" -le 999 ] 2>/dev/null || {
        echo "z2k-openwrt: adapter.api вне диапазона 1..999: $_v" >&2
        return 1
    }
    printf '%s\n' "$_v"
    return 0
}

# z2k_ow_manifest_api_min <entry-json> — требование записи (stdout).
# Поле openwrt_adapter_api_min: quoted string или bare number (читаем оба —
# формат фиксируем строкой, но чужую сборку с числом не валим).
# Отсутствие поля = 1 (backward-compatible optional field). Поле есть, но не
# целое 1..999 — ПУСТО + rc 1 (fail closed: окно с битым требованием
# применять нельзя).
z2k_ow_manifest_api_min() {
    local _v
    case "$1" in
        *'"openwrt_adapter_api_min"'*) ;;
        *) printf '1\n'; return 0 ;;
    esac
    _v=$(printf '%s' "$1" \
        | sed -n 's/.*"openwrt_adapter_api_min"[[:space:]]*:[[:space:]]*"*\([0-9][0-9]*\)"*[[:space:]]*[,}].*/\1/p' \
        | head -1)
    case "$_v" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$_v" -ge 1 ] 2>/dev/null && [ "$_v" -le 999 ] 2>/dev/null || return 1
    printf '%s\n' "$_v"
    return 0
}

# z2k_ow_manifest_api_required <manifest> <installed-tag> — max требования
# окна обновления (stdout). Незнакомый tag — окно = вся история (как
# au_history_entries_after: консервативно в сторону отказа, не разрешения).
z2k_ow_manifest_api_required() {
    local _m="$1" _tag="$2" _max=1 _e _need _entries
    [ -f "$_m" ] || return 1
    _entries=$(au_history_entries_after "$_m" "$_tag" 2>/dev/null)
    while IFS= read -r _e; do
        [ -n "$_e" ] || continue
        _need=$(z2k_ow_manifest_api_min "$_e") || return 1
        [ "$_need" -gt "$_max" ] 2>/dev/null && _max="$_need"
    done <<EOF
$_entries
EOF
    printf '%s\n' "$_max"
    return 0
}

# z2k_ow_adapter_gate <apply|check> — гейт ДО любой payload mutation.
# rc 0: proceed. apply + too old: сообщение + rc 1. check + too old:
# ADAPTER_UPDATE_REQUIRED + rc 2. Нет tag-файла (fresh/seed-path): skip, rc 0
# (свежая установка получает совместимый payload по построению seed, §10
# контракта; проверять тут не с чем). Провал fetch: rc 1 в обоих режимах
# (это НЕ вердикт про адаптер, а отсутствие данных).
z2k_ow_adapter_gate() {
    local _action="${1:-apply}" _tagfile _tag _req _inst
    _tagfile="${Z2K_AU_INSTALLED_TAG_FILE:-${Z2K_STATE:-/etc/z2k/state}/installed-tag}"
    if [ ! -f "$_tagfile" ]; then return 0; fi
    _tag=$(tr -d ' \t\r\n' < "$_tagfile" 2>/dev/null)
    [ -n "$_tag" ] || return 0
    au_fetch_manifest || {
        au_log "adapter-gate: манифест не получен — без данных не решаю"
        return 1
    }
    _req=$(z2k_ow_manifest_api_required "$Z2K_AU_TMP_DIR/UPDATES.json" "$_tag") || {
        au_log "adapter-gate: битое требование API в манифесте — fail closed"
        return 1
    }
    _inst=$(z2k_ow_adapter_api_installed) || {
        au_log "adapter-gate: версия адаптера нечитаема — fail closed"
        return 1
    }
    if [ "$_req" -le "$_inst" ] 2>/dev/null; then return 0; fi
    au_log "adapter-gate: манифест требует adapter API $_req, установлен $_inst — нужен upgrade пакета, payload нетронут"
    if [ "$_action" = "check" ]; then
        echo "ADAPTER_UPDATE_REQUIRED (нужен adapter API $_req, установлен $_inst: обновите пакет z2k-adapter, затем повторите)"
        return 2
    fi
    echo "adapter package upgrade required: manifest needs adapter API $_req, installed $_inst — обновите пакет z2k-adapter (apk add z2k-adapter), payload нетронут" >&2
    return 1
}

# Converge an initialized updater-owned panel when a newer package carries an
# embedded CI snapshot. This is not a second updater: manifest resolution,
# immutable ref selection, hash verification, atomic delivery, rollback and
# metadata writes are delegated to the existing common/reinstall path.
# A production package has no snapshot pair and therefore fails closed rather
# than extracting seed.tar.gz over executable panel files.
z2k_ow_panel_payload_sync() {
    local _tagfile="${Z2K_AU_INSTALLED_TAG_FILE:-${Z2K_STATE:-/etc/z2k/state}/installed-tag}"
    local _tag _mrc=0
    z2k_ow_panel_payload_compatible 2>/dev/null && return 0
    [ -f "${Z2K_PAYLOAD_MARKER:-${Z2K_ETC:-/etc/z2k}/.payload-initialized}" ] || {
        echo "z2k-openwrt: PANEL_PAYLOAD_MISMATCH: initialized payload marker is missing" >&2
        return 1
    }
    command -v z2k_platform_fetch_manifest >/dev/null 2>&1 || {
        echo "z2k-openwrt: PANEL_PAYLOAD_MISMATCH: manifest authority is unavailable" >&2
        return 1
    }
    z2k_platform_fetch_manifest || _mrc=$?
    if [ "$_mrc" != "0" ] || [ "${Z2K_OW_MANIFEST_MODE:-}" != "snapshot" ]; then
        echo "z2k-openwrt: PANEL_PAYLOAD_MISMATCH: this APK has no usable CI snapshot; signed production updater delivery is required" >&2
        return 1
    fi
    _tag=$(tr -d ' \t\r\n' < "$_tagfile" 2>/dev/null)
    [ -n "$_tag" ] || {
        echo "z2k-openwrt: PANEL_PAYLOAD_MISMATCH: installed payload tag is missing" >&2
        return 1
    }
    au_log "panel payload mismatch: converging updater-owned payload from embedded CI snapshot ref ${Z2K_AU_TARGET_REF}"
    z2k_ow_payload_reinstall "$_tag" "" || {
        echo "z2k-openwrt: PANEL_PAYLOAD_MISMATCH: verified snapshot delivery failed; payload was rolled back or marked dirty" >&2
        return 1
    }
    z2k_ow_panel_payload_compatible || {
        echo "z2k-openwrt: PANEL_PAYLOAD_MISMATCH: verified delivery completed but executable panel contract is still stale" >&2
        return 1
    }
    return 0
}

# --- full payload reinstall --------------------------------------------------
# Исполнитель для Z2K_AU_REINSTALL_EXECUTOR. Контекст вызова (au_apply_reinstall):
# манифест уже verified+fetched ($Z2K_AU_TMP_DIR/UPDATES.json), lock держится
# вызывающим, tag/meta двигает ТОЛЬКО этот код и только в конце.
#
# Порядок (контракт §9): API re-check → ref pin → plan=ALL updater-owned →
# snapshot → download ALL → verify ALL → replace → steps (доставленным
# кодом) → prune → meta → tag LAST. Ошибка до tag: rollback, старые
# payload/meta/tag. Crash: files→meta→tag (см. контракт §9).

# z2k_ow_reinstall_dest_ok <repo-path> <dest> — 0 если dest разрешён для
# payload-перезаписи: под /usr/lib/z2k/, кроме package-owned
# share/seed.tar.gz, share/adapter.api и share/panel.api; плюс merge-цель extra-domains
# (её пишет au_merge_extra_domains 3-way-merge'ом, не blind-overwrite).
z2k_ow_reinstall_dest_ok() {
    # Корни — ЖИВЫЕ ($Z2K_ROOT/$Z2K_ETC), не литералы: тесты релоцируют
    # production-абсолюты в sysroot, в проде значения те же самые.
    local _root="${Z2K_ROOT:-/usr/lib/z2k}" _etc="${Z2K_ETC:-/etc/z2k}"
    case "$2" in
        "$_root"/share/seed.tar.gz|"$_root"/share/adapter.api|"$_root"/share/panel.api)
            return 1 ;;
        "$_root"/*)
            return 0 ;;
        "$_etc"/user-lists/extra-domains.txt)
            [ "$1" = "files/lists/extra-domains.txt" ] && return 0
            return 1 ;;
        *)
            return 1 ;;
    esac
}

# z2k_ow_payload_reinstall <target_tag> <reset_state>
z2k_ow_payload_reinstall() {
    local _tag="$1" _reset_arg="${2:-}"
    local _manifest="$Z2K_AU_TMP_DIR/UPDATES.json"
    [ -n "$_tag" ] || { au_log "reinstall: пустой target_tag"; return 1; }
    [ -f "$_manifest" ] || { au_log "reinstall: нет манифеста $_manifest"; return 1; }

    # 1. API re-check (defense in depth: executor могут позвать и иначе).
    local _tagfile _installed _req _inst
    _tagfile="${Z2K_AU_INSTALLED_TAG_FILE:-${Z2K_STATE:-/etc/z2k/state}/installed-tag}"
    _installed=$(tr -d ' \t\r\n' < "$_tagfile" 2>/dev/null)
    [ -n "$_installed" ] || { au_log "reinstall: нет installed tag — не с чем сравнить окно"; return 1; }
    _req=$(z2k_ow_manifest_api_required "$_manifest" "$_installed") || {
        au_log "reinstall: битое требование API — fail closed"; return 1; }
    _inst=$(z2k_ow_adapter_api_installed) || {
        au_log "reinstall: версия адаптера нечитаема — fail closed"; return 1; }
    if [ "$_req" -gt "$_inst" ] 2>/dev/null; then
        au_log "reinstall: нужен adapter API $_req, установлен $_inst — сначала upgrade пакета, payload нетронут"
        return 1
    fi

    # 2. ref pin (как converge): всё из одного объявленного среза.
    Z2K_AU_TARGET_REF=$(au_manifest_ref "$_manifest" "$_tag")
    export Z2K_AU_TARGET_REF
    [ -n "$Z2K_AU_TARGET_REF" ] \
        && au_log "reinstall: файлы тянем по неизменяемой ссылке $Z2K_AU_TARGET_REF" \
        || au_log "reinstall: в манифесте нет ref для $_tag — тянем с ветки (старый манифест)"

    # 3. plan = ВСЕ ключи install_map (полная переустановка, не дельта).
    # Граница блока — по "files_sha256" (порядок ключей несущий, генератор
    # его держит): иначе changed_files из history загрязнили бы план.
    # Ключ без sha в files_sha256 — отказ целиком: reinstall обязан verify ALL,
    # безэталонная доставка здесь запрещена (у converge такой строгости нет —
    # там эталон может отсутствовать у старых манифестов).
    local _keysf="$Z2K_AU_TMP_DIR/reinstall.keys" _planf="$Z2K_AU_TMP_DIR/reinstall.plan"
    local _pairsf="$Z2K_AU_TMP_DIR/reinstall.pairs"
    sed -n '/"install_map"[[:space:]]*:/,/"files_sha256"[[:space:]]*:/p' "$_manifest" 2>/dev/null \
        | sed '$d' \
        | grep -oE '"[^"]+"[[:space:]]*:[[:space:]]*\[' 2>/dev/null \
        | sed 's/^"//; s/"[[:space:]]*:[[:space:]]*\[$//' > "$_keysf" 2>/dev/null
    [ -s "$_keysf" ] || { au_log "reinstall: в манифесте нет install_map-ключей"; return 1; }
    au_targets_bulk "$_manifest" "$_keysf" > "$_pairsf" 2>/dev/null
    local _bad="" _k _d _sha _nokeys=""
    while IFS="$(printf '\t')" read -r _k _d; do
        [ -n "$_k" ] && [ -n "$_d" ] || continue
        if ! z2k_ow_reinstall_dest_ok "$_k" "$_d"; then
            _bad="$_bad $_k->$_d"
        fi
    done < "$_pairsf"
    if [ -n "$_bad" ]; then
        au_log "reinstall: ОТКАЗ: цели вне updater-owned:$_bad (PACKAGE ∩ UPDATER обязан быть пуст)"
        return 1
    fi
    # Каждый ключ плана обязан иметь sha (verify ALL) и хотя бы одну цель.
    while IFS= read -r _k; do
        [ -n "$_k" ] || continue
        _sha=$(au_manifest_file_sha "$_manifest" "$_k" 2>/dev/null)
        if [ -z "$_sha" ]; then
            au_log "reinstall: ОТКАЗ: у $_k нет sha256 в манифесте — безэталонная доставка запрещена"
            return 1
        fi
        grep -q "^$(printf '%s' "$_k" | sed 's/[][\.*^$/]/\\&/g')$(printf '\t')" "$_pairsf" 2>/dev/null || \
            _nokeys="$_nokeys $_k"
    done < "$_keysf"
    if [ -n "$_nokeys" ]; then
        au_log "reinstall: ОТКАЗ: ключи без целей в install_map:$_nokeys"
        return 1
    fi
    cp -f "$_keysf" "$_planf"

    # 4. snapshot текущих целей (откат — только на ошибке, НЕ на crash:
    # crash лечит frozen seed_ensure по marker/partial — см. контракт §9).
    au_log "reinstall: файлов в плане: $(awk 'END {print NR}' "$_planf" 2>/dev/null)"
    au_snapshot_for_patch $(tr '\n' ' ' < "$_planf" 2>/dev/null) || {
        au_log "reinstall: снимок не снялся — обновление отменено"; return 1; }

    # 5. доставка: download ALL → verify ALL → atomic lay (converge-примитив;
    # внутри: extra-domains идёт 3-way merge, НЕ blind-overwrite).
    if ! au_converge_apply "$_manifest" "$_planf"; then
        au_log "reinstall: доставка не удалась — откат"
        au_rollback_patch || au_mark_dirty_tree "$_installed" "$_tag"
        return 1
    fi

    # 6. шаги окном обновления, ДОСТАВЛЕННЫМ кодом (урок p-67.9 — как converge).
    # Путь — через Z2K_ROOT (openwrt payload root; ZAPRET2_DIR здесь равен
    # ему же, но его /opt-дефолт триггерит forbidden-guard и врёт читателю).
    local _tags _e _full="" _reset="" _steps _sh _steps_h="" _rc=0
    local _ac_self="${Z2K_ROOT:-/usr/lib/z2k}/lib/auto_update.sh"
    _tags=$(au_history_entries_after "$_manifest" "$_installed" 2>/dev/null \
        | sed -n 's/.*"v"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    for _t2 in $_tags; do
        _e=$(grep "^[[:space:]]*{\"v\": \"$_t2\"" "$_manifest" 2>/dev/null | head -1)
        [ -n "$(au_entry_bool "$_e" full_install 2>/dev/null)" ] && _full=1
        [ "$(au_entry_bool "$_e" reset_state 2>/dev/null)" = "true" ] && _reset=1
    done
    [ "$_reset_arg" = "reset_state" ] && _reset=1
    # shellcheck disable=SC2086
    _steps=$( { au_steps_union "$_manifest" $_tags
                [ -n "$_reset" ] && echo reset-state; } | au_steps_ordered | tr '\n' ' ')
    for _sh in $_steps; do _steps_h="$_steps_h, $(au_step_human "$_sh" 2>/dev/null || printf '%s' "$_sh")"; done
    [ -n "$_steps" ] \
        && au_log "reinstall: после доставки:${_steps_h#, }" \
        || au_log "reinstall: после доставки делать ничего не нужно"
    if [ -f "$_ac_self" ] && sh -n "$_ac_self" 2>/dev/null; then
        au_log "reinstall: шаги исполняет доставленный код ($_ac_self)"
        # shellcheck source=/dev/null
        # shellcheck disable=SC2086
        ( . "$_ac_self" >/dev/null 2>&1; au_run_steps $_steps ) || _rc=$?
    else
        au_log "reinstall: доставленный auto_update.sh не разбирается — шаги идут прежним кодом"
        # shellcheck disable=SC2086
        au_run_steps $_steps || _rc=$?
    fi
    if [ "$_rc" != "0" ]; then
        au_log "reinstall: шаг не удался (код $_rc) — откат"
        au_rollback_patch || au_mark_dirty_tree "$_installed" "$_tag"
        return 1
    fi
    [ -n "$_full" ] && au_log "reinstall: окно содержало full_install-флаг (информационно: мы и есть переустановка)"

    # 7. prune + meta + tag LAST (порядок files → meta → tag).
    au_prune_orphans
    if ! au_write_payload_meta "$_tag"; then
        au_log "reinstall: НЕ записалась payload.meta — откат, отметку не двигаем"
        au_rollback_patch || au_mark_dirty_tree "$_installed" "$_tag"
        return 1
    fi
    if ! au_write_installed_tag "$_tag"; then
        au_log "reinstall: НЕ записался installed-tag — откат"
        au_rollback_patch || au_mark_dirty_tree "$_installed" "$_tag"
        return 1
    fi
    au_log "reinstall выполнен: $_installed -> $_tag"
    return 0
}
