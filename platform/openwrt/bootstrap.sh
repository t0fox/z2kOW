#!/bin/sh
# Persistent configuration bootstrap only. Release installation is owned by
# platform/openwrt/release.sh; this file never stages or versions payloads.

z2k_ow_retire_discovery() {
    local _init="${Z2K_OW_LEGACY_DETECT_INIT:-/etc/init.d/z2k-detect}"
    local _proc_root="${Z2K_OW_PROC_ROOT:-/proc}" _proc _pid _args _n
    local _det="${Z2K_DETECT_BIN:-$Z2K_BIN/z2k-detect}"
    local _owned_init=0 _retired=0

    if [ -e "$_init" ] || [ -L "$_init" ]; then
        if [ -L "$_init" ] || [ ! -f "$_init" ] \
           || ! grep -Fqx '# /etc/init.d/z2k-detect - reactive DPI-discovery daemon (parity S98z2k-detect).' "$_init" 2>/dev/null \
           || ! grep -Fqx '# PACKAGE-owned.' "$_init" 2>/dev/null \
           || ! grep -Fqx 'START=98' "$_init" 2>/dev/null; then
            echo "z2k-openwrt: preserving unrecognized legacy init path $_init" >&2
        else
            _owned_init=1
            if [ -x "$_init" ]; then
                "$_init" stop >/dev/null 2>&1 || return 1
            fi
            _retired=1
        fi
    fi

    for _proc in "$_proc_root"/[0-9]*; do
        [ -r "$_proc/cmdline" ] || continue
        _args=$(tr '\000' '\n' 2>/dev/null <"$_proc/cmdline" | head -2)
        [ "$_args" = "$(printf '%s\nrun' "$_det")" ] || continue
        _retired=1
        _pid=${_proc##*/}
        if [ -n "${Z2K_OW_KILL_CMD:-}" ]; then
            "$Z2K_OW_KILL_CMD" "$_pid" || { [ ! -d "$_proc" ] || return 1; }
        else
            kill "$_pid" 2>/dev/null || { [ ! -d "$_proc" ] || return 1; }
        fi
        _n=0
        while [ -r "$_proc/cmdline" ] && [ "$_n" -lt 5 ]; do
            _args=$(tr '\000' '\n' 2>/dev/null <"$_proc/cmdline" | head -2)
            [ "$_args" = "$(printf '%s\nrun' "$_det")" ] || break
            sleep 1
            _n=$((_n + 1))
        done
        _args=$(tr '\000' '\n' 2>/dev/null <"$_proc/cmdline" | head -2)
        [ "$_args" != "$(printf '%s\nrun' "$_det")" ] || return 1
    done

    [ "$_retired" = "1" ] || return 0
    rm -f "$Z2K_LISTS_DIR/discovered-domains.txt" \
        "$Z2K_LISTS_DIR/discovered-domains.txt.etag" \
        "$Z2K_STATE/discovered-domains.txt" \
        "$Z2K_STATE/discovered-domains.txt.etag" || return 1
    [ "$_owned_init" = "0" ] || rm -f "$_init" || return 1
    return 0
}

z2k_ow_bootstrap() {
    z2k_ow_retire_discovery || return 1
    mkdir -p "$Z2K_ETC" "$Z2K_STATE" "$Z2K_USER_LISTS" "$Z2K_CONF_DIR" \
        "$Z2K_RUN" "$Z2K_LOCKS" "$Z2K_LOG" "$Z2K_DOWNLOADS" "$Z2K_GENERATED" || return 1

    # Prefer OpenWrt's target triplet: uname -m reports plain mips on some
    # devices and cannot tell the release's big/little-endian runtime apart.
    if ! command -v z2k_ow_arch_name >/dev/null 2>&1; then
        . "${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}/arch.sh" || return 1
    fi
    _arch_name="$(z2k_ow_arch_name)" || {
        echo "z2k-openwrt: неизвестная архитектура роутера" >&2
        return 1
    }
    _arch_dir="linux-$_arch_name"
    _runtime="${Z2K_ZAPRET2_RUNTIME:-/opt/zapret2}"
    for _pair in nfq2/nfqws2 ip2net/ip2net mdig/mdig; do
        _dir="${_pair%%/*}" _name="${_pair#*/}"
        _source="$_runtime/binaries/$_arch_dir/$_name"
        _link="$_runtime/$_dir/$_name"
        [ -x "$_source" ] || {
            echo "z2k-openwrt: нет $_source для этой архитектуры" >&2
            return 1
        }
        mkdir -p "$(dirname "$_link")" || return 1
        _tmp_link="$_link.z2k-new.$$"
        rm -f "$_tmp_link"
        ln -s "../binaries/$_arch_dir/$_name" "$_tmp_link" || return 1
        mv -f "$_tmp_link" "$_link" || { rm -f "$_tmp_link"; return 1; }
    done

    if [ ! -f "$Z2K_CONFIG" ]; then
        [ -f "$Z2K_ROOT/share/config.default" ] || {
            echo "z2k-openwrt: нет ни $Z2K_CONFIG, ни дефолта" >&2
            return 1
        }
        cp -f "$Z2K_ROOT/share/config.default" "$Z2K_CONFIG" || return 1
    fi
    if [ ! -L "$Z2K_ROOT/config" ]; then
        [ ! -e "$Z2K_ROOT/config" ] || {
            echo "z2k-openwrt: $Z2K_ROOT/config существует и не симлинк" >&2
            return 1
        }
        ln -s "$Z2K_CONFIG" "$Z2K_ROOT/config" || return 1
    fi
    if [ ! -L "$Z2K_LISTS_DIR/whitelist.txt" ]; then
        [ ! -e "$Z2K_LISTS_DIR/whitelist.txt" ] || {
            echo "z2k-openwrt: lists/whitelist.txt существует и не симлинк" >&2
            return 1
        }
        [ -e "$Z2K_USER_LISTS/whitelist.txt" ] || : > "$Z2K_USER_LISTS/whitelist.txt" || return 1
        ln -s "$Z2K_USER_LISTS/whitelist.txt" "$Z2K_LISTS_DIR/whitelist.txt" || return 1
    fi
    for _f in "$Z2K_USER_LISTS/whitelist.txt" \
             "$Z2K_STATE/tcp16_asn.txt" "$Z2K_STATE/tcp16_sni.txt"; do
        [ -e "$_f" ] || : > "$_f" || return 1
    done
    if [ ! -e "$Z2K_USER_LISTS/extra-domains.txt" ]; then
        if [ -s "$Z2K_LISTS_DIR/extra-domains.txt" ]; then
            cp -f "$Z2K_LISTS_DIR/extra-domains.txt" "$Z2K_USER_LISTS/extra-domains.txt" || return 1
        else
            : > "$Z2K_USER_LISTS/extra-domains.txt" || return 1
        fi
    fi
    for _p in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
        [ -s "$Z2K_EXTRA_STRATS_DIR/$_p/Strategy.txt" ] || {
            echo "z2k-openwrt: нет $Z2K_EXTRA_STRATS_DIR/$_p/Strategy.txt" >&2
            return 1
        }
    done
    for _f in zapret-lib.lua zapret-antidpi.lua zapret-auto.lua; do
        if [ ! -f "$Z2K_ZAPRET2_RUNTIME/lua/$_f" ] && \
           [ ! -f "$Z2K_ZAPRET2_RUNTIME/lua/$_f.gz" ]; then
            echo "z2k-openwrt: предупреждение: нет runtime lua/$_f" >&2
        fi
    done
}
