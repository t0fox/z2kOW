#!/bin/sh
# Единый путь установки полного проверенного релиза OpenWrt.

# Пока install_release работает, WebPanel показывает общий таймер. Записывать
# этапы в её журнал заданий, чтобы было видно медленную распаковку архива;
# команды CLI и cron сохраняют привычный вывод.
z2k_ow_install_progress() {
    [ -n "${Z2K_JOB_ID:-}" ] || return 0
    local _epoch
    _epoch=$(date +%s 2>/dev/null) || _epoch=
    case "$_epoch" in
        ''|*[!0-9]*) printf '%s\n' "$*" >&2 ;;
        *) printf '@z2k-ts:%s|%s\n' "$_epoch" "$*" >&2 ;;
    esac
}

z2k_ow_json_value() {
    _file="$1" _expr="$2"
    command -v jsonfilter >/dev/null 2>&1 || return 1
    jsonfilter -i "$_file" -e "@.$_expr" 2>/dev/null | head -n 1
}

z2k_ow_release_current() {
    _manifest="$1"
    . "${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}/manifest.sh" || return 1
    z2k_ow_manifest_release_ok "$_manifest" || return 1
    z2k_ow_json_value "$_manifest" current
}

z2k_ow_release_state_tag() {
    local _state="${1:-$(z2k_ow_path /etc/z2k/state/installed-release)}" _tag="" _record=""
    . "${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}/release_state.sh" || return 1
    if [ -e "$_state" ]; then
        _record=$(z2k_ow_release_state_read "$_state" 2>/dev/null) || {
            # Старое обновление сохраняло только тег. Такой формат нужен лишь
            # для однократной миграции; повреждённая запись не считается
            # установленной версией в статусе, интерфейсе и командах обновления.
            [ "$(wc -l < "$_state" 2>/dev/null | tr -d ' \t\r\n')" = 1 ] || return 0
            _tag=$(sed -n '1p' "$_state" | tr -d ' \t\r\n')
            printf '%s' "$_tag" | grep -Eq '^[pr]-[0-9]+(\.[0-9]+)+$' || return 0
            printf '%s\n' "$_tag"
            return 0
        }
        _tag=$(printf '%s\n' "$_record" | sed -n 's/^tag=//p' | head -1)
        [ -n "$_tag" ] && printf '%s\n' "$_tag"
        return 0
    fi
    # Читать старые маркеры только для миграции установленного z2kOW.
    # install_release удаляет их после успешной установки полного релиза.
    for _legacy in /opt/zapret2/.z2k-installed-tag \
        /etc/z2k/state/installed-tag /etc/z2k/state/product-tag; do
        _legacy="$(z2k_ow_path "$_legacy")"
        [ -r "$_legacy" ] || continue
        _tag="$(tr -d ' \t\r\n' < "$_legacy" 2>/dev/null)" || return 1
        [ -n "$_tag" ] && { printf '%s\n' "$_tag"; return 0; }
    done
    return 0
}

z2k_ow_release_state_seq() {
    local _state="${1:-$(z2k_ow_path /etc/z2k/state/installed-release)}" _record=""
    . "${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}/release_state.sh" || return 1
    _record=$(z2k_ow_release_state_read "$_state" 2>/dev/null) || return 0
    printf '%s\n' "$_record" | sed -n 's/^seq=//p' | head -1
}

z2k_ow_release_state_write() {
    local _state="$1" _manifest="$2" _tag _seq _tmp
    _tag="$(z2k_ow_json_value "$_manifest" current)" || return 1
    _seq="$(z2k_ow_json_value "$_manifest" seq)" || return 1
    printf '%s' "$_tag" | grep -Eq '^[pr]-[0-9]+(\.[0-9]+)+$' || return 1
    printf '%s' "$_seq" | grep -Eq '^[1-9][0-9]*$' || return 1
    mkdir -p "$(dirname "$_state")" || return 1
    _tmp="${_state}.z2k-new.$$"
    ( umask 077; printf 'tag=%s\nseq=%s\n' "$_tag" "$_seq" > "$_tmp" ) || {
        rm -f "$_tmp"
        return 1
    }
    chmod 600 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$_state" || { rm -f "$_tmp"; return 1; }
}

z2k_ow_legacy_packages_present() {
    command -v apk >/dev/null 2>&1 || return 1
    for _pkg in z2k-adapter z2k-webpanel z2k-zapret2-runtime z2k-warp-runtime; do
        apk info -e "$_pkg" >/dev/null 2>&1 && return 0
    done
    return 1
}

z2k_ow_release_decision() {
    _manifest="$1" _state="$2"
    _tag="$(z2k_ow_release_current "$_manifest")" || return 1
    _seq="$(z2k_ow_json_value "$_manifest" seq)" || return 1
    _installed="$(z2k_ow_release_state_tag "$_state")" || return 1
    if z2k_ow_legacy_packages_present; then
        # Мигрировать владение пакетами через полную установку релиза,
        # даже если старый маркер совпал с текущей версией.
        printf 'update %s\n' "$_tag"
        return 0
    fi
    if z2k_ow_relay_identity_migration_needed; then
        printf 'update %s\n' "$_tag"
        return 0
    fi
    if [ -z "$_installed" ]; then
        # Старую пакетную установку нужно провести через однократную миграцию.
        # Если маркера нет, безопасно синхронизировать состояние upstream,
        # не переустанавливая вслепую всю историю релизов.
        if z2k_ow_legacy_packages_present; then
            printf 'update %s\n' "$_tag"
        else
            printf 'resync %s\n' "$_tag"
        fi
        return 0
    fi
    case "$_installed" in *[!A-Za-z0-9._-]*) return 1 ;; esac
    if [ "$_installed" = "$_tag" ] && [ "$(z2k_ow_release_state_seq "$_state")" != "$_seq" ]; then
        # При изменении номера версии выполнить полную установку и проверку
        # состояния служб до замены единой записи о версии.
        printf 'update %s\n' "$_tag"
        return 0
    fi
    command -v au_decide >/dev/null 2>&1 || {
        echo "z2k-openwrt: механизм выбора upstream-релиза недоступен" >&2
        return 1
    }
    _decision="$(au_decide "$_installed" "$_manifest")" || return 1
    _action="$(printf '%s\n' "$_decision" | sed -n '1{s/[[:space:]].*$//;p;}')"
    case "$_action" in
        none) printf 'none %s\n' "$_tag" ;;
        patch|reinstall) printf 'update %s\n' "$_tag" ;;
        *) echo "z2k-openwrt: неверный результат выбора upstream-релиза" >&2; return 1 ;;
    esac
}

z2k_ow_path() {
    _p="$1"
    if [ -n "${Z2K_OW_SYSROOT:-}" ]; then
        printf '%s%s\n' "${Z2K_OW_SYSROOT%/}" "$_p"
    else
        printf '%s\n' "$_p"
    fi
}

z2k_ow_download() {
    _url="$1" _out="$2"
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 60 -O "$_out" "$_url"
    elif command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --show-error --connect-timeout 10 --max-time 180 -o "$_out" "$_url"
    else
        echo "z2k-openwrt: нужен HTTPS-загрузчик (wget или curl)" >&2
        return 1
    fi
}

z2k_ow_pkg_installed() {
    _pkg="$1"
    apk info -e "$_pkg" >/dev/null 2>&1
}

z2k_ow_pkg_files() {
    _pkg="$1"
    apk info --contents "$_pkg" 2>/dev/null
}

# Сохранить идентификатор relay при переносе из прежнего каталога payload
# в постоянное состояние OpenWrt. Здесь же хранится назначение маршрута,
# поэтому обновление /opt/zapret2 не удалит эти пользовательские данные.
z2k_ow_relay_identity_migration_needed() {
    local _legacy _state _state_root
    _legacy="$(z2k_ow_path "${Z2K_OW_LEGACY_RELAY_ID_FILE:-/opt/zapret2/.z2k-relay-id}")"
    _state_root="${Z2K_STATE:-${Z2K_ETC:-/etc/z2k}/state}"
    _state="$(z2k_ow_path "${Z2K_RELAY_ID_FILE:-$_state_root/relay-id.json}")"
    [ -f "$_legacy" ] && [ ! -f "$_state" ]
}

z2k_ow_migrate_relay_identity() {
    local _legacy _state _state_root _tmp
    _legacy="$(z2k_ow_path "${Z2K_OW_LEGACY_RELAY_ID_FILE:-/opt/zapret2/.z2k-relay-id}")"
    _state_root="${Z2K_STATE:-${Z2K_ETC:-/etc/z2k}/state}"
    _state="$(z2k_ow_path "${Z2K_RELAY_ID_FILE:-$_state_root/relay-id.json}")"
    [ -f "$_legacy" ] || return 0
    [ -f "$_state" ] && return 0
    mkdir -p "$(dirname "$_state")" || return 1
    _tmp="${_state}.migrate.$$"
    cp -p "$_legacy" "$_tmp" || { rm -f "$_tmp"; return 1; }
    chmod 600 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$_state" || { rm -f "$_tmp"; return 1; }
}

z2k_ow_legacy_path_allowed() {
    _legacy_path="${1#./}"
    _legacy_path="${_legacy_path#/}"
    case "$_legacy_path" in
        usr/lib/z2k|usr/lib/z2k/*|opt/zapret2|opt/zapret2/* \
        |usr/bin/z2kow|usr/sbin/install_release \
        |etc/init.d/z2k|etc/init.d/z2k-webpanel|etc/init.d/z2k-detect \
        |etc/hotplug.d/iface/90-z2k|etc/sysctl.d/99-z2k.conf \
        |usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft)
            return 0 ;;
        *) return 1 ;;
    esac
}

z2k_ow_pkg_remove_legacy() {
    _names="$1"
    [ -n "$_names" ] || return 0
    # Не позволять скриптам пакетов останавливать службы или удалять файлы,
    # которые передаются установщику полного набора файлов релиза.
    # shellcheck disable=SC2086
    apk del --no-scripts $_names
}

z2k_ow_legacy_migrate() {
    _legacy_root="${1:-$(z2k_ow_path /usr/lib/z2k)}"
    command -v apk >/dev/null 2>&1 || {
        echo "z2k-openwrt: нужен apk для системных зависимостей OpenWrt" >&2
        return 1
    }
    _names=""
    _legacy_key="$_legacy_root/share/z2k-feed.pem"
    _feed_dir="$(z2k_ow_path /etc/apk/repositories.d)"
    for _feed in "$_feed_dir"/*; do
        [ -f "$_feed" ] || continue
        if [ -L "$_feed" ]; then
            if grep -qiE 'z2kow|feed\.z2k\.example\.com' "$_feed"; then
                echo "z2k-openwrt: миграция остановлена: старый feed является символической ссылкой: $_feed" >&2
                return 1
            fi
            continue
        fi
    done
    _key="$(z2k_ow_path /etc/apk/keys/z2k-feed.pem)"
    _repositories="$(z2k_ow_path /etc/apk/repositories)"
    for _pkg in z2k-adapter z2k-webpanel z2k-zapret2-runtime z2k-warp-runtime; do
        if z2k_ow_pkg_installed "$_pkg"; then
            _contents="$(z2k_ow_pkg_files "$_pkg")" || {
                echo "z2k-openwrt: не удалось прочитать список файлов старого пакета $_pkg" >&2
                return 1
            }
            case "$_contents" in
                *www/cgi-bin/luci*|*www/luci-static*|*etc/config/uhttpd*)
                    echo "z2k-openwrt: миграция остановлена: пакет $_pkg владеет защищённым путём LuCI/uhttpd" >&2
                    return 1
                    ;;
            esac
            while IFS= read -r _owned_path; do
                [ -n "$_owned_path" ] || continue
                z2k_ow_legacy_path_allowed "$_owned_path" || {
                    echo "z2k-openwrt: миграция остановлена: пакет $_pkg владеет неизвестным путём $_owned_path" >&2
                    return 1
                }
            done <<EOF_OWNERSHIP
$_contents
EOF_OWNERSHIP
            _names="$_names $_pkg"
        fi
    done
    if [ -e "$_key" ] || [ -L "$_key" ]; then
        if [ ! -f "$_legacy_key" ] || ! cmp -s "$_legacy_key" "$_key"; then
            echo "z2k-openwrt: старый ключ feed не совпадает с установленным ключом z2kOW; миграция остановлена" >&2
            return 1
        fi
    fi

    apk add kmod-nft-queue kmod-tun kmod-nfnetlink-log conntrack openssl-util jsonfilter tcpdump-mini curl || {
        echo "z2k-openwrt: не удалось обеспечить системные зависимости OpenWrt" >&2
        return 1
    }
    # Панель запускает собственный lighttpd на настроенном порту. Скрипты
    # пакетов включают системный lighttpd, который занимает порт LuCI 80 и
    # отвечает 403 на /cgi-bin/luci; ставить только сервер и модули.
    apk add --no-scripts lighttpd lighttpd-mod-cgi lighttpd-mod-setenv lighttpd-mod-alias || {
        echo "z2k-openwrt: не удалось обеспечить системные зависимости OpenWrt" >&2
        return 1
    }
    z2k_ow_pkg_remove_legacy "$_names" || {
        echo "z2k-openwrt: не удалось удалить старое владение пакетами z2kOW" >&2
        return 1
    }

    for _feed in "$_feed_dir"/*; do
        [ -f "$_feed" ] || continue
        [ ! -L "$_feed" ] || continue
        _one="${_feed}.z2k.$$"
        awk 'tolower($0) !~ /github\.com\/t0fox\/z2kow\// && tolower($0) !~ /feed\.z2k\.example\.com\//' "$_feed" > "$_one" \
            || { rm -f "$_one"; return 1; }
        if grep -qiE 'z2kow|feed\.z2k\.example\.com' "$_one"; then
            echo "z2k-openwrt: в $_feed осталась неизвестная запись старого репозитория" >&2
            rm -f "$_one"
            return 1
        fi
        if [ ! -s "$_one" ] && grep -qiE 'z2kow|feed\.z2k\.example\.com' "$_feed"; then
            rm -f "$_feed" "$_one" || return 1
        else
            mv -f "$_one" "$_feed" || return 1
        fi
    done
    if [ -e "$_key" ] || [ -L "$_key" ]; then rm -f "$_key" || return 1; fi
    if [ -f "$_repositories" ]; then
        _repo_tmp="${_repositories}.z2k.$$"
        awk 'tolower($0) !~ /github\.com\/t0fox\/z2kow\// && tolower($0) !~ /feed\.z2k\.example\.com\//' "$_repositories" > "$_repo_tmp" \
            && mv -f "$_repo_tmp" "$_repositories" || { rm -f "$_repo_tmp"; return 1; }
        if grep -qiE 'z2kow|feed\.z2k\.example\.com' "$_repositories"; then
            echo "z2k-openwrt: осталась неизвестная запись старого репозитория; миграция остановлена" >&2
            return 1
        fi
    fi
    for _pkg in z2k-adapter z2k-webpanel z2k-zapret2-runtime z2k-warp-runtime; do
        if z2k_ow_pkg_installed "$_pkg"; then
            echo "z2k-openwrt: осталось старое владение пакетом: $_pkg" >&2
            return 1
        fi
    done
    return 0
}

z2k_ow_archive_entries_safe() {
    _entries="$1"
    awk '
        function safe_link(path, target, path_parts, path_count, depth, target_parts, target_count, i) {
            if (target == "" || target ~ /^\// || target ~ /\\/ || target ~ /\/\// \
                || target ~ /[[:space:][:cntrl:]]/) return 0
            path_count = split(path, path_parts, "/")
            depth = path_count - 1
            target_count = split(target, target_parts, "/")
            for (i = 1; i <= target_count; i++) {
                if (target_parts[i] == "" || target_parts[i] == ".") continue
                if (target_parts[i] == "..") {
                    if (depth == 0) return 0
                    depth--
                } else {
                    depth++
                }
            }
            return 1
        }
        {
            kind = substr($1, 1, 1)
            if (kind != "-" && kind != "d" && kind != "l") exit 1
            if (kind == "l") {
                if (NF < 3 || $(NF - 1) != "->") exit 1
                path = $(NF - 2)
                target = $NF
                if (!safe_link(path, target)) exit 1
            } else {
                path = $NF
            }
            if (path ~ /\/\//) exit 1
            sub(/\/$/, "", path)
            if (path == "" || path ~ /^\// || path ~ /[[:space:][:cntrl:]]/ \
                || path ~ /\\/ || path ~ /(^|\/)\.\.?($|\/)/) exit 1
            if (path == "www" || path ~ /^www\// || path == "etc/config/uhttpd" \
                || path == "etc/apk" || path ~ /^etc\/apk\// \
                || path ~ /(^|\/)[^/]+\.apk$/ || path == "packages.adb") exit 1
            count++
        }
        END { if (count == 0) exit 1 }
    ' "$_entries"
}

z2k_ow_archive_safe() {
    _archive="$1"
    _listing="${2:-${Z2K_TMP:-/tmp/z2k}/archive-list.$$}"
    _details="${_listing}.details"
    tar -tzf "$_archive" > "$_listing" 2>/dev/null || return 1
    [ -s "$_listing" ] || return 1
    while IFS= read -r _entry; do
        _entry=${_entry%/}
        case "$_entry" in
            ''|/*|../*|*/../*|*/..|..|*\\*|*" "*|*"	"*) return 1 ;;
            www|www/*|etc/config/uhttpd|etc/apk|etc/apk/*|*/*.apk|packages.adb) return 1 ;;
        esac
    done < "$_listing"
    tar -tvzf "$_archive" > "$_details" 2>/dev/null || return 1
    z2k_ow_archive_entries_safe "$_details" || return 1
    rm -f "$_details" || return 1
    grep -qx 'usr/lib/z2k/platform/openwrt/release.sh' "$_listing" \
        && grep -qx 'usr/sbin/install_release' "$_listing" \
        && grep -qx 'usr/bin/z2kow' "$_listing"
}

z2k_ow_owned_paths() {
    _owned="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}/owned-paths.txt"
    [ -r "$_owned" ] || return 1
    cat "$_owned"
}

z2k_ow_restore_paths() {
    _transaction="$1" _paths="$2" _transaction_id="$3"
    _failed=0 _format_v2=0
    grep -Fqx 'V|2' "$_transaction" 2>/dev/null && _format_v2=1
    # Сначала убедиться, что откат возможен для всех путей. Не менять часть
    # дерева, если для другого уже применённого пути пропала исходная копия.
    while IFS= read -r _rel; do
        [ -n "$_rel" ] || continue
        _dst="$(z2k_ow_path "$_rel")"
        _save="${_dst}.z2k-backup.${_transaction_id}"
        _had_original=0 _was_applied=0 _restore_started=0
        grep -Fqx "O|$_rel" "$_transaction" 2>/dev/null && _had_original=1
        grep -Fqx "I|$_rel" "$_transaction" 2>/dev/null && _was_applied=1
        grep -Fqx "R|$_rel" "$_transaction" 2>/dev/null && _restore_started=1
        if [ ! -e "$_save" ] && [ ! -L "$_save" ]; then
            if [ "$_had_original" = 1 ] \
                && { { [ "$_was_applied" = 1 ] && [ "$_restore_started" = 0 ]; } \
                    || { [ ! -e "$_dst" ] && [ ! -L "$_dst" ]; }; }; then
                echo "z2k-openwrt: отсутствует исходная резервная копия $_rel" >&2
                return 1
            fi
            if [ "$_had_original" = 0 ] && [ "$_was_applied" = 1 ] \
                && [ "$_format_v2" != 1 ] && [ "$_restore_started" = 0 ]; then
                echo "z2k-openwrt: старый формат транзакции не подтверждает откат для $_rel" >&2
                return 1
            fi
        fi
    done < "$_paths"
    while IFS= read -r _rel; do
        [ -n "$_rel" ] || continue
        _dst="$(z2k_ow_path "$_rel")"
        _save="${_dst}.z2k-backup.${_transaction_id}"
        _had_original=0 _was_applied=0 _restore_started=0
        grep -Fqx "O|$_rel" "$_transaction" 2>/dev/null && _had_original=1
        grep -Fqx "I|$_rel" "$_transaction" 2>/dev/null && _was_applied=1
        grep -Fqx "R|$_rel" "$_transaction" 2>/dev/null && _restore_started=1
        if [ -e "$_save" ] || [ -L "$_save" ]; then
            if [ "$_restore_started" = 0 ]; then
                printf 'R|%s\n' "$_rel" >> "$_transaction" || { _failed=1; continue; }
                _restore_started=1
            fi
            if [ -e "$_dst" ] || [ -L "$_dst" ]; then rm -rf "$_dst" || { _failed=1; continue; }; fi
            mkdir -p "$(dirname "$_dst")" || { _failed=1; continue; }
            mv "$_save" "$_dst" || { _failed=1; continue; }
            { [ -e "$_dst" ] || [ -L "$_dst" ]; } && { [ ! -e "$_save" ] && [ ! -L "$_save" ]; } || _failed=1
        elif [ "$_had_original" = 1 ]; then
            # Исходный путь существовал до транзакции. Если замена началась,
            # но копия и завершённое восстановление отсутствуют, сохранить журнал.
            if [ "$_was_applied" = 1 ] && [ "$_restore_started" = 0 ]; then
                echo "z2k-openwrt: отсутствует исходная резервная копия $_rel" >&2
                _failed=1
            elif [ ! -e "$_dst" ] && [ ! -L "$_dst" ]; then
                echo "z2k-openwrt: восстановленный исходный путь отсутствует: $_rel" >&2
                _failed=1
            fi
        elif [ "$_was_applied" = 1 ]; then
            if [ "$_format_v2" != 1 ] && [ "$_restore_started" = 0 ]; then
                echo "z2k-openwrt: старый формат транзакции не подтверждает откат для $_rel" >&2
                _failed=1
                continue
            fi
            if [ "$_restore_started" = 0 ]; then
                printf 'R|%s\n' "$_rel" >> "$_transaction" || { _failed=1; continue; }
            fi
            if [ -e "$_dst" ] || [ -L "$_dst" ]; then rm -rf "$_dst" || _failed=1; fi
            { [ ! -e "$_dst" ] && [ ! -L "$_dst" ]; } || _failed=1
        fi
    done < "$_paths"
    return "$_failed"
}

z2k_ow_backup_paths() {
    _transaction="$1" _paths="$2" _transaction_id="$3"
    printf 'V|2\n' > "$_transaction" || return 1
    while IFS= read -r _rel; do
        [ -n "$_rel" ] || continue
        _dst="$(z2k_ow_path "$_rel")"
        _save="${_dst}.z2k-backup.${_transaction_id}"
        _new="${_dst}.z2k-new.${_transaction_id}"
        [ ! -e "$_save" ] && [ ! -L "$_save" ] && [ ! -e "$_new" ] && [ ! -L "$_new" ] || {
            echo "z2k-openwrt: устаревший файл транзакции блокирует путь $_rel" >&2
            return 1
        }
        mkdir -p "$(dirname "$_dst")" || return 1
        # Журнал с опережающей записью позволяет продолжить восстановление
        # после прерванной замены нескольких путей. Если mv завершился ошибкой
        # до создания копии, исходный путь останется нетронутым.
        printf 'B|%s\n' "$_rel" >> "$_transaction" || return 1
        if [ -e "$_dst" ] || [ -L "$_dst" ]; then
            # Записать наличие исходного пути до переименования, чтобы при
            # восстановлении отличить потерю копии от нового файла.
            printf 'O|%s\n' "$_rel" >> "$_transaction" || return 1
            mv "$_dst" "$_save" || return 1
        fi
    done < "$_paths"
}

z2k_ow_apply_staged_tree() {
    _stage="$1" _transaction="$2" _paths="$3" _transaction_id="$4"
    while IFS= read -r _rel; do
        [ -n "$_rel" ] || continue
        _dst="$(z2k_ow_path "$_rel")"
        _src="$_stage$_rel"
        [ -e "$_src" ] || [ -L "$_src" ] || {
            echo "z2k-openwrt: архив не содержит принадлежащий релизу путь $_rel" >&2
            return 1
        }
        mkdir -p "$(dirname "$_dst")" || return 1
        _new="${_dst}.z2k-new.${_transaction_id}"
        printf 'I|%s\n' "$_rel" >> "$_transaction" || return 1
        # Финальное переименование выполняется в том же каталоге и атомарно.
        # Большие каталоги сначала перемещаются из временного каталога на той же файловой
        # системе; небольшие файлы /etc копируются во временный файл рядом.
        if [ -d "$_src" ] && [ ! -L "$_src" ]; then
            if mv "$_src" "$_dst" 2>/dev/null; then
                continue
            fi
            rm -rf "$_new"
            cp -a "$_src" "$_new" || return 1
        else
            rm -f "$_new"
            cp -p "$_src" "$_new" 2>/dev/null || cp -a "$_src" "$_new" || return 1
        fi
        mv "$_new" "$_dst" || return 1
    done < "$_paths"
}

z2k_ow_cleanup_transaction() {
    _paths="$1" _transaction_id="$2" _failed=0
    while IFS= read -r _rel; do
        [ -n "$_rel" ] || continue
        _dst="$(z2k_ow_path "$_rel")"
        rm -rf "${_dst}.z2k-backup.${_transaction_id}" \
            "${_dst}.z2k-new.${_transaction_id}" || _failed=1
        { [ ! -e "${_dst}.z2k-backup.${_transaction_id}" ] \
            && [ ! -L "${_dst}.z2k-backup.${_transaction_id}" ] \
            && [ ! -e "${_dst}.z2k-new.${_transaction_id}" ] \
            && [ ! -L "${_dst}.z2k-new.${_transaction_id}" ]; } || _failed=1
    done < "$_paths"
    return "$_failed"
}

z2k_ow_cleanup_install_workspace() {
    _failed=0
    rm -rf "$1" || _failed=1
    if [ -e "$2" ] || [ -L "$2" ]; then
        if z2k_ow_temp_workspace_owned "$2"; then
            rm -rf "$2" || _failed=1
        else
            echo "z2k-openwrt: временный каталог не принадлежит установщику; оставлен без изменений: $2" >&2
            _failed=1
        fi
    fi
    { [ ! -e "$1" ] && [ ! -e "$2" ]; } || _failed=1
    return "$_failed"
}

z2k_ow_temp_workspace_owned() {
    [ -d "$1" ] && [ ! -L "$1" ] \
        && [ -f "$1/.z2kow-owner" ] && [ ! -L "$1/.z2kow-owner" ] \
        && [ "$(cat "$1/.z2kow-owner" 2>/dev/null)" = "z2kow-release-stage-v1" ]
}

z2k_ow_prepare_temp_workspace() {
    _temp="$1" _temp_parent="${1%/*}"
    case "$_temp" in /*) ;; *) echo "z2k-openwrt: временный путь должен быть абсолютным: $_temp" >&2; return 1 ;; esac
    [ "$_temp" != / ] && [ -n "$_temp_parent" ] && [ "$_temp_parent" != / ] \
        || { echo "z2k-openwrt: небезопасный временный путь: $_temp" >&2; return 1; }
    [ ! -L "$_temp_parent" ] \
        || { echo "z2k-openwrt: временный каталог является символической ссылкой: $_temp_parent" >&2; return 1; }
    { [ ! -e "$_temp_parent" ] || [ -d "$_temp_parent" ]; } \
        || { echo "z2k-openwrt: родитель временного каталога не является каталогом: $_temp_parent" >&2; return 1; }
    mkdir -p "$_temp_parent" || return 1
    if [ -e "$_temp" ] || [ -L "$_temp" ]; then
        z2k_ow_temp_workspace_owned "$_temp" || {
            echo "z2k-openwrt: временный каталог уже существует и не принадлежит установщику: $_temp" >&2
            return 1
        }
        rm -rf "$_temp" || return 1
    fi
    mkdir -m 700 "$_temp" || return 1
    printf '%s\n' 'z2kow-release-stage-v1' > "$_temp/.z2kow-owner" || {
        rmdir "$_temp" 2>/dev/null || true
        return 1
    }
}

z2k_ow_cleanup_temp_workspace() {
    [ -e "$1" ] || [ -L "$1" ] || return 0
    z2k_ow_temp_workspace_owned "$1" || {
        echo "z2k-openwrt: временный каталог не принадлежит установщику; оставлен без изменений: $1" >&2
        return 1
    }
    rm -rf "$1"
}

# Откатить активную транзакцию. Удалять резервные копии и журнал только после
# проверки файлов, состояния релиза и восстановленных служб.
z2k_ow_rollback_install() {
    _rollback_phase="$1"
    echo "z2k-openwrt: этап «$_rollback_phase» не выполнен; восстанавливается предыдущий релиз" >&2
    if ! z2k_ow_restore_paths "$_transaction" "$_paths" "$_transaction_id"; then
        echo "z2k-openwrt: откат не завершён; данные для восстановления сохранены в $_work" >&2
        z2k_ow_cleanup_temp_workspace "$_tmp_work" || true
        return 1
    fi
    if [ -f "$_work/state-was-present" ]; then
        [ -f "$_old_state" ] || {
            echo "z2k-openwrt: не найдено сохранённое состояние релиза; данные восстановления оставлены в $_work" >&2
            return 1
        }
        _state_tmp="${_state}.z2k-recover.$$"
        cp -p "$_old_state" "$_state_tmp" && mv -f "$_state_tmp" "$_state" \
            || { echo "z2k-openwrt: не удалось восстановить состояние релиза; данные оставлены в $_work" >&2; return 1; }
        cmp -s "$_old_state" "$_state" \
            || { echo "z2k-openwrt: состояние релиза после восстановления не прошло проверку; данные оставлены в $_work" >&2; return 1; }
    elif [ -f "$_work/state-write-started" ]; then
        rm -f "$_state" || { echo "z2k-openwrt: не удалось удалить незафиксированное состояние релиза; данные оставлены в $_work" >&2; return 1; }
        [ ! -e "$_state" ] || { echo "z2k-openwrt: незафиксированное состояние релиза сохранилось; данные оставлены в $_work" >&2; return 1; }
    fi
    z2k_ow_restart_services "$_service" "$_panel" \
        || { echo "z2k-openwrt: предыдущие службы не запустились; данные восстановления оставлены в $_work" >&2; z2k_ow_cleanup_temp_workspace "$_tmp_work" || true; return 1; }
    { [ ! -x "$_service" ] || ! z2k_ow_service_enabled \
        || { z2k_ow_service_call "$_service" status >/dev/null 2>&1 && z2k_ow_dataplane_ready; }; } \
        || { echo "z2k-openwrt: служба z2k не прошла проверку состояния; данные оставлены в $_work" >&2; z2k_ow_cleanup_temp_workspace "$_tmp_work" || true; return 1; }
        { [ ! -x "$_panel" ] || { z2k_ow_service_call "$_panel" running >/dev/null 2>&1 && z2k_ow_webpanel_http_ready; }; } \
        || { echo "z2k-openwrt: служба WebPanel или HTTP-проверка не пройдена; данные оставлены в $_work" >&2; z2k_ow_cleanup_temp_workspace "$_tmp_work" || true; return 1; }
    z2k_ow_cleanup_transaction "$_paths" "$_transaction_id" \
        || { echo "z2k-openwrt: очистка после отката не завершена; данные восстановления оставлены в $_work" >&2; z2k_ow_cleanup_temp_workspace "$_tmp_work" || true; return 1; }
    z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work" \
        || { echo "z2k-openwrt: откат проверен, но журнал не удалён; проверьте $_work" >&2; return 1; }
    echo "z2k-openwrt: откат завершён и проверен" >&2
    echo "Z2KOW_ROLLBACK=complete"
    return 0
}

z2k_ow_recover_transaction() {
    _work="$1" _state="$2" _service="$3" _target_tag="${4:-}" _target_seq="${5:-}" _panel="${6:-}"
    [ -f "$_work/transaction-active" ] || return 0
    _paths="$_work/owned-paths"
    _transaction="$_work/transaction.log"
    _id="$(cat "$_work/transaction-id" 2>/dev/null)"
    case "$_id" in ''|*[!0-9]*) echo "z2k-openwrt: неверный номер прерванной транзакции" >&2; return 1 ;; esac
    [ -s "$_paths" ] || { echo "z2k-openwrt: в прерванной транзакции отсутствует журнал путей" >&2; return 1; }
    _installed_record="$(z2k_ow_release_state_read "$_state" 2>/dev/null)" || _installed_record=""
    if [ -e "$_work/transaction-target" ] || [ -L "$_work/transaction-target" ]; then
        [ -f "$_work/transaction-target" ] && [ ! -L "$_work/transaction-target" ] || {
            echo "z2k-openwrt: неверная цель прерванной транзакции" >&2
            return 1
        }
        _transaction_target_record="$(z2k_ow_release_state_read "$_work/transaction-target" 2>/dev/null)" || {
            echo "z2k-openwrt: повреждена цель прерванной транзакции; журнал оставлен в $_work" >&2
            return 1
        }
    else
        # Старые журналы не содержат цель; для них доступно лишь точное
        # сравнение с tag + seq текущего проверенного манифеста.
        [ -n "$_target_tag" ] && [ -n "$_target_seq" ] || return 1
        _transaction_target_record=$(printf 'tag=%s\nseq=%s' "$_target_tag" "$_target_seq")
    fi
    if [ -n "$_installed_record" ] \
        && [ "$_installed_record" = "$_transaction_target_record" ] \
        && [ -f "$_work/state-write-started" ] \
        && [ -f "$_transaction" ] \
        && ! grep -q '^R|' "$_transaction"; then
        # Проверка состояния и запись версии успели завершиться до отключения
        # питания; прервалось только удаление временных файлов транзакции.
        # Записи R| означают, что начался откат; даже совпадающий tag + seq
        # при повторной установке не должен превращать его в успешный commit.
        z2k_ow_cleanup_transaction "$_paths" "$_id" || {
            echo "z2k-openwrt: очистка завершённой транзакции не выполнена; журнал оставлен в $_work" >&2
            return 1
        }
        z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work" || return 1
        return 0
    fi
    z2k_ow_restore_paths "$_transaction" "$_paths" "$_id" || return 1
    if [ -f "$_work/state-was-present" ]; then
        [ -f "$_work/installed-release.old" ] || return 1
        _state_tmp="${_state}.z2k-recover.$$"
        cp -p "$_work/installed-release.old" "$_state_tmp" && mv -f "$_state_tmp" "$_state" \
            && cmp -s "$_work/installed-release.old" "$_state" || return 1
    elif [ -f "$_work/state-write-started" ]; then
        rm -f "$_state" || return 1
    fi
    z2k_ow_restart_services "$_service" "$_panel" || {
        echo "z2k-openwrt: файлы восстановлены, но прежние службы не запустились; журнал оставлен в $_work" >&2
        return 1
    }
    { [ ! -x "$_service" ] || ! z2k_ow_service_enabled \
        || { z2k_ow_service_call "$_service" status >/dev/null 2>&1 && z2k_ow_dataplane_ready; }; } || {
        echo "z2k-openwrt: служба z2k после восстановления не прошла проверку; журнал оставлен в $_work" >&2
        return 1
    }
    { [ ! -x "$_panel" ] || { z2k_ow_service_call "$_panel" running >/dev/null 2>&1 && z2k_ow_webpanel_http_ready; }; } || {
        echo "z2k-openwrt: WebPanel после восстановления не прошла проверку; журнал оставлен в $_work" >&2
        return 1
    }
    z2k_ow_cleanup_transaction "$_paths" "$_id" || {
        echo "z2k-openwrt: очистка восстановления не выполнена; журнал оставлен в $_work" >&2
        return 1
    }
    z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work" || return 1
    echo "z2k-openwrt: восстановлена прерванная транзакция установки" >&2
}

z2k_ow_service_call() {
    local _service_path="${1:-}"
    shift
    [ -n "$_service_path" ] || return 1

    # Приёмочный тест запускает настоящую точку входа на временной файловой системе,
    # где службы OpenWrt rc.common/procd недоступны.
    if [ "${Z2K_OW_TESTING:-0}" = 1 ] && [ -n "${Z2K_OW_TEST_SERVICE_HELPER:-}" ]; then
        "${Z2K_OW_TEST_SERVICE_HELPER}" "$_service_path" "$@"
        return $?
    fi

    # При новой установке движок запущен из временной распаковки. procd наследует
    # окружение вызывающего init-скрипта; если передать ему эти переменные,
    # перезапущенные службы продолжат искать файлы в каталоге, который удалит
    # install.sh после завершения.
    if [ -n "${Z2K_OW_BOOTSTRAP_MANIFEST:-}" ]; then
        (
            unset Z2K_ADAPTER_DIR Z2K_LIB Z2K_AU_PUBKEY \
                Z2K_OW_BOOTSTRAP_MANIFEST Z2K_OW_BOOTSTRAP_SIGNATURE \
                Z2K_OW_BOOTSTRAP_ARTIFACT Z2K_OW_BOOTSTRAP_PUBLIC_KEY \
                Z2KOW_MANIFEST_URL Z2KOW_TRUST_KEY \
                Z2K_OW_INSTALL_TMP Z2K_OW_SYSROOT TMPDIR
            "$_service_path" "$@"
        )
    else
        "$_service_path" "$@"
    fi
}

z2k_ow_system_preflight() {
    [ "${Z2K_OW_TESTING:-0}" = 1 ] && return 0
    local _release_file="${Z2K_OW_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"
    local _release _meminfo="${Z2K_OW_MEMINFO_FILE:-/proc/meminfo}" _available_kb
    [ -r "$_release_file" ] || { echo "z2k-openwrt: это не OpenWrt — $_release_file недоступен" >&2; return 1; }
    . "$_release_file"
    [ "${DISTRIB_ID:-}" = OpenWrt ] || { echo "z2k-openwrt: поддерживается только OpenWrt" >&2; return 1; }
    _release=${DISTRIB_RELEASE:-}
    case "$_release" in
        SNAPSHOT) ;;
        *)
            awk -v version="$_release" 'BEGIN {
                if (!match(version, /^[0-9]+\.[0-9]+/)) exit 1
                split(substr(version, RSTART, RLENGTH), part, /\./)
                exit !((part[1] > 24) || (part[1] == 24 && part[2] >= 10))
            }' || { echo "z2k-openwrt: поддерживается OpenWrt 24.10 или новее с apk" >&2; return 1; }
            ;;
    esac
    command -v apk >/dev/null 2>&1 || { echo "z2k-openwrt: нужен apk для системных зависимостей OpenWrt" >&2; return 1; }
    for _tool in awk df grep readlink sha256sum tar; do
        command -v "$_tool" >/dev/null 2>&1 || { echo "z2k-openwrt: необходимая системная команда отсутствует: $_tool" >&2; return 1; }
    done
    [ -r "$_meminfo" ] || { echo "z2k-openwrt: не удалось определить объём свободной оперативной памяти" >&2; return 1; }
    _available_kb=$(awk '
        /^MemAvailable:/ { available=$2; found=1 }
        /^MemFree:/ { free=$2 }
        /^Buffers:/ { buffers=$2 }
        /^Cached:/ { cached=$2 }
        END {
            if (!found) available=free+buffers+cached
            if (available ~ /^[0-9]+$/) printf "%.0f\n", available
        }
    ' "$_meminfo")
    case "$_available_kb" in ''|*[!0-9]*) echo "z2k-openwrt: не удалось определить объём свободной оперативной памяти" >&2; return 1 ;; esac
    [ "$_available_kb" -ge 8192 ] || {
        echo "z2k-openwrt: недостаточно оперативной памяти: требуется 8192 КиБ, доступно $_available_kb КиБ" >&2
        return 1
    }
    . "$_adapter/arch.sh" || return 1
    z2k_ow_arch_name >/dev/null 2>&1 || {
        echo "z2k-openwrt: архитектура роутера не поддерживается; файлы релиза не установлены" >&2
        return 1
    }
}

# Проверить не только процесс lighttpd, но и ответ HTTP на настроенном адресе панели.
z2k_ow_webpanel_http_ready() {
    if [ "${Z2K_OW_TESTING:-0}" = 1 ]; then
        [ -n "${Z2K_OW_TEST_HTTP_PROBE:-}" ] || return 0
        "${Z2K_OW_TEST_HTTP_PROBE}"
        return $?
    fi
    local _panel_settings="${Z2K_ETC:-/etc/z2k}/webpanel" _panel_bind _panel_port
    . "$_adapter/webpanel.sh" || return 1
    WP_SETTINGS_DIR="$_panel_settings"
    WP_PORT_DEFAULT=8088
    _panel_port="$(wp_panel_port)"
    _panel_bind=$(cat "$_panel_settings/bind" 2>/dev/null | tr -d ' \t\r\n')
    [ -n "$_panel_bind" ] || _panel_bind="$(wp_lan_ip)" || return 1
    case "$_panel_bind" in ''|*[!0-9.]*) return 1 ;; esac
    printf '%s' "$_panel_port" | grep -Eq '^[1-9][0-9]{0,4}$' || return 1
    command -v curl >/dev/null 2>&1 || { echo "z2k-openwrt: curl отсутствует для HTTP-проверки WebPanel" >&2; return 1; }
    curl --fail --silent --show-error --connect-timeout 3 --max-time 5 \
        -o /dev/null "http://$_panel_bind:$_panel_port/"
}

z2k_ow_service_enabled() {
    local _enabled_config _enabled
    _enabled_config="$(z2k_ow_path "${Z2K_CONFIG:-/etc/z2k/config}")"
    _enabled=$(sed -n 's/^[[:space:]]*ENABLED[[:space:]]*=[[:space:]]*//p' "$_enabled_config" 2>/dev/null \
        | head -1 | tr -d "'\" \t\r")
    [ "$_enabled" != 0 ]
}

# Проверять NFQUEUE readiness только если dataplane включён оператором.
z2k_ow_dataplane_ready() {
    if command -v z2k_ow_core_ready >/dev/null 2>&1; then
        z2k_ow_core_ready || {
            echo "z2k-openwrt: dataplane не прошёл проверку NFQUEUE" >&2
            return 1
        }
        return 0
    fi
    [ "${Z2K_OW_TESTING:-0}" = 1 ] && return 0
    echo "z2k-openwrt: проверка готовности dataplane недоступна" >&2
    return 1
}

z2k_ow_restart_services() {
    _restart_failed=0
    for _restart_service in "$1" "$2"; do
        [ -n "$_restart_service" ] && [ -x "$_restart_service" ] || continue
        if [ "$_restart_service" = "$1" ] && ! z2k_ow_service_enabled; then
            continue
        fi
        z2k_ow_service_call "$_restart_service" restart >/dev/null 2>&1 || \
            z2k_ow_service_call "$_restart_service" start >/dev/null 2>&1 || _restart_failed=1
    done
    [ "$_restart_failed" = 0 ]
}

_z2k_ow_install_release_locked() {
    _reinstall=0
    if [ "${1:-}" = "--reinstall" ]; then
        _reinstall=1
        [ "$#" -eq 2 ] || {
        echo "использование: install_release --reinstall <тег-установленного-релиза>" >&2
            return 2
        }
        _requested="$2"
    else
        [ "$#" -eq 1 ] || {
        echo "использование: install_release <тег-релиза>" >&2
            return 2
        }
        _requested="$1"
    fi
    printf '%s' "$_requested" | grep -Eq '^[pr]-[0-9]+(\.[0-9]+)+$' || {
        echo "использование: install_release [--reinstall] <тег-релиза>" >&2
        return 2
    }

    _root="${Z2K_ROOT:-/usr/lib/z2k}"
    _adapter="${Z2K_ADAPTER_DIR:-$_root/platform/openwrt}"
    _lib="${Z2K_LIB:-$_root/lib}"
    . "$_adapter/paths.sh" || return 1
    . "$_adapter/release_state.sh" || return 1
    _state="$(z2k_ow_path "${Z2K_OW_INSTALLED_RELEASE_FILE:-/etc/z2k/state/installed-release}")"
    _work="$(z2k_ow_path "${Z2K_OW_INSTALL_WORK:-/usr/lib/.z2k-install}")"
    _tmp_parent="${Z2K_OW_INSTALL_TMP%/}"
    [ -n "$_tmp_parent" ] || return 1
    _tmp_work="$_tmp_parent/z2kow-release"
    _stage="$_tmp_work/stage"
    _archive="$_tmp_work/openwrt-rootfs.tar.gz"
    _manifest="${Z2K_OW_BOOTSTRAP_MANIFEST:-${Z2K_OW_MANIFEST_PATH:-${Z2K_AU_TMP_DIR:-/tmp/z2k/update}/UPDATES.json}}"
    _bootstrap_artifact_url=""
    if [ -n "${Z2K_OW_BOOTSTRAP_MANIFEST:-}" ] \
        && [ "$_manifest" = "$Z2K_OW_BOOTSTRAP_MANIFEST" ] \
        && [ -n "${Z2KOW_MANIFEST_URL:-}" ]; then
        case "$Z2KOW_MANIFEST_URL" in
            http://*/UPDATES.json|https://*/UPDATES.json)
                _bootstrap_artifact_url="${Z2KOW_MANIFEST_URL%/UPDATES.json}/openwrt-rootfs.tar.gz"
                ;;
        esac
    fi
    _paths="$_work/owned-paths"
    _old_state="$_work/installed-release.old"
    _service="$(z2k_ow_path /etc/init.d/z2k)"
    _panel="$(z2k_ow_path /etc/init.d/z2k-webpanel)"
    _transaction="$_work/transaction.log"
    _transaction_id="$$"
    _stopped=0 _tag=""

    z2k_ow_install_progress "Проверяю манифест и подпись релиза"
    if [ "${Z2K_OW_TESTING:-0}" != 1 ]; then
        [ "$(id -u 2>/dev/null || echo 1)" = 0 ] || { echo "install_release нужно запускать от root" >&2; return 1; }
        . "$_adapter/env.sh" || return 1
        . "$_lib/utils.sh" || return 1
        . "$_lib/auto_update.sh" || return 1
        . "$_adapter/manifest.sh" || return 1
        if [ -n "${Z2K_OW_BOOTSTRAP_MANIFEST:-}" ]; then
            _sig="${Z2K_OW_BOOTSTRAP_SIGNATURE:-${Z2K_OW_BOOTSTRAP_MANIFEST}.sig}"
            z2k_ow_manifest_verify_signature "$_manifest" "$_sig" || {
                echo "z2k-openwrt: подпись bootstrap-манифеста неверна или недоступна" >&2
                return 1
            }
            z2k_ow_manifest_release_ok "$_manifest" "$_bootstrap_artifact_url" || return 1
        else
            z2k_ow_manifest_prepare_production "$_manifest" || return 1
        fi
    else
        . "$_adapter/manifest.sh" || return 1
    fi
    z2k_ow_manifest_release_ok "$_manifest" "$_bootstrap_artifact_url" || return 1
    _tag="$(z2k_ow_json_value "$_manifest" current)" || return 1
    _seq="$(z2k_ow_json_value "$_manifest" seq)" || return 1
    z2k_ow_recover_transaction "$_work" "$_state" "$_service" "$_tag" "$_seq" "$_panel" || return 1
    z2k_ow_system_preflight || return 1
    _installed="$(z2k_ow_release_state_tag "$_state")" || _installed=""
    _state_record="$(z2k_ow_release_state_read "$_state")" || _state_record=""
    if [ "$_reinstall" = 1 ]; then
        [ -n "$_state_record" ] && [ "$_installed" = "$_requested" ] || {
            echo "z2k-openwrt: целевая версия для повторной установки не совпадает с установленной" >&2
            return 1
        }
        if [ "$_tag" != "$_installed" ] \
            || [ "$(z2k_ow_release_state_seq "$_state")" != "$_seq" ]; then
            echo "Z2KOW_REINSTALL_UPDATE_AVAILABLE:$_tag"
            return 3
        fi
    fi
    [ "$_tag" = "$_requested" ] || {
        echo "z2k-openwrt: можно установить только текущий проверенный релиз ($_tag)" >&2
        return 1
    }
    # Архив и временная распаковка находятся в отдельном каталоге с маркером
    # владельца: заданный пользователем родительский каталог не очищается.
    if [ -n "$_state_record" ] && [ "$_installed" = "$_tag" ] \
        && [ "$(z2k_ow_release_state_seq "$_state")" = "$_seq" ] \
        && [ "$_reinstall" != 1 ] \
        && ! z2k_ow_legacy_packages_present && ! z2k_ow_relay_identity_migration_needed; then
        if z2k_ow_installed_payload_ready; then
            echo "none $_tag"
            return 0
        fi
        echo "z2k-openwrt: файлы или службы установленного релиза повреждены; выполняется полное восстановление" >&2
    fi

    _url="$(z2k_ow_json_value "$_manifest" artifact.url)" || return 1
    _sha="$(z2k_ow_json_value "$_manifest" artifact.sha256 | tr 'A-F' 'a-f')" || return 1
    _size="$(z2k_ow_json_value "$_manifest" artifact.size_bytes)" || return 1
    case "$_sha" in *[!0-9a-f]*|'') return 1 ;; esac
    [ "${#_sha}" -eq 64 ] || return 1
    case "$_size" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_size" -gt 0 ] || return 1

    mkdir -p "$_work" || return 1
    z2k_ow_prepare_temp_workspace "$_tmp_work" || return 1
    rm -rf "$_transaction" "$_work/transaction-active" \
        "$_work/transaction-id" "$_work/state-was-present" \
        "$_work/state-write-started" "$_work/transaction-target" \
        "$_work/transaction-target.new.$$" "$_old_state"
    mkdir -p "$_stage" || return 1
    if [ -n "${Z2K_OW_BOOTSTRAP_ARTIFACT:-}" ]; then
        _archive="$Z2K_OW_BOOTSTRAP_ARTIFACT"
    elif [ "${Z2K_OW_TESTING:-0}" = 1 ] && [ -n "${Z2K_OW_ARTIFACT_PATH:-}" ]; then
        _archive="$Z2K_OW_ARTIFACT_PATH"
    else
        z2k_ow_install_progress "Загружаю полный архив релиза"
        z2k_ow_download "$_url" "$_archive" || {
            z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1;
        }
    fi
    z2k_ow_install_progress "Проверяю размер и SHA-256 архива"
    [ "$(wc -c < "$_archive" | tr -d ' \t\r\n')" = "$_size" ] \
        || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    _actual="$(sha256sum "$_archive" 2>/dev/null | awk '{print $1}')"
    [ "$_actual" = "$_sha" ] || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    z2k_ow_install_progress "Проверяю список файлов архива"
    z2k_ow_archive_safe "$_archive" "$_work/archive-list" \
        || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    z2k_ow_install_progress "Извлекаю файлы для архитектуры роутера"
    z2k_ow_extract_target_payload "$_archive" "$_stage" "$_work/archive-list" "$_work" \
        || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    z2k_ow_owned_paths > "$_paths" || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    z2k_ow_migrate_relay_identity || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }

    printf '%s\n' "$_transaction_id" > "$_work/transaction-id" \
        || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    _expected_record=$(printf 'tag=%s\nseq=%s' "$_tag" "$_seq")
    _target_record_tmp="$_work/transaction-target.new.$$"
    printf 'tag=%s\nseq=%s\n' "$_tag" "$_seq" > "$_target_record_tmp" \
        && mv -f "$_target_record_tmp" "$_work/transaction-target" || {
            rm -f "$_target_record_tmp"
            z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"
            return 1
        }
    if [ -e "$_state" ]; then
        cp -p "$_state" "$_old_state" \
            || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
        : > "$_work/state-was-present" \
            || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    fi
    : > "$_work/transaction-active" \
        || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }

    if [ -x "$_service" ]; then
        z2k_ow_install_progress "Останавливаю сервис перед заменой файлов"
        _stopped=1
        z2k_ow_service_call "$_service" stop >/dev/null 2>&1 || {
            z2k_ow_rollback_install "service stop"
            return 1
        }
    fi
    z2k_ow_backup_paths "$_transaction" "$_paths" "$_transaction_id" || {
        z2k_ow_rollback_install "backup creation"
        return 1
    }
    z2k_ow_legacy_migrate "$(z2k_ow_path /usr/lib/z2k).z2k-backup.$_transaction_id" || {
        z2k_ow_rollback_install "legacy migration"
        return 1
    }

    z2k_ow_install_progress "Применяю проверенные файлы релиза"
    if ! z2k_ow_apply_staged_tree "$_stage" "$_transaction" "$_paths" "$_transaction_id"; then
        z2k_ow_rollback_install "file apply"
        return 1
    fi

    _state_dir="$(dirname "$_state")"
    mkdir -p "$_state_dir" || {
        z2k_ow_rollback_install "release state directory creation"
        return 1
    }

    if [ "${Z2K_OW_TESTING:-0}" != 1 ]; then
        _bootstrap="$_adapter/bootstrap.sh"
        if [ -r "$_bootstrap" ]; then
            . "$_bootstrap" || { z2k_ow_rollback_install "bootstrap load"; return 1; }
            . "$_adapter/paths.sh" || { z2k_ow_rollback_install "path initialization"; return 1; }
            . "$_adapter/env.sh" || { z2k_ow_rollback_install "environment initialization"; return 1; }
            z2k_ow_bootstrap || {
                z2k_ow_rollback_install "platform bootstrap"
                return 1
            }
        fi
    fi
    if [ "${Z2K_OW_TESTING:-0}" != 1 ] || [ "${Z2K_OW_TEST_HEALTHCHECK:-0}" = 1 ]; then
        z2k_ow_install_progress "Перезапускаю сервисы и проверяю доступность панели"
        for _svc in "$_service" "$_panel"; do
            [ -x "$_svc" ] || continue
            if [ "$_svc" = "$_service" ] && ! z2k_ow_service_enabled; then
                continue
            fi
            z2k_ow_service_call "$_svc" enable >/dev/null 2>&1 || true
            _svc_name=$(basename "$_svc")
            _restart_log="$_work/$_svc_name-restart.log"
            _start_log="$_work/$_svc_name-start.log"
            if z2k_ow_service_call "$_svc" restart >"$_restart_log" 2>&1; then
                :
            else
                _restart_rc=$?
                if z2k_ow_service_call "$_svc" start >"$_start_log" 2>&1; then
                    :
                else
                    _start_rc=$?
                    echo "z2k-openwrt: служба не запустилась после замены файлов: $_svc (перезапуск=$_restart_rc запуск=$_start_rc)" >&2
                    for _diagnostic in "$_restart_log" "$_start_log"; do
                        if [ -s "$_diagnostic" ]; then
                            echo "z2k-openwrt: вывод $(basename "$_diagnostic") (последние 30 строк):" >&2
                            tail -n 30 "$_diagnostic" >&2 || true
                        fi
                    done
                    z2k_ow_rollback_install "service start"
                    return 1
                fi
            fi
        done
        _n=0
        while [ "$_n" -lt 15 ]; do
            if [ ! -x "$_service" ] || ! z2k_ow_service_enabled \
                || { z2k_ow_service_call "$_service" status >/dev/null 2>&1 && z2k_ow_dataplane_ready; }; then
                if [ ! -x "$_panel" ] || { z2k_ow_service_call "$_panel" running >/dev/null 2>&1 && z2k_ow_webpanel_http_ready; }; then break; fi
            fi
            _n=$((_n + 1)); sleep 1
        done
        [ "$_n" -lt 15 ] || { z2k_ow_rollback_install "service health check"; return 1; }
    fi

    : > "$_work/state-write-started" || {
        z2k_ow_rollback_install "release state journal"
        return 1
    }
    _state_tmp="${_state}.z2k-new.$_transaction_id"
    if ! z2k_ow_release_state_write "$_state" "$_manifest" \
        || [ "$(z2k_ow_release_state_read "$_state" 2>/dev/null)" != "$_expected_record" ]; then
        echo "z2k-openwrt: не удалось зафиксировать единую запись установленной версии" >&2
        z2k_ow_rollback_install "release state commit"
        return 1
    fi

    # Старое пакетное обновление хранило ещё два маркера версии. Удалять их
    # только после проверки нового полного набора файлов; единственным локальным
    # источником состояния остаётся installed-release.
    rm -f "${_state%/*}/installed-tag" \
          "${_state%/*}/product-tag" \
          "${_state%/*}/product-update.status" \
          "$(z2k_ow_path "${Z2K_ZAPRET2_RUNTIME:-/opt/zapret2}/.z2k-installed-tag")" \
          "$(z2k_ow_path "${Z2K_ZAPRET2_RUNTIME:-/opt/zapret2}/.z2k-tree-dirty")"
    z2k_ow_cleanup_transaction "$_paths" "$_transaction_id" || {
        echo "z2k-openwrt: релиз установлен, но резервные копии не очищены; данные восстановления оставлены в $_work" >&2
        z2k_ow_cleanup_temp_workspace "$_tmp_work" || true
        return 1
    }
    z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work" || {
        echo "z2k-openwrt: релиз установлен, но журнал транзакции не удалён" >&2
        return 1
    }
    printf 'installed %s\n' "$_tag"
}

# Вернуть размер файлов выбранной архитектуры для проверки свободного места.
z2k_ow_payload_size_for_arch() {
    _archive="$1" _arch="$2"
    tar -tvzf "$_archive" 2>/dev/null | awk -v arch="$_arch" '
        $1 ~ /^-/ && $3 ~ /^[0-9]+$/ {
            path=$NF; sub(/\/$/, "", path)
            split(path, part, "/")
            if (part[1] == "usr" && part[2] == "lib" && part[3] == "z2k" && part[4] == "bin" && part[5] ~ /^linux-/ && part[5] != ("linux-" arch)) next
            if (part[1] == "usr" && part[2] == "lib" && part[3] == "z2k" && part[4] == "platform" && part[5] == "openwrt" && part[6] == "bin" && part[7] ~ /^linux-/ && part[7] != ("linux-" arch)) next
            if (part[1] == "opt" && part[2] == "zapret2" && part[3] == "binaries" && part[4] ~ /^linux-/ && part[4] != ("linux-" arch)) next
            total += $3
        }
        END { printf "%.0f\n", total }
    '
}

# Подсчитать размер файлов релиза для каждого принадлежащего ему пути за один проход.
z2k_ow_payload_sizes_for_arch() {
    local _ps_archive="$1" _ps_arch="$2" _ps_paths="$3"
    tar -tvzf "$_ps_archive" 2>/dev/null | awk -v arch="$_ps_arch" -v paths="$_ps_paths" '
        BEGIN {
            while ((getline path < paths) > 0) {
                sub(/^\//, "", path)
                if (path != "") owned[++count] = path
            }
            close(paths)
        }
        $1 ~ /^-/ && $3 ~ /^[0-9]+$/ {
            path=$NF; sub(/\/$/, "", path)
            split(path, part, "/")
            if (part[1] == "usr" && part[2] == "lib" && part[3] == "z2k" && part[4] == "bin" && part[5] ~ /^linux-/ && part[5] != ("linux-" arch)) next
            if (part[1] == "usr" && part[2] == "lib" && part[3] == "z2k" && part[4] == "platform" && part[5] == "openwrt" && part[6] == "bin" && part[7] ~ /^linux-/ && part[7] != ("linux-" arch)) next
            if (part[1] == "opt" && part[2] == "zapret2" && part[3] == "binaries" && part[4] ~ /^linux-/ && part[4] != ("linux-" arch)) next
            for (i=1; i<=count; i++)
                if (path == owned[i] || index(path, owned[i] "/") == 1) size[i] += $3
        }
        END { for (i=1; i<=count; i++) printf "%s|%.0f\n", owned[i], size[i] }
    '
}

# Для пропуска установки недостаточно совпадающего тега: проверить файлы
# выбранной архитектуры и наличие всех путей, принадлежащих релизу.
z2k_ow_installed_payload_ready() {
    local _ready_root _ready_runtime
    local _ready_arch _ready_rel _ready_path
    local _ready_pair _ready_dir _ready_name _ready_link _ready_target
    _ready_root="${Z2K_ROOT:-$Z2K_OW_CANON_ROOT_SUFFIX}"
    _ready_runtime="$(z2k_ow_path "${Z2K_ZAPRET2_RUNTIME:-$Z2K_OW_CANON_ZAPRET2_SUFFIX}")"
    [ "$_ready_root" != "$Z2K_OW_CANON_ROOT_SUFFIX" ] \
        || _ready_root="$(z2k_ow_path "$Z2K_OW_CANON_ROOT_SUFFIX")"
    . "$_adapter/arch.sh" || return 1
    _ready_arch="$(z2k_ow_arch_name 2>/dev/null)" || { echo "z2k-openwrt: архитектура установленного релиза не поддерживается" >&2; return 1; }
    [ -x "$(z2k_ow_path /usr/bin/z2kow)" ] || { echo "z2k-openwrt: исполняемый файл z2kow отсутствует или повреждён" >&2; return 1; }
    [ -x "$(z2k_ow_path /usr/sbin/install_release)" ] || { echo "z2k-openwrt: движок обновления отсутствует или повреждён" >&2; return 1; }
    for _ready_path in \
        "$_ready_root/bin/linux-$_ready_arch/tg-mtproxy-client" \
        "$_ready_root/bin/linux-$_ready_arch/z2k-rt-proxy" \
        "$_ready_root/bin/linux-$_ready_arch/z2k-detect" \
        "$_ready_root/platform/openwrt/bin/linux-$_ready_arch/z2k-warpd" \
        "$_ready_runtime/binaries/linux-$_ready_arch/nfq2/nfqws2" \
        "$_ready_runtime/binaries/linux-$_ready_arch/ip2net/ip2net" \
        "$_ready_runtime/binaries/linux-$_ready_arch/mdig/mdig"; do
        [ -s "$_ready_path" ] && [ -x "$_ready_path" ] || {
            echo "z2k-openwrt: исполняемый файл выбранной архитектуры отсутствует или повреждён: $_ready_path" >&2
            return 1
        }
    done
    while IFS= read -r _ready_rel; do
        [ -n "$_ready_rel" ] || continue
        _ready_path="$(z2k_ow_path "$_ready_rel")"
        { [ -e "$_ready_path" ] || [ -L "$_ready_path" ]; } || {
            echo "z2k-openwrt: отсутствует путь, принадлежащий релизу: $_ready_rel" >&2
            return 1
        }
    done <<EOF_OWNED
$(z2k_ow_owned_paths)
EOF_OWNED
    if [ "${Z2K_OW_TESTING:-0}" != 1 ]; then
        for _ready_pair in nfq2/nfqws2 ip2net/ip2net mdig/mdig; do
            _ready_dir=${_ready_pair%%/*} _ready_name=${_ready_pair#*/}
            _ready_link="$_ready_runtime/$_ready_dir/$_ready_name"
            _ready_target="$_ready_runtime/$_ready_dir/../binaries/linux-$_ready_arch/$_ready_name"
            [ -L "$_ready_link" ] \
                && [ "$(readlink "$_ready_link" 2>/dev/null)" = "../binaries/linux-$_ready_arch/$_ready_name" ] \
                && [ -x "$_ready_target" ] || {
                    echo "z2k-openwrt: неверная символическая ссылка runtime: $_ready_link" >&2
                    return 1
                }
        done
    fi
    if z2k_ow_service_enabled; then
        if [ -x "$_service" ]; then
            z2k_ow_service_call "$_service" status >/dev/null 2>&1 || {
                echo "z2k-openwrt: служба z2k не прошла проверку состояния" >&2
                return 1
            }
        fi
        z2k_ow_dataplane_ready || {
            echo "z2k-openwrt: установленный dataplane не готов" >&2
            return 1
        }
    fi
    if [ -x "$_panel" ]; then
        { z2k_ow_service_call "$_panel" running >/dev/null 2>&1 && z2k_ow_webpanel_http_ready; } || {
            echo "z2k-openwrt: служба WebPanel или HTTP-проверка не пройдена" >&2
            return 1
        }
    fi
    return 0
}

# Проверить место на каждой целевой файловой системе до остановки служб.
# Старые каталоги payload переименовываются рядом, поэтому их размер уже учтён
# в занятом месте и не прибавляется повторно к требованию.
z2k_ow_overlay_preflight() {
    local _ov_archive="$1" _ov_arch="$2" _ov_paths="$3" _ov_listing="$4" _ov_work="$5"
    local _ov_sizes="$_ov_work/owned-payload-sizes" _ov_requirements="$_ov_work/overlay-requirements"
    local _ov_rel _ov_bytes _ov_member _ov_dst _ov_probe
    local _ov_df _ov_filesystem _ov_df_rest _ov_available_kb _ov_mountpoint
    local _ov_needed
    : > "$_ov_requirements" || return 1
    z2k_ow_payload_sizes_for_arch "$_ov_archive" "$_ov_arch" "$_ov_paths" > "$_ov_sizes" || return 1
    [ -s "$_ov_sizes" ] || { echo "z2k-openwrt: не удалось определить размеры файлов релиза" >&2; return 1; }
    while IFS='|' read -r _ov_rel _ov_bytes; do
        [ -n "$_ov_rel" ] || continue
        case "$_ov_bytes" in ''|*[!0-9]*) return 1 ;; esac
        _ov_member=${_ov_rel#/}
        if ! grep -Fqx "$_ov_member" "$_ov_listing" \
            && ! grep -Fq "$_ov_member/" "$_ov_listing"; then
            echo "z2k-openwrt: архив релиза не содержит принадлежащий ему путь $_ov_member" >&2
            return 1
        fi
        _ov_dst="$(z2k_ow_path "/$_ov_rel")"
        _ov_probe="$(dirname "$_ov_dst")"
        while [ ! -d "$_ov_probe" ] && [ "$_ov_probe" != / ]; do _ov_probe="$(dirname "$_ov_probe")"; done
        [ -d "$_ov_probe" ] || { echo "z2k-openwrt: не найдена файловая система назначения для $_ov_rel" >&2; return 1; }
        _ov_df="$(df -Pk "$_ov_probe" 2>/dev/null | awk 'END { if (NR >= 2) print $1 "|" $4 "|" $NF}')"
        _ov_filesystem=${_ov_df%%|*}
        _ov_df_rest=${_ov_df#*|}
        _ov_available_kb=${_ov_df_rest%%|*}
        _ov_mountpoint=${_ov_df_rest#*|}
        case "$_ov_available_kb" in ''|*[!0-9]*)
            echo "z2k-openwrt: не удалось определить свободное место для $_ov_rel" >&2
            return 1
            ;;
        esac
        [ -n "$_ov_filesystem" ] && [ -n "$_ov_mountpoint" ] || return 1
        printf '%s|%s|%s|%s\n' "$_ov_filesystem" "$_ov_mountpoint" "$_ov_available_kb" "$_ov_bytes" \
            >> "$_ov_requirements" || return 1
    done < "$_ov_sizes"
    awk -F'|' -v reserve=4194304 '
        {
            key=$1 "|" $2
            if (!(key in seen)) { available[key]=$3; seen[key]=1 }
            else if ($3 < available[key]) available[key]=$3
            needed[key]+=$4
            mountpoint[key]=$2
        }
        END {
            failed=0
            for (key in seen) {
                if (available[key] * 1024 < needed[key] + reserve) {
                    printf "z2k-openwrt: недостаточно места в %s (нужно %.0f байт и ещё 4 МиБ для отката; доступно %.0f КиБ)\n", mountpoint[key], needed[key], available[key] > "/dev/stderr"
                    failed=1
                }
            }
            exit failed
        }
    ' "$_ov_requirements" || return 1
}

# Сначала проверить каждый путь в архиве, затем распаковать общие файлы и
# исполняемые файлы нужной архитектуры. UPDATES.json по-прежнему подтверждает и
# хэширует весь архив; отбор файлов экономит ограниченную память flash.
z2k_ow_extract_target_payload() {
    _archive="$1" _stage="$2" _listing="$3" _work="$4"
    # Архитектура определяется роутером, а не архивом. Использовать уже
    # установленный определитель вместо отдельного извлечения одного файла:
    # tar всё равно распаковывает архив целиком для чтения этого файла.
    . "$_adapter/arch.sh" || return 1
    _target_arch="$(z2k_ow_arch_name 2>/dev/null)" || {
        echo "z2k-openwrt: архитектура роутера не поддерживается; архив не распакован" >&2
        return 1
    }
    z2k_ow_overlay_preflight "$_archive" "$_target_arch" \
        "${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}/owned-paths.txt" \
        "$_listing" "$_work" || return 1
    _selected="$_work/target-payload-list"
    awk -v arch="$_target_arch" '
        {
            path=$0; sub(/\/$/, "", path)
            # Извлекать только файлы и ссылки. Имена каталогов в списке -T
            # могут повторно обрабатываться tar; родительские каталоги он
            # создаёт автоматически для каждого извлечённого файла.
            if ($0 ~ /\/$/) next
            split(path, part, "/")
            if (part[1] == "usr" && part[2] == "lib" && part[3] == "z2k" && part[4] == "bin" && part[5] ~ /^linux-/ && part[5] != ("linux-" arch)) next
            if (part[1] == "usr" && part[2] == "lib" && part[3] == "z2k" && part[4] == "platform" && part[5] == "openwrt" && part[6] == "bin" && part[7] ~ /^linux-/ && part[7] != ("linux-" arch)) next
            if (part[1] == "opt" && part[2] == "zapret2" && part[3] == "binaries" && part[4] ~ /^linux-/ && part[4] != ("linux-" arch)) next
            print $0
        }
    ' "$_listing" > "$_selected" || return 1
    _unpacked="$(z2k_ow_payload_size_for_arch "$_archive" "$_target_arch")" || return 1
    case "$_unpacked" in ''|*[!0-9]*) return 1 ;; esac
    _available_kb="$(df -Pk "$_stage" 2>/dev/null | awk 'END {print $4}')"
    case "$_available_kb" in ''|*[!0-9]*) echo "z2k-openwrt: не удалось определить место для распаковки архива" >&2; return 1 ;; esac
    if ! awk -v free_kb="$_available_kb" -v needed="$_unpacked" 'BEGIN { exit (free_kb * 1024 >= needed + 8388608) ? 0 : 1 }'; then
        echo "z2k-openwrt: недостаточно места для распаковки файлов выбранной архитектуры (нужно ${_unpacked} байт и ещё 8 МиБ; доступно ${_available_kb} КиБ)" >&2
        return 1
    fi
    tar -xzf "$_archive" -C "$_stage" -T "$_selected" || return 1
    for _required in \
        "usr/lib/z2k/bin/linux-$_target_arch/tg-mtproxy-client" \
        "usr/lib/z2k/bin/linux-$_target_arch/z2k-rt-proxy" \
        "usr/lib/z2k/bin/linux-$_target_arch/z2k-detect" \
        "usr/lib/z2k/platform/openwrt/bin/linux-$_target_arch/z2k-warpd" \
        "opt/zapret2/binaries/linux-$_target_arch/nfq2/nfqws2" \
        "opt/zapret2/binaries/linux-$_target_arch/ip2net/ip2net" \
        "opt/zapret2/binaries/linux-$_target_arch/mdig/mdig"; do
        [ -s "$_stage/$_required" ] && [ -x "$_stage/$_required" ] || {
            echo "z2k-openwrt: в полном архиве релиза отсутствует исполняемый файл выбранной архитектуры $_required" >&2
            return 1
        }
    done
}

# Полную транзакцию может выполнять только один процесс. После аварии остаётся
# файл блокировки с PID; следующий запуск удаляет устаревшую блокировку и
# вызывает z2k_ow_recover_transaction() для восстановления или очистки.
z2k_ow_install_lock_acquire() {
    local _lock="$1" _pid="" _attempt=0
    while [ "$_attempt" -lt 3 ]; do
        if mkdir "$_lock" 2>/dev/null; then
            if ! printf '%s\n' "$$" > "$_lock/pid"; then
                rm -f "$_lock/pid" 2>/dev/null || true
                rmdir "$_lock" 2>/dev/null || true
                return 1
            fi
            return 0
        fi
        if [ ! -d "$_lock" ] || [ -L "$_lock" ]; then
            echo "z2k-openwrt: небезопасный путь блокировки установщика: $_lock" >&2
            return 1
        fi
        _pid="$(cat "$_lock/pid" 2>/dev/null)"
        case "$_pid" in
            ''|*[!0-9]*)
                echo "z2k-openwrt: у блокировки установщика нет корректного владельца: $_lock" >&2
                return 1
                ;;
        esac
        if [ "$_pid" = "$$" ] || kill -0 "$_pid" 2>/dev/null; then
            echo "z2k-openwrt: уже выполняется другой install_release (PID $_pid)" >&2
            return 1
        fi
        rm -f "$_lock/pid" 2>/dev/null || return 1
        rmdir "$_lock" 2>/dev/null || return 1
        _attempt=$((_attempt + 1))
    done
    echo "z2k-openwrt: не удалось получить блокировку установщика $_lock" >&2
    return 1
}

z2k_ow_install_lock_release() {
    local _lock="$1" _pid=""
    [ -d "$_lock" ] && [ ! -L "$_lock" ] || return 0
    _pid="$(cat "$_lock/pid" 2>/dev/null)"
    [ "$_pid" = "$$" ] || return 0
    rm -f "$_lock/pid" 2>/dev/null || return 1
    rmdir "$_lock" 2>/dev/null
}

# Установщик OpenWrt не проходит через установщик Keenetic, который создаёт
# списки WARP для игр. После успешной установки запустить общий обновлятор,
# если списки пусты; доступность источника не влияет на проверку релиза и откат.
z2k_ow_seed_warp_games() {
    [ "${Z2K_OW_TESTING:-0}" != 1 ] || return 0
    local _root="${Z2K_ROOT:-/usr/lib/z2k}" _games="${Z2K_ROOT:-/usr/lib/z2k}/lists/warp/games"
    local _updater="${Z2K_ROOT:-/usr/lib/z2k}/z2k-update-lists.sh" _file
    [ -x "$_updater" ] || return 0
    for _file in "$_games"/*.txt; do
        [ -s "$_file" ] && return 0
    done
    (
        export ZAPRET2_DIR="$_root"
        export CONFIG_FILE="${Z2K_CONFIG:-/etc/z2k/config}"
        export Z2K_WARP_IPSET_SCRIPT="${Z2K_ADAPTER_DIR:-$_root/platform/openwrt}/warp.sh"
        export LOG_FILE="${Z2K_LOG:-/tmp/z2k/logs}/z2k-warp-games.log"
        sh "$_updater" warp-games
    ) </dev/null >/dev/null 2>&1 &
    return 0
}

# Общая точка входа для новой установки и всех обновлений.
z2k_ow_install_release() {
    local _lock _rc
    _lock="$(z2k_ow_path "${Z2K_OW_INSTALL_LOCK:-/usr/lib/.z2k-install.lock}")"
    z2k_ow_install_lock_acquire "$_lock" || return 1
    if _z2k_ow_install_release_locked "$@"; then
        _rc=0
    else
        _rc=$?
    fi
    z2k_ow_install_lock_release "$_lock" || {
        echo "z2k-openwrt: не удалось снять блокировку установщика $_lock" >&2
        [ "$_rc" -ne 0 ] || _rc=1
    }
    [ "$_rc" -ne 0 ] || z2k_ow_seed_warp_games
    return "$_rc"
}
