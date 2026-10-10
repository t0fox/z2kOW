#!/bin/sh
# Единый путь установки полного проверенного релиза OpenWrt.

# Пока install_release работает, WebPanel показывает общий таймер. Записывать
# этапы в её журнал заданий, чтобы было видно медленную распаковку архива;
# команды CLI и cron сохраняют привычный вывод.
z2k_ow_install_progress() {
    [ -n "${Z2K_JOB_ID:-}" ] || { printf 'z2kOW: %s\n' "$*" >&2; return 0; }
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

# Отпечаток применённого архива дополняет tag + seq: одноимённый хотфикс
# может иметь те же продуктовые значения, но другой immutable payload.
z2k_ow_artifact_digest_read() {
    local _digest_file="$1"
    [ -f "$_digest_file" ] && [ ! -L "$_digest_file" ] || return 1
    [ "$(wc -l < "$_digest_file" | tr -d ' \t\r\n')" = 1 ] || return 1
    grep -Eq '^[0-9a-f]{64}$' "$_digest_file" || return 1
    cat "$_digest_file"
}

z2k_ow_artifact_receipt_matches() {
    local _receipt_manifest="$1" _receipt_state="$2" _expected_url="${3:-}" _receipt_expected _receipt_actual
    _receipt_expected="$(z2k_ow_manifest_artifact_sha256 "$_receipt_manifest" "" "$_expected_url")" || return 1
    _receipt_actual="$(z2k_ow_artifact_digest_read "${_receipt_state%/*}/installed-artifact-sha256")" || return 1
    [ "$_receipt_actual" = "$_receipt_expected" ]
}

z2k_ow_artifact_receipt_write() {
    local _receipt_state="$1" _receipt_sha="$2" _receipt_path _receipt_tmp
    printf '%s' "$_receipt_sha" | grep -Eq '^[0-9a-f]{64}$' || return 1
    _receipt_path="${_receipt_state%/*}/installed-artifact-sha256"
    _receipt_tmp="$_receipt_path.z2k-new.$$"
    (umask 077; printf '%s\n' "$_receipt_sha" > "$_receipt_tmp") \
        && mv -f "$_receipt_tmp" "$_receipt_path" || { rm -f "$_receipt_tmp"; return 1; }
}

z2k_ow_restore_artifact_receipt() {
    local _receipt_work="$1" _receipt_state="$2" _receipt_path _receipt_tmp
    _receipt_path="${_receipt_state%/*}/installed-artifact-sha256"
    if [ -f "$_receipt_work/artifact-was-present" ]; then
        [ -f "$_receipt_work/installed-artifact.old" ] || return 1
        _receipt_tmp="$_receipt_path.z2k-recover.$$"
        cp -p "$_receipt_work/installed-artifact.old" "$_receipt_tmp" \
            && mv -f "$_receipt_tmp" "$_receipt_path" \
            && cmp -s "$_receipt_work/installed-artifact.old" "$_receipt_path" || return 1
    elif [ -f "$_receipt_work/state-write-started" ]; then
        rm -f "$_receipt_path" || return 1
    fi
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
    if [ "$_installed" = "$_tag" ] && ! z2k_ow_artifact_receipt_matches "$_manifest" "$_state"; then
        printf 'update %s\n' "$_tag"
        return 0
    fi
    command -v au_decide >/dev/null 2>&1 || {
        echo "z2k-openwrt: механизм выбора версии исходного проекта недоступен" >&2
        return 1
    }
    _decision="$(au_decide "$_installed" "$_manifest")" || return 1
    _action="$(printf '%s\n' "$_decision" | sed -n '1{s/[[:space:]].*$//;p;}')"
    case "$_action" in
        none) printf 'none %s\n' "$_tag" ;;
        patch|reinstall) printf 'update %s\n' "$_tag" ;;
        *) echo "z2k-openwrt: неверный результат выбора версии исходного проекта" >&2; return 1 ;;
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
        if wget -q -T 60 -O "$_out" "$_url"; then
            return 0
        else
            _download_rc=$?
        fi
    elif command -v curl >/dev/null 2>&1; then
        if curl --fail --location --silent --show-error --connect-timeout 10 --max-time 180 -o "$_out" "$_url"; then
            return 0
        else
            _download_rc=$?
        fi
    else
        echo "z2k-openwrt: нужна программа для защищённой загрузки (wget или curl)" >&2
        return 1
    fi
    echo "z2k-openwrt: не удалось скачать архив выпуска: адрес $_url; временный файл $_out; код ошибки $_download_rc" >&2
    return "$_download_rc"
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

# Системные зависимости должны быть готовы до остановки работающего z2k.
z2k_ow_system_dependencies() {
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
                echo "z2k-openwrt: перенос остановлен: путь прежнего источника пакетов является символической ссылкой: $_feed" >&2
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
        echo "z2k-openwrt: перенос остановлен: пакет $_pkg владеет защищённым путём LuCI/uhttpd" >&2
                    return 1
                    ;;
            esac
            while IFS= read -r _owned_path; do
                [ -n "$_owned_path" ] || continue
                z2k_ow_legacy_path_allowed "$_owned_path" || {
                    echo "z2k-openwrt: перенос остановлен: пакет $_pkg владеет неизвестным путём $_owned_path" >&2
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
            echo "z2k-openwrt: ключ прежнего источника пакетов не совпадает с ключом z2kOW; перенос остановлен" >&2
            return 1
        fi
    fi

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
            echo "z2k-openwrt: в $_feed осталась неизвестная запись старого источника пакетов" >&2
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
                || path ~ /(^|\/)[^\/]+\.apk$/ || path == "packages.adb") exit 1
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
                sync || { _failed=1; continue; }
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
                sync || { _failed=1; continue; }
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
            sync || return 1
            mv "$_dst" "$_save" || return 1
        else
            sync || return 1
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
        sync || return 1
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

z2k_ow_remove_boot_recovery() {
    local _br_work="$1" _br_hook _br_expected
    [ -f "$_br_work/recovery-hook" ] || return 0
    _br_hook="$(cat "$_br_work/recovery-hook")" || return 1
    _br_expected="$(z2k_ow_path /etc/rc.d/S21z2kow-install-recovery)"
    [ "$_br_hook" = "$_br_expected" ] || return 1
    if [ -e "$_br_hook" ] || [ -L "$_br_hook" ]; then
        [ -L "$_br_hook" ] && [ "$(readlink "$_br_hook")" = "$_br_work/recovery-engine/recover_boot.sh" ] || {
            echo "z2k-openwrt: ссылка загрузочного восстановления заменена; журнал оставлен" >&2
            return 1
        }
        rm -f "$_br_hook" || return 1
    fi
}

# Сохранить только принадлежащие продукту ссылки запуска. Старые init-скрипты
# могут ещё не иметь recovery guard, поэтому при аварии они не должны запускаться.
z2k_ow_capture_startup() {
    local _bs_work="$1" _bs_dir _bs_path _bs_name _bs_target _bs_service
    _bs_dir="$(z2k_ow_path /etc/rc.d)"
    mkdir -p "$_bs_work/startup-links" || return 1
    [ -d "$_bs_work/startup-links" ] && [ ! -L "$_bs_work/startup-links" ] || return 1
    : > "$_bs_work/startup-paths" || return 1
    for _bs_path in "$_bs_dir"/S??z2k "$_bs_dir"/S??z2k-webpanel; do
        [ -e "$_bs_path" ] || [ -L "$_bs_path" ] || continue
        _bs_name=${_bs_path##*/}
        case "$_bs_name" in S[0-9][0-9]z2k) _bs_service=z2k ;; S[0-9][0-9]z2k-webpanel) _bs_service=z2k-webpanel ;; *) return 1 ;; esac
        [ -L "$_bs_path" ] || { echo "z2k-openwrt: неизвестный путь автозапуска: $_bs_path" >&2; return 1; }
        _bs_target="$(readlink "$_bs_path")" || return 1
        case "$_bs_target" in "../init.d/$_bs_service"|"/etc/init.d/$_bs_service"|"$(z2k_ow_path "/etc/init.d/$_bs_service")") ;;
            *) echo "z2k-openwrt: неизвестная цель автозапуска: $_bs_path" >&2; return 1 ;;
        esac
        rm -f "$_bs_work/startup-links/$_bs_name" || return 1
        ln -s "$_bs_target" "$_bs_work/startup-links/$_bs_name" || return 1
        printf '%s\n' "$_bs_name" >> "$_bs_work/startup-paths" || return 1
    done
    : > "$_bs_work/startup-links-prepared"
}

z2k_ow_suspend_startup() {
    local _bs_work="$1" _bs_dir _bs_path _bs_name _bs_target _bs_service
    [ -f "$_bs_work/startup-links-prepared" ] || return 0
    _bs_dir="$(z2k_ow_path /etc/rc.d)"
    for _bs_path in "$_bs_dir"/S??z2k "$_bs_dir"/S??z2k-webpanel; do
        [ -e "$_bs_path" ] || [ -L "$_bs_path" ] || continue
        _bs_name=${_bs_path##*/}
        case "$_bs_name" in S[0-9][0-9]z2k) _bs_service=z2k ;; S[0-9][0-9]z2k-webpanel) _bs_service=z2k-webpanel ;; *) return 1 ;; esac
        [ -L "$_bs_path" ] || return 1
        _bs_target="$(readlink "$_bs_path")" || return 1
        case "$_bs_target" in "../init.d/$_bs_service"|"/etc/init.d/$_bs_service"|"$(z2k_ow_path "/etc/init.d/$_bs_service")") ;;
            *) return 1 ;;
        esac
        rm -f "$_bs_path" || return 1
    done
    sync
}

z2k_ow_restore_startup() {
    local _bs_work="$1" _bs_dir _bs_name _bs_target _bs_mode="${2:-rollback}" _bs_service _bs_existing _bs_found
    [ -f "$_bs_work/startup-links-prepared" ] || return 0
    [ "$_bs_mode" = commit ] || z2k_ow_suspend_startup "$_bs_work" || return 1
    _bs_dir="$(z2k_ow_path /etc/rc.d)"
    while IFS= read -r _bs_name; do
        case "$_bs_name" in S[0-9][0-9]z2k|S[0-9][0-9]z2k-webpanel) ;; *) return 1 ;; esac
        if [ "$_bs_mode" = commit ]; then
            # enable уже создал ссылки нового релиза. Если dataplane выключен,
            # сохранить прежний автозапуск для его независимых maintenance-задач.
            case "$_bs_name" in S[0-9][0-9]z2k) _bs_service=z2k ;; *) _bs_service=z2k-webpanel ;; esac
            _bs_found=0
            for _bs_existing in "$_bs_dir"/S??"$_bs_service"; do
                if [ -e "$_bs_existing" ] || [ -L "$_bs_existing" ]; then _bs_found=1; break; fi
            done
            [ "$_bs_found" = 0 ] || continue
        fi
        [ -L "$_bs_work/startup-links/$_bs_name" ] || return 1
        _bs_target="$(readlink "$_bs_work/startup-links/$_bs_name")" || return 1
        ln -s "$_bs_target" "$_bs_dir/$_bs_name" || return 1
    done < "$_bs_work/startup-paths"
    sync
}

# Копия того же проверенного движка остаётся на постоянном разделе, даже когда
# основные файлы программы временно отсутствуют. rcS вызовет её до z2k (START=22).
z2k_ow_prepare_boot_recovery() {
    local _br_work="$1" _br_tmp="$2" _br_adapter="$3" _br_engine _br_hook _br_file
    _br_engine="$_br_work/recovery-engine"
    _br_hook="$(z2k_ow_path /etc/rc.d/S21z2kow-install-recovery)"
    if [ -e "$_br_hook" ] || [ -L "$_br_hook" ]; then
        [ -L "$_br_hook" ] && [ "$(readlink "$_br_hook")" = "$_br_engine/recover_boot.sh" ] || {
            echo "z2k-openwrt: чужая ссылка запуска мешает подготовить восстановление при загрузке" >&2
            return 1
        }
    fi
    mkdir -p "$_br_engine" "${_br_hook%/*}" || return 1
    for _br_file in paths.sh env.sh release_state.sh release.sh arch.sh recover_boot.sh; do
        [ -f "$_br_adapter/$_br_file" ] && [ -s "$_br_adapter/$_br_file" ] || return 1
        cp -p "$_br_adapter/$_br_file" "$_br_engine/$_br_file" || return 1
    done
    chmod 0755 "$_br_engine/recover_boot.sh" || return 1
    printf '%s\n' "$_br_tmp" > "$_br_work/temporary-work" || return 1
    printf '%s\n' "$_br_hook" > "$_br_work/recovery-hook" || return 1
    if [ ! -L "$_br_hook" ]; then
        ln -s "$_br_engine/recover_boot.sh" "$_br_hook" || return 1
    fi
    z2k_ow_capture_startup "$_br_work"
}

z2k_ow_remove_empty_install_tmp_parent() {
    local _parent="$1" _canonical_suffix="${Z2K_OW_CANON_INSTALL_TMP_SUFFIX:-}" _canonical
    [ -n "$_canonical_suffix" ] || return 0
    _canonical="$(z2k_ow_path "$_canonical_suffix")" || return 1
    [ "$_parent" = "$_canonical" ] || return 0
    rmdir "$_parent" 2>/dev/null || true
}

z2k_ow_cleanup_install_workspace() {
    _failed=0
    # Cleanup вызывается после подтверждённого commit/rollback либо до замены
    # файлов. Сначала снять active и сохранить это на диск: ошибка удаления
    # workspace после снятия boot hook не должна заблокировать здоровые службы.
    if [ -e "$1/transaction-active" ] || [ -L "$1/transaction-active" ]; then
        rm -f "$1/transaction-active" || return 1
        sync || return 1
    fi
    z2k_ow_remove_boot_recovery "$1" || return 1
    rm -rf "$1" || _failed=1
    if [ -e "$2" ] || [ -L "$2" ]; then
        if z2k_ow_temp_workspace_owned "$2"; then
            rm -rf "$2" || _failed=1
        else
            echo "z2k-openwrt: временный каталог не принадлежит установщику; оставлен без изменений: $2" >&2
            _failed=1
        fi
    fi
    z2k_ow_remove_empty_install_tmp_parent "${2%/*}" || _failed=1
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

# Удалять только каталог распаковки с проверенным маркером владельца. Он может
# остаться после отключения питания до начала транзакции.
z2k_ow_remove_install_stage() {
    local _stage_path="$1" _work_path="$2" _owner="${1}.owner"
    [ "$_stage_path" = "$_work_path/stage" ] || return 1
    [ -d "$_work_path" ] && [ ! -L "$_work_path" ] || return 1
    if [ -e "$_stage_path" ] || [ -L "$_stage_path" ] \
        || [ -e "$_owner" ] || [ -L "$_owner" ]; then
        [ -d "$_stage_path" ] && [ ! -L "$_stage_path" ] \
            && [ -f "$_owner" ] && [ ! -L "$_owner" ] \
            && [ "$(cat "$_owner" 2>/dev/null)" = "z2kow-overlay-stage-v1" ] || {
                echo "z2k-openwrt: каталог временной распаковки не принадлежит установщику; оставлен без изменений: $_stage_path" >&2
                return 1
            }
        rm -rf "$_stage_path" "$_owner" || return 1
    fi
    return 0
}

# Архив проверяется до заполнения этого каталога. Распакованные файлы находятся
# на постоянном разделе, чтобы не занимать оперативную память роутера. Маркер
# позволяет удалить незавершённую распаковку после отключения питания.
z2k_ow_prepare_install_stage() {
    local _stage_path="$1" _work_path="$2" _owner="${1}.owner"
    [ "$_stage_path" = "$_work_path/stage" ] || return 1
    [ -d "$_work_path" ] && [ ! -L "$_work_path" ] || return 1
    z2k_ow_remove_install_stage "$_stage_path" "$_work_path" || return 1
    mkdir -m 700 "$_stage_path" \
        && printf '%s\n' 'z2kow-overlay-stage-v1' > "$_owner" || {
            rm -rf "$_stage_path" "$_owner"
            return 1
        }
}

z2k_ow_cleanup_temp_workspace() {
    [ -e "$1" ] || [ -L "$1" ] || return 0
    z2k_ow_temp_workspace_owned "$1" || {
        echo "z2k-openwrt: временный каталог не принадлежит установщику; оставлен без изменений: $1" >&2
        return 1
    }
    rm -rf "$1" && z2k_ow_remove_empty_install_tmp_parent "${1%/*}"
}

# Откатить активную транзакцию. Удалять резервные копии и журнал только после
# проверки файлов, состояния релиза и восстановленных служб.
z2k_ow_rollback_install() {
    _rollback_phase="$1"
    echo "z2k-openwrt: этап «$_rollback_phase» не выполнен; восстанавливается предыдущий релиз" >&2
    z2k_ow_suspend_startup "$_work" || return 1
    if [ -f "$_work/reinstall-from-archive" ]; then
        z2k_ow_restore_direct_archive "$_work" "$_paths" "$_state" || {
            echo "z2k-openwrt: восстановление из проверенного архива не завершено; данные сохранены в $_work" >&2
            z2k_ow_cleanup_temp_workspace "$_tmp_work" || true
            return 1
        }
    elif ! z2k_ow_restore_paths "$_transaction" "$_paths" "$_transaction_id"; then
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
    z2k_ow_restore_artifact_receipt "$_work" "$_state" && sync || {
        echo "z2k-openwrt: отпечаток прежнего архива не восстановлен; журнал оставлен" >&2
        return 1
    }
    z2k_ow_restart_services "$_service" "$_panel" \
        || { echo "z2k-openwrt: предыдущие службы не запустились; данные восстановления оставлены в $_work" >&2; z2k_ow_cleanup_temp_workspace "$_tmp_work" || true; return 1; }
    { [ ! -x "$_service" ] || ! z2k_ow_service_enabled \
        || { z2k_ow_service_call "$_service" status >/dev/null 2>&1 && z2k_ow_dataplane_ready; }; } \
        || { echo "z2k-openwrt: служба z2k не прошла проверку состояния; данные оставлены в $_work" >&2; z2k_ow_cleanup_temp_workspace "$_tmp_work" || true; return 1; }
        { [ ! -x "$_panel" ] || { z2k_ow_service_call "$_panel" running >/dev/null 2>&1 && z2k_ow_webpanel_http_ready; }; } \
        || { echo "z2k-openwrt: служба панели управления или проверка доступности по HTTP не пройдена; данные оставлены в $_work" >&2; z2k_ow_cleanup_temp_workspace "$_tmp_work" || true; return 1; }
    z2k_ow_restore_startup "$_work" || return 1
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
    _transaction_target_digest=""
    _installed_digest=""
    if [ -e "$_work/transaction-artifact" ] || [ -L "$_work/transaction-artifact" ]; then
        _transaction_target_digest="$(z2k_ow_artifact_digest_read "$_work/transaction-artifact")" || {
            echo "z2k-openwrt: повреждён отпечаток цели транзакции; журнал оставлен" >&2
            return 1
        }
        _installed_digest="$(z2k_ow_artifact_digest_read "${_state%/*}/installed-artifact-sha256")" || _installed_digest=""
    fi
    if [ -n "$_installed_record" ] \
        && [ "$_installed_record" = "$_transaction_target_record" ] \
        && { [ -z "$_transaction_target_digest" ] || [ "$_installed_digest" = "$_transaction_target_digest" ]; } \
        && [ -f "$_work/state-write-started" ] \
        && [ -f "$_transaction" ] \
        && ! grep -q '^R|' "$_transaction"; then
        # Проверка состояния и запись версии успели завершиться до отключения
        # питания; прервалось только удаление временных файлов транзакции.
        # Записи R| означают, что начался откат; даже совпадающий tag + seq
        # при повторной установке не должен превращать его в успешный commit.
        z2k_ow_restore_startup "$_work" commit || return 1
        z2k_ow_cleanup_transaction "$_paths" "$_id" || {
            echo "z2k-openwrt: очистка завершённой транзакции не выполнена; журнал оставлен в $_work" >&2
            return 1
        }
        z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work" || return 1
        return 0
    fi
    z2k_ow_suspend_startup "$_work" || return 1
    if [ -f "$_work/reinstall-from-archive" ]; then
        z2k_ow_restore_direct_archive "$_work" "$_paths" "$_state" || return 1
    else
        z2k_ow_restore_paths "$_transaction" "$_paths" "$_id" || return 1
    fi
    if [ -f "$_work/state-was-present" ]; then
        [ -f "$_work/installed-release.old" ] || return 1
        _state_tmp="${_state}.z2k-recover.$$"
        cp -p "$_work/installed-release.old" "$_state_tmp" && mv -f "$_state_tmp" "$_state" \
            && cmp -s "$_work/installed-release.old" "$_state" || return 1
    elif [ -f "$_work/state-write-started" ]; then
        rm -f "$_state" || return 1
    fi
    z2k_ow_restore_artifact_receipt "$_work" "$_state" && sync || {
        echo "z2k-openwrt: отпечаток прежнего архива не восстановлен; журнал оставлен" >&2
        return 1
    }
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
        echo "z2k-openwrt: панель управления после восстановления не прошла проверку; журнал оставлен в $_work" >&2
        return 1
    }
    z2k_ow_restore_startup "$_work" || return 1
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

# Сопоставить путь с самым длинным mountpoint, а не с именем устройства df.
z2k_ow_storage_type() {
    local _storage_path _mountinfo="${Z2K_OW_MOUNTINFO_FILE:-/proc/self/mountinfo}"
    _storage_path="$(readlink -f "$1" 2>/dev/null)" || return 1
    [ -n "$_storage_path" ] && [ -r "$_mountinfo" ] || return 1
    Z2K_STORAGE_PATH="$_storage_path" awk '
        BEGIN { path=ENVIRON["Z2K_STORAGE_PATH"] }
        {
            point=$5
            gsub(/\\040/, " ", point)
            gsub(/\\011/, "\t", point)
            if (point == "/" || path == point || index(path, point "/") == 1) {
                if (length(point) > longest) {
                    for (i=6; i<=NF; i++) if ($i == "-") {
                        kind=$(i+1); longest=length(point); break
                    }
                }
            }
        }
        END { if (kind == "") exit 1; print kind }
    ' "$_mountinfo"
}

# Оценка складывает одновременно используемые оперативную память и временное хранилище.
# После записи архива, распаковки и списков файлов они уже учтены в MemAvailable и df.
z2k_ow_memory_preflight() {
    local _memory_path="$1" _archive_bytes="$2" _stage_bytes="$3" _engine_index_bytes="$4"
    local _memory_reserve="$5" _tmpfs_extra_bytes="${6:-0}" _memory_type _memory_available _memory_tmp_free_kb
    local _memory_info="${Z2K_OW_MEMINFO_FILE:-/proc/meminfo}"
    _memory_type="$(z2k_ow_storage_type "$_memory_path")" || {
        echo "z2k-openwrt: не удалось определить тип временной файловой системы: $_memory_path" >&2
        return 1
    }
    for _budget_value in "$_archive_bytes" "$_stage_bytes" "$_engine_index_bytes" \
        "$_memory_reserve" "$_tmpfs_extra_bytes"; do
        case "$_budget_value" in ''|*[!0-9]*) echo "z2k-openwrt: неверная оценка временного бюджета" >&2; return 1 ;; esac
        [ "${#_budget_value}" -le 10 ] && [ "$_budget_value" -le 2147483647 ] 2>/dev/null \
            || { echo "z2k-openwrt: оценка временного бюджета выходит за допустимый диапазон" >&2; return 1; }
    done
    [ -r "$_memory_info" ] || return 1
    _memory_available=$(awk '
        /^MemAvailable:/ { available=$2; found=1 }
        /^MemFree:/ { free=$2; fallback=1 }
        /^Buffers:/ { buffers=$2 }
        /^Cached:/ { cached=$2 }
        /^Shmem:/ { shmem=$2 }
        END {
            if (!found && !fallback) exit 1
            if (!found) available=free+buffers+cached-shmem
            if (available < 0) available=0
            if (available ~ /^[0-9]+$/) printf "%.0f\n", available
            else exit 1
        }
    ' "$_memory_info") || return 1
    [ -n "$_memory_available" ] || return 1
    awk -v kind="$_memory_type" -v available="$_memory_available" \
        -v archive="$_archive_bytes" -v stage="$_stage_bytes" \
        -v engine="$_engine_index_bytes" -v reserve="$_memory_reserve" \
        -v tmpfs_extra="$_tmpfs_extra_bytes" '
        BEGIN {
            if (available !~ /^[0-9]+$/ || archive !~ /^[0-9]+$/ \
                || stage !~ /^[0-9]+$/ || engine !~ /^[0-9]+$/ \
                || reserve !~ /^[0-9]+$/ || tmpfs_extra !~ /^[0-9]+$/) exit 1
            ram_archive = (kind == "tmpfs" || kind == "ramfs" || kind == "rootfs") ? archive : 0
            ram_needed = ram_archive + stage + engine + reserve
            tmpfs_needed = archive + stage + tmpfs_extra + reserve
            if (available*1024 < ram_needed) {
                printf "z2k-openwrt: недостаточно свободной оперативной памяти для установщика и резерва (нужно %.0f байт; доступно %.0f КиБ)\n", ram_needed, available > "/dev/stderr"
                exit 1
            }
            exit 0
        }' || return 1
    _memory_tmp_free_kb=$(df -Pk "$_memory_path" 2>/dev/null | awk 'END { if (NR >= 2) print $4 }') || return 1
    case "$_memory_tmp_free_kb" in ''|*[!0-9]*)
        echo "z2k-openwrt: не удалось определить свободное место на временной файловой системе: $_memory_path" >&2
        return 1 ;;
    esac
    awk -v free_kb="$_memory_tmp_free_kb" -v archive="$_archive_bytes" \
        -v stage="$_stage_bytes" -v extra="$_tmpfs_extra_bytes" -v reserve="$_memory_reserve" '
        BEGIN {
            needed = archive + stage + extra + reserve
            if (free_kb !~ /^[0-9]+$/ || free_kb*1024 < needed) {
                printf "z2k-openwrt: недостаточно места во временном хранилище (нужно %.0f байт; доступно %.0f КиБ)\n", needed, free_kb > "/dev/stderr"
                exit 1
            }
        }'
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
    for _tool in awk df du grep readlink sha256sum sync tar tr xargs; do
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
    command -v curl >/dev/null 2>&1 || { echo "z2k-openwrt: не найдена программа curl для проверки доступности панели по HTTP" >&2; return 1; }
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
            echo "z2k-openwrt: сетевой модуль не прошёл проверку очереди NFQUEUE" >&2
            return 1
        }
        return 0
    fi
    [ "${Z2K_OW_TESTING:-0}" = 1 ] && return 0
    echo "z2k-openwrt: не удалось проверить готовность сетевого модуля" >&2
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
        echo "Использование: install_release --reinstall <тег-установленного-релиза>" >&2
            return 2
        }
        _requested="$2"
    else
        [ "$#" -eq 1 ] || {
        echo "Использование: install_release <тег-релиза>" >&2
            return 2
        }
        _requested="$1"
    fi
    printf '%s' "$_requested" | grep -Eq '^[pr]-[0-9]+(\.[0-9]+)+$' || {
        echo "Использование: install_release [--reinstall] <тег-релиза>" >&2
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
    _stage="$_work/stage"
    _archive="$_work/openwrt-rootfs.tar.gz"
    _manifest="${Z2K_OW_BOOTSTRAP_MANIFEST:-${Z2K_OW_MANIFEST_PATH:-${Z2K_AU_TMP_DIR:-/tmp/z2k/update}/UPDATES.json}}"
    . "$_adapter/arch.sh" || return 1
    _target_arch="$(z2k_ow_arch_name 2>/dev/null)" || {
        echo "z2k-openwrt: архитектура роутера не поддерживается" >&2
        return 1
    }
    _bootstrap_artifact_url=""
    _bootstrap_manifest_base=""
    if [ -n "${Z2K_OW_BOOTSTRAP_MANIFEST:-}" ] \
        && [ "$_manifest" = "$Z2K_OW_BOOTSTRAP_MANIFEST" ] \
        && [ -n "${Z2KOW_MANIFEST_URL:-}" ]; then
        case "$Z2KOW_MANIFEST_URL" in
            http://*/UPDATES.json|https://*/UPDATES.json)
                _bootstrap_manifest_base="${Z2KOW_MANIFEST_URL%/UPDATES.json}"
                ;;
            *) echo "z2k-openwrt: неверный адрес манифеста обновления при первой установке" >&2; return 1 ;;
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
        [ "$(id -u 2>/dev/null || echo 1)" = 0 ] || { echo "install_release нужно запускать от имени суперпользователя" >&2; return 1; }
        . "$_adapter/env.sh" || return 1
        . "$_lib/utils.sh" || return 1
        . "$_lib/auto_update.sh" || return 1
        . "$_adapter/manifest.sh" || return 1
        if [ -n "${Z2K_OW_BOOTSTRAP_MANIFEST:-}" ]; then
            _sig="${Z2K_OW_BOOTSTRAP_SIGNATURE:-${Z2K_OW_BOOTSTRAP_MANIFEST}.sig}"
            z2k_ow_manifest_verify_signature "$_manifest" "$_sig" || {
                echo "z2k-openwrt: подпись манифеста первой установки неверна или недоступна" >&2
                return 1
            }
        else
            z2k_ow_manifest_prepare_production "$_manifest" || return 1
        fi
    else
        . "$_adapter/manifest.sh" || return 1
    fi
    if [ -n "$_bootstrap_manifest_base" ]; then
        case "$(z2k_ow_manifest_type "$_manifest" artifacts)" in
            object) _bootstrap_artifact_filename="openwrt-rootfs-$_target_arch.tar.gz" ;;
            '') _bootstrap_artifact_filename="openwrt-rootfs.tar.gz" ;;
            *) echo "z2k-openwrt: неверная карта архитектурных архивов" >&2; return 1 ;;
        esac
        _bootstrap_artifact_url="$_bootstrap_manifest_base/$_bootstrap_artifact_filename"
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
        && z2k_ow_artifact_receipt_matches "$_manifest" "$_state" "$_bootstrap_artifact_url" \
        && ! z2k_ow_legacy_packages_present && ! z2k_ow_relay_identity_migration_needed; then
        if z2k_ow_installed_payload_ready; then
            echo "none $_tag"
            return 0
        fi
        echo "z2k-openwrt: файлы или службы установленного релиза повреждены; выполняется полное восстановление" >&2
    fi

    z2k_ow_manifest_select_artifact "$_manifest" "$_target_arch" "$_bootstrap_artifact_url" || return 1
    _url="$Z2K_OW_ARTIFACT_URL"
    _sha="$Z2K_OW_ARTIFACT_SHA256"
    _size="$Z2K_OW_ARTIFACT_SIZE_BYTES"
    _manifest_unpacked="$Z2K_OW_ARTIFACT_UNPACKED_SIZE_BYTES"
    case "$_sha" in *[!0-9a-f]*|'') return 1 ;; esac
    [ "${#_sha}" -eq 64 ] || return 1
    case "$_size" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_size" -gt 0 ] || return 1
    _same_artifact_reinstall=0
    if [ "$_reinstall" = 1 ]; then
        _installed_artifact="$(z2k_ow_artifact_digest_read "${_state%/*}/installed-artifact-sha256")" \
            || _installed_artifact=
        [ -n "$_installed_artifact" ] && [ "$_installed_artifact" = "$_sha" ] \
            && _same_artifact_reinstall=1
    fi

    mkdir -p "$_work" || return 1
    z2k_ow_prepare_temp_workspace "$_tmp_work" || return 1
    # Загруженный архив хранится на постоянном разделе вместе с временной
    # распаковкой, поэтому оперативную память и временное хранилище резервируем
    # только под индексы, служебные файлы и запас.
    _pre_archive=0 _pre_stage=0 _pre_engine=0 _pre_overlay_archive=0
    if [ -z "${Z2K_OW_BOOTSTRAP_ARTIFACT:-}" ] \
        && ! { [ "${Z2K_OW_TESTING:-0}" = 1 ] && [ -n "${Z2K_OW_ARTIFACT_PATH:-}" ]; }; then
        _pre_overlay_archive="$_size"
        _pre_engine=2097152
    fi
    z2k_ow_install_progress "Проверяю совместный запас оперативной памяти и временного хранилища"
    z2k_ow_memory_preflight "$_tmp_work" "$_pre_archive" "$_pre_stage" \
        "$_pre_engine" 8388608 "$_pre_engine" \
        || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    rm -rf "$_transaction" "$_work/transaction-active" \
        "$_work/transaction-id" "$_work/state-was-present" \
        "$_work/state-write-started" "$_work/transaction-target" \
        "$_work/transaction-artifact" "$_work/artifact-was-present" "$_work/installed-artifact.old" \
        "$_work/transaction-artifact-size" "$_work/transaction-arch" \
        "$_work/reinstall-from-archive" "$_work/transaction-target.new.$$" "$_old_state"
    if [ -e "$_archive" ] || [ -L "$_archive" ]; then
        [ -f "$_archive" ] && [ ! -L "$_archive" ] || {
            echo "z2k-openwrt: временный архив повреждён или подменён; проверьте $_archive" >&2
            return 1
        }
        rm -f "$_archive" || {
            echo "z2k-openwrt: не удалось удалить незавершённый архив предыдущей попытки" >&2
            return 1
        }
    fi
    if [ "$_same_artifact_reinstall" = 1 ]; then
        z2k_ow_remove_install_stage "$_stage" "$_work" || {
            echo "z2k-openwrt: не удалось безопасно удалить оставшуюся временную распаковку" >&2
            z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"
            return 1
        }
    elif ! z2k_ow_prepare_install_stage "$_stage" "$_work"; then
        z2k_ow_cleanup_temp_workspace "$_tmp_work" || true
        return 1
    fi
    if [ "$_pre_overlay_archive" -gt 0 ]; then
        z2k_ow_install_progress "Проверяю место на постоянном разделе под архив, распаковку и восстановление"
        _pre_overlay_payload="${_manifest_unpacked:-0}"
        [ "$_same_artifact_reinstall" != 1 ] || _pre_overlay_payload=0
        z2k_ow_overlay_download_preflight "$_work" "$_pre_overlay_archive" "$_pre_overlay_payload" \
            || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    fi
    if [ -n "${Z2K_OW_BOOTSTRAP_ARTIFACT:-}" ]; then
        _archive="$Z2K_OW_BOOTSTRAP_ARTIFACT"
    elif [ "${Z2K_OW_TESTING:-0}" = 1 ] && [ -n "${Z2K_OW_ARTIFACT_PATH:-}" ]; then
        _archive="$Z2K_OW_ARTIFACT_PATH"
    else
        z2k_ow_install_progress "Загружаю архив архитектуры $_target_arch"
        z2k_ow_download "$_url" "$_archive" || {
            z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1;
        }
    fi
    z2k_ow_install_progress "Проверяю размер и SHA-256 архива"
    _actual_size="$(wc -c < "$_archive" | tr -d ' \t\r\n')"
    [ "$_actual_size" = "$_size" ] || {
        echo "z2k-openwrt: размер архива не совпал с манифестом (ожидалось $_size байт, получено $_actual_size)" >&2
        z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"
        return 1
    }
    _actual="$(sha256sum "$_archive" 2>/dev/null | awk '{print $1}')"
    [ "$_actual" = "$_sha" ] || {
        echo "z2k-openwrt: SHA-256 архива не совпал с проверенным манифестом" >&2
        z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"
        return 1
    }
    if [ "$_same_artifact_reinstall" = 1 ] && [ "$_archive" != "$_work/openwrt-rootfs.tar.gz" ]; then
        cp -p "$_archive" "$_work/openwrt-rootfs.tar.gz" || {
            echo "z2k-openwrt: не удалось сохранить архив повторной установки для восстановления" >&2
            z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"
            return 1
        }
        _archive="$_work/openwrt-rootfs.tar.gz"
    fi
    z2k_ow_install_progress "Проверяю список файлов архива"
    z2k_ow_archive_safe "$_archive" "$_work/archive-list" \
        || { echo "z2k-openwrt: архив содержит запрещённый путь, тип записи или цель ссылки" >&2; z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    z2k_ow_owned_paths > "$_paths" || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    if [ "$_same_artifact_reinstall" = 1 ]; then
        z2k_ow_install_progress "Проверяю список файлов перед повторной установкой той же версии"
        z2k_ow_prepare_target_payload_list "$_archive" "$_work/archive-list" \
            "$_work" "$_target_arch" \
            || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    else
        z2k_ow_install_progress "Извлекаю файлы для архитектуры роутера"
        z2k_ow_extract_target_payload "$_archive" "$_stage" "$_work/archive-list" "$_work" "$_tmp_work" \
            || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    fi
    # Проверить постоянное хранилище до установки пакетов: apk сам меняет
    # overlay, поэтому отказ по недостатку места должен наступить раньше.
    if [ "$_same_artifact_reinstall" = 1 ]; then
        z2k_ow_install_progress "Заранее проверяю место для повторной установки"
        z2k_ow_overlay_direct_preflight "$_archive" "$_target_arch" "$_paths" "$_work" \
            || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    else
        z2k_ow_install_progress "Заранее проверяю место для архива, распаковки и отката"
        z2k_ow_overlay_preflight "$_archive" "$_target_arch" "$_adapter/owned-paths.txt" \
            "$_work/archive-list" "$_work" "$_stage" \
            || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    fi
    z2k_ow_install_progress "Проверяю системные зависимости до остановки служб"
    z2k_ow_system_dependencies || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    # apk мог занять место: повторить расчёт payload на каждой целевой ФС.
    if [ "$_same_artifact_reinstall" = 1 ]; then
        z2k_ow_install_progress "Повторно проверяю место для архива и замены прежних файлов"
        z2k_ow_overlay_direct_preflight "$_archive" "$_target_arch" "$_paths" "$_work" \
            || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
        z2k_ow_install_progress "Повторно проверяю свободную память перед заменой файлов"
        z2k_ow_memory_preflight "$_tmp_work" 0 0 2097152 8388608 2097152 \
            || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    else
        z2k_ow_install_progress "Повторно проверяю место после установки системных зависимостей"
        z2k_ow_overlay_preflight "$_archive" "$_target_arch" "$_adapter/owned-paths.txt" \
            "$_work/archive-list" "$_work" "$_stage" \
            || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    fi
    z2k_ow_migrate_relay_identity || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }

    printf '%s\n' "$_transaction_id" > "$_work/transaction-id" \
        || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    _expected_record=$(printf 'tag=%s\nseq=%s' "$_tag" "$_seq")
    printf '%s\n' "$_sha" > "$_work/transaction-artifact" \
        || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    printf '%s\n' "$_size" > "$_work/transaction-artifact-size" \
        || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    printf '%s\n' "$_target_arch" > "$_work/transaction-arch" \
        || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
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
    if [ -e "${_state%/*}/installed-artifact-sha256" ] || [ -L "${_state%/*}/installed-artifact-sha256" ]; then
        [ -f "${_state%/*}/installed-artifact-sha256" ] && [ ! -L "${_state%/*}/installed-artifact-sha256" ] \
            && cp -p "${_state%/*}/installed-artifact-sha256" "$_work/installed-artifact.old" \
            && : > "$_work/artifact-was-present" \
            || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    fi
    z2k_ow_prepare_boot_recovery "$_work" "$_tmp_work" "$_adapter" || {
        z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"
        return 1
    }
    if [ "$_same_artifact_reinstall" = 1 ]; then
        printf '%s\n' same-archive-v1 > "$_work/reinstall-from-archive" || {
            z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"
            return 1
        }
        sync || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    fi
    : > "$_work/transaction-active" \
        || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    sync || { z2k_ow_cleanup_install_workspace "$_work" "$_tmp_work"; return 1; }
    z2k_ow_suspend_startup "$_work" || { z2k_ow_rollback_install "приостановка автозапуска"; return 1; }

    if [ -x "$_service" ]; then
        z2k_ow_install_progress "Останавливаю службу перед заменой файлов"
        _stopped=1
        z2k_ow_service_call "$_service" stop >/dev/null 2>&1 || {
            z2k_ow_rollback_install "остановка службы"
            return 1
        }
    fi
    if [ "$_same_artifact_reinstall" = 1 ]; then
        printf 'V|2\n' > "$_transaction" || { z2k_ow_rollback_install "запись журнала повторной установки"; return 1; }
        z2k_ow_install_progress "Освобождаю место прежних файлов после проверки архива"
        z2k_ow_remove_owned_paths "$_paths" || { z2k_ow_rollback_install "освобождение места для повторной установки"; return 1; }
        z2k_ow_install_progress "Устанавливаю проверенный архив выбранной архитектуры"
        if ! z2k_ow_extract_target_payload_direct "$_archive" "$_work" "$_target_arch" "$_paths"; then
            z2k_ow_rollback_install "распаковка того же проверенного выпуска"
            return 1
        fi
    else
        z2k_ow_backup_paths "$_transaction" "$_paths" "$_transaction_id" || {
            z2k_ow_rollback_install "создание резервных копий"
            return 1
        }
        z2k_ow_legacy_migrate "$(z2k_ow_path /usr/lib/z2k).z2k-backup.$_transaction_id" || {
            z2k_ow_rollback_install "миграция прежней установки"
            return 1
        }
        z2k_ow_install_progress "Применяю проверенные файлы релиза"
        if ! z2k_ow_apply_staged_tree "$_stage" "$_transaction" "$_paths" "$_transaction_id"; then
            z2k_ow_rollback_install "применение файлов"
            return 1
        fi
    fi

    _state_dir="$(dirname "$_state")"
    mkdir -p "$_state_dir" || {
        z2k_ow_rollback_install "создание каталога состояния релиза"
        return 1
    }

    if [ "${Z2K_OW_TESTING:-0}" != 1 ]; then
        _bootstrap="$_adapter/bootstrap.sh"
        if [ -r "$_bootstrap" ]; then
            . "$_bootstrap" || { z2k_ow_rollback_install "загрузка bootstrap"; return 1; }
            . "$_adapter/paths.sh" || { z2k_ow_rollback_install "инициализация путей"; return 1; }
            . "$_adapter/env.sh" || { z2k_ow_rollback_install "инициализация окружения"; return 1; }
            z2k_ow_bootstrap || {
                z2k_ow_rollback_install "инициализация OpenWrt"
                return 1
            }
        fi
    fi
    if [ "${Z2K_OW_TESTING:-0}" != 1 ] || [ "${Z2K_OW_TEST_HEALTHCHECK:-0}" = 1 ]; then
        z2k_ow_install_progress "Перезапускаю сервисы и проверяю доступность панели"
        for _svc in "$_service" "$_panel"; do
            [ -f "$_svc" ] && [ -x "$_svc" ] || {
                echo "z2k-openwrt: обязательный системный скрипт запуска исчез или не запускается: $_svc" >&2
                z2k_ow_rollback_install "проверка обязательного системного скрипта запуска"
                return 1
            }
            if [ "$_svc" = "$_service" ] && ! z2k_ow_service_enabled; then
                continue
            fi
            _svc_name=$(basename "$_svc")
            _enable_log="$_work/$_svc_name-enable.log"
            if ! z2k_ow_service_call "$_svc" enable >"$_enable_log" 2>&1; then
                echo "z2k-openwrt: не удалось включить автозапуск обязательной службы: $_svc" >&2
                tail -n 30 "$_enable_log" >&2 || true
                z2k_ow_rollback_install "включение автозапуска службы"
                return 1
            fi
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
                    z2k_ow_rollback_install "запуск службы"
                    return 1
                fi
            fi
        done
        _n=0
        while [ "$_n" -lt 15 ]; do
            if [ -x "$_service" ] && { ! z2k_ow_service_enabled \
                || { z2k_ow_service_call "$_service" status >/dev/null 2>&1 && z2k_ow_dataplane_ready; }; }; then
                if [ -x "$_panel" ] && z2k_ow_service_call "$_panel" running >/dev/null 2>&1 && z2k_ow_webpanel_http_ready; then break; fi
            fi
            _n=$((_n + 1)); sleep 1
        done
        [ "$_n" -lt 15 ] || { z2k_ow_rollback_install "проверка состояния служб"; return 1; }
    fi

    z2k_ow_restore_startup "$_work" commit || {
        z2k_ow_rollback_install "сохранение настроек автозапуска"
        return 1
    }
    : > "$_work/state-write-started" || {
        z2k_ow_rollback_install "журналирование версии релиза"
        return 1
    }
    sync || { z2k_ow_rollback_install "сохранение журнала версии на диск"; return 1; }
    _state_tmp="${_state}.z2k-new.$_transaction_id"
    if ! z2k_ow_release_state_write "$_state" "$_manifest" \
        || [ "$(z2k_ow_release_state_read "$_state" 2>/dev/null)" != "$_expected_record" ] \
        || ! z2k_ow_artifact_receipt_write "$_state" "$_sha" \
        || ! z2k_ow_artifact_receipt_matches "$_manifest" "$_state" "$_bootstrap_artifact_url" \
        || ! sync; then
        echo "z2k-openwrt: не удалось зафиксировать единую запись установленной версии" >&2
        z2k_ow_rollback_install "фиксация версии и отпечатка архива"
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
    if [ "${Z2K_OW_TESTING:-0}" != 1 ] && command -v z2k_ow_retire_discovery >/dev/null 2>&1; then
        z2k_ow_retire_discovery || {
            echo "z2k-openwrt: релиз установлен; очистка старых данных обнаружения узлов отложена до следующего запуска" >&2
            return 1
        }
    fi
    printf 'Установлен выпуск %s\n' "$_tag"
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

# Для повторной установки того же подписанного архива файлы можно заменить
# на месте: проверенный архив остаётся резервом, поэтому дублировать весь
# установленный набор во временном каталоге не требуется.
z2k_ow_overlay_direct_preflight() {
    local _archive="$1" _arch="$2" _paths="$3" _work="$4"
    local _sizes="$_work/direct-payload-sizes" _requirements="$_work/direct-overlay-requirements"
    local _rel _bytes _dst _probe _df _filesystem _rest _available_kb _mountpoint
    local _reclaim_kb _work_df _work_available_kb
    z2k_ow_payload_sizes_for_arch "$_archive" "$_arch" "$_paths" > "$_sizes" \
        || { echo "z2k-openwrt: не удалось посчитать размер прежнего и нового набора файлов" >&2; return 1; }
    [ -s "$_sizes" ] || { echo "z2k-openwrt: архив не содержит принадлежащие установке файлы" >&2; return 1; }
    _work_df="$(df -Pk "$_work" 2>/dev/null | awk 'END { if (NR >= 2) print $4}')"
    case "$_work_df" in ''|*[!0-9]*)
        echo "z2k-openwrt: не удалось определить свободное место для резервного архива" >&2
        return 1 ;;
    esac
    _work_available_kb="$_work_df"
    if [ "$_work_available_kb" -lt 4096 ]; then
        echo "z2k-openwrt: недостаточно места после сохранения резервного архива: нужно не менее 4 МиБ; доступно $_work_available_kb КиБ" >&2
        return 1
    fi
    : > "$_requirements" || return 1
    while IFS='|' read -r _rel _bytes; do
        [ -n "$_rel" ] || continue
        case "$_bytes" in ''|*[!0-9]*) return 1 ;; esac
        _dst="$(z2k_ow_path "/$_rel")"
        _probe="$(dirname "$_dst")"
        while [ ! -d "$_probe" ] && [ "$_probe" != / ]; do _probe="$(dirname "$_probe")"; done
        [ -d "$_probe" ] || { echo "z2k-openwrt: не найдена файловая система для $_rel" >&2; return 1; }
        _df="$(df -Pk "$_probe" 2>/dev/null | awk 'END { if (NR >= 2) print $1 "|" $4 "|" $NF}')"
        _filesystem=${_df%%|*}
        _rest=${_df#*|}
        _available_kb=${_rest%%|*}
        _mountpoint=${_rest#*|}
        case "$_available_kb" in ''|*[!0-9]*)
            echo "z2k-openwrt: не удалось определить свободное место для $_rel" >&2
            return 1 ;;
        esac
        [ -n "$_filesystem" ] && [ -n "$_mountpoint" ] || return 1
        _reclaim_kb=0
        if [ -e "$_dst" ] || [ -L "$_dst" ]; then
            _reclaim_kb="$(du -sk "$_dst" 2>/dev/null | awk 'END { if (NR >= 1) print $1}')"
            case "$_reclaim_kb" in ''|*[!0-9]*)
                echo "z2k-openwrt: не удалось оценить место, которое освободит прежний путь $_rel" >&2
                return 1 ;;
            esac
        fi
        printf '%s|%s|%s|%s|%s\n' "$_filesystem" "$_mountpoint" \
            "$_available_kb" "$_bytes" "$_reclaim_kb" >> "$_requirements" || return 1
    done < "$_sizes"
    awk -F'|' '
        {
            key=$1 "|" $2
            if (!(key in seen) || $3 < available[key]) available[key]=$3
            seen[key]=1
            needed[key]+=$4
            reclaim[key]+=$5
            mountpoint[key]=$2
        }
        END {
            failed=0
            for (key in seen) {
                if ((available[key] + reclaim[key]) * 1024 < needed[key] + 4194304) {
                    printf "z2k-openwrt: недостаточно места в %s для безопасной повторной установки (нужно %.0f байт; доступно %.0f КиБ, прежние файлы освободят до %.0f КиБ)\n", mountpoint[key], needed[key] + 4194304, available[key], reclaim[key] > "/dev/stderr"
                    failed=1
                }
            }
            exit failed
        }
    ' "$_requirements"
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
    for _ready_path in "$_service" "$_panel"; do
        [ -f "$_ready_path" ] && [ -s "$_ready_path" ] && [ -x "$_ready_path" ] || {
            echo "z2k-openwrt: обязательная служба отсутствует или неисполняема: $_ready_path" >&2
            return 1
        }
    done
    for _ready_path in \
        "$_ready_root/bin/linux-$_ready_arch/tg-mtproxy-client" \
        "$_ready_root/bin/linux-$_ready_arch/z2k-rt-proxy" \
        "$_ready_root/bin/linux-$_ready_arch/z2k-detect" \
        "$_ready_root/platform/openwrt/bin/linux-$_ready_arch/z2k-warpd" \
        "$_ready_runtime/binaries/linux-$_ready_arch/nfqws2" \
        "$_ready_runtime/binaries/linux-$_ready_arch/ip2net" \
        "$_ready_runtime/binaries/linux-$_ready_arch/mdig"; do
        [ -f "$_ready_path" ] && [ -s "$_ready_path" ] && [ -x "$_ready_path" ] || {
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
                    echo "z2k-openwrt: неверная символическая ссылка среды zapret2: $_ready_link" >&2
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
            echo "z2k-openwrt: установленный сетевой модуль не готов" >&2
            return 1
        }
    fi
    if [ -x "$_panel" ]; then
        { z2k_ow_service_call "$_panel" running >/dev/null 2>&1 && z2k_ow_webpanel_http_ready; } || {
            echo "z2k-openwrt: служба панели управления или проверка доступности по HTTP не пройдена" >&2
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
    local _ov_stage="${6:-}" _ov_stage_bytes="${7:-0}" _ov_source _ov_source_fs _ov_stage_df
    local _ov_sizes="$_ov_work/owned-payload-sizes" _ov_requirements="$_ov_work/overlay-requirements"
    local _ov_rel _ov_bytes _ov_member _ov_dst _ov_probe
    local _ov_df _ov_filesystem _ov_df_rest _ov_available_kb _ov_mountpoint
    local _ov_needed _ov_stage_filesystem _ov_stage_available_kb _ov_stage_mountpoint
    case "$_ov_stage_bytes" in ''|*[!0-9]*) return 1 ;; esac
    if [ -n "$_ov_stage" ]; then
        _ov_stage_df="$(df -Pk "$_ov_stage" 2>/dev/null | awk 'END { if (NR >= 2) print $1 "|" $4 "|" $NF}')"
        _ov_stage_filesystem=${_ov_stage_df%%|*}
        _ov_stage_df=${_ov_stage_df#*|}
        _ov_stage_available_kb=${_ov_stage_df%%|*}
        _ov_stage_mountpoint=${_ov_stage_df#*|}
        case "$_ov_stage_available_kb" in ''|*[!0-9]*)
            echo "z2k-openwrt: не удалось определить свободное место на разделе временной распаковки" >&2
            return 1
            ;;
        esac
        [ -n "$_ov_stage_filesystem" ] && [ -n "$_ov_stage_mountpoint" ] || return 1
        if ! awk -v available="$_ov_stage_available_kb" -v bytes="$_ov_stage_bytes" \
            'BEGIN { exit (available * 1024 >= bytes + 4194304) ? 0 : 1 }'; then
            echo "z2k-openwrt: недостаточно места на разделе временной распаковки $_ov_stage_mountpoint (нужно $_ov_stage_bytes байт и ещё 4 МиБ для отката; доступно $_ov_stage_available_kb КиБ)" >&2
            return 1
        fi
    fi
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
        if [ -n "$_ov_stage" ]; then
            _ov_source="$_ov_stage/$_ov_member"
            if [ -d "$_ov_source" ] && [ ! -L "$_ov_source" ]; then
                _ov_source_fs="$(df -Pk "$_ov_source" 2>/dev/null | awk 'END { if (NR >= 2) print $1 "|" $NF }')"
                # Каталог на том же mount перемещается rename; его место уже
                # занято staging и отражено в df. Файлы и EXDEV требуют копии.
                [ "$_ov_source_fs" != "$_ov_filesystem|$_ov_mountpoint" ] || _ov_bytes=0
            elif [ "$_ov_stage_filesystem|$_ov_stage_mountpoint" = "$_ov_filesystem|$_ov_mountpoint" ] \
                && ! grep -Fqx "$_ov_member" "$_ov_listing" \
                && grep -Fq "$_ov_member/" "$_ov_listing"; then
                # До распаковки каталог определяется по дочерним записям архива.
                # На том же разделе он будет перемещён целиком после проверки.
                _ov_bytes=0
            fi
        fi
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

# Архив и временная распаковка одновременно занимают постоянный раздел.
# Проверить их суммарный размер до загрузки, чтобы не заполнить его частичным
# файлом или незавершённой распаковкой.
z2k_ow_overlay_download_preflight() {
    local _download_dir="$1" _archive_bytes="$2" _payload_bytes="$3"
    local _df _filesystem _rest _available_kb _mountpoint
    for _needed in "$_archive_bytes" "$_payload_bytes"; do
        case "$_needed" in ''|*[!0-9]*) return 1 ;; esac
    done
    _df="$(df -Pk "$_download_dir" 2>/dev/null | awk 'END { if (NR >= 2) print $1 "|" $4 "|" $NF}')"
    _filesystem=${_df%%|*}
    _rest=${_df#*|}
    _available_kb=${_rest%%|*}
    _mountpoint=${_rest#*|}
    case "$_available_kb" in ''|*[!0-9]*)
        echo "z2k-openwrt: не удалось определить свободное место для архива релиза" >&2
        return 1
        ;;
    esac
    [ -n "$_filesystem" ] && [ -n "$_mountpoint" ] || return 1
    if ! awk -v available="$_available_kb" -v archive="$_archive_bytes" -v payload="$_payload_bytes" \
        'BEGIN { exit (available * 1024 >= archive + payload + 4194304) ? 0 : 1 }'; then
        echo "z2k-openwrt: недостаточно места на разделе $_mountpoint для архива, временных файлов релиза и резерва отката (архив $_archive_bytes байт, распаковка $_payload_bytes байт, резерв 4 МиБ; доступно $_available_kb КиБ)" >&2
        return 1
    fi
}

# Сначала проверить каждый путь в архиве, затем распаковать общие файлы и
# исполняемые файлы нужной архитектуры. Подпись UPDATES.json подтверждает архив
# целиком. До распаковки и перед остановкой служб проверяется место на разделах.
z2k_ow_prepare_target_payload_list() {
    local _prepare_archive="$1" _prepare_listing="$2" _prepare_work="$3" _prepare_arch="$4"
    local _prepare_selected="$_prepare_work/target-payload-list" _prepare_measured _prepare_required
    awk -v arch="$_prepare_arch" '
        {
            path=$0; sub(/\/$/, "", path)
            if ($0 ~ /\/$/) next
            split(path, part, "/")
            if (part[1] == "usr" && part[2] == "lib" && part[3] == "z2k" && part[4] == "bin" && part[5] ~ /^linux-/ && part[5] != ("linux-" arch)) next
            if (part[1] == "usr" && part[2] == "lib" && part[3] == "z2k" && part[4] == "platform" && part[5] == "openwrt" && part[6] == "bin" && part[7] ~ /^linux-/ && part[7] != ("linux-" arch)) next
            if (part[1] == "opt" && part[2] == "zapret2" && part[3] == "binaries" && part[4] ~ /^linux-/ && part[4] != ("linux-" arch)) next
            print $0
        }
    ' "$_prepare_listing" > "$_prepare_selected" || return 1
    _prepare_measured="$(z2k_ow_payload_size_for_arch "$_prepare_archive" "$_prepare_arch")" || return 1
    case "$_prepare_measured" in ''|*[!0-9]*) return 1 ;; esac
    if [ -n "${_manifest_unpacked:-}" ]; then
        case "$_manifest_unpacked" in ''|*[!0-9]*) return 1 ;; esac
        if [ "$_prepare_measured" -gt "$_manifest_unpacked" ]; then
            echo "z2k-openwrt: размер распакованного содержимого превышает размер из подписанного манифеста" >&2
            return 1
        fi
        Z2K_OW_TARGET_UNPACKED_BYTES="$_manifest_unpacked"
    else
        Z2K_OW_TARGET_UNPACKED_BYTES="$_prepare_measured"
    fi
    for _prepare_required in \
        "usr/bin/z2kow" \
        "usr/sbin/install_release" \
        "etc/init.d/z2k" \
        "etc/init.d/z2k-webpanel" \
        "usr/lib/z2k/bin/linux-$_prepare_arch/tg-mtproxy-client" \
        "usr/lib/z2k/bin/linux-$_prepare_arch/z2k-rt-proxy" \
        "usr/lib/z2k/bin/linux-$_prepare_arch/z2k-detect" \
        "usr/lib/z2k/platform/openwrt/bin/linux-$_prepare_arch/z2k-warpd" \
        "opt/zapret2/binaries/linux-$_prepare_arch/nfqws2" \
        "opt/zapret2/binaries/linux-$_prepare_arch/ip2net" \
        "opt/zapret2/binaries/linux-$_prepare_arch/mdig"; do
        grep -Fqx "$_prepare_required" "$_prepare_selected" || {
            echo "z2k-openwrt: в архиве отсутствует необходимый файл выбранной архитектуры $_prepare_required" >&2
            return 1
        }
    done
}

z2k_ow_extract_target_payload() {
    _archive="$1" _stage="$2" _listing="$3" _work="$4" _memory_path="${5:-$2}"
    # Архитектура определяется роутером, а не архивом. Использовать уже
    # установленный определитель вместо отдельного извлечения одного файла:
    # tar всё равно распаковывает архив целиком для чтения этого файла.
    . "$_adapter/arch.sh" || return 1
    _target_arch="$(z2k_ow_arch_name 2>/dev/null)" || {
        echo "z2k-openwrt: архитектура роутера не поддерживается; архив не распакован" >&2
        return 1
    }
    z2k_ow_prepare_target_payload_list "$_archive" "$_listing" "$_work" "$_target_arch" || return 1
    _selected="$_work/target-payload-list"
    _unpacked="$Z2K_OW_TARGET_UNPACKED_BYTES"
    z2k_ow_overlay_preflight "$_archive" "$_target_arch" \
        "${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}/owned-paths.txt" \
        "$_listing" "$_work" "$_stage" "$_unpacked" || return 1
    # Распакованные файлы находятся на проверенном постоянном разделе, а не в
    # памяти. Повторно оставить запас в 8 МиБ после чтения списка архива.
    z2k_ow_memory_preflight "$_memory_path" 0 0 0 8388608 0 || return 1
    awk -v arch="$_target_arch" '
        {
            path=$0; sub(/\/$/, "", path); split(path, part, "/")
            foreign = (part[1] == "usr" && part[2] == "lib" && part[3] == "z2k" && part[4] == "bin" && part[5] ~ /^linux-/ && part[5] != ("linux-" arch)) \
                || (part[1] == "usr" && part[2] == "lib" && part[3] == "z2k" && part[4] == "platform" && part[5] == "openwrt" && part[6] == "bin" && part[7] ~ /^linux-/ && part[7] != ("linux-" arch)) \
                || (part[1] == "opt" && part[2] == "zapret2" && part[3] == "binaries" && part[4] ~ /^linux-/ && part[4] != ("linux-" arch))
            if (foreign) exit 1
        }
    ' "$_selected" || { echo "z2k-openwrt: выбранный список содержит бинарники чужой архитектуры" >&2; return 1; }
    # Передача списком аргументов работает и с BusyBox tar без поддержки -T.
    # Нулевой разделитель сохраняет имена буквально, размер команды ограничен.
    if tr '\n' '\000' < "$_selected" \
        | xargs -0 -r -s 32768 tar -xzf "$_archive" -C "$_stage"; then
        :
    else
        _extract_rc=$?
        echo "z2k-openwrt: не удалось распаковать проверенный архив во временный каталог $_stage; код ошибки $_extract_rc" >&2
        return 1
    fi
    for _required in \
        "usr/bin/z2kow" \
        "usr/sbin/install_release" \
        "etc/init.d/z2k" \
        "etc/init.d/z2k-webpanel" \
        "usr/lib/z2k/bin/linux-$_target_arch/tg-mtproxy-client" \
        "usr/lib/z2k/bin/linux-$_target_arch/z2k-rt-proxy" \
        "usr/lib/z2k/bin/linux-$_target_arch/z2k-detect" \
        "usr/lib/z2k/platform/openwrt/bin/linux-$_target_arch/z2k-warpd" \
        "opt/zapret2/binaries/linux-$_target_arch/nfqws2" \
        "opt/zapret2/binaries/linux-$_target_arch/ip2net" \
        "opt/zapret2/binaries/linux-$_target_arch/mdig"; do
        [ -f "$_stage/$_required" ] && [ -s "$_stage/$_required" ] && [ -x "$_stage/$_required" ] || {
            echo "z2k-openwrt: в полном архиве релиза отсутствует исполняемый файл выбранной архитектуры $_required" >&2
            return 1
        }
    done
}

z2k_ow_remove_owned_paths() {
    local _remove_paths="$1" _rel _dst
    while IFS= read -r _rel; do
        [ -n "$_rel" ] || continue
        case "$_rel" in
            /usr/lib/z2k|/opt/zapret2|/usr/bin/z2kow|/usr/sbin/install_release|\
            /etc/init.d/z2k|/etc/init.d/z2k-webpanel|/etc/hotplug.d/iface/90-z2k|\
            /etc/sysctl.d/99-z2k.conf|/usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft) ;;
            *) echo "z2k-openwrt: неизвестный принадлежащий релизу путь оставлен без изменений: $_rel" >&2; return 1 ;;
        esac
        _dst="$(z2k_ow_path "$_rel")"
        rm -rf "$_dst" || {
            echo "z2k-openwrt: не удалось освободить место, занятое прежним файлом $_rel" >&2
            return 1
        }
        { [ ! -e "$_dst" ] && [ ! -L "$_dst" ]; } || {
            echo "z2k-openwrt: прежний файл не удалён перед повторной установкой: $_rel" >&2
            return 1
        }
    done < "$_remove_paths"
    sync
}

z2k_ow_transaction_archive_verify() {
    local _verify_work="$1" _archive
    local _expected _expected_size _actual_size _actual
    _archive="$_verify_work/openwrt-rootfs.tar.gz"
    [ -f "$_archive" ] && [ ! -L "$_archive" ] || {
        echo "z2k-openwrt: архив для восстановления отсутствует или подменён; журнал оставлен в $_verify_work" >&2
        return 1
    }
    _expected="$(z2k_ow_artifact_digest_read "$_verify_work/transaction-artifact")" || return 1
    _expected_size="$(cat "$_verify_work/transaction-artifact-size" 2>/dev/null)"
    case "$_expected_size" in ''|*[!0-9]*)
        echo "z2k-openwrt: размер архива для восстановления повреждён; журнал оставлен в $_verify_work" >&2
        return 1 ;;
    esac
    _actual_size="$(wc -c < "$_archive" | tr -d ' \t\r\n')" || return 1
    [ "$_actual_size" = "$_expected_size" ] || {
        echo "z2k-openwrt: размер архива для восстановления изменился; журнал оставлен в $_verify_work" >&2
        return 1
    }
    _actual="$(sha256sum "$_archive" 2>/dev/null | awk '{print $1}')" || return 1
    [ "$_actual" = "$_expected" ] || {
        echo "z2k-openwrt: SHA-256 архива для восстановления не совпал; журнал оставлен в $_verify_work" >&2
        return 1
    }
}

z2k_ow_extract_target_payload_direct() {
    local _direct_archive="$1" _direct_work="$2" _direct_arch="$3" _direct_paths="$4"
    local _direct_listing="$_direct_work/archive-list" _direct_source="$_direct_work/target-payload-list"
    local _direct_owned="$_direct_work/target-owned-payload-list" _direct_root _direct_rel _direct_expected
    [ -f "$_direct_source" ] && [ ! -L "$_direct_source" ] || {
        echo "z2k-openwrt: проверенный список файлов для прямой распаковки отсутствует" >&2
        return 1
    }
    _direct_expected="$(z2k_ow_artifact_digest_read "$_direct_work/transaction-artifact")" || return 1
    _direct_actual="$(sha256sum "$_direct_archive" 2>/dev/null | awk '{print $1}')" || return 1
    [ "$_direct_actual" = "$_direct_expected" ] || {
        echo "z2k-openwrt: архив изменился перед распаковкой; активные файлы не тронуты" >&2
        return 1
    }
    awk -v paths="$_direct_paths" '
        BEGIN {
            while ((getline path < paths) > 0) {
                sub(/^\//, "", path)
                if (path != "") owned[++count] = path
            }
            close(paths)
        }
        {
            path=$0; sub(/\/$/, "", path)
            for (i=1; i<=count; i++)
                if (path == owned[i] || index(path, owned[i] "/") == 1) {
                    print $0
                    break
                }
        }
    ' "$_direct_source" > "$_direct_owned" || return 1
    [ -s "$_direct_owned" ] || {
        echo "z2k-openwrt: список прямой распаковки пуст; журнал оставлен в $_direct_work" >&2
        return 1
    }
    _direct_root="$(z2k_ow_path /)"
    if tr '\n' '\000' < "$_direct_owned" \
        | xargs -0 -r -s 32768 tar -xzf "$_direct_archive" -C "$_direct_root"; then
        :
    else
        _direct_extract_rc=$?
        echo "z2k-openwrt: не удалось восстановить проверенный выпуск в $_direct_root; код ошибки $_direct_extract_rc" >&2
        return 1
    fi
    for _direct_expected in \
        "usr/bin/z2kow" \
        "usr/sbin/install_release" \
        "etc/init.d/z2k" \
        "etc/init.d/z2k-webpanel" \
        "usr/lib/z2k/bin/linux-$_direct_arch/tg-mtproxy-client" \
        "usr/lib/z2k/bin/linux-$_direct_arch/z2k-rt-proxy" \
        "usr/lib/z2k/bin/linux-$_direct_arch/z2k-detect" \
        "usr/lib/z2k/platform/openwrt/bin/linux-$_direct_arch/z2k-warpd" \
        "opt/zapret2/binaries/linux-$_direct_arch/nfqws2" \
        "opt/zapret2/binaries/linux-$_direct_arch/ip2net" \
        "opt/zapret2/binaries/linux-$_direct_arch/mdig"; do
        _direct_expected="$(z2k_ow_path "/$_direct_expected")"
        [ -f "$_direct_expected" ] && [ -s "$_direct_expected" ] && [ -x "$_direct_expected" ] || {
            echo "z2k-openwrt: после распаковки отсутствует исполняемый файл выбранной архитектуры $_direct_expected" >&2
            return 1
        }
    done
    while IFS= read -r _direct_rel; do
        [ -n "$_direct_rel" ] || continue
        _direct_expected="$(z2k_ow_path "$_direct_rel")"
        { [ -e "$_direct_expected" ] || [ -L "$_direct_expected" ]; } || {
            echo "z2k-openwrt: после распаковки отсутствует принадлежащий релизу путь $_direct_rel" >&2
            return 1
        }
    done < "$_direct_paths"
}

z2k_ow_restore_direct_archive() {
    local _restore_work="$1" _restore_paths="$2" _restore_state="$3"
    local _restore_archive="$_restore_work/openwrt-rootfs.tar.gz" _restore_arch _restore_old_digest
    local _restore_old_record _restore_target_record
    [ -f "$_restore_work/reinstall-from-archive" ] \
        && [ ! -L "$_restore_work/reinstall-from-archive" ] \
        && [ "$(cat "$_restore_work/reinstall-from-archive" 2>/dev/null)" = same-archive-v1 ] || {
            echo "z2k-openwrt: неизвестный способ восстановления; журнал оставлен в $_restore_work" >&2
            return 1
        }
    [ -f "$_restore_work/state-was-present" ] \
        && [ -f "$_restore_work/installed-release.old" ] \
        && [ -f "$_restore_work/installed-artifact.old" ] || {
            echo "z2k-openwrt: для повторной установки не сохранена прежняя запись состояния; журнал оставлен" >&2
            return 1
        }
    _restore_old_record="$(z2k_ow_release_state_read "$_restore_work/installed-release.old")" || return 1
    _restore_target_record="$(z2k_ow_release_state_read "$_restore_work/transaction-target")" || return 1
    [ "$_restore_old_record" = "$_restore_target_record" ] || {
        echo "z2k-openwrt: архив восстановления не совпадает с прежней версией; журнал оставлен" >&2
        return 1
    }
    _restore_old_digest="$(z2k_ow_artifact_digest_read "$_restore_work/installed-artifact.old")" || return 1
    [ "$_restore_old_digest" = "$(z2k_ow_artifact_digest_read "$_restore_work/transaction-artifact")" ] || {
        echo "z2k-openwrt: прежний отпечаток архива не совпадает с архивом восстановления; журнал оставлен" >&2
        return 1
    }
    _restore_arch="$(cat "$_restore_work/transaction-arch" 2>/dev/null)"
    case "$_restore_arch" in arm64|arm|x86_64|x86|mips|mipsel|riscv64) ;; *)
        echo "z2k-openwrt: архитектура в журнале восстановления повреждена; журнал оставлен" >&2
        return 1 ;;
    esac
    z2k_ow_transaction_archive_verify "$_restore_work" || return 1
    z2k_ow_archive_safe "$_restore_archive" "$_restore_work/archive-list" || {
        echo "z2k-openwrt: архив восстановления содержит запрещённый путь; журнал оставлен" >&2
        return 1
    }
    _manifest_unpacked=
    z2k_ow_prepare_target_payload_list "$_restore_archive" "$_restore_work/archive-list" \
        "$_restore_work" "$_restore_arch" || {
            echo "z2k-openwrt: список проверенного архива для восстановления не прошёл проверку; журнал оставлен" >&2
            return 1
        }
    z2k_ow_overlay_direct_preflight "$_restore_archive" "$_restore_arch" "$_restore_paths" "$_restore_work" || return 1
    z2k_ow_remove_owned_paths "$_restore_paths" || return 1
    z2k_ow_extract_target_payload_direct "$_restore_archive" "$_restore_work" \
        "$_restore_arch" "$_restore_paths" || return 1
    sync
}

# Полную транзакцию может выполнять только один процесс. После аварии остаётся
# файл блокировки с PID; следующий запуск удаляет устаревшую блокировку и
# вызывает z2k_ow_recover_transaction() для восстановления или очистки.
z2k_ow_install_lock_acquire() {
    local _lock="$1" _pid="" _attempt=0 _boot_id _lock_boot
    _boot_id="$(cat "${Z2K_OW_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null)"
    [ -n "$_boot_id" ] || { echo "z2k-openwrt: идентификатор загрузки недоступен" >&2; return 1; }
    while [ "$_attempt" -lt 3 ]; do
        if mkdir "$_lock" 2>/dev/null; then
            if ! printf '%s\n' "$$" > "$_lock/pid" \
                || ! printf '%s\n' "$_boot_id" > "$_lock/boot-id"; then
                rm -f "$_lock/pid" "$_lock/boot-id" 2>/dev/null || true
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
        _lock_boot="$(cat "$_lock/boot-id" 2>/dev/null)"
        if { [ -z "$_lock_boot" ] || [ "$_lock_boot" = "$_boot_id" ]; } \
            && { [ "$_pid" = "$$" ] || kill -0 "$_pid" 2>/dev/null; }; then
            echo "z2k-openwrt: уже выполняется другой install_release (PID $_pid)" >&2
            return 1
        fi
        rm -f "$_lock/pid" "$_lock/boot-id" 2>/dev/null || return 1
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
    rm -f "$_lock/pid" "$_lock/boot-id" 2>/dev/null || return 1
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
