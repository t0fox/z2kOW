#!/bin/sh
# Product-release updater for the OpenWrt APK packages.
# This is deliberately separate from platform/openwrt/update.sh: that file
# advances the upstream z2k payload lane recorded in UPDATES.json.
set -u

SYSROOT="${Z2K_PRODUCT_SYSROOT:-/}"
RELEASE_BASE="https://github.com/t0fox/z2kOW/releases/latest/download"
PRODUCT="z2kOW"
STATE_DIR="${Z2K_STATE:-}/"
STATE_DIR="${STATE_DIR%/}"
PRODUCT_TAG_FILE="${Z2K_PRODUCT_TAG_FILE:-$STATE_DIR/product-tag}"
STATUS_FILE="${Z2K_PRODUCT_UPDATE_STATUS_FILE:-$STATE_DIR/product-update.status}"
ENGINE_TAG_FILE="${Z2K_ENGINE_TAG_FILE:-$STATE_DIR/installed-tag}"
PRODUCT_BUILD_COMMIT_FILE="${Z2K_PRODUCT_BUILD_COMMIT_FILE:-$Z2K_ROOT/share/product-build-commit}"
PINNED_KEY="${Z2K_FEED_PUBLIC_KEY:-$Z2K_ROOT/share/z2k-feed.pem}"
APK_KEY="${SYSROOT%/}/etc/apk/keys/z2k-feed.pem"
TMP_DIR=""
WEBPANEL_DEP_SEED=".z2k-webpanel-product-update-deps"
WEBPANEL_DEP_SEED_ACTIVE=0

path() { printf '%s%s' "${SYSROOT%/}" "$1"; }

die() {
    printf 'z2kow: %s\n' "$*" >&2
    return 1
}

[ -n "${Z2K_STATE:-}" ] && [ -n "${Z2K_ETC:-}" ] && [ -n "${Z2K_ROOT:-}" ] \
    || { die "OpenWrt paths contract was not loaded"; exit 1; }

cleanup() {
    if [ "$WEBPANEL_DEP_SEED_ACTIVE" = "1" ]; then
        WEBPANEL_DEP_SEED_ACTIVE=0
        apk del "$WEBPANEL_DEP_SEED" >/dev/null 2>&1 || true
    fi
    [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

json_string() {
    printf '"'
    printf '%s' "$1" | LC_ALL=C awk '
        BEGIN { for (i = 0; i < 32; i++) ctl[sprintf("%c", i)] = i }
        {
            s = $0
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "\\") printf "\\\\"
                else if (c == "\"") printf "\\\""
                else if (c == "\n") printf "\\n"
                else if (c == "\r") printf "\\r"
                else if (c == "\t") printf "\\t"
                else if (c in ctl) printf "\\u%04x", ctl[c]
                else printf "%s", c
            }
        }'
    printf '"'
}

state_write() {
    _state="$1" _current="$2" _latest="$3" _message="$4"
    mkdir -p "$STATE_DIR" || return 1
    _tmp="$STATUS_FILE.new.$$"
    _message=$(printf '%s' "$_message" | tr '\r\n' '  ' | cut -c1-240)
    {
        printf 'state=%s\n' "$_state"
        printf 'installed=%s\n' "$_current"
        printf 'latest=%s\n' "$_latest"
        printf 'message=%s\n' "$_message"
        printf 'updated_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%s')"
    } > "$_tmp" || return 1
    chmod 0600 "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$STATUS_FILE"
}

state_get() {
    _key="$1"
    [ -r "$STATUS_FILE" ] || return 0
    sed -n "s/^${_key}=//p" "$STATUS_FILE" | head -n 1
}

new_tmp() {
    [ -z "$TMP_DIR" ] || return 0
    _parent="${TMPDIR:-/tmp}"
    mkdir -p "$_parent" || return 1
    TMP_DIR="$_parent/z2kow-product.$$"
    (umask 077 && mkdir "$TMP_DIR") || { TMP_DIR=""; return 1; }
}

download() {
    _url="$1" _out="$2"
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O "$_out" "$_url"
    elif command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 -o "$_out" "$_url"
    else
        die "нужен HTTPS downloader: wget или curl"
    fi
}

sha256() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

json_get() {
    jsonfilter -i "$1" -e "$2" 2>/dev/null | head -n 1
}

valid_semver() {
    printf '%s\n' "$1" | awk -F. '
        NF != 3 { exit 1 }
        {
            for (i = 1; i <= 3; i++) {
                if ($i !~ /^(0|[1-9][0-9]*)$/) exit 1
            }
        }'
}

package_version() {
    _pkg="$1"
    _line=$(apk list --installed "$_pkg" 2>/dev/null | head -n 1)
    case "$_line" in
        "$_pkg"-*) _value=${_line#"$_pkg"-}; printf '%s\n' "${_value%% *}" ;;
        *) return 1 ;;
    esac
}

snapshot_sha_from_version() {
    printf '%s\n' "$1" | sed -n 's/^[0-9][0-9.]*_alpha[0-9]\{14\}~\([0-9a-f]\{40\}\)-r1$/\1/p'
}

# Return 0 for a coherent CI snapshot, 2 for a mixed snapshot/release pair,
# and 1 when both package versions are production-style or unavailable.
product_snapshot_status() {
    _adapter_version=$(package_version z2k-adapter 2>/dev/null || true)
    _panel_version=$(package_version z2k-webpanel 2>/dev/null || true)
    _adapter_sha=$(snapshot_sha_from_version "$_adapter_version")
    _panel_sha=$(snapshot_sha_from_version "$_panel_version")
    PRODUCT_SNAPSHOT_SHA=""
    if [ -n "$_adapter_sha" ] || [ -n "$_panel_sha" ]; then
        if [ -n "$_adapter_sha" ] && [ "$_adapter_sha" = "$_panel_sha" ]; then
            PRODUCT_SNAPSHOT_SHA="$_adapter_sha"
            return 0
        fi
        return 2
    fi
    return 1
}

engine_tag() {
    _tag=""
    [ -r "$ENGINE_TAG_FILE" ] && _tag=$(tr -d ' \t\r\n' < "$ENGINE_TAG_FILE" 2>/dev/null || true)
    case "$_tag" in p-[0-9]*.[0-9]*) printf '%s\n' "$_tag" ;; *) printf '%s\n' unknown ;; esac
}

emit_snapshot_json() {
    _mode="${1:-status}" _channel_state=snapshot _installed=SNAPSHOT _build="$PRODUCT_SNAPSHOT_SHA"
    _adapter_version=$(package_version z2k-adapter 2>/dev/null || echo unknown)
    _panel_version=$(package_version z2k-webpanel 2>/dev/null || echo unknown)
    _engine=$(engine_tag)
    if [ -z "$_build" ]; then
        _channel_state=snapshot-inconsistent
        _installed="SNAPSHOT (package mismatch)"
        _message="Установлены snapshot-пакеты с несовпадающими build SHA; production channel заблокирован"
    else
        _message="Production channel is not activated for CI snapshots"
    fi
    case "$_mode" in
        info)
            printf '{"ok":true,"channel":"snapshot","state":'; json_string "$_channel_state"
            printf ',"installed":'; json_string "$_installed"
            printf ',"latest":null,"build":'; json_string "$_build"
            printf ',"engine":'; json_string "$_engine"
            printf ',"adapter":'; json_string "$_adapter_version"
            printf ',"webpanel":'; json_string "$_panel_version"
            printf ',"production_channel_active":false,"history":[],"message":'; json_string "$_message"
            printf '}\n'
            ;;
        *)
            printf '{"ok":true,"state":'; json_string "$_channel_state"
            printf ',"installed":'; json_string "$_installed"
            printf ',"latest":null,"update_available":false,"skipped_releases":null,"build":'; json_string "$_build"
            printf ',"engine":'; json_string "$_engine"
            printf ',"adapter":'; json_string "$_adapter_version"
            printf ',"webpanel":'; json_string "$_panel_version"
            printf ',"production_channel_active":false,"message":'; json_string "$_message"
            printf '}\n'
            ;;
    esac
}

current_product_tag() {
    _tag=""
    if [ -r "$PRODUCT_TAG_FILE" ]; then
        IFS= read -r _tag < "$PRODUCT_TAG_FILE" || true
    fi
    case "$_tag" in v[0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$_tag" ;; *) printf '%s\n' unknown ;; esac
}

installed_release_tag() {
    _adapter=$(package_version z2k-adapter 2>/dev/null) || return 1
    _panel=$(package_version z2k-webpanel 2>/dev/null) || return 1
    [ "$_panel" = "$_adapter" ] || return 1
    case "$_adapter" in *-r1) _version=${_adapter%-r1} ;; *) return 1 ;; esac
    valid_semver "$_version" || return 1
    printf 'v%s\n' "$_version"
}

previous_product_tag() {
    _tag=$(current_product_tag)
    if [ "$_tag" != unknown ]; then
        printf '%s\n' "$_tag"
        return 0
    fi
    installed_release_tag || printf 'unknown\n'
}

verify_release_files() {
    _base="$1" _dir="$2"
    download "$_base/SHA256SUMS" "$_dir/SHA256SUMS" \
        || { die "не удалось скачать SHA256SUMS из $_base"; return 1; }
    download "$_base/SHA256SUMS.sig" "$_dir/SHA256SUMS.sig" \
        || { die "не удалось скачать подпись SHA256SUMS из $_base"; return 1; }
    openssl dgst -sha256 -verify "$PINNED_KEY" -signature "$_dir/SHA256SUMS.sig" \
        "$_dir/SHA256SUMS" >/dev/null 2>&1 \
        || { die "подпись SHA256SUMS недействительна для закреплённого feed key"; return 1; }
    download "$_base/release-manifest.json" "$_dir/release-manifest.json" \
        || { die "не удалось скачать release-manifest.json из $_base"; return 1; }
    _expected=$(awk '$2 == "release-manifest.json" { if (found++) exit 2; print $1 }' "$_dir/SHA256SUMS") || {
        die "SHA256SUMS не содержит единственную запись release-manifest.json"; return 1;
    }
    printf '%s' "$_expected" | grep -Eq '^[0-9a-f]{64}$' \
        || { die "SHA256SUMS содержит некорректный hash release-manifest.json"; return 1; }
    [ "$(sha256 "$_dir/release-manifest.json")" = "$_expected" ] \
        || { die "hash release-manifest.json не совпадает с подписанными SHA256SUMS"; return 1; }
}

verify_manifest() {
    _manifest="$1"
    command -v jsonfilter >/dev/null 2>&1 || { die "не найден jsonfilter"; return 1; }
    [ -s "$PINNED_KEY" ] || { die "в пакете отсутствует pinned production public key"; return 1; }
    [ -s "$APK_KEY" ] || { die "не установлен production APK feed key"; return 1; }
    [ "$(sha256 "$PINNED_KEY")" = "$(sha256 "$APK_KEY")" ] \
        || { die "APK trust key не совпадает с package-pinned production key"; return 1; }
    command -v openssl >/dev/null 2>&1 || { die "не найден openssl для проверки release signature"; return 1; }
    _product=$(json_get "$_manifest" '@.product')
    _schema=$(json_get "$_manifest" '@.schema')
    _channel=$(json_get "$_manifest" '@.channel')
    _version=$(json_get "$_manifest" '@.version')
    _tag=$(json_get "$_manifest" '@.tag')
    _release=$(json_get "$_manifest" '@.openwrt.release')
    _target=$(json_get "$_manifest" '@.openwrt.target')
    _arch=$(json_get "$_manifest" '@.openwrt.arch')
    _history_version=$(json_get "$_manifest" '@.history[0].version')
    _history_tag=$(json_get "$_manifest" '@.history[0].tag')
    [ "$_product" = "$PRODUCT" ] && [ "$_schema" = 2 ] && [ "$_channel" = stable ] \
        || { die "product manifest identity, schema or channel is invalid"; return 1; }
    valid_semver "$_version" || { die "product release version is invalid"; return 1; }
    [ "$_tag" = "v$_version" ] && [ "$_history_version" = "$_version" ] \
        && [ "$_history_tag" = "v$_version" ] \
        || { die "product manifest latest release history does not match version"; return 1; }
    [ "$_release" = "25.12.5" ] && [ "$_target" = "mediatek/filogic" ] \
        && [ "$_arch" = "aarch64_cortex-a53" ] \
        || { die "release does not support this OpenWrt target"; return 1; }
    _latest="$_version"
}

load_latest_manifest() {
    new_tmp || { die "не удалось создать временный каталог"; return 1; }
    verify_release_files "$RELEASE_BASE" "$TMP_DIR" || return 1
    verify_manifest "$TMP_DIR/release-manifest.json" || return 1
    _current=$(current_product_tag)
    _manifest="$TMP_DIR/release-manifest.json"
}

count_skipped_releases() {
    _wanted="$1"
    _count=0 _found=0
    for _tag in $(jsonfilter -i "$_manifest" -e '@.history[*].tag' 2>/dev/null); do
        if [ "$_tag" = "$_wanted" ]; then _found=1; break; fi
        _count=$((_count + 1))
    done
    if [ "$_found" = 1 ]; then printf '%s\n' "$_count"; else printf 'unknown\n'; fi
}

emit_status_json() {
    _snapshot_rc=0
    product_snapshot_status || _snapshot_rc=$?
    if [ "$_snapshot_rc" -eq 0 ] || [ "$_snapshot_rc" -eq 2 ]; then
        emit_snapshot_json status
        return 0
    fi
    _state=$(state_get state); _installed=$(state_get installed); _latest=$(state_get latest)
    _message=$(state_get message); _updated=$(state_get updated_at)
    [ -n "$_state" ] || _state=unknown
    [ -n "$_installed" ] || _installed=$(current_product_tag)
    [ -n "$_latest" ] || _latest=unknown
    [ -n "$_message" ] || _message=""
    [ -n "$_updated" ] || _updated=""
    printf '{"ok":true,"state":'; json_string "$_state"
    printf ',"installed":'; json_string "$_installed"
    printf ',"latest":'; json_string "$_latest"
    printf ',"message":'; json_string "$_message"
    printf ',"updated_at":'; json_string "$_updated"
    printf '}\n'
}

emit_check_json() {
    _current="$1" _latest="$2"
    _available=true
    [ "$_current" = "v$_latest" ] && _available=false
    _skipped=$(count_skipped_releases "$_current")
    state_write "$([ "$_available" = true ] && echo update-available || echo up-to-date)" \
        "$_current" "v$_latest" ""
    printf '{"ok":true,"installed":'; json_string "$_current"
    printf ',"latest":'; json_string "v$_latest"
    printf ',"update_available":%s,"skipped_releases":' "$_available"
    case "$_skipped" in ''|*[!0-9]*) printf 'null' ;; *) printf '%s' "$_skipped" ;; esac
    printf '}\n'
}

atomic_record_tag() {
    _version="$1"
    valid_semver "$_version" || { die "installed package version is not a production SemVer"; return 1; }
    mkdir -p "$STATE_DIR" || return 1
    _tmp="$PRODUCT_TAG_FILE.new.$$"
    printf 'v%s\n' "$_version" > "$_tmp" || return 1
    chmod 0600 "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$PRODUCT_TAG_FILE"
}

record_installed_version() {
    _expected_version="${1:-}"
    _adapter=$(package_version z2k-adapter) || { die "z2k-adapter не установлен"; return 1; }
    _panel=$(package_version z2k-webpanel) || { die "z2k-webpanel не установлен"; return 1; }
    _version="${_adapter%-r1}"
    [ "$_adapter" = "$_version-r1" ] && [ "$_panel" = "$_adapter" ] \
        || { die "версии adapter/webpanel не образуют production release r1"; return 1; }
    [ -z "$_expected_version" ] || [ "$_version" = "$_expected_version" ] \
        || { die "установленные APK версии $_version не совпадают с проверенным релизом $_expected_version"; return 1; }
    atomic_record_tag "$_version"
}

lan_ipv4() {
    _ip=$(ip -4 -o addr show dev br-lan 2>/dev/null \
        | awk '$3 == "inet" { sub(/\/.*/, "", $4); if ($4 != "127.0.0.1") { print $4; exit } }' || true)
    if [ -z "$_ip" ] && command -v uci >/dev/null 2>&1; then
        _ip=$(uci -q get network.lan.ipaddr 2>/dev/null || true)
    fi
    printf '%s\n' "$_ip"
}

health_check() {
    _root="${SYSROOT%/}"
    "$_root/etc/init.d/z2k" status >/dev/null 2>&1 \
        && pidof nfqws2 >/dev/null 2>&1 || { die "core health check failed"; return 1; }
    "$_root/etc/init.d/z2k-webpanel" running >/dev/null 2>&1 \
        || { die "webpanel service health check failed"; return 1; }
    _lan=$(lan_ipv4)
    [ -n "$_lan" ] || { die "не удалось определить LAN IPv4"; return 1; }
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 5 -O /dev/null "http://$_lan:8088/" \
            || { die "webpanel HTTP check on port 8088 failed"; return 1; }
    elif command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --connect-timeout 3 --max-time 5 -o /dev/null "http://$_lan:8088/" \
            || { die "webpanel HTTP check on port 8088 failed"; return 1; }
    else
        die "нужен wget или curl для проверки webpanel"
        return 1
    fi
}

rollback_to_tag() {
    _old_tag="$1"
    case "$_old_tag" in v[0-9]*.[0-9]*.[0-9]*) ;; *) return 1 ;; esac
    _old_version=${_old_tag#v}
    valid_semver "$_old_version" || return 1
    _old_base="https://github.com/t0fox/z2kOW/releases/download/$_old_tag"
    _rollback_dir="$TMP_DIR/rollback"
    mkdir -p "$_rollback_dir" || return 1
    verify_release_files "$_old_base" "$_rollback_dir" || return 1
    verify_manifest "$_rollback_dir/release-manifest.json" || return 1
    [ "$(json_get "$_rollback_dir/release-manifest.json" '@.version')" = "$_old_version" ] || return 1
    download "$_old_base/packages.adb" "$_rollback_dir/packages.adb" || return 1
    _expected=$(awk '$2 == "packages.adb" { print $1 }' "$_rollback_dir/SHA256SUMS")
    [ "$(sha256 "$_rollback_dir/packages.adb")" = "$_expected" ] || return 1
    for _pkg in z2k-adapter z2k-webpanel; do
        _pkg_version="$_old_version-r1"
        _name="$_pkg-$_pkg_version.apk"
        _expected=$(awk -v name="$_name" '$2 == name { print $1 }' "$_rollback_dir/SHA256SUMS")
        printf '%s' "$_expected" | grep -Eq '^[0-9a-f]{64}$' || return 1
        download "$_old_base/$_name" "$_rollback_dir/$_name" || return 1
        [ "$(sha256 "$_rollback_dir/$_name")" = "$_expected" ] || return 1
    done

    # Add the immutable old signed index to the system repositories for one
    # package-scoped APK transaction. Existing system feeds remain available.
    _repos="$TMP_DIR/rollback-repositories"
    : > "$_repos" || return 1
    for _repo_file in "$(path /etc/apk/repositories)" "$(path /etc/apk/repositories.d)"/*.list "$(path /lib/apk/repositories.d)"/*.list; do
        [ -f "$_repo_file" ] || continue
        while IFS= read -r _repo_line || [ -n "$_repo_line" ]; do
            case "$_repo_line" in
                *github.com/t0fox/z2kOW/releases/latest/download/packages.adb*) continue ;;
            esac
            printf '%s\n' "$_repo_line" >> "$_repos"
        done < "$_repo_file"
    done
    printf 'ndx file://%s/packages.adb\n' "$_rollback_dir" >> "$_repos"
    apk --repositories-file "$_repos" update || return 1
    apk --repositories-file "$_repos" upgrade --available z2k-adapter z2k-webpanel || return 1
    health_check || return 1
    return 0
}

run_check() {
    _snapshot_rc=0
    product_snapshot_status || _snapshot_rc=$?
    if [ "$_snapshot_rc" -eq 0 ] || [ "$_snapshot_rc" -eq 2 ]; then
        emit_snapshot_json check
        return 0
    fi
    _current=$(current_product_tag)
    state_write checking "$_current" unknown "Проверяю подпись production release manifest"
    if ! load_latest_manifest; then
        state_write failed "$_current" unknown "Не удалось проверить production release manifest; см. вывод команды"
        return 1
    fi
    _current=$(current_product_tag)
    emit_check_json "$_current" "$_latest"
}

run_update() {
    _snapshot_rc=0
    product_snapshot_status || _snapshot_rc=$?
    if [ "$_snapshot_rc" -eq 0 ] || [ "$_snapshot_rc" -eq 2 ]; then
        _snapshot_reason="CI snapshot не входит в production update channel; дождитесь подписанного product release"
        [ "$_snapshot_rc" -eq 0 ] || _snapshot_reason="snapshot-пакеты имеют разные build SHA; production update остановлен"
        die "$_snapshot_reason"
        return 1
    fi
    [ "$(id -u 2>/dev/null || echo 1)" = 0 ] || { die "update требует root"; return 1; }
    _lock="$(path /var/lock)/z2kow-product-update.lock"
    mkdir -p "$(dirname "$_lock")" || return 1
    mkdir "$_lock" 2>/dev/null || { die "product update уже выполняется"; return 1; }
    trap 'rmdir "$_lock" 2>/dev/null; cleanup' EXIT HUP INT TERM
    _previous=$(previous_product_tag)
    state_write checking "$_previous" unknown "Проверяю подпись stable release и целевую версию"
    if ! load_latest_manifest; then
        state_write failed "$_previous" unknown "Проверка production release завершилась ошибкой"
        return 1
    fi
    _previous=$(previous_product_tag)
    _latest_tag="v$_latest"
    if [ "$_previous" = "$_latest_tag" ]; then
        state_write up-to-date "$_previous" "$_latest_tag" "Установлена последняя product release"
        printf 'z2kOW %s уже актуален\n' "$_latest_tag"
        return 0
    fi
    state_write updating "$_previous" "$_latest_tag" "Обновляю подписанные пакеты z2kOW"
    if ! apk update; then
        state_write failed "$_previous" "$_latest_tag" "Signed APK index update failed; package transaction did not start"
        die "apk update завершился ошибкой; packages не менялись"
        return 1
    fi
    # Lighttpd serves only the private panel port. The APK default service
    # hook can start its stock instance on :80, replacing uhttpd's LuCI path.
    # Stage dependency upgrades without scripts, then keep hooks enabled for
    # the z2k packages themselves.
    WEBPANEL_DEP_SEED_ACTIVE=1
    if ! apk --no-scripts add --upgrade --virtual "$WEBPANEL_DEP_SEED" \
        lighttpd lighttpd-mod-cgi lighttpd-mod-setenv lighttpd-mod-alias; then
        state_write failed "$_previous" "$_latest_tag" "Lighttpd dependency staging failed; product transaction did not start"
        die "не удалось обновить Lighttpd dependencies без запуска штатного сервиса"
        return 1
    fi
    if ! apk add --upgrade z2k-adapter z2k-webpanel; then
        _reason="APK package transaction failed; package files may have changed"
        state_write rollback "$_previous" "$_latest_tag" "$_reason; пытаюсь восстановить previous signed release"
        case "$_previous" in
            v[0-9]*.[0-9]*.[0-9]*)
                if rollback_to_tag "$_previous"; then
                    if record_installed_version "${_previous#v}"; then
                        state_write rolled-back "$_previous" "$_latest_tag" "$_reason; previous immutable release restored"
                        die "APK package transaction завершилась ошибкой; восстановлен $_previous"
                        return 1
                    fi
                fi
                ;;
        esac
        state_write failed "$_previous" "$_latest_tag" "$_reason; rollback unavailable, failed, or package versions did not match; product-tag was not advanced"
        die "APK package transaction завершилась ошибкой; rollback недоступен или завершился ошибкой"
        return 1
    fi
    state_write health-check "$_previous" "$_latest_tag" "Проверяю core, nfqws2 и webpanel после APK transaction"
    if health_check; then
        if record_installed_version "${_latest_tag#v}"; then
            state_write updated "v$_latest" "v$_latest" "Обновление и runtime health checks прошли"
            printf 'z2kOW обновлён: v%s\n' "$_latest"
            return 0
        fi
        _reason="APK packages healthy, но не удалось записать product-tag"
    else
        _reason="post-update health check failed"
    fi

    state_write rollback "$_previous" "$_latest_tag" "$_reason; пытаюсь восстановить previous signed release"
    case "$_previous" in
        v[0-9]*.[0-9]*.[0-9]*)
            if rollback_to_tag "$_previous" && record_installed_version "${_previous#v}"; then
                state_write rolled-back "$_previous" "$_latest_tag" "$_reason; previous immutable release restored"
                printf 'Обновление не прошло; восстановлена %s\n' "$_previous" >&2
                return 1
            fi
            ;;
    esac
    state_write failed "$_previous" "$_latest_tag" "$_reason; rollback unavailable or failed"
    die "$_reason; APK did not confirm previous release rollback"
}

usage() {
    cat <<'EOF'
Использование: z2kow {install|update|check|status|restart|info|version|diag|uninstall}

  install, update    обновить только z2k-adapter и z2k-webpanel из signed APK feed
  check              проверить latest stable release и подпись metadata
  status             показать product update state
  info               вывести проверенный cumulative release manifest (JSON)
  version            показать установленную product/package version
  diag               запустить диагностику z2kOW
  uninstall [--purge] удалить пакеты; --purge дополнительно удаляет config и persistent state
EOF
}

command_name="${1:-status}"
case "$command_name" in
    check)
        _snapshot_rc=0
        product_snapshot_status || _snapshot_rc=$?
        if [ "$_snapshot_rc" -eq 0 ] || [ "$_snapshot_rc" -eq 2 ]; then
            emit_snapshot_json check
        elif load_latest_manifest; then
            _current=$(current_product_tag)
            emit_check_json "$_current" "$_latest"
        else
            state_write failed "$(current_product_tag)" unknown "Не удалось проверить signed product manifest"
            exit 1
        fi
        ;;
    info)
        _snapshot_rc=0
        product_snapshot_status || _snapshot_rc=$?
        if [ "$_snapshot_rc" -eq 0 ] || [ "$_snapshot_rc" -eq 2 ]; then
            emit_snapshot_json info
        else
            load_latest_manifest || exit 1
            cat "$_manifest"
        fi
        ;;
    status)
        emit_status_json
        ;;
    record)
        record_installed_version || exit 1
        ;;
    update|install)
        run_update || exit $?
        ;;
    version)
        _snapshot_rc=0
        product_snapshot_status || _snapshot_rc=$?
        _tag=$(current_product_tag)
        _adapter=$(package_version z2k-adapter 2>/dev/null || echo unknown)
        _panel=$(package_version z2k-webpanel 2>/dev/null || echo unknown)
        if [ "$_snapshot_rc" -eq 0 ]; then
            printf 'product=SNAPSHOT %s\nbuild=%s\n' "$(printf '%s' "$PRODUCT_SNAPSHOT_SHA" | cut -c1-8)" "$PRODUCT_SNAPSHOT_SHA"
        elif [ "$_snapshot_rc" -eq 2 ]; then
            printf 'product=SNAPSHOT INCONSISTENT\nbuild=unknown\n'
        else
            _build=$(tr -d ' \t\r\n' < "$PRODUCT_BUILD_COMMIT_FILE" 2>/dev/null || true)
            printf '%s' "$_build" | grep -Eq '^[0-9a-f]{40}$' || _build=unknown
            printf 'product=%s\nbuild=%s\n' "$_tag" "$_build"
        fi
        printf 'engine=%s\nadapter=%s\nwebpanel=%s\n' "$(engine_tag)" "$_adapter" "$_panel"
        ;;
    diag)
        exec "$Z2K_ROOT/z2k-diag.sh" "${2:-}"
        ;;
    uninstall)
        [ "$(id -u 2>/dev/null || echo 1)" = 0 ] || { die "uninstall требует root"; exit 1; }
        _owned_repo="$(path /etc/apk/repositories.d/z2kow.list)"
        _remove_repo=0 _remove_key=0
        if [ -f "$_owned_repo" ] \
           && grep -qxF "ndx $RELEASE_BASE/packages.adb" "$_owned_repo" \
           && [ "$(wc -l < "$_owned_repo" | tr -d ' \t\r\n')" = 1 ]; then
            _remove_repo=1
        fi
        if [ -s "$PINNED_KEY" ] && [ -s "$APK_KEY" ] \
           && [ "$(sha256 "$PINNED_KEY")" = "$(sha256 "$APK_KEY")" ]; then
            _remove_key=1
        fi
        apk del z2k-webpanel z2k-adapter || exit $?
        [ "$_remove_repo" = 0 ] || rm -f "$_owned_repo"
        [ "$_remove_key" = 0 ] || rm -f "$APK_KEY"
        if [ "${2:-}" = "--purge" ]; then
            rm -rf "$Z2K_ETC"
        else
            rm -f "$PRODUCT_TAG_FILE" "$STATUS_FILE"
        fi
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
