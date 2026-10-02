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
Z2K_SLD_STATE_MIGRATION_MARKER="${Z2K_SLD_STATE_MIGRATION_MARKER:-${Z2K_STATE:-/etc/z2k/state}/domain-sld-v1.done}"

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
    local _fallback="${Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE:-${Z2K_TMP:-/tmp/z2k}}/z2k-autocircular-state.tsv"
    # p-84.23's OpenWrt override lives under /tmp/z2k, while older installs
    # wrote the same fallback directly under /tmp. Scan both so an upgrade
    # cannot leave the old yt_quic rows behind. Tests may redirect this legacy
    # path without touching the host /tmp.
    local _legacy="${Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE:-/tmp/z2k-autocircular-state.tsv}"
    local _f _rc _all_ok=1 _failed=0 _saw=0 _seen=""

    # The marker is advisory only. Always inspect both paths: a fallback file
    # can be created after an earlier boot, and a busy-lock attempt must be
    # retried even when a previous run left the marker behind.
    for _f in "$_primary" "$_fallback" "$_legacy"; do
        # Do not process the same file twice when an override points at the
        # primary or preferred fallback path.
        case " $_seen " in *" $_f "*) continue ;; esac
        _seen="$_seen $_f"
        # Missing/empty files are valid on a fresh install; only files that
        # exist and contain state participate in the completion decision.
        [ -s "$_f" ] || continue
        _saw=1
        _z2k_ow_migrate_quic_state_file "$_f"
        _rc=$?
        if [ "$_rc" -ne 0 ]; then
            [ "$_rc" -eq 75 ] && echo "z2k-openwrt: QUIC state busy: $_f" >&2
            _all_ok=0
            _failed=1
        fi
    done

    # Mark complete once every existing state file was inspected/migrated.
    # Missing/empty fallbacks remain valid and do not create a spurious marker.
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

# Upstream p-86.2 changes domain rotation from full hostnames to the native
# second-level scope (nld=2). OpenWrt stores the same rotator rows in a
# persistent primary file and one or more fallbacks, so merge them before
# rewriting every extant copy. This runs in procd start_service before the
# nfqws2 instance is registered; a held writer lock fails closed and retries
# on the next service start.
z2k_ow_migrate_sld_state() {
    local _primary="${STATE_FILE:-${Z2K_STATE:-/etc/z2k/state}/state.tsv}"
    local _fallback="${Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE:-${Z2K_TMP:-/tmp/z2k}}/z2k-autocircular-state.tsv"
    local _legacy="${Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE:-/tmp/z2k-autocircular-state.tsv}"
    local _files="" _locked="" _f _seen="" _rc=0 _merged _tmp _needs=0

    for _f in "$_primary" "$_fallback" "$_legacy"; do
        case " $_seen " in *" $_f "*) continue ;; esac
        _seen="$_seen $_f"
        [ -s "$_f" ] || continue
        _files="$_files $_f"
    done
    [ -n "$_files" ] || return 0

    # Keep every source stable while selecting winners and preparing backups.
    # The path list is limited to fixed OpenWrt state paths (no user input).
    for _f in $_files; do
        if ! _z2k_ow_state_lock_acquire "$_f"; then
            echo "z2k-openwrt: domain state busy: $_f" >&2
            _rc=1
            break
        fi
        _locked="$_locked $_f"
    done

    _merged="${Z2K_TMP:-/tmp/z2k}/state.sld.$$"
    if [ "$_rc" = 0 ]; then
        for _f in $_files; do
            if [ ! -f "$_f.pre-86.2" ] && ! cp -p "$_f" "$_f.pre-86.2" 2>/dev/null; then
                _rc=1
                break
            fi
        done
    fi
    if [ "$_rc" = 0 ]; then
        mkdir -p "$(dirname "$_merged")" 2>/dev/null || _rc=1
    fi
    if [ "$_rc" = 0 ]; then
        # Frozen rows win over automatic rows; then choose the newest row. If
        # timestamps tie, prefer a row already stored at the canonical root,
        # then use a stable lexical tie-break. Keep family suffixes, IPs,
        # nohost, strategy and optional trailing columns intact.
        # shellcheck disable=SC2086
        awk -F '\t' 'BEGIN { OFS="\t" }
            !/^#/ && NF >= 3 {
                original=tolower($2); host=original; family=""
                if (host ~ /\|[46]$/) { family=substr(host,length(host)-1); host=substr(host,1,length(host)-2) }
                sub(/\.$/,"",host)
                if (host != "nohost" && host !~ /:/ && host !~ /^[0-9.]+$/) {
                    n=split(host,labels,".")
                    if (n > 2) host=labels[n-1] "." labels[n]
                }
                canonical=host family; id=$1 FS canonical
                frozen=($5 == "frozen"); stamp=$4+0; exact=(original == canonical)
                if (!(id in row) || frozen > pin[id] ||
                    (frozen == pin[id] && (stamp > ts[id] ||
                    (stamp == ts[id] && (exact > root[id] ||
                    (exact == root[id] && original < source[id])))))) {
                    $2=canonical
                    if ($5 == "") $5="auto"
                    row[id]=$0; pin[id]=frozen; ts[id]=stamp
                    root[id]=exact; source[id]=original
                }
            }
            END { for (id in row) print row[id] }
        ' $_files > "${_merged}.rows" 2>/dev/null || _rc=1
        if [ "$_rc" = 0 ]; then
            { printf '# z2k autocircular state: second-level domain keys (86.2)\n'
              LC_ALL=C sort "${_merged}.rows"
            } > "$_merged" 2>/dev/null || _rc=1
        fi
    fi

    if [ "$_rc" = 0 ]; then
        for _f in $_files; do
            cmp -s "$_merged" "$_f" || _needs=1
        done
    fi

    # Stage every output before replacing any source. If a rename fails midway,
    # the next run re-merges the staged canonical copy with remaining old rows.
    if [ "$_rc" = 0 ] && [ "$_needs" = 1 ]; then
        for _f in $_files; do
            _tmp="${_f}.sld.$$"
            if ! cp -p "$_f" "$_tmp" 2>/dev/null || ! cat "$_merged" > "$_tmp" 2>/dev/null; then
                _rc=1
                break
            fi
        done
    fi
    if [ "$_rc" = 0 ] && [ "$_needs" = 1 ]; then
        for _f in $_files; do
            _tmp="${_f}.sld.$$"
            if ! mv -f "$_tmp" "$_f" 2>/dev/null; then
                _rc=1
                break
            fi
        done
    fi
    if [ "$_rc" = 0 ]; then
        mkdir -p "$(dirname "$Z2K_SLD_STATE_MIGRATION_MARKER")" 2>/dev/null || _rc=1
        _tmp="${Z2K_SLD_STATE_MIGRATION_MARKER}.tmp.$$"
        if [ "$_rc" = 0 ]; then
            printf 'domain-sld migrated\n' > "$_tmp" 2>/dev/null || _rc=1
            if [ "$_rc" = 0 ] && ! cmp -s "$_tmp" "$Z2K_SLD_STATE_MIGRATION_MARKER"; then
                mv -f "$_tmp" "$Z2K_SLD_STATE_MIGRATION_MARKER" 2>/dev/null || _rc=1
            fi
        fi
    fi

    for _f in $_files; do rm -f "${_f}.sld.$$" 2>/dev/null || true; done
    rm -f "$_merged" "${_merged}.rows" "${Z2K_SLD_STATE_MIGRATION_MARKER}.tmp.$$" 2>/dev/null || true
    for _f in $_locked; do _z2k_ow_state_lock_release "$_f"; done
    return "$_rc"
}
