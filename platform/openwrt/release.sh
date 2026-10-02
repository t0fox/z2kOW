#!/bin/sh
# One controlled full-payload release path for OpenWrt.

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
            # The former updater stored a single plain tag. Read that exact
            # legacy shape only to select the one-time full migration path;
            # malformed canonical records remain invalid and are never used
            # as installed state by status/UI/update APIs.
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
    # Read the former markers only to migrate an already-installed z2kOW.
    # install_release removes these after a healthy full-payload convergence.
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
        # Migrate package ownership through the same complete release install,
        # even if an old marker happens to equal current.
        printf 'update %s\n' "$_tag"
        return 0
    fi
    if z2k_ow_relay_identity_migration_needed; then
        printf 'update %s\n' "$_tag"
        return 0
    fi
    if [ -z "$_installed" ]; then
        # A package-owned legacy install must enter the one-time migration.
        # A genuinely missing marker follows upstream's safe resync behavior,
        # avoiding a blind reinstall of every release in history.
        if z2k_ow_legacy_packages_present; then
            printf 'update %s\n' "$_tag"
        else
            printf 'resync %s\n' "$_tag"
        fi
        return 0
    fi
    case "$_installed" in *[!A-Za-z0-9._-]*) return 1 ;; esac
    if [ "$_installed" = "$_tag" ] && [ "$(z2k_ow_release_state_seq "$_state")" != "$_seq" ]; then
        # Sequence drift must pass through full convergence and health checks
        # before the canonical state is replaced.
        printf 'update %s\n' "$_tag"
        return 0
    fi
    command -v au_decide >/dev/null 2>&1 || {
        echo "z2k-openwrt: upstream release decision engine is unavailable" >&2
        return 1
    }
    _decision="$(au_decide "$_installed" "$_manifest")" || return 1
    _action="$(printf '%s\n' "$_decision" | sed -n '1{s/[[:space:]].*$//;p;}')"
    case "$_action" in
        none) printf 'none %s\n' "$_tag" ;;
        patch|reinstall) printf 'update %s\n' "$_tag" ;;
        *) echo "z2k-openwrt: invalid upstream release decision" >&2; return 1 ;;
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
        echo "z2k-openwrt: нужен HTTPS downloader (wget или curl)" >&2
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

# Preserve the upstream per-install relay identity when moving from its former
# payload location to the persistent OpenWrt state directory. The new route
# assignment metadata lives in that same file, so update replacement cannot
# erase it together with /opt/zapret2.
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
    # Keep package scripts from stopping or deleting files being transferred
    # to the full-payload installer.
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
                echo "z2k-openwrt: refusing legacy feed symlink: $_feed" >&2
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
                echo "z2k-openwrt: не удалось прочитать legacy ownership: $_pkg" >&2
                return 1
            }
            case "$_contents" in
                *www/cgi-bin/luci*|*www/luci-static*|*etc/config/uhttpd*)
                    echo "z2k-openwrt: отказ миграции: $_pkg claims a protected LuCI/uhttpd path" >&2
                    return 1
                    ;;
            esac
            while IFS= read -r _owned_path; do
                [ -n "$_owned_path" ] || continue
                z2k_ow_legacy_path_allowed "$_owned_path" || {
                    echo "z2k-openwrt: отказ миграции: $_pkg claims an unrecognized path: $_owned_path" >&2
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
            echo "z2k-openwrt: legacy feed key is not an exact installed z2kOW key; refusing migration" >&2
            return 1
        fi
    fi

    apk add kmod-nft-queue kmod-tun kmod-nfnetlink-log conntrack openssl-util jsonfilter || {
        echo "z2k-openwrt: не удалось обеспечить системные зависимости OpenWrt" >&2
        return 1
    }
    # The panel starts its own lighttpd instance on its configured port. The
    # package hooks enable the stock lighttpd service, which binds LuCI's port
    # 80 and returns 403 for /cgi-bin/luci; install only the server/modules.
    apk add --no-scripts lighttpd lighttpd-mod-cgi lighttpd-mod-setenv lighttpd-mod-alias || {
        echo "z2k-openwrt: не удалось обеспечить системные зависимости OpenWrt" >&2
        return 1
    }
    z2k_ow_pkg_remove_legacy "$_names" || {
        echo "z2k-openwrt: не удалось удалить legacy z2kOW ownership" >&2
        return 1
    }

    for _feed in "$_feed_dir"/*; do
        [ -f "$_feed" ] || continue
        [ ! -L "$_feed" ] || continue
        _one="${_feed}.z2k.$$"
        awk 'tolower($0) !~ /github\.com\/t0fox\/z2kow\// && tolower($0) !~ /feed\.z2k\.example\.com\//' "$_feed" > "$_one" \
            || { rm -f "$_one"; return 1; }
        if grep -qiE 'z2kow|feed\.z2k\.example\.com' "$_one"; then
            echo "z2k-openwrt: unrecognized legacy repository entry remains in $_feed" >&2
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
            echo "z2k-openwrt: unrecognized legacy repository entry remains; refusing migration" >&2
            return 1
        fi
    fi
    for _pkg in z2k-adapter z2k-webpanel z2k-zapret2-runtime z2k-warp-runtime; do
        if z2k_ow_pkg_installed "$_pkg"; then
            echo "z2k-openwrt: legacy package ownership remains: $_pkg" >&2
            return 1
        fi
    done
    return 0
}

z2k_ow_archive_safe() {
    _archive="$1"
    _listing="${2:-${Z2K_TMP:-/tmp/z2k}/archive-list.$$}"
    tar -tzf "$_archive" > "$_listing" 2>/dev/null || return 1
    [ -s "$_listing" ] || return 1
    while IFS= read -r _entry; do
        _entry=${_entry%/}
        case "$_entry" in
            ''|/*|../*|*/../*|*/..|..|*\\*|*" "*|*"	"*) return 1 ;;
            www|www/*|etc/config/uhttpd|etc/apk|etc/apk/*|*/*.apk|packages.adb) return 1 ;;
        esac
    done < "$_listing"
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
    _failed=0
    while IFS= read -r _rel; do
        [ -n "$_rel" ] || continue
        _dst="$(z2k_ow_path "$_rel")"
        _save="${_dst}.z2k-backup.${_transaction_id}"
        if [ -e "$_save" ] || [ -L "$_save" ]; then
            if [ -e "$_dst" ] || [ -L "$_dst" ]; then rm -rf "$_dst" || _failed=1; fi
            mkdir -p "$(dirname "$_dst")" || _failed=1
            mv "$_save" "$_dst" || _failed=1
        elif grep -Fqx "I|$_rel" "$_transaction" 2>/dev/null; then
            if [ -e "$_dst" ] || [ -L "$_dst" ]; then rm -rf "$_dst" || _failed=1; fi
        fi
    done < "$_paths"
    return "$_failed"
}

z2k_ow_backup_paths() {
    _transaction="$1" _paths="$2" _transaction_id="$3"
    : > "$_transaction" || return 1
    while IFS= read -r _rel; do
        [ -n "$_rel" ] || continue
        _dst="$(z2k_ow_path "$_rel")"
        _save="${_dst}.z2k-backup.${_transaction_id}"
        _new="${_dst}.z2k-new.${_transaction_id}"
        [ ! -e "$_save" ] && [ ! -L "$_save" ] && [ ! -e "$_new" ] && [ ! -L "$_new" ] || {
            echo "z2k-openwrt: stale transaction sidecar blocks $_rel" >&2
            return 1
        }
        mkdir -p "$(dirname "$_dst")" || return 1
        # Write-ahead journal lets a later invocation recover an interrupted
        # multi-path update. If mv fails before the backup exists, recovery
        # leaves the original destination untouched.
        printf 'B|%s\n' "$_rel" >> "$_transaction" || return 1
        if [ -e "$_dst" ] || [ -L "$_dst" ]; then
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
            echo "z2k-openwrt: archive omits owned path $_rel" >&2
            return 1
        }
        mkdir -p "$(dirname "$_dst")" || return 1
        _new="${_dst}.z2k-new.${_transaction_id}"
        printf 'I|%s\n' "$_rel" >> "$_transaction" || return 1
        # A final rename is always same-directory (and therefore atomic).
        # Large payload directories first try a same-filesystem rename from
        # staging; small /etc files are copied to an adjacent temporary file.
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
    _paths="$1" _transaction_id="$2"
    while IFS= read -r _rel; do
        [ -n "$_rel" ] || continue
        _dst="$(z2k_ow_path "$_rel")"
        rm -rf "${_dst}.z2k-backup.${_transaction_id}" \
            "${_dst}.z2k-new.${_transaction_id}"
    done < "$_paths"
}

z2k_ow_recover_transaction() {
    _work="$1" _state="$2" _service="$3" _target="${4:-}" _panel="${5:-}"
    [ -f "$_work/transaction-active" ] || return 0
    _paths="$_work/owned-paths"
    _transaction="$_work/transaction.log"
    _id="$(cat "$_work/transaction-id" 2>/dev/null)"
    case "$_id" in ''|*[!0-9]*) echo "z2k-openwrt: invalid interrupted transaction id" >&2; return 1 ;; esac
    [ -s "$_paths" ] || { echo "z2k-openwrt: interrupted transaction has no path journal" >&2; return 1; }
    _installed="$(z2k_ow_release_state_tag "$_state")" || return 1
    if [ -n "$_target" ] && [ "$_installed" = "$_target" ] \
        && [ -f "$_work/state-write-started" ]; then
        # Health checks and the state commit completed before power was lost;
        # only cleanup of lightweight rollback files was interrupted.
        z2k_ow_cleanup_transaction "$_paths" "$_id" || return 1
        rm -rf "$_work" || return 1
        return 0
    fi
    z2k_ow_restore_paths "$_transaction" "$_paths" "$_id" || return 1
    if [ -f "$_work/state-was-present" ]; then
        [ -f "$_work/installed-release.old" ] || return 1
        _state_tmp="${_state}.z2k-recover.$$"
        cp -p "$_work/installed-release.old" "$_state_tmp" && mv -f "$_state_tmp" "$_state" || return 1
    elif [ -f "$_work/state-write-started" ]; then
        rm -f "$_state" || return 1
    fi
    z2k_ow_cleanup_transaction "$_paths" "$_id"
    rm -rf "$_work" || return 1
    z2k_ow_restart_services "$_service" "$_panel" || true
    echo "z2k-openwrt: recovered interrupted install transaction" >&2
}

z2k_ow_restart_services() {
    _restart_failed=0
    for _restart_service in "$1" "$2"; do
        [ -n "$_restart_service" ] && [ -x "$_restart_service" ] || continue
        "$_restart_service" restart >/dev/null 2>&1 || \
            "$_restart_service" start >/dev/null 2>&1 || _restart_failed=1
    done
    [ "$_restart_failed" = 0 ]
}

_z2k_ow_install_release_locked() {
    _requested="${1:-}"
    printf '%s' "$_requested" | grep -Eq '^[pr]-[0-9]+(\.[0-9]+)+$' || {
        echo "usage: install_release <release-tag>" >&2
        return 2
    }

    _root="${Z2K_ROOT:-/usr/lib/z2k}"
    _adapter="${Z2K_ADAPTER_DIR:-$_root/platform/openwrt}"
    _lib="${Z2K_LIB:-$_root/lib}"
    . "$_adapter/release_state.sh" || return 1
    _state="$(z2k_ow_path "${Z2K_OW_INSTALLED_RELEASE_FILE:-/etc/z2k/state/installed-release}")"
    _work="$(z2k_ow_path "${Z2K_OW_INSTALL_WORK:-/usr/lib/.z2k-install}")"
    _stage="$_work/stage"
    _archive="$_work/openwrt-rootfs.tar.gz"
    _manifest="${Z2K_OW_BOOTSTRAP_MANIFEST:-${Z2K_OW_MANIFEST_PATH:-${Z2K_AU_TMP_DIR:-/tmp/z2k/update}/UPDATES.json}}"
    _paths="$_work/owned-paths"
    _old_state="$_work/installed-release.old"
    _service="$(z2k_ow_path /etc/init.d/z2k)"
    _panel="$(z2k_ow_path /etc/init.d/z2k-webpanel)"
    _transaction="$_work/transaction.log"
    _transaction_id="$$"
    _stopped=0 _tag=""

    if [ "${Z2K_OW_TESTING:-0}" != 1 ]; then
        [ "$(id -u 2>/dev/null || echo 1)" = 0 ] || { echo "install_release must run as root" >&2; return 1; }
        . "$_adapter/paths.sh" || return 1
        . "$_adapter/env.sh" || return 1
        . "$_lib/utils.sh" || return 1
        . "$_lib/auto_update.sh" || return 1
        . "$_adapter/manifest.sh" || return 1
        if [ -n "${Z2K_OW_BOOTSTRAP_MANIFEST:-}" ]; then
            _sig="${Z2K_OW_BOOTSTRAP_SIGNATURE:-${Z2K_OW_BOOTSTRAP_MANIFEST}.sig}"
            z2k_ow_manifest_verify_signature "$_manifest" "$_sig" || {
                echo "z2k-openwrt: bootstrap manifest signature invalid or unavailable" >&2
                return 1
            }
            z2k_ow_manifest_release_ok "$_manifest" || return 1
        else
            z2k_ow_manifest_prepare_production "$_manifest" || return 1
        fi
    else
        . "$_adapter/manifest.sh" || return 1
    fi
    z2k_ow_manifest_release_ok "$_manifest" || return 1
    _tag="$(z2k_ow_json_value "$_manifest" current)" || return 1
    [ "$_tag" = "$_requested" ] || {
        echo "z2k-openwrt: only controlled current release may be installed ($_tag)" >&2
        return 1
    }
    z2k_ow_recover_transaction "$_work" "$_state" "$_service" "$_tag" "$_panel" || return 1
    _installed="$(z2k_ow_release_state_tag "$_state")" || return 1
    _state_record="$(z2k_ow_release_state_read "$_state")" || _state_record=""
    _seq="$(z2k_ow_json_value "$_manifest" seq)" || return 1
    if [ -n "$_state_record" ] && [ "$_installed" = "$_tag" ] \
        && [ "$(z2k_ow_release_state_seq "$_state")" = "$_seq" ] \
        && ! z2k_ow_legacy_packages_present && ! z2k_ow_relay_identity_migration_needed; then
        echo "none $_tag"
        return 0
    fi

    _url="$(z2k_ow_json_value "$_manifest" artifact.url)" || return 1
    _sha="$(z2k_ow_json_value "$_manifest" artifact.sha256 | tr 'A-F' 'a-f')" || return 1
    _size="$(z2k_ow_json_value "$_manifest" artifact.size_bytes)" || return 1
    case "$_sha" in *[!0-9a-f]*|'') return 1 ;; esac
    [ "${#_sha}" -eq 64 ] || return 1
    case "$_size" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_size" -gt 0 ] || return 1

    mkdir -p "$_work" || return 1
    rm -rf "$_stage" "$_transaction" "$_work/transaction-active" \
        "$_work/transaction-id" "$_work/state-was-present" \
        "$_work/state-write-started" "$_old_state"
    mkdir -p "$_stage" || return 1
    if [ -n "${Z2K_OW_BOOTSTRAP_ARTIFACT:-}" ]; then
        cp "$Z2K_OW_BOOTSTRAP_ARTIFACT" "$_archive" || return 1
    elif [ "${Z2K_OW_TESTING:-0}" = 1 ] && [ -n "${Z2K_OW_ARTIFACT_PATH:-}" ]; then
        cp "$Z2K_OW_ARTIFACT_PATH" "$_archive" || return 1
    else
        z2k_ow_download "$_url" "$_archive" || { rm -rf "$_work"; return 1; }
    fi
    [ "$(wc -c < "$_archive" | tr -d ' \t\r\n')" = "$_size" ] || { rm -rf "$_work"; return 1; }
    _actual="$(sha256sum "$_archive" 2>/dev/null | awk '{print $1}')"
    [ "$_actual" = "$_sha" ] || { rm -rf "$_work"; return 1; }
    z2k_ow_archive_safe "$_archive" "$_work/archive-list" || { rm -rf "$_work"; return 1; }
    z2k_ow_extract_target_payload "$_archive" "$_stage" "$_work/archive-list" "$_work" \
        || { rm -rf "$_work"; return 1; }
    z2k_ow_owned_paths > "$_paths" || { rm -rf "$_work"; return 1; }
    z2k_ow_migrate_relay_identity || { rm -rf "$_work"; return 1; }

    printf '%s\n' "$_transaction_id" > "$_work/transaction-id" || { rm -rf "$_work"; return 1; }
    if [ -e "$_state" ]; then
        cp -p "$_state" "$_old_state" || { rm -rf "$_work"; return 1; }
        : > "$_work/state-was-present" || { rm -rf "$_work"; return 1; }
    fi
    : > "$_work/transaction-active" || { rm -rf "$_work"; return 1; }

    if [ -x "$_service" ]; then
        "$_service" stop >/dev/null 2>&1 || true
        _stopped=1
    fi
    z2k_ow_backup_paths "$_transaction" "$_paths" "$_transaction_id" || {
        z2k_ow_restore_paths "$_transaction" "$_paths" "$_transaction_id" || true
        rm -rf "$_work"
        [ "$_stopped" = 0 ] || z2k_ow_restart_services "$_service" "$_panel" || true
        return 1
    }
    z2k_ow_legacy_migrate "$(z2k_ow_path /usr/lib/z2k).z2k-backup.$_transaction_id" || {
        z2k_ow_restore_paths "$_transaction" "$_paths" "$_transaction_id" || true
        z2k_ow_cleanup_transaction "$_paths" "$_transaction_id"
        rm -rf "$_work"
        [ "$_stopped" = 0 ] || z2k_ow_restart_services "$_service" "$_panel" || true
        return 1
    }

    if ! z2k_ow_apply_staged_tree "$_stage" "$_transaction" "$_paths" "$_transaction_id"; then
        z2k_ow_restore_paths "$_transaction" "$_paths" "$_transaction_id" || echo "z2k-openwrt: file rollback incomplete" >&2
        z2k_ow_cleanup_transaction "$_paths" "$_transaction_id"
        [ "$_stopped" = 0 ] || z2k_ow_restart_services "$_service" "$_panel" || true
        rm -rf "$_work"
        return 1
    fi

    _state_dir="$(dirname "$_state")"
    mkdir -p "$_state_dir" || {
        z2k_ow_restore_paths "$_transaction" "$_paths" "$_transaction_id" || true
        z2k_ow_cleanup_transaction "$_paths" "$_transaction_id"
        [ "$_stopped" = 0 ] || z2k_ow_restart_services "$_service" "$_panel" || true
        rm -rf "$_work"; return 1
    }

    if [ "${Z2K_OW_TESTING:-0}" != 1 ]; then
        _bootstrap="$_adapter/bootstrap.sh"
        if [ -r "$_bootstrap" ]; then
            . "$_bootstrap" || return 1
            . "$_adapter/paths.sh" || return 1
            . "$_adapter/env.sh" || return 1
            z2k_ow_bootstrap || {
                z2k_ow_restore_paths "$_transaction" "$_paths" "$_transaction_id" || true
                z2k_ow_cleanup_transaction "$_paths" "$_transaction_id"
                z2k_ow_restart_services "$_service" "$_panel" || true
                rm -rf "$_work"; return 1
            }
        fi
    fi
    if [ "${Z2K_OW_TESTING:-0}" != 1 ] || [ "${Z2K_OW_TEST_HEALTHCHECK:-0}" = 1 ]; then
        for _svc in "$_service" "$_panel"; do
            [ -x "$_svc" ] || continue
            "$_svc" enable >/dev/null 2>&1 || true
            "$_svc" restart >/dev/null 2>&1 || "$_svc" start >/dev/null 2>&1 || {
                echo "z2k-openwrt: service failed after payload replacement: $_svc" >&2
                z2k_ow_restore_paths "$_transaction" "$_paths" "$_transaction_id" || true
                z2k_ow_cleanup_transaction "$_paths" "$_transaction_id"
                z2k_ow_restart_services "$_service" "$_panel" || true
                rm -rf "$_work"; return 1
            }
        done
        _n=0
        while [ "$_n" -lt 15 ]; do
            if [ ! -x "$_service" ] || "$_service" status >/dev/null 2>&1; then
                if [ ! -x "$_panel" ] || "$_panel" running >/dev/null 2>&1; then break; fi
            fi
            _n=$((_n + 1)); sleep 1
        done
        [ "$_n" -lt 15 ] || {
            z2k_ow_restore_paths "$_transaction" "$_paths" "$_transaction_id" || true
            z2k_ow_cleanup_transaction "$_paths" "$_transaction_id"
            z2k_ow_restart_services "$_service" "$_panel" || true
            rm -rf "$_work"; return 1
        }
    fi

    : > "$_work/state-write-started" || {
        z2k_ow_restore_paths "$_transaction" "$_paths" "$_transaction_id" || true
        z2k_ow_cleanup_transaction "$_paths" "$_transaction_id"
        z2k_ow_restart_services "$_service" "$_panel" || true
        rm -rf "$_work"; return 1
    }
    _state_tmp="${_state}.z2k-new.$_transaction_id"
    z2k_ow_release_state_write "$_state" "$_manifest" || {
        z2k_ow_restore_paths "$_transaction" "$_paths" "$_transaction_id" || true
        z2k_ow_cleanup_transaction "$_paths" "$_transaction_id"
        if [ -f "$_old_state" ]; then mv -f "$_old_state" "$_state"; else rm -f "$_state"; fi
        z2k_ow_restart_services "$_service" "$_panel" || true
        rm -rf "$_work"; return 1
    }

    # The former package updater kept two additional version markers. Retire
    # them only after the new full payload is healthy; the single canonical
    # installed-release file remains the only local release state.
    rm -f "${_state%/*}/installed-tag" \
          "${_state%/*}/product-tag" \
          "${_state%/*}/product-update.status" \
          "$(z2k_ow_path "${Z2K_ZAPRET2_RUNTIME:-/opt/zapret2}/.z2k-installed-tag")" \
          "$(z2k_ow_path "${Z2K_ZAPRET2_RUNTIME:-/opt/zapret2}/.z2k-tree-dirty")"
    z2k_ow_cleanup_transaction "$_paths" "$_transaction_id"
    rm -rf "$_work"
    printf 'installed %s\n' "$_tag"
}

# Return the target-specific extracted size for the disk-space gate.
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

# Verify every archive member first, then unpack common files and only the
# router's binary variants. UPDATES.json still approves and hashes the entire
# one-file release payload; pruning saves constrained flash during installation.
z2k_ow_extract_target_payload() {
    _archive="$1" _stage="$2" _listing="$3" _work="$4"
    _arch_script=usr/lib/z2k/platform/openwrt/arch.sh
    tar -xzf "$_archive" -C "$_stage" "$_arch_script" || return 1
    . "$_stage/$_arch_script" || return 1
    _target_arch="$(z2k_ow_arch_name 2>/dev/null)" || {
        echo "z2k-openwrt: unsupported router architecture; release payload was not extracted" >&2
        return 1
    }
    _selected="$_work/target-payload-list"
    awk -v arch="$_target_arch" '
        {
            path=$0; sub(/\/$/, "", path)
            # Extract regular members and links only. Directory names in a
            # -T file can be treated as duplicate exact matches by tar, while
            # parent directories are created automatically for each member.
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
    _available_kb="$(df -Pk "$_work" 2>/dev/null | awk 'END {print $4}')"
    case "$_available_kb" in ''|*[!0-9]*) echo "z2k-openwrt: cannot determine free space for payload staging" >&2; return 1 ;; esac
    if ! awk -v free_kb="$_available_kb" -v needed="$_unpacked" 'BEGIN { exit (free_kb * 1024 >= needed + 8388608) ? 0 : 1 }'; then
        echo "z2k-openwrt: insufficient free space for target payload staging (need ${_unpacked} bytes plus 8 MiB; available ${_available_kb} KiB)" >&2
        return 1
    fi
    tar -xzf "$_archive" -C "$_stage" -T "$_selected" || return 1
    for _required in \
        "usr/lib/z2k/bin/linux-$_target_arch/tg-mtproxy-client" \
        "usr/lib/z2k/bin/linux-$_target_arch/z2k-rt-proxy" \
        "usr/lib/z2k/bin/linux-$_target_arch/z2k-detect" \
        "usr/lib/z2k/platform/openwrt/bin/linux-$_target_arch/z2k-warpd"; do
        [ -s "$_stage/$_required" ] || {
            echo "z2k-openwrt: complete release payload omits target binary $_required" >&2
            return 1
        }
    done
}

# One process owns the full convergence transaction at a time. A crashed
# installer leaves only its PID marker; the next invocation removes that
# stale lock and lets z2k_ow_recover_transaction() restore or finish cleanup.
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
            echo "z2k-openwrt: refusing unsafe installer lock path $_lock" >&2
            return 1
        fi
        _pid="$(cat "$_lock/pid" 2>/dev/null)"
        case "$_pid" in
            ''|*[!0-9]*)
                echo "z2k-openwrt: installer lock has no valid owner: $_lock" >&2
                return 1
                ;;
        esac
        if [ "$_pid" = "$$" ] || kill -0 "$_pid" 2>/dev/null; then
            echo "z2k-openwrt: another install_release is running (pid $_pid)" >&2
            return 1
        fi
        rm -f "$_lock/pid" 2>/dev/null || return 1
        rmdir "$_lock" 2>/dev/null || return 1
        _attempt=$((_attempt + 1))
    done
    echo "z2k-openwrt: could not acquire installer lock $_lock" >&2
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

# Public convergence entry point used by both fresh install and every update.
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
        echo "z2k-openwrt: could not release installer lock $_lock" >&2
        [ "$_rc" -ne 0 ] || _rc=1
    }
    return "$_rc"
}
