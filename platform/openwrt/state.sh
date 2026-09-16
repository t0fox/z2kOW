#!/bin/sh
# platform/openwrt/state.sh - OpenWrt-owned persistent state migrations.
#
# Upstream p-84.23 renamed the QUIC rotation pool from yt_quic to quic. The
# OpenWrt lifecycle does not run the Keenetic S99 init, so this migration runs
# here before nfqws2 is registered with procd.

# State writers use <state-file>.lock, a ten second stale threshold, and
# tmp-file + rename writes. Keep that protocol here so the daemon never sees a
# partially rewritten state file.
Z2K_QUIC_STATE_MIGRATION_MARKER="${Z2K_QUIC_STATE_MIGRATION_MARKER:-${Z2K_STATE:-/etc/z2k/state}/quic-pool-key-migrated}"

_z2k_ow_state_lock_acquire() {
    local _path="$1" _lock="${1}.lock" _now _stamp _age
    _now="$(date +%s 2>/dev/null || echo 0)"
    case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
    if [ -e "$_lock" ]; then
        _stamp="$(cat "$_lock" 2>/dev/null)"
        case "$_stamp" in
            ''|*[!0-9]*) rm -f "$_lock" 2>/dev/null || return 1 ;;
            *)
                # Match Lua's clock-recovery/stale-lock rules.
                if [ "$_now" -gt 0 ] && [ "$_stamp" -gt $((_now + 10)) ]; then
                    rm -f "$_lock" 2>/dev/null || return 1
                elif [ "$_now" -gt 0 ]; then
                    _age=$((_now - _stamp))
                    [ "$_age" -gt 10 ] || return 1
                    rm -f "$_lock" 2>/dev/null || return 1
                else
                    return 1
                fi
                ;;
        esac
    fi
    # Exclusive create is the shell-side form of the upstream lock protocol.
    ( set -C; printf '%s' "$_now" > "$_lock" ) 2>/dev/null || return 1
    return 0
}

_z2k_ow_state_lock_release() {
    rm -f "${1}.lock" 2>/dev/null || true
}

_z2k_ow_migrate_quic_state_file() {
    local _path="$1" _tmp="${1}.mig.$$"
    [ -s "$_path" ] || return 0
    _z2k_ow_state_lock_acquire "$_path" || return 75

    # A canonical file is already complete and must not be rewritten.
    if ! awk -F '\t' '$1 == "yt_quic" { found=1; exit } END { exit !found }' \
            "$_path" 2>/dev/null; then
        _z2k_ow_state_lock_release "$_path"
        return 0
    fi

    # cp -p carries the original mode and numeric owner/group to the file that
    # will be atomically renamed into place. awk changes only the first TSV
    # field, preserving strategy number and all remaining columns.
    if ! cp -p "$_path" "$_tmp" 2>/dev/null || \
       ! awk -F '\t' 'BEGIN { OFS="\t" } $1 == "yt_quic" { $1="quic" } { print }' \
            "$_path" > "${_tmp}.content" 2>/dev/null || \
       ! cat "${_tmp}.content" > "$_tmp" 2>/dev/null || \
       ! mv -f "$_tmp" "$_path" 2>/dev/null; then
        rm -f "$_tmp" "${_tmp}.content" 2>/dev/null
        _z2k_ow_state_lock_release "$_path"
        return 1
    fi
    rm -f "${_tmp}.content" 2>/dev/null
    _z2k_ow_state_lock_release "$_path"
    return 0
}

# Missing/empty files deliberately do not receive a completion marker. A
# busy/failed migration returns non-zero so init will not start nfqws2 against
# an old key; the next start retries safely.
z2k_ow_migrate_quic_state() {
    local _primary="${STATE_FILE:-${Z2K_STATE:-/etc/z2k/state}/state.tsv}"
    local _fallback="${Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE:-/tmp/z2k}/z2k-autocircular-state.tsv"
    local _f _rc _all_ok=1 _failed=0 _saw=0

    # The marker is advisory only. Always inspect both paths: a fallback file
    # can be created after an earlier boot, and a busy-lock attempt must be
    # retried even when a previous run left the marker behind.
    for _f in "$_primary" "$_fallback"; do
        [ -s "$_f" ] || { _all_ok=0; continue; }
        _saw=1
        _z2k_ow_migrate_quic_state_file "$_f"
        _rc=$?
        if [ "$_rc" -ne 0 ]; then
            [ "$_rc" -eq 75 ] && echo "z2k-openwrt: QUIC state busy: $_f" >&2
            _all_ok=0
            _failed=1
        fi
    done

    # Be conservative: mark complete only when both configured files existed
    # and were successfully inspected/migrated. This keeps a missing/empty
    # fallback eligible for a later boot.
    if [ "$_saw" -eq 1 ] && [ "$_all_ok" -eq 1 ]; then
        mkdir -p "$(dirname "${Z2K_QUIC_STATE_MIGRATION_MARKER}")" 2>/dev/null || return 1
        local _mark_tmp="${Z2K_QUIC_STATE_MIGRATION_MARKER}.tmp.$$"
        if ! printf 'quic-pool-key migrated\n' > "$_mark_tmp" 2>/dev/null || \
           ! mv -f "$_mark_tmp" "${Z2K_QUIC_STATE_MIGRATION_MARKER}" 2>/dev/null; then
            rm -f "$_mark_tmp" 2>/dev/null
            return 1
        fi
    fi
    [ "$_failed" -eq 0 ]
}
