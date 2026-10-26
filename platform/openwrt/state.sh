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
Z2K_POOL_RENUMBER_MIGRATION_MARKER="${Z2K_POOL_RENUMBER_MIGRATION_MARKER:-${Z2K_STATE:-/etc/z2k/state}/pool-renumber-v1.done}"
Z2K_CUSTOM_BLOB_MIGRATION_MARKER="${Z2K_CUSTOM_BLOB_MIGRATION_MARKER:-${Z2K_STATE:-/etc/z2k/state}/custom-blobs-v1.done}"

# p-86.24 снимает два старых фейка. Переносим ссылки в пользовательских
# стратегиях до запуска nfqws2 и оставляем рядом снимок для отката.
z2k_ow_migrate_custom_blobs() {
    local _dir="${Z2K_EXTRA_STRATEGIES_RUNTIME:-${Z2K_USER_LISTS:-/etc/z2k/user-lists}/custom-strategies}"
    local _marker="$Z2K_CUSTOM_BLOB_MIGRATION_MARKER"
    local _file _tmp _failed=0 _moved=0
    [ -f "$_marker" ] && return 0
    for _file in "$_dir"/*.txt; do
        [ -f "$_file" ] && [ ! -L "$_file" ] || continue
        grep -Eq 'blob=(quic_dbankcloud|tls_clienthello_www_onetrust_com)([^A-Za-z0-9_]|$)' "$_file" 2>/dev/null || continue
        [ -f "$_file.pre-blob-migration-v1" ] || cp -p "$_file" "$_file.pre-blob-migration-v1" 2>/dev/null || { _failed=1; continue; }
        _tmp="$_file.mig"
        if sed \
            -e 's/blob=quic_dbankcloud:/blob=quic_initial_steamcommunity_com:/g' \
            -e 's/blob=quic_dbankcloud\([[:space:]]\)/blob=quic_initial_steamcommunity_com\1/g' \
            -e 's/blob=quic_dbankcloud$/blob=quic_initial_steamcommunity_com/' \
            -e 's/blob=tls_clienthello_www_onetrust_com:/blob=tls_clienthello_www_sferum_ru:/g' \
            -e 's/blob=tls_clienthello_www_onetrust_com\([[:space:]]\)/blob=tls_clienthello_www_sferum_ru\1/g' \
            -e 's/blob=tls_clienthello_www_onetrust_com$/blob=tls_clienthello_www_sferum_ru/' \
            "$_file" > "$_tmp" 2>/dev/null && [ -s "$_tmp" ] && mv -f "$_tmp" "$_file" 2>/dev/null; then
            _moved=$((_moved + 1))
        else
            rm -f "$_tmp" 2>/dev/null
            _failed=1
        fi
    done
    if [ "$_failed" = 0 ]; then
        mkdir -p "$(dirname "$_marker")" 2>/dev/null || return 1
        : > "$_marker" 2>/dev/null || return 1
    fi
    [ "$_moved" = 0 ] || echo "z2k-openwrt: обновлены фейки в пользовательских стратегиях ($_moved файл(ов))"
    return 0
}

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

# Подготовить только файлы autocircular для пользователя nfqws2.
# /etc/z2k/state и соседние данные остаются с прежними владельцами и правами.
_z2k_ow_prepare_autocircular_file() {
    local _path="$1" _user="$2" _work_dir="$3" _header="${4:-}"
    local _metadata _owner _mode _uid _tmp
    [ ! -L "$_path" ] || return 1
    _uid=$(id -u "$_user" 2>/dev/null) || return 1
    if [ ! -e "$_path" ]; then
        [ -n "$_header" ] || return 0
        _tmp=$(mktemp "$_work_dir/.autocircular-init.XXXXXX") || return 1
        printf '%b' "$_header" > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    else
        [ -f "$_path" ] || return 1
        # В базовой прошивке OpenWrt утилита `stat` может отсутствовать.
        # BusyBox `ls -ln` есть в штатном наборе и даёт числового владельца
        # вместе с символьной маской прав; не завязываем запуск службы на
        # пакет coreutils.
        _metadata=$(LC_ALL=C ls -ldn "$_path" 2>/dev/null | LC_ALL=C awk '
            NR == 1 { print $3 ":" $1; found = 1 }
            END { if (!found) exit 1 }
        ') || {
            echo "z2k-openwrt: не удалось прочитать владельца и права файла состояния: $_path" >&2
            return 1
        }
        _owner=${_metadata%%:*}; _mode=${_metadata#*:}
        [ "$_owner" != "$_uid" ] || [ "$_mode" != -rw-r--r-- ] || return 0
        _tmp=$(mktemp "$_work_dir/.autocircular-fix.XXXXXX") || return 1
        cp -p "$_path" "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    fi
    chown "$_user" "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    chmod 644 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    # Атомарная замена имени не позволяет записи пройти по подставленной ссылке.
    mv -f "$_tmp" "$_path" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    return 0
}

z2k_ow_prepare_autocircular_storage() {
    local _primary="${STATE_FILE:-${Z2K_AUTOCIRCULAR_DIR:-${Z2K_ETC:-/etc/z2k}/autocircular}/state.tsv}"
    local _fallback="${STATE_FILE_FALLBACK:-}"
    [ -n "$_fallback" ] || _fallback="${Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE:-${Z2K_AUTOCIRCULAR_FALLBACK_DIR:-${Z2K_TMP:-/tmp/z2k}/autocircular}}/z2k-autocircular-state.tsv"
    local _primary_dir="${_primary%/*}" _fallback_dir="${_fallback%/*}" _user="${WS_USER:-nobody}"
    local _root_state="${Z2K_STATE:-${Z2K_ETC:-/etc/z2k}/state}"
    [ -n "$_primary_dir" ] && [ -n "$_fallback_dir" ] || return 1
    mkdir -p "$_primary_dir" "$_fallback_dir" "$_root_state" 2>/dev/null || return 1
    [ ! -L "$_primary_dir" ] && [ ! -L "$_fallback_dir" ] || return 1
    chown "$_user" "$_primary_dir" "$_fallback_dir" 2>/dev/null || return 1
    chmod 755 "$_primary_dir" "$_fallback_dir" 2>/dev/null || return 1
    _z2k_ow_prepare_autocircular_file "$_primary" "$_user" "$_root_state" \
        '# z2k autocircular state (persisted circular strategy)\n# key\thost\tstrategy\tts\tmode\tsni\n' || return 1
    _z2k_ow_prepare_autocircular_file "$_fallback" "$_user" "$_root_state" || return 1
    return 0
}

# Однократно перенести состояние со старых OpenWrt-путей в отдельный каталог.
# Сначала копии помещаются в закрытый root-каталог, затем новая запись
# атомарно публикуется и только после этого старое имя освобождается.
z2k_ow_migrate_autocircular_state() {
    local _primary="${STATE_FILE:-${Z2K_AUTOCIRCULAR_DIR:-${Z2K_ETC:-/etc/z2k}/autocircular}/state.tsv}"
    local _old_primary="${Z2K_AUTOCIRCULAR_LEGACY_PRIMARY_OVERRIDE:-${Z2K_STATE:-${Z2K_ETC:-/etc/z2k}/state}/state.tsv}"
    local _old_tmp="${Z2K_AUTOCIRCULAR_LEGACY_TMP_OVERRIDE:-${Z2K_TMP:-/tmp/z2k}/z2k-autocircular-state.tsv}"
    local _old_fallback="${Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE:-/tmp/z2k-autocircular-state.tsv}"
    local _old_runtime="${Z2K_AUTOCIRCULAR_LEGACY_RUNTIME_OVERRIDE:-${Z2K_ZAPRET2_RUNTIME:-/opt/zapret2}/extra_strats/cache/autocircular/state.tsv}"
    local _backup_dir="${Z2K_AUTOCIRCULAR_BACKUP_DIR:-${Z2K_STATE:-${Z2K_ETC:-/etc/z2k}/state}/autocircular-migration-backup}"
    local _legacy="" _seen=" $_primary " _locked="" _f _backup _backup_tmp _tmp="" _rc=0

    z2k_ow_prepare_autocircular_storage || return 1
    for _f in "$_old_primary" "$_old_tmp" "$_old_fallback" "$_old_runtime"; do
        case "$_seen" in *" $_f "*) continue ;; esac
        _seen="$_seen$_f "
        [ -s "$_f" ] || continue
        _legacy="${_legacy:+$_legacy }$_f"
    done
    [ -n "$_legacy" ] || return 0

    # Источники фиксированы адаптером; удерживаем их и новый файл до публикации.
    for _f in $_legacy "$_primary"; do
        if ! _z2k_ow_state_lock_acquire "$_f"; then
            echo "z2k-openwrt: autocircular state busy: $_f" >&2
            _rc=1
            break
        fi
        _locked="$_locked $_f"
    done

    # Временные и резервные файлы хранятся отдельно от доступных nobody путей.
    if [ "$_rc" = 0 ]; then
        mkdir -p "$_backup_dir" 2>/dev/null || _rc=1
        if [ "$_rc" = 0 ]; then
            [ ! -L "$_backup_dir" ] || _rc=1
            if [ "$_rc" = 0 ]; then
                chown 0:0 "$_backup_dir" 2>/dev/null || _rc=1
                chmod 700 "$_backup_dir" 2>/dev/null || _rc=1
            fi
        fi
        for _f in $_legacy; do
            [ "$_rc" = 0 ] || break
            case "$_f" in
                "$_old_primary") _backup="$_backup_dir/legacy-primary.tsv" ;;
                "$_old_tmp") _backup="$_backup_dir/legacy-z2k-tmp.tsv" ;;
                "$_old_fallback") _backup="$_backup_dir/legacy-tmp.tsv" ;;
                "$_old_runtime") _backup="$_backup_dir/legacy-runtime.tsv" ;;
                *) _rc=1; break ;;
            esac
            [ -e "$_backup" ] && continue
            _backup_tmp=$(mktemp "$_backup_dir/.backup.XXXXXX") || { _rc=1; break; }
            if ! cp -p "$_f" "$_backup_tmp" 2>/dev/null || \
               ! mv -f "$_backup_tmp" "$_backup" 2>/dev/null; then
                rm -f "$_backup_tmp" 2>/dev/null || true
                _rc=1
                break
            fi
        done
    fi

    if [ "$_rc" = 0 ]; then
        _tmp=$(mktemp "$_backup_dir/.state-migrate.XXXXXX") || _rc=1
    fi

    # Последней читается новая копия: при одинаковой метке времени она главнее.
    if [ "$_rc" = 0 ]; then
        # shellcheck disable=SC2086
        awk -F '\t' '
            BEGIN { OFS="\t" }
            /^#/ || NF < 3 || $1 == "" || $2 == "" || $3 !~ /^[0-9]+$/ || $3 < 1 { next }
            {
                id=$1 FS $2
                stamp=($4 ~ /^[0-9]+$/) ? $4+0 : 0
                if (!(id in row) || stamp >= ts[id]) { row[id]=$0; ts[id]=stamp }
            }
            END {
                print "# z2k autocircular state (persisted circular strategy)"
                print "# key\thost\tstrategy\tts\tmode\tsni"
                for (id in row) print row[id]
            }
        ' $_legacy "$_primary" > "$_tmp" 2>/dev/null || _rc=1
    fi
    if [ "$_rc" = 0 ]; then
        chown "${WS_USER:-nobody}" "$_tmp" 2>/dev/null || _rc=1
        chmod 644 "$_tmp" 2>/dev/null || _rc=1
    fi
    if [ "$_rc" = 0 ]; then
        mv -f "$_tmp" "$_primary" 2>/dev/null || _rc=1
    fi
    if [ "$_rc" = 0 ]; then
        for _f in $_legacy; do
            rm -f "$_f" 2>/dev/null || { _rc=1; break; }
        done
    fi

    rm -f "$_tmp" 2>/dev/null || true
    for _f in $_locked; do _z2k_ow_state_lock_release "$_f"; done
    [ "$_rc" -eq 0 ] || return 1
    z2k_ow_prepare_autocircular_storage
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

# p-86.24 reordered TCP/QUIC strategy pools. Automatic picks must be measured
# again; user-frozen picks keep the same technique through the published map.
# Run after yt_quic -> quic and before nfqws2 can read any state copy.
z2k_ow_migrate_pool_renumber() {
    [ -f "$Z2K_POOL_RENUMBER_MIGRATION_MARKER" ] && return 0
    local _primary="${STATE_FILE:-${Z2K_AUTOCIRCULAR_DIR:-${Z2K_ETC:-/etc/z2k}/autocircular}/state.tsv}"
    local _fallback="${Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE:-${Z2K_AUTOCIRCULAR_FALLBACK_DIR:-${Z2K_TMP:-/tmp/z2k}/autocircular}}/z2k-autocircular-state.tsv"
    local _legacy="${Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE:-/tmp/z2k-autocircular-state.tsv}"
    local _runtime="${Z2K_ZAPRET2_RUNTIME:-/opt/zapret2}/extra_strats/cache/autocircular/state.tsv"
    local _rkn='1=41,2=6,3=19,4=33,5=17,6=2,7=3,8=23,9=22,10=x,11=30,12=15,13=24,14=20,15=28,16=26,17=21,18=42,19=8,20=32,21=25,22=50,23=53,24=31,25=54,26=46,27=55,28=38,29=45,30=16,31=48,32=34,33=47,34=49,35=5,36=18,37=4,38=44,39=14,40=x,41=13,42=36,43=35,44=37,45=x,46=x,47=39,48=51,49=40,50=52'
    local _yt='1=1,2=17,3=20,4=13,5=28,6=25,7=30,8=3,9=19,10=10,11=2,12=15,13=21,14=14,15=7,16=29,17=9,18=24,19=16,20=5,21=23,22=4'
    local _gv='1=3,2=25,3=7,4=17,5=6,6=31,7=5,8=12,9=4,10=11,11=32,12=28,13=13,14=1,15=8,16=22,17=18,18=19,19=16,20=20,21=14,22=9'
    local _quic='1=4,2=10,3=5,4=18,5=3,6=2,7=14,8=8,9=7'
    local _discord='1=2,2=3,3=1,4=4,5=5,6=6'
    local _seen=" " _file _locked="" _failed=0 _changed=0 _tmp _content _rc

    for _file in "$_primary" "$_fallback" "$_legacy" "$_runtime"; do
        case "$_seen" in *" $_file "*) continue ;; esac
        _seen="$_seen$_file "
        [ -f "$_file" ] || continue
        if ! _z2k_ow_state_lock_acquire "$_file"; then
            echo "z2k-openwrt: state busy during pool migration: $_file" >&2
            _failed=1
            break
        fi
        _locked="$_locked $_file"
        if ! awk -F '\t' '$1 ~ /^(rkn_tcp|yt_tcp|gv_tcp|google_tls|quic|discord_udp)$/ { found=1; exit } END { exit !found }' "$_file" 2>/dev/null; then
            continue
        fi
        _tmp="${_file}.pool-renumber.$$"
        _content="${_tmp}.content"
        if ! cp -p "$_file" "$_tmp" 2>/dev/null || \
           ! awk -F '\t' -v RKN="$_rkn" -v YT="$_yt" -v GV="$_gv" -v QU="$_quic" -v DV="$_discord" '
                function load(s, m,   n, a, i, kv) { n=split(s,a,","); for (i=1;i<=n;i++) { split(a[i],kv,"="); m[kv[1]]=kv[2] } }
                function remap(m, n) { return (n in m) ? m[n] : "" }
                BEGIN { OFS="\t"; load(RKN,rkn); load(YT,yt); load(GV,gv); load(QU,qu); load(DV,dv) }
                /^#/ || NF < 3 { print; next }
                $1 == "rkn_tcp" { n=remap(rkn,$3+0) }
                $1 == "yt_tcp" { n=remap(yt,$3+0) }
                $1 == "gv_tcp" { n=remap(gv,$3+0) }
                $1 == "google_tls" { s=$3+0; if (s<=22) n=remap(yt,s); else { n=remap(gv,s-22); if (n!="" && n!="x") n+=33 } }
                $1 == "quic" { n=remap(qu,$3+0) }
                $1 ~ /^(rkn_tcp|yt_tcp|gv_tcp|google_tls|quic)$/ && $5 != "frozen" { n="x" }
                $1 == "discord_udp" { n=($5 == "frozen") ? remap(dv,$3+0) : "x" }
                $1 ~ /^(rkn_tcp|yt_tcp|gv_tcp|google_tls|quic|discord_udp)$/ { if (n == "x") next; if (n != "") $3=n }
                { print }
            ' "$_file" > "$_content" 2>/dev/null; then
            _failed=1
        fi
        if [ "$_failed" -eq 0 ] && cmp -s "$_file" "$_content" 2>/dev/null; then
            rm -f "$_tmp" "$_content"
        elif [ "$_failed" -eq 0 ]; then
            if [ ! -f "$_file.pre-pool-renumber-v1" ] && ! cp -p "$_file" "$_file.pre-pool-renumber-v1" 2>/dev/null; then
                _failed=1
            elif ! cat "$_content" > "$_tmp" 2>/dev/null || ! mv -f "$_tmp" "$_file" 2>/dev/null; then
                _failed=1
            else
                _changed=$((_changed + 1))
                rm -f "$_content"
            fi
        fi
        rm -f "$_tmp" "$_content"
        [ "$_failed" -eq 0 ] || break
    done
    for _file in $_locked; do _z2k_ow_state_lock_release "$_file"; done
    [ "$_failed" -eq 0 ] || return 1
    mkdir -p "$(dirname "$Z2K_POOL_RENUMBER_MIGRATION_MARKER")" 2>/dev/null || return 1
    _tmp="${Z2K_POOL_RENUMBER_MIGRATION_MARKER}.tmp.$$"
    if ! printf 'strategy pools migrated to p-86.24\n' > "$_tmp" 2>/dev/null || \
       ! mv -f "$_tmp" "$Z2K_POOL_RENUMBER_MIGRATION_MARKER" 2>/dev/null; then
        rm -f "$_tmp" 2>/dev/null
        return 1
    fi
    [ "$_changed" -eq 0 ] || echo "z2k-openwrt: перенесены закреплённые стратегии пулов p-86.24; автоматические выборы сброшены"
    return 0
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
    local _files="" _sources="" _locked="" _f _f_attrs _seen="" _rc=0 _merged _tmp _needs=0

    for _f in "$_primary" "$_fallback" "$_legacy"; do
        case " $_seen " in *" $_f "*) continue ;; esac
        _seen="$_seen $_f"
        [ -s "$_f" ] || continue
        _files="$_files $_f"
    done
    [ -n "$_files" ] || return 0
    _sources="${_files# }"
    case " $_files " in *" $_primary "*) : ;; *) _files="$_files $_primary" ;; esac
    mkdir -p "$(dirname "$_primary")" 2>/dev/null || return 1

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
            if [ -f "$_f" ] && [ ! -f "$_f.pre-86.2" ] && \
               ! cp -p "$_f" "$_f.pre-86.2" 2>/dev/null; then
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
        ' $_sources > "${_merged}.rows" 2>/dev/null || _rc=1
        if [ "$_rc" = 0 ]; then
            { printf '# z2k autocircular state: second-level domain keys (86.2)\n'
              LC_ALL=C sort "${_merged}.rows"
            } > "$_merged" 2>/dev/null || _rc=1
        fi
    fi

    if [ "$_rc" = 0 ]; then
        for _f in $_files; do
            if [ ! -f "$_f" ] || ! cmp -s "$_merged" "$_f"; then
                _needs=1
            fi
        done
    fi

    # Stage every output before replacing any source. If a rename fails midway,
    # the next run re-merges the staged canonical copy with remaining old rows.
    if [ "$_rc" = 0 ] && [ "$_needs" = 1 ]; then
        for _f in $_files; do
            _tmp="${_f}.sld.$$"
            if [ -f "$_f" ]; then
                _f_attrs="$_f"
            else
                _f_attrs="${_sources%% *}"
            fi
            if ! cp -p "$_f_attrs" "$_tmp" 2>/dev/null || \
               ! cat "$_merged" > "$_tmp" 2>/dev/null; then
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
