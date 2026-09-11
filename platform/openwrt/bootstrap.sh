#!/bin/sh
# platform/openwrt/bootstrap.sh - идемпотентный bootstrap persistent-состояния.
#
# Вызывается из procd-сервиса перед генерацией (и из package postinst).
# НЕ пишет в payload ($Z2K_ROOT read-only): только /etc/z2k и /tmp/z2k.
#
# Маркер инициализации payload и seed-tarball. Model A: seed — ТОЛЬКО
# bootstrap для пустой установки, никогда — upgrade payload. Правило см.
# z2k_ow_seed_ensure ниже.
Z2K_PAYLOAD_MARKER="${Z2K_PAYLOAD_MARKER:-$Z2K_ETC/.payload-initialized}"
Z2K_SEED_TARBALL="${Z2K_SEED_TARBALL:-$Z2K_ROOT/share/seed.tar.gz}"
# Корень извлечения seed ("/" в проде; тестам — sysroot).
Z2K_SEED_DEST="${Z2K_SEED_DEST:-/}"
# Минимальный обязательный payload (относительно $Z2K_ROOT): marker ставится
# только когда всё это на месте, и проверяется при каждом ensure.
# share/seed.meta — тоже required: без него tag установить не из чего.
Z2K_PAYLOAD_REQUIRED="${Z2K_PAYLOAD_REQUIRED:-lib/utils.sh lib/config_official.sh lib/strategies.sh lua/z2k-alert.lua lua/z2k-state-persist.lua strats_new2.txt extra_strats/TCP/RKN/Strategy.txt share/seed.meta}"
#
# Мосты, которые создаёт z2k_ow_bootstrap (обоснование — в contract):
#   $Z2K_ROOT/config → /etc/z2k/config (чтения ${ZAPRET2_DIR}/config внутри
#     generate_*; запись идёт явным путём мимо симлинка, он в безопасности);
#   lists/whitelist.txt → /etc/z2k/user-lists/whitelist.txt (user-owned);
#   lists/discovered-domains.txt → /etc/z2k/state/discovered-domains.txt
#     (публикации демона; генератор ссылается безусловно).
#
# Требует выставленных путей (env.sh).

z2k_ow_bootstrap() {
    # --- каталоги ---
    mkdir -p "$Z2K_ETC" "$Z2K_STATE" "$Z2K_USER_LISTS" "$Z2K_CONF_DIR" \
             "$Z2K_RUN" "$Z2K_LOCKS" "$Z2K_LOG" "$Z2K_DOWNLOADS" "$Z2K_GENERATED" \
        || return 1

    # --- канонический конфиг ---
    if [ ! -f "$Z2K_CONFIG" ]; then
        if [ -f "$Z2K_ROOT/share/config.default" ]; then
            cp -f "$Z2K_ROOT/share/config.default" "$Z2K_CONFIG" || return 1
        else
            echo "z2k-openwrt: нет ни $Z2K_CONFIG, ни дефолта" >&2
            return 1
        fi
    fi

    # --- мост supplementary-reads ---
    if [ ! -L "$Z2K_ROOT/config" ]; then
        [ -e "$Z2K_ROOT/config" ] && {
            echo "z2k-openwrt: $Z2K_ROOT/config существует и не симлинк — отказываюсь" >&2
            return 1
        }
        ln -s "$Z2K_CONFIG" "$Z2K_ROOT/config" || return 1
    fi

    # --- stateful-члены lists (пустые плейсхолдеры по образцу install.sh) ---
    if [ ! -L "$Z2K_LISTS_DIR/whitelist.txt" ]; then
        [ -e "$Z2K_LISTS_DIR/whitelist.txt" ] && {
            echo "z2k-openwrt: lists/whitelist.txt существует и не симлинк" >&2
            return 1
        }
        ln -s "$Z2K_USER_LISTS/whitelist.txt" "$Z2K_LISTS_DIR/whitelist.txt" || return 1
    fi
    if [ ! -L "$Z2K_LISTS_DIR/discovered-domains.txt" ]; then
        [ -e "$Z2K_LISTS_DIR/discovered-domains.txt" ] && {
            echo "z2k-openwrt: lists/discovered-domains.txt существует и не симлинк" >&2
            return 1
        }
        ln -s "$Z2K_STATE/discovered-domains.txt" "$Z2K_LISTS_DIR/discovered-domains.txt" || return 1
    fi
    for _f in "$Z2K_USER_LISTS/whitelist.txt" "$Z2K_STATE/discovered-domains.txt" \
             "$Z2K_STATE/tcp16_asn.txt" "$Z2K_STATE/tcp16_sni.txt"; do
        [ -e "$_f" ] || : > "$_f" || return 1
    done

    # Runtime-копия extra-domains сидируется shipped-базой (как install.sh на
    # Keenetic): пользователь правит файл, который видит, а 3-way merge
    # считает добавленные строки его собственными.
    if [ ! -e "$Z2K_USER_LISTS/extra-domains.txt" ]; then
        if [ -s "$Z2K_LISTS_DIR/extra-domains.txt" ]; then
            cp -f "$Z2K_LISTS_DIR/extra-domains.txt" "$Z2K_USER_LISTS/extra-domains.txt" || return 1
        else
            : > "$Z2K_USER_LISTS/extra-domains.txt" || return 1
        fi
    fi

    # --- Strategy.txt прематериализованы сборкой; отсутствие = fail-closed ---
    for _p in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
        [ -s "$Z2K_EXTRA_STRATS_DIR/$_p/Strategy.txt" ] || {
            echo "z2k-openwrt: нет $Z2K_EXTRA_STRATS_DIR/$_p/Strategy.txt (сборка не материализовала стратегии)" >&2
            return 1
        }
    done

    # --- fork-lua в runtime: только предупреждение (зависимость пакета) ---
    for _f in zapret-lib.lua zapret-antidpi.lua zapret-auto.lua; do
        if [ ! -f "$Z2K_ZAPRET2_RUNTIME/lua/$_f" ] && \
           [ ! -f "$Z2K_ZAPRET2_RUNTIME/lua/$_f.gz" ]; then
            echo "z2k-openwrt: предупреждение: нет $Z2K_ZAPRET2_RUNTIME/lua/$_f (поставьте zapret2 runtime)" >&2
        fi
    done
    return 0
}

# z2k_ow_payload_ok — 0, если весь Z2K_PAYLOAD_REQUIRED на месте и непуст.
z2k_ow_payload_ok() {
    local _r
    for _r in $Z2K_PAYLOAD_REQUIRED; do
        [ -s "$Z2K_ROOT/$_r" ] || return 1
    done
    return 0
}

# z2k_ow_payload_empty — 0, если от payload нет НИЧЕГО (ни одного required).
# Отличие empty от partial — load-bearing: empty = известные хорошие состояния
# (fresh, prerm-purge, sysupgrade-wipe) — seed content там правильный ответ;
# partial = неизвестное повреждение — seed content мог бы откатить updater-
# файлы под стоящим тегом (Scenario D), поэтому только громкий провал.
z2k_ow_payload_empty() {
    local _r
    for _r in $Z2K_PAYLOAD_REQUIRED; do
        [ -e "$Z2K_ROOT/$_r" ] && return 1
    done
    return 0
}

# z2k_ow_seed_write_tag — installed-tag из seed.meta, ТОЛЬКО если tag
# отсутствует/пуст. Формат — как au_write_installed_tag (printf + \n,
# mkdir, re-read verify): существующий tag НЕ трогаем никогда.
# Путь — Z2K_AU_INSTALLED_TAG_FILE с тем же дефолтом, что env.sh (postinst
# env.sh не сорсит — только paths.sh + этот файл).
z2k_ow_seed_write_tag() {
    local _tagfile="${Z2K_AU_INSTALLED_TAG_FILE:-$Z2K_STATE/installed-tag}"
    local _tag="" _cur=""
    [ -f "$_tagfile" ] && \
        _cur=$(tr -d '[:space:]' < "$_tagfile" 2>/dev/null)
    [ -n "$_cur" ] && return 0
    [ -f "$Z2K_ROOT/share/seed.meta" ] || {
        echo "z2k-openwrt: нет seed.meta — версию установить не из чего" >&2
        return 1
    }
    _tag=$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" 2>/dev/null | head -1 | tr -d '[:space:]')
    case "$_tag" in
        ''|*[!A-Za-z0-9._-]*) echo "z2k-openwrt: seed.meta без валидного tag" >&2; return 1 ;;
    esac
    mkdir -p "$(dirname "$_tagfile")" 2>/dev/null || return 1
    printf '%s\n' "$_tag" > "${_tagfile}.new.$$" 2>/dev/null || return 1
    mv -f "${_tagfile}.new.$$" "$_tagfile" 2>/dev/null || return 1
    _cur=$(tr -d '[:space:]' < "$_tagfile" 2>/dev/null)
    [ "$_cur" = "$_tag" ] || return 1
    return 0
}

# z2k_ow_seed_ensure — ЕДИНСТВЕННЫЙ законный писатель seed (зовёт postinst).
#
# Матрица (marker ПОСЛЕДНИМ всегда; marker ⇒ payload verified):
#   no marker + empty/non-ok payload -> extract -> bootstrap -> verify -> tag?=meta -> mark
#   no marker + payload ok .......... -> bootstrap -> verify -> tag?=meta -> mark (без extract)
#   marker + payload ok ............. -> bootstrap -> verify (upgrade: ничего не трогаем)
#   marker + payload empty .......... -> extract (prerm-purge/sysupgrade repair) ->
#                                        bootstrap -> verify (TAG PRESERVED — никакого отката версии)
#   marker + payload partial ........ -> ГРОМКИЙ провал без авто-recovery
#                                        (repair: руками чистка payload + удалить marker)
z2k_ow_seed_ensure() {
    # Извлекаем, только если payload НЕ цел И (нет marker ИЛИ payload пуст):
    # marker+empty = prerm-purge/sysupgrade repair (tag при этом PRESERVED —
    # никакого отката версии); marker+partial сюда не попадает (см. ниже).
    if ! z2k_ow_payload_ok && { [ ! -f "$Z2K_PAYLOAD_MARKER" ] || z2k_ow_payload_empty; }; then
        [ -f "$Z2K_SEED_TARBALL" ] || {
            echo "z2k-openwrt: нет seed $Z2K_SEED_TARBALL и payload пуст — нечем инициализировать" >&2
            return 1
        }
        tar -xzf "$Z2K_SEED_TARBALL" -C "$Z2K_SEED_DEST" || {
            echo "z2k-openwrt: извлечение seed не удалось — marker не ставлю" >&2
            return 1
        }
    fi
    z2k_ow_bootstrap || return 1
    if ! z2k_ow_payload_ok; then
        if [ -f "$Z2K_PAYLOAD_MARKER" ] && ! z2k_ow_payload_empty; then
            echo "z2k-openwrt: payload частичен при marker (partial, не empty) — авто-recovery запрещён, чините вручную" >&2
        else
            echo "z2k-openwrt: payload неполон — молчаливого success не будет" >&2
        fi
        return 1
    fi
    z2k_ow_seed_write_tag || return 1
    if [ ! -f "$Z2K_PAYLOAD_MARKER" ]; then
        : > "$Z2K_PAYLOAD_MARKER" || return 1
    fi
    return 0
}
