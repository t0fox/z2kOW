#!/bin/sh
# Canonical OpenWrt implementation of the upstream `uninstall` action.
# This file is shared by `z2kow uninstall` and the confirmed WebPanel job.

_z2k_ow_uninstall_progress() {
    [ -n "${Z2K_JOB_ID:-}" ] || return 0
    local _epoch
    _epoch=$(date +%s 2>/dev/null) || _epoch=
    case "$_epoch" in
        ''|*[!0-9]*) printf 'Удаление z2k: %s\n' "$*" >&2 ;;
        *) printf '@z2k-ts:%s|Удаление z2k: %s\n' "$_epoch" "$*" >&2 ;;
    esac
}

z2k_ow_uninstall_paths_load() {
    local _root="${Z2K_ROOT:-/usr/lib/z2k}" _adapter
    _adapter="${Z2K_ADAPTER_DIR:-$_root/platform/openwrt}"
    [ -r "$_adapter/paths.sh" ] && . "$_adapter/paths.sh" || {
        echo "z2k-openwrt: adapter paths are unavailable; refusing uninstall" >&2
        return 1
    }
    . "$_adapter/env.sh" || return 1
    . "$_adapter/release.sh" || return 1
    . "$_adapter/schedule.sh" || return 1
    . "$_adapter/firewall.sh" || return 1
    . "$_adapter/tg.sh" || return 1
    . "$_adapter/rt.sh" || return 1
    Z2K_WARP_SOURCE_ONLY=1
    export Z2K_WARP_SOURCE_ONLY
    . "$_adapter/warp.sh" || return 1
    unset Z2K_WARP_SOURCE_ONLY
    . "$_adapter/insta-ip.sh" || return 1
    . "$_adapter/tiktok.sh" || return 1
    . "$_adapter/doh.sh" || return 1
    return 0
}

_z2k_ow_uninstall_path_is_safe() {
    local _path="$1" _suffix="$2" _expected
    _expected="$_suffix"
    [ -z "${Z2K_OW_SYSROOT:-}" ] || _expected="${Z2K_OW_SYSROOT%/}${_suffix}"
    [ "$_path" = "$_expected" ] || {
        echo "z2k-openwrt: refusing unsafe uninstall path: $_path (expected $_expected)" >&2
        return 1
    }
    case "$_path" in
        /|*//*|*/../*|*/..|*/./*|*/.)
            echo "z2k-openwrt: refusing non-canonical uninstall path: $_path" >&2
            return 1
            ;;
    esac
    return 0
}

_z2k_ow_uninstall_validate_paths() {
    _z2k_ow_uninstall_path_is_safe "$Z2K_ROOT" "$Z2K_OW_CANON_ROOT_SUFFIX" || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_ETC" "$Z2K_OW_CANON_ETC_SUFFIX" || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_STATE" "$Z2K_OW_CANON_STATE_SUFFIX" || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_CONFIG" "$Z2K_OW_CANON_CONFIG_SUFFIX" || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_USER_LISTS" "$Z2K_OW_CANON_USER_LISTS_SUFFIX" || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_TMP" "$Z2K_OW_CANON_TMP_SUFFIX" || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_WARP_TMP" "$Z2K_OW_CANON_WARP_TMP_SUFFIX" || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_OW_INSTALL_TMP" "$Z2K_OW_CANON_INSTALL_TMP_SUFFIX" || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_ZAPRET2_RUNTIME" "$Z2K_OW_CANON_ZAPRET2_SUFFIX" || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_OW_ROLLBACK_DIR" "$Z2K_OW_CANON_ROLLBACK_SUFFIX" || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_OW_INSTALL_WORK" /usr/lib/.z2k-install || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_OW_INSTALL_LOCK" /usr/lib/.z2k-install.lock || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_OW_CORE_INIT" /etc/init.d/z2k || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_OW_PANEL_INIT" /etc/init.d/z2k-webpanel || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_OW_HOTPLUG_FILE" /etc/hotplug.d/iface/90-z2k || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_OW_SYSCTL_FILE" /etc/sysctl.d/99-z2k.conf || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_OW_WARP_NFT_FILE" /usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_OW_CLI_FILE" /usr/bin/z2kow || return 1
    _z2k_ow_uninstall_path_is_safe "$Z2K_OW_INSTALL_RELEASE_FILE" /usr/sbin/install_release || return 1
    [ "$WARP_DEVICE" = "$Z2K_STATE/warp/device.json" ] || {
        echo "z2k-openwrt: refusing WARP identity outside canonical state: $WARP_DEVICE" >&2
        return 1
    }
    _z2k_ow_uninstall_path_is_safe "$WARP_DEVICE" "$Z2K_OW_CANON_WARP_DEVICE_SUFFIX" || return 1
    local _dir
    for _dir in "$Z2K_ROOT" "$Z2K_ETC" "$Z2K_ZAPRET2_RUNTIME" "$Z2K_TMP" \
        "$Z2K_WARP_TMP" "$Z2K_OW_INSTALL_TMP" "$Z2K_OW_INSTALL_WORK" \
        "$Z2K_OW_ROLLBACK_DIR"; do
        if [ -L "$_dir" ]; then
            echo "z2k-openwrt: refusing symlink at owned uninstall directory $_dir" >&2
            return 1
        fi
    done
    return 0
}

_z2k_ow_uninstall_has_owned_install() {
    local _warp_dir _entry
    _warp_dir=$(dirname "$WARP_DEVICE")
    for _entry in "$Z2K_ROOT" "$Z2K_ZAPRET2_RUNTIME" "$Z2K_TMP" \
        "$Z2K_OW_INSTALL_TMP" "$Z2K_WARP_TMP" "$Z2K_OW_INSTALL_WORK" \
        "$Z2K_OW_ROLLBACK_DIR" "$Z2K_OW_INSTALL_LOCK" \
        "$Z2K_OW_CORE_INIT" "$Z2K_OW_PANEL_INIT" \
        "$Z2K_OW_HOTPLUG_FILE" "$Z2K_OW_SYSCTL_FILE" "$Z2K_OW_WARP_NFT_FILE" \
        "$Z2K_OW_CLI_FILE" "$Z2K_OW_INSTALL_RELEASE_FILE"; do
        if [ -e "$_entry" ] || [ -L "$_entry" ]; then
            return 0
        fi
    done
    # /etc/z2k is retained only as the upstream WARP identity/config directory
    # after a successful uninstall. Ignore that one subtree on repeat calls.
    if [ -d "$Z2K_ETC" ]; then
        _entry=$(find "$Z2K_ETC" -mindepth 1 ! -path "$_warp_dir" \
            ! -path "$_warp_dir/*" -print -quit 2>/dev/null)
        [ -n "$_entry" ] && return 0
    fi
    return 1
}

_z2k_ow_uninstall_remove_cron() {
    local _rc=0
    [ -f "$Z2K_CRON_TAB" ] || return 0
    z2k_ow_cron_remove || _rc=1
    z2k_ow_tg_cron_remove || _rc=1
    z2k_ow_rt_cron_remove || _rc=1
    z2k_ow_warp_cron_remove || _rc=1
    z2k_ow_fw_cron_remove || _rc=1
    z2k_ow_tcp16_cron_remove || _rc=1
    z2k_ow_tiktok_cron_remove || _rc=1
    return "$_rc"
}

_z2k_ow_uninstall_stop_owned_nfqws() {
    local _proc_root="${Z2K_OW_PROC_ROOT:-/proc}" _binary="${Z2K_NFQWS2:-$Z2K_ZAPRET2_RUNTIME/nfq2/nfqws2}"
    local _resolved="" _proc _pid _exe _n
    [ -x "$_binary" ] || return 0
    _resolved=$(readlink -f "$_binary" 2>/dev/null) || return 1
    for _proc in "$_proc_root"/[0-9]*; do
        [ -r "$_proc/exe" ] || continue
        _exe=$(readlink -f "$_proc/exe" 2>/dev/null) || continue
        [ "$_exe" = "$_resolved" ] || continue
        _pid=${_proc##*/}
        kill "$_pid" 2>/dev/null || true
        _n=0
        while [ -e "$_proc/exe" ] && [ "$_n" -lt 3 ]; do
            sleep 1
            _n=$((_n + 1))
        done
        if [ -e "$_proc/exe" ]; then
            kill -9 "$_pid" 2>/dev/null || true
            sleep 1
        fi
        [ ! -e "$_proc/exe" ] || {
            echo "z2k-openwrt: cannot stop z2k-owned nfqws2 process $_pid" >&2
            return 1
        }
    done
    return 0
}

_z2k_ow_uninstall_fw4_include() {
    local _file="$Z2K_OW_WARP_NFT_FILE" _saved="" _rc=0 _rules=""
    local _rule="${WARP_FW4_RULE_COMMENT:-!z2k: WARP forwarded traffic}"
    local _nft="${Z2K_OW_NFT_BIN:-nft}" _reload="${Z2K_FW4_RELOAD:-/etc/init.d/firewall}"
    if ! command -v "$_nft" >/dev/null 2>&1 && [ ! -x "$_nft" ]; then
        echo "z2k-openwrt: nft is unavailable; cannot verify fw4 cleanup" >&2
        return 1
    fi
    _rules=$("$_nft" list ruleset 2>/dev/null) || {
        echo "z2k-openwrt: nft could not inspect the fw4 ruleset" >&2
        return 1
    }
    if [ -e "$_file" ] || [ -L "$_file" ]; then
        _saved="${_file}.uninstall.$$"
        [ ! -e "$_saved" ] && [ ! -L "$_saved" ] || return 1
        cp -p "$_file" "$_saved" || return 1
        rm -f "$_file" || { rm -f "$_saved"; return 1; }
    fi
    if [ -n "$_saved" ] || printf '%s\n' "$_rules" | grep -qF "$_rule"; then
        [ -x "$_reload" ] && "$_reload" reload >/dev/null 2>&1 || _rc=1
    fi
    _rules=$("$_nft" list ruleset 2>/dev/null) || _rc=1
    if printf '%s\n' "$_rules" | grep -qF "$_rule"; then
        _rc=1
    fi
    if [ "$_rc" != 0 ]; then
        if [ -n "$_saved" ]; then
            mv "$_saved" "$_file" 2>/dev/null || \
                echo "z2k-openwrt: WARP firewall include backup remains at $_saved" >&2
            "$_reload" reload >/dev/null 2>&1 || true
        fi
        echo "z2k-openwrt: fw4 still has z2k WARP state; retry uninstall after firewall reload succeeds" >&2
        return 1
    fi
    [ -z "$_saved" ] || rm -f "$_saved"
    return 0
}

_z2k_ow_uninstall_preserve_warp_move() {
    local _warp_dir _backup _moved=0
    _warp_dir=$(dirname "$WARP_DEVICE")
    _backup="${Z2K_ETC}.warp-preserve"
    [ ! -L "$_warp_dir" ] || { echo "z2k-openwrt: WARP state path is a symlink; refusing uninstall" >&2; return 1; }
    [ ! -e "$_warp_dir" ] || [ -d "$_warp_dir" ] || {
        echo "z2k-openwrt: WARP state path is not a directory; refusing uninstall" >&2
        return 1
    }
    [ ! -L "$_backup" ] && { [ ! -e "$_backup" ] || [ -d "$_backup" ]; } || {
        echo "z2k-openwrt: invalid WARP preservation path: $_backup" >&2
        return 1
    }
    if [ -d "$_warp_dir" ] && [ -d "$_backup" ]; then
        echo "z2k-openwrt: both WARP state and interrupted preservation exist; refusing to choose" >&2
        return 1
    fi
    if [ -d "$_warp_dir" ]; then
        mv "$_warp_dir" "$_backup" || return 1
        _moved=1
    fi
    if [ -e "$Z2K_ETC" ] || [ -L "$Z2K_ETC" ]; then
        rm -rf "$Z2K_ETC" || {
            if [ "$_moved" = 1 ]; then
                mkdir -p "$(dirname "$_warp_dir")" 2>/dev/null
                mv "$_backup" "$_warp_dir" 2>/dev/null || \
                    echo "z2k-openwrt: WARP state preserved at $_backup" >&2
            fi
            return 1
        }
    fi
    if [ -d "$_backup" ]; then
        mkdir -p "$(dirname "$_warp_dir")" || {
            echo "z2k-openwrt: WARP state preserved at $_backup" >&2
            return 1
        }
        mv "$_backup" "$_warp_dir" || {
            echo "z2k-openwrt: WARP state preserved at $_backup" >&2
            return 1
        }
    fi
    [ ! -e "$Z2K_OW_INSTALLED_RELEASE_FILE" ] || return 1
    [ ! -e "$Z2K_CONFIG" ] || return 1
    return 0
}

_z2k_ow_uninstall_service() {
    local _service="$1" _label="$2"
    if [ ! -e "$_service" ] && [ ! -L "$_service" ]; then
        return 0
    fi
    [ ! -L "$_service" ] || {
        echo "z2k-openwrt: refusing to execute symlinked $_label service: $_service" >&2
        return 1
    }
    [ -x "$_service" ] || {
        echo "z2k-openwrt: owned $_label service is not executable: $_service" >&2
        return 1
    }
    "$_service" disable >/dev/null 2>&1 || return 1
    "$_service" stop >/dev/null 2>&1
}

_z2k_ow_uninstall_verify_processes() {
    local _fn
    for _fn in z2k_ow_tg_running z2k_ow_rt_running warp_running wp_panel_running; do
        command -v "$_fn" >/dev/null 2>&1 || continue
        if "$_fn" >/dev/null 2>&1; then
            echo "z2k-openwrt: $_fn still reports a z2k-owned process after stop" >&2
            return 1
        fi
    done
    return 0
}

_z2k_ow_uninstall_cleanup_trap() {
    local _rc=$?
    if [ -n "${_Z2K_OW_UNINSTALL_LOCK:-}" ]; then
        z2k_ow_install_lock_release "$_Z2K_OW_UNINSTALL_LOCK" || {
            echo "z2k-openwrt: could not release install lock $_Z2K_OW_UNINSTALL_LOCK" >&2
            [ "$_rc" -ne 0 ] || _rc=1
        }
    fi
    exit "$_rc"
}

z2k_ow_uninstall() (
    local _rc=0 _work _state _preserved_warp=0
    Z2K_OW_CORE_INIT="${Z2K_OW_CORE_INIT:-$(z2k_ow_path /etc/init.d/z2k)}"
    Z2K_OW_PANEL_INIT="${Z2K_OW_PANEL_INIT:-$(z2k_ow_path /etc/init.d/z2k-webpanel)}"
    Z2K_OW_HOTPLUG_FILE="${Z2K_OW_HOTPLUG_FILE:-$(z2k_ow_path /etc/hotplug.d/iface/90-z2k)}"
    Z2K_OW_SYSCTL_FILE="${Z2K_OW_SYSCTL_FILE:-$(z2k_ow_path /etc/sysctl.d/99-z2k.conf)}"
    Z2K_OW_WARP_NFT_FILE="${Z2K_OW_WARP_NFT_FILE:-$(z2k_ow_path /usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft)}"
    Z2K_OW_CLI_FILE="${Z2K_OW_CLI_FILE:-$(z2k_ow_path /usr/bin/z2kow)}"
    Z2K_OW_INSTALL_RELEASE_FILE="${Z2K_OW_INSTALL_RELEASE_FILE:-$(z2k_ow_path /usr/sbin/install_release)}"
    Z2K_OW_ROLLBACK_DIR="${Z2K_OW_ROLLBACK_DIR:-$(z2k_ow_path "$Z2K_OW_CANON_ROLLBACK_SUFFIX")}"
    Z2K_OW_INSTALL_WORK="${Z2K_OW_INSTALL_WORK:-$(z2k_ow_path /usr/lib/.z2k-install)}"
    Z2K_OW_INSTALL_LOCK="${Z2K_OW_INSTALL_LOCK:-$(z2k_ow_path /usr/lib/.z2k-install.lock)}"
    WARP_DEVICE="${WARP_DEVICE:-$Z2K_STATE/warp/device.json}"
    export Z2K_OW_CORE_INIT Z2K_OW_PANEL_INIT Z2K_OW_HOTPLUG_FILE Z2K_OW_SYSCTL_FILE \
        Z2K_OW_WARP_NFT_FILE Z2K_OW_CLI_FILE Z2K_OW_INSTALL_RELEASE_FILE \
        Z2K_OW_ROLLBACK_DIR Z2K_OW_INSTALL_WORK Z2K_OW_INSTALL_LOCK WARP_DEVICE

    _z2k_ow_uninstall_validate_paths || return 1
    _z2k_ow_uninstall_has_owned_install || {
        echo "z2k-openwrt: z2kOW is already uninstalled"
        return 0
    }
    if [ "${Z2K_OW_TESTING:-0}" != 1 ] && [ "$(id -u 2>/dev/null || echo 1)" != 0 ]; then
        echo "z2k-openwrt: uninstall must run as root" >&2
        return 1
    fi

    _Z2K_OW_UNINSTALL_LOCK="$Z2K_OW_INSTALL_LOCK"
    z2k_ow_install_lock_acquire "$_Z2K_OW_UNINSTALL_LOCK" || return 1
    trap _z2k_ow_uninstall_cleanup_trap EXIT

    _work="$Z2K_OW_INSTALL_WORK"
    _state="$Z2K_OW_INSTALLED_RELEASE_FILE"
    _z2k_ow_uninstall_progress "проверяю и восстанавливаю прерванную транзакцию установки"
    z2k_ow_recover_transaction "$_work" "$_state" "$Z2K_OW_CORE_INIT" "" "$Z2K_OW_PANEL_INIT" || {
        echo "z2k-openwrt: cannot recover interrupted release transaction; uninstall stopped safely" >&2
        return 1
    }

    # Remove future cron launches first, then disable and stop every procd
    # owner while its adapters and state are still present.
    _z2k_ow_uninstall_progress "снимаю расписания и останавливаю panel/core службы"
    _z2k_ow_uninstall_remove_cron || _rc=1
    _z2k_ow_uninstall_service "$Z2K_OW_PANEL_INIT" WebPanel || _rc=1
    _z2k_ow_uninstall_service "$Z2K_OW_CORE_INIT" core || _rc=1
    _z2k_ow_uninstall_stop_owned_nfqws || _rc=1
    _z2k_ow_uninstall_verify_processes || _rc=1

    # Keep exact OpenWrt-owned service integrations removable even if an older
    # stop path missed them. Each adapter removes only its own nft/UCI entries.
    _z2k_ow_uninstall_progress "очищаю принадлежащие интеграции Telegram, RT, WARP, Insta, TikTok и DoH"
    z2k_ow_tg cleanup || _rc=1
    z2k_ow_rt cleanup || _rc=1
    z2k_ow_warp cleanup || _rc=1
    z2k_ow_insta_uninstall || _rc=1
    z2k_ow_tiktok_uninstall || _rc=1
    z2k_ow_doh_uninstall || _rc=1
    z2k_ow_fw_remove || _rc=1
    _z2k_ow_uninstall_progress "проверяю firewall и восстанавливаю исходные offload-настройки"
    z2k_ow_stop_verify || _rc=1
    _z2k_ow_uninstall_fw4_include || _rc=1
    if [ -f "$Z2K_FW4_OFFLOAD_STATE" ]; then
        if command -v z2k_ow_offload_restore >/dev/null 2>&1; then
            z2k_ow_offload_restore || _rc=1
        else
            echo "z2k-openwrt: cannot restore the saved fw4 offload settings" >&2
            _rc=1
        fi
    fi
    if [ "$_rc" != 0 ]; then
        echo "z2k-openwrt: service or owned firewall cleanup failed; product files retained for a safe retry" >&2
        return 1
    fi

    # A successful upstream uninstall removes config, lists, custom strategies,
    # autocircular/TCP16/release state and panel settings. Its WARP registration
    # directory lives outside the removed tree and survives; move that one small
    # directory aside on the same filesystem, remove /etc/z2k, then restore it.
    _z2k_ow_uninstall_preserve_warp_move || {
        echo "z2k-openwrt: cannot safely preserve WARP registration state; product files retained" >&2
        return 1
    }

    _z2k_ow_uninstall_progress "удаляю runtime, rollback-снимок и временные файлы"
    rm -rf "$Z2K_OW_INSTALL_WORK" || { echo "z2k-openwrt: cannot remove install transaction workspace" >&2; return 1; }
    rm -rf "$Z2K_OW_ROLLBACK_DIR" || { echo "z2k-openwrt: cannot remove rollback snapshot" >&2; return 1; }
    rm -rf "$Z2K_ZAPRET2_RUNTIME" || { echo "z2k-openwrt: cannot remove owned zapret2 runtime" >&2; return 1; }
    rm -rf "$Z2K_TMP" "$Z2K_WARP_TMP" "$Z2K_OW_INSTALL_TMP" || {
        echo "z2k-openwrt: cannot remove z2k runtime/cache staging" >&2
        return 1
    }
    rm -f "$Z2K_OW_HOTPLUG_FILE" "$Z2K_OW_SYSCTL_FILE" \
        "$Z2K_OW_WARP_NFT_FILE" "$Z2K_OW_CLI_FILE" "$Z2K_OW_INSTALL_RELEASE_FILE" || {
        echo "z2k-openwrt: cannot remove owned OpenWrt hooks or commands" >&2
        return 1
    }
    rm -f "$Z2K_OW_PANEL_INIT" "$Z2K_OW_CORE_INIT" || {
        echo "z2k-openwrt: cannot remove owned procd init scripts" >&2
        return 1
    }
    _z2k_ow_uninstall_progress "удаляю payload z2kOW; сохранённая регистрация WARP остаётся на месте"
    rm -rf "$Z2K_ROOT" || {
        echo "z2k-openwrt: cannot remove the z2kOW release payload" >&2
        return 1
    }
    echo "z2k-openwrt: uninstall complete; WARP registration state preserved at $WARP_DEVICE"
    return 0
)

z2k_ow_uninstall_confirm() {
    local _answer="" _tty="${Z2K_UNINSTALL_TTY:-/dev/tty}"
    while :; do
        printf '%s [y/N]: ' "Вы уверены? Это действие необратимо!"
        if ! IFS= read -r _answer < "$_tty"; then return 1; fi
        _answer=$(printf '%s' "$_answer" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')
        case "$_answer" in
            y|yes|д|да) return 0 ;;
            ''|n|no|н|нет|неа) return 1 ;;
            *) printf '%s\n' 'Введите y/n' >&2 ;;
        esac
    done
}

z2k_ow_uninstall_async() {
    local _script="${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt/uninstall.sh"
    local _job_id _base
    [ -r "$_script" ] || { echo "z2k-openwrt: canonical uninstall script unavailable: $_script" >&2; return 1; }
    _job_id="$(date +%s)$$"
    _base="${Z2K_JOB_DIR:-${Z2K_OW_CANON_JOB_PREFIX%/*}}/z2k-job-${_job_id}"
    [ "${Z2K_OW_TESTING:-0}" != 1 ] || _base="${Z2K_JOB_PREFIX:-$_base}"
    (
        trap '' HUP
        env Z2K_UNINSTALL_CONFIRMED=1 /bin/sh "$_script" --worker > "${_base}.log" 2>&1
        _rc=$?
        printf '%s\n' "$_rc" > "${_base}.exit.new" && mv -f "${_base}.exit.new" "${_base}.exit"
        exit "$_rc"
    ) </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" > "${_base}.pid" || return 1
    printf '%s' "$_job_id"
}

z2k_ow_uninstall_main() {
    local _mode="${1:-cli}"
    case "$_mode" in
        --worker)
            [ "$#" -eq 1 ] || { echo 'usage: uninstall.sh --worker' >&2; return 2; }
            [ "${Z2K_UNINSTALL_CONFIRMED:-}" = 1 ] || {
                echo "z2k-openwrt: background uninstall requires server-side confirmation" >&2
                return 2
            }
            z2k_ow_uninstall_paths_load || return 1
            z2k_ow_uninstall
            ;;
        cli)
            [ "$#" -eq 0 ] || { shift; [ "$#" -eq 0 ] || { echo 'usage: z2kow uninstall' >&2; return 2; }; }
            if [ "${Z2K_UNINSTALL_CONFIRMED:-}" != 1 ] && ! z2k_ow_uninstall_confirm; then
                echo "z2k-openwrt: uninstall cancelled"
                return 0
            fi
            z2k_ow_uninstall_paths_load || return 1
            z2k_ow_uninstall
            ;;
        *) echo 'usage: z2kow uninstall' >&2; return 2 ;;
    esac
}

if [ "${0##*/}" = uninstall.sh ] && [ "${Z2K_OW_UNINSTALL_SOURCE_ONLY:-0}" != 1 ]; then
    _z2k_ow_uninstall_rc=0
    if [ "$#" -eq 0 ]; then
        z2k_ow_uninstall_main cli || _z2k_ow_uninstall_rc=$?
    else
        z2k_ow_uninstall_main "$@" || _z2k_ow_uninstall_rc=$?
    fi
    exit "$_z2k_ow_uninstall_rc"
fi
