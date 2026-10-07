#!/bin/sh
# Browser-originated FLOWOFFLOAD comparison for OpenWrt. Existing zapret2
# helpers remain the only owner of the flowtable and persistent config.

z2k_ow_offload_benchmark_root() { printf '%s/flowoffload-benchmark' "${Z2K_STATE:-/etc/z2k/state}"; }
z2k_ow_offload_benchmark_runtime() { printf '%s/flowoffload-benchmark' "${Z2K_TMP:-/tmp/z2k}"; }
z2k_ow_offload_benchmark_session_dir() { printf '%s/session' "$(z2k_ow_offload_benchmark_runtime)"; }
z2k_ow_offload_benchmark_state_file() { printf '%s/state' "$(z2k_ow_offload_benchmark_session_dir)"; }
z2k_ow_offload_benchmark_restore_file() { printf '%s/restore' "$(z2k_ow_offload_benchmark_root)"; }
z2k_ow_offload_benchmark_lock_dir() { printf '%s/lock' "$(z2k_ow_offload_benchmark_runtime)"; }
z2k_ow_offload_benchmark_stop_file() { printf '%s/stop' "$(z2k_ow_offload_benchmark_session_dir)"; }

z2k_ow_offload_benchmark_field() {
    [ -r "$(z2k_ow_offload_benchmark_state_file)" ] || return 1
    sed -n "s/^$1=//p" "$(z2k_ow_offload_benchmark_state_file)" | tail -1
}
z2k_ow_offload_benchmark_set_field() {
    local _file="$(z2k_ow_offload_benchmark_state_file)" _tmp
    _tmp="$_file.new.$$"
    [ -f "$_file" ] || : > "$_file"
    if grep -q "^$1=" "$_file"; then sed "s/^$1=.*/$1=$2/" "$_file" > "$_tmp" || return 1
    else cat "$_file" > "$_tmp" || return 1; printf '%s=%s\n' "$1" "$2" >> "$_tmp" || return 1; fi
    mv -f "$_tmp" "$_file"
}
z2k_ow_offload_benchmark_mode_from_config() { z2k_ow_flowoffload_mode 2>/dev/null; }
z2k_ow_offload_benchmark_verify_mode() {
    local _mode="$1" _facts _ft _flags
    [ "$(z2k_ow_offload_benchmark_mode_from_config)" = "$_mode" ] || return 1
    _facts=$(z2k_ow_flowoffload_status 2>/dev/null)
    _ft=$(printf '%s' "$_facts" | sed -n 's/.*flowtable=\([^;]*\).*/\1/p')
    _flags=$(printf '%s' "$_facts" | sed -n 's/.*flags=\([^;]*\).*/\1/p')
    case "$_mode" in
        none) [ "$_ft" = absent ] ;;
        software) [ "$_ft" = present ] && [ "$_flags" = software ] ;;
        hardware) [ "$_ft" = present ] && [ "$_flags" = offload ] ;;
        *) return 1 ;;
    esac
}

# z2k_ow_flowoffload_status scans router-wide conntrack state. A marker may
# belong to an unrelated client, so it is not evidence for the browser sample.
# Until the sampled socket can be correlated exactly, fail closed for actual
# per-flow observation; mode application is still verified from nft/config.
z2k_ow_offload_benchmark_sample_actual() {
    case "$1" in
        none) printf 'not-observed' ;;
        software|hardware|*) printf 'unknown' ;;
    esac
}

z2k_ow_offload_benchmark_number_or_null() {
    case "$1" in ''|*[!0-9.+-]*) printf null; return ;; esac
    awk -v n="$1" 'BEGIN { if (n ~ /^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)$/) printf "%s", n; else printf "null" }'
}
z2k_ow_offload_benchmark_median() {
    [ "$#" -gt 0 ] || { printf null; return; }
    printf '%s\n' "$@" | LC_ALL=C sort -n | awk '{ a[NR]=$1 } END { if (!NR) print "null"; else if (NR%2) printf "%g",a[(NR+1)/2]; else printf "%g",(a[NR/2]+a[NR/2+1])/2 }'
}
z2k_ow_offload_benchmark_delta_pct() {
    local _a _b
    _a=$(z2k_ow_offload_benchmark_number_or_null "$1"); _b=$(z2k_ow_offload_benchmark_number_or_null "$2")
    [ "$_a" != null ] && [ "$_b" != null ] || { printf null; return; }
    awk -v a="$_a" -v b="$_b" 'BEGIN { if (a==0) print "null"; else printf "%.0f",(b-a)*100/a }'
}
z2k_ow_offload_benchmark_new_token() {
    local _v _uuid_file="${Z2K_BENCH_UUID_FILE:-/proc/sys/kernel/random/uuid}" IFS
    _v=
    IFS= read -r _v < "$_uuid_file" || _v=
    _v=$(printf '%s' "$_v" | sed 's/-//g')
    case "$_v" in ''|*[!0-9a-f]*) echo "kernel UUID source unavailable" >&2; return 1 ;; esac
    [ "${#_v}" -eq 32 ] || { echo "kernel UUID source returned an invalid token" >&2; return 1; }
    printf '%s' "$_v"
}

z2k_ow_offload_benchmark_yandex_host() {
    local _url="$1" _host
    case "$_url" in https://*.cdn.yandex.net/*) ;; *) return 1 ;; esac
    printf '%s\n' "$_url" | grep -Eq '^[A-Za-z0-9:/?&=._-]+$' || return 1
    _host=${_url#https://}; _host=${_host%%/*}
    case "$_host" in *..*|.*|*.) return 1 ;; esac
    printf '%s\n' "$_host" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+cdn\.yandex\.net$' || return 1
    printf '%s' "$_host"
}
z2k_ow_offload_benchmark_yandex_url_valid() {
    local _kind="$1" _url="$2" _mid="$3"
    z2k_ow_offload_benchmark_yandex_host "$_url" >/dev/null || return 1
    case "$_kind" in
        latency)
            printf '%s\n' "$_url" | grep -Eq "^https://([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\\.)+cdn\\.yandex\\.net/[A-Za-z0-9_-]+/ping\\?mid=${_mid}&lid=[0-9]+$" ;;
        download)
            printf '%s\n' "$_url" | grep -Eq "^https://([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\\.)+cdn\\.yandex\\.net/[A-Za-z0-9_-]+/probes/(50mb|100kb)\\?lid=[0-9]+&mid=${_mid}(&timeout=[0-9]+)?$" ;;
        upload)
            printf '%s\n' "$_url" | grep -Eq "^https://([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\\.)+cdn\\.yandex\\.net/[A-Za-z0-9_-]+/upload\\?mid=${_mid}&size=[1-9][0-9]*(&timeout=[0-9]+)?$" ;;
        *) return 1 ;;
    esac
}
z2k_ow_offload_benchmark_yandex_url_lid() {
    case "$1" in
        latency) printf '%s\n' "$2" | sed -n 's/.*&lid=\([0-9][0-9]*\)$/\1/p' ;;
        download) printf '%s\n' "$2" | sed -n 's/.*?lid=\([0-9][0-9]*\)&mid=.*/\1/p' ;;
        *) return 1 ;;
    esac
}
z2k_ow_offload_benchmark_validate_yandex_probes() {
    local _source="$1" _target="$2" _bytes _mid _i _j _k _url _host _timeout _size _type _lid _lids _lid_count=0
    local _lat_count=0 _download_count=0 _upload_count=0 _full_downloads=0 _full_uploads=0
    local _chosen_latency= _chosen_download= _chosen_upload= _chosen_server=
    [ -r "$_source" ] && command -v jsonfilter >/dev/null 2>&1 || return 1
    _bytes=$(wc -c < "$_source" 2>/dev/null | tr -d ' ')
    case "$_bytes" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_bytes" -gt 1 ] && [ "$_bytes" -le 65536 ] || return 1
    [ "$(jsonfilter -q -i "$_source" -t '@.mid' 2>/dev/null)" = string ] || return 1
    [ "$(jsonfilter -q -i "$_source" -t '@.lid' 2>/dev/null)" = array ] || return 1
    for _type in latency download upload; do
        [ "$(jsonfilter -q -i "$_source" -t "@.$_type" 2>/dev/null)" = object ] || return 1
        [ "$(jsonfilter -q -i "$_source" -t "@.$_type.probes" 2>/dev/null)" = array ] || return 1
    done
    _mid=$(jsonfilter -q -i "$_source" -e '@.mid' 2>/dev/null)
    printf '%s\n' "$_mid" | grep -Eq '^[A-Za-z0-9_-]{16,128}$' || return 1
    _lids=
    for _i in 0 1 2 3 4 5 6; do
        _type=$(jsonfilter -q -i "$_source" -t "@.lid[$_i]" 2>/dev/null)
        [ -n "$_type" ] || break
        [ "$_i" -lt 6 ] && [ "$_type" = string ] || return 1
        _lid=$(jsonfilter -q -i "$_source" -e "@.lid[$_i]" 2>/dev/null)
        case "$_lid" in ''|*[!0-9]*|0*) return 1 ;; esac
        case " $_lids " in *" $_lid "*) return 1 ;; esac
        _lids="${_lids}${_lids:+ }$_lid"
        _lid_count=$((_lid_count+1)); [ "$_lid_count" -le 6 ] || return 1
    done
    [ "$_lid_count" -ge 1 ] || return 1

    for _i in 0 1 2 3; do
        _type=$(jsonfilter -q -i "$_source" -t "@.latency.probes[$_i]" 2>/dev/null)
        [ -n "$_type" ] || break
        [ "$_type" = object ] || return 1
        [ "$(jsonfilter -q -i "$_source" -t "@.latency.probes[$_i].url" 2>/dev/null)" = string ] || return 1
        _url=$(jsonfilter -q -i "$_source" -e "@.latency.probes[$_i].url" 2>/dev/null)
        [ -n "$_url" ] || break
        [ "$_i" -lt 3 ] && z2k_ow_offload_benchmark_yandex_url_valid latency "$_url" "$_mid" || return 1
        _lid=$(z2k_ow_offload_benchmark_yandex_url_lid latency "$_url")
        case " $_lids " in *" $_lid "*) ;; *) return 1 ;; esac
        _lat_count=$((_lat_count+1))
    done
    [ "$_lat_count" -ge 1 ] && [ "$_lat_count" -le 3 ] || return 1

    for _i in 0 1 2 3 4 5 6; do
        _type=$(jsonfilter -q -i "$_source" -t "@.download.probes[$_i]" 2>/dev/null)
        [ -n "$_type" ] || break
        [ "$_type" = object ] || return 1
        [ "$(jsonfilter -q -i "$_source" -t "@.download.probes[$_i].url" 2>/dev/null)" = string ] || return 1
        _url=$(jsonfilter -q -i "$_source" -e "@.download.probes[$_i].url" 2>/dev/null)
        [ -n "$_url" ] || break
        [ "$_i" -lt 6 ] && z2k_ow_offload_benchmark_yandex_url_valid download "$_url" "$_mid" || return 1
        _lid=$(z2k_ow_offload_benchmark_yandex_url_lid download "$_url")
        case " $_lids " in *" $_lid "*) ;; *) return 1 ;; esac
        _download_count=$((_download_count+1))
        _type=$(jsonfilter -q -i "$_source" -t "@.download.probes[$_i].timeout" 2>/dev/null)
        [ -z "$_type" ] || [ "$_type" = int ] || return 1
        _timeout=$(jsonfilter -q -i "$_source" -e "@.download.probes[$_i].timeout" 2>/dev/null)
        if [ -n "$_timeout" ]; then case "$_timeout" in *[!0-9]*|0) return 1 ;; esac; fi
        case "$_url" in */probes/50mb\?*) [ -z "$_timeout" ] && _full_downloads=$((_full_downloads+1)) ;; esac
    done
    [ "$_download_count" -ge 1 ] && [ "$_download_count" -le 6 ] && [ "$_full_downloads" -ge 1 ] || return 1

    for _i in 0 1 2 3 4 5 6; do
        _type=$(jsonfilter -q -i "$_source" -t "@.upload.probes[$_i]" 2>/dev/null)
        [ -n "$_type" ] || break
        [ "$_type" = object ] || return 1
        [ "$(jsonfilter -q -i "$_source" -t "@.upload.probes[$_i].url" 2>/dev/null)" = string ] || return 1
        [ "$(jsonfilter -q -i "$_source" -t "@.upload.probes[$_i].size" 2>/dev/null)" = int ] || return 1
        _url=$(jsonfilter -q -i "$_source" -e "@.upload.probes[$_i].url" 2>/dev/null)
        [ -n "$_url" ] || break
        [ "$_i" -lt 6 ] && z2k_ow_offload_benchmark_yandex_url_valid upload "$_url" "$_mid" || return 1
        _size=$(jsonfilter -q -i "$_source" -e "@.upload.probes[$_i].size" 2>/dev/null)
        case "$_size" in ''|*[!0-9]*) return 1 ;; esac
        [ "$_size" -gt 0 ] && [ "$_size" -le 52428800 ] || return 1
        case "$_url" in *"&size=$_size"*) ;; *) return 1 ;; esac
        _upload_count=$((_upload_count+1))
        _type=$(jsonfilter -q -i "$_source" -t "@.upload.probes[$_i].timeout" 2>/dev/null)
        [ -z "$_type" ] || [ "$_type" = int ] || return 1
        _timeout=$(jsonfilter -q -i "$_source" -e "@.upload.probes[$_i].timeout" 2>/dev/null)
        if [ -n "$_timeout" ]; then case "$_timeout" in *[!0-9]*|0) return 1 ;; esac; fi
        case "$_url" in */upload\?*) [ -z "$_timeout" ] && _full_uploads=$((_full_uploads+1)) ;; esac
    done
    [ "$_upload_count" -ge 1 ] && [ "$_upload_count" -le 6 ] && [ "$_full_uploads" -ge 1 ] || return 1

    for _i in 0 1 2; do
        _url=$(jsonfilter -q -i "$_source" -e "@.latency.probes[$_i].url" 2>/dev/null); [ -n "$_url" ] || continue
        _host=$(z2k_ow_offload_benchmark_yandex_host "$_url") || return 1
        for _j in 0 1 2 3 4 5; do
            _chosen_download=$(jsonfilter -q -i "$_source" -e "@.download.probes[$_j].url" 2>/dev/null); [ -n "$_chosen_download" ] || continue
            case "$_chosen_download" in */probes/50mb\?*) ;; *) continue ;; esac
            _timeout=$(jsonfilter -q -i "$_source" -e "@.download.probes[$_j].timeout" 2>/dev/null); [ -z "$_timeout" ] || continue
            [ "$(z2k_ow_offload_benchmark_yandex_host "$_chosen_download")" = "$_host" ] || continue
            for _k in 0 1 2 3 4 5; do
                _chosen_upload=$(jsonfilter -q -i "$_source" -e "@.upload.probes[$_k].url" 2>/dev/null); [ -n "$_chosen_upload" ] || continue
                _timeout=$(jsonfilter -q -i "$_source" -e "@.upload.probes[$_k].timeout" 2>/dev/null); [ -z "$_timeout" ] || continue
                [ "$(z2k_ow_offload_benchmark_yandex_host "$_chosen_upload")" = "$_host" ] || continue
                _chosen_latency=$_url; _chosen_server=$_host; break
            done
            [ -n "$_chosen_latency" ] && break
        done
        [ -n "$_chosen_latency" ] && break
    done
    [ -n "$_chosen_latency" ] && [ -n "$_chosen_download" ] && [ -n "$_chosen_upload" ] && [ -n "$_chosen_server" ] || return 1
    printf '{"provider":"yandex-internetometer","server":"%s","mid":"%s","latency_url":"%s","download_url":"%s","upload_url":"%s"}\n' \
        "$_chosen_server" "$_mid" "$_chosen_latency" "$_chosen_download" "$_chosen_upload" > "$_target.new.$$" \
        && mv -f "$_target.new.$$" "$_target"
}
z2k_ow_offload_benchmark_prepare_yandex_probes() {
    local _dir="$(z2k_ow_offload_benchmark_session_dir)" _raw="$(z2k_ow_offload_benchmark_session_dir)/probes.raw.json" _url
    command -v curl >/dev/null 2>&1 || { echo 'на роутере нет curl для запроса probe-конфигурации Яндекса' >&2; return 1; }
    _url="https://yandex.ru/internet/api/v0/get-probes?nocache=$(date +%s)$$&from=internet"
    if ! curl -fsS --connect-timeout 5 --max-time 20 --max-filesize 65536 \
        -H 'User-Agent: Mozilla/5.0 z2kOW' -H 'Referer: https://yandex.ru/internet/' -H 'Accept: application/json' \
        -o "$_raw" "$_url" >/dev/null 2>&1; then
        rm -f "$_raw"
        echo 'не удалось получить probe-конфигурацию Яндекс Интернетометра' >&2
        return 1
    fi
    z2k_ow_offload_benchmark_validate_yandex_probes "$_raw" "$_dir/probe-config.json" || {
        rm -f "$_raw" "$_dir/probe-config.json" "$_dir/probe-config.json.new.$$"
        echo 'ответ get-probes не прошёл строгую проверку формата или CDN endpoints' >&2
        return 1
    }
    rm -f "$_raw"
}
z2k_ow_offload_benchmark_probe_config_json() {
    local _file="$(z2k_ow_offload_benchmark_session_dir)/probe-config.json"
    if [ -s "$_file" ]; then cat "$_file"; else printf null; fi
}
z2k_ow_offload_benchmark_provider_server() {
    case "$(z2k_ow_offload_benchmark_field provider 2>/dev/null)" in
        yandex-internetometer) jsonfilter -q -i "$(z2k_ow_offload_benchmark_session_dir)/probe-config.json" -e '@.server' 2>/dev/null ;;
        cloudflare) printf speed.cloudflare.com ;;
        *) printf '' ;;
    esac
}

z2k_ow_offload_benchmark_pid_alive() {
    local _p="$1" _s
    [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null || return 1
    _s=$(awk '{print $3}' "/proc/$_p/stat" 2>/dev/null); [ "$_s" != Z ]
}
z2k_ow_offload_benchmark_recover() {
    local _f="$(z2k_ow_offload_benchmark_restore_file)" _mode _pid _boot _current _created _now _lock
    if [ ! -r "$_f" ]; then
        _lock=$(z2k_ow_offload_benchmark_lock_dir)
        [ -d "$_lock" ] || return 0
        _pid=$(z2k_ow_offload_benchmark_field pid 2>/dev/null)
        z2k_ow_offload_benchmark_pid_alive "$_pid" && return 0
        _created=$(z2k_ow_offload_benchmark_field created 2>/dev/null)
        _now=$(date +%s 2>/dev/null)
        case "$_created:$_now" in *[!0-9:]*) return 0 ;; esac
        [ $((_now - _created)) -gt 120 ] || return 0
        z2k_ow_offload_benchmark_set_field status failed
        z2k_ow_offload_benchmark_set_field message 'background worker did not start'
        z2k_ow_offload_benchmark_write_result failed 'background worker did not start'
        rm -rf "$_lock"
        return 0
    fi
    _mode=$(sed -n 's/^mode=//p' "$_f" | head -1)
    _pid=$(sed -n 's/^pid=//p' "$_f" | head -1)
    _boot=$(sed -n 's/^boot=//p' "$_f" | head -1)
    _current=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    case "$_mode" in none|software|hardware) ;; *) return 1 ;; esac
    [ -z "$_boot" ] || [ -z "$_current" ] || [ "$_boot" = "$_current" ] || _pid=
    z2k_ow_offload_benchmark_pid_alive "$_pid" && return 0
    toggle_flowoffload "$_mode" >/dev/null 2>&1 || return 1
    z2k_ow_offload_benchmark_verify_mode "$_mode" || return 1
    rm -f "$_f"; rm -rf "$(z2k_ow_offload_benchmark_lock_dir)"
    if [ -r "$(z2k_ow_offload_benchmark_state_file)" ]; then
        z2k_ow_offload_benchmark_set_field status failed
        z2k_ow_offload_benchmark_set_field message 'interrupted benchmark; original mode recovered'
        z2k_ow_offload_benchmark_write_result failed 'interrupted benchmark; original mode recovered'
    fi
}

z2k_ow_offload_benchmark_start() {
    local _provider="${1:-yandex-internetometer}" _mode _dir _session _token
    case "$_provider" in yandex-internetometer|cloudflare) ;; *) echo "unsupported provider" >&2; return 1 ;; esac
    z2k_ow_offload_benchmark_recover || { echo "исходный режим FLOWOFFLOAD не восстановлен" >&2; return 1; }
    z2k_ow_flowoffload_available || { echo "FLOWOFFLOAD benchmark недоступен" >&2; return 1; }
    is_running >/dev/null 2>&1 || { echo "сначала запустите сервис z2kOW" >&2; return 1; }
    _mode=$(z2k_ow_offload_benchmark_mode_from_config)
    case "$_mode" in none|software|hardware) ;; *) echo "текущий режим нельзя безопасно сохранить" >&2; return 1 ;; esac
    mkdir -p "$(z2k_ow_offload_benchmark_root)" "$(z2k_ow_offload_benchmark_runtime)" || return 1
    mkdir "$(z2k_ow_offload_benchmark_lock_dir)" 2>/dev/null || { echo "benchmark уже выполняется" >&2; return 1; }
    _dir=$(z2k_ow_offload_benchmark_session_dir)
    rm -rf "$_dir"; mkdir -p "$_dir/samples" || { rmdir "$(z2k_ow_offload_benchmark_lock_dir)"; return 1; }
    _session="$(date +%s)$$"; _token=$(z2k_ow_offload_benchmark_new_token) \
        || { rm -rf "$(z2k_ow_offload_benchmark_lock_dir)" "$_dir"; return 1; }
    if [ "$_provider" = yandex-internetometer ] && ! z2k_ow_offload_benchmark_prepare_yandex_probes; then
        rm -rf "$(z2k_ow_offload_benchmark_lock_dir)" "$_dir"
        return 1
    fi
    printf 'session=%s\ntoken=%s\nprovider=%s\nstatus=starting\nmode=\ntrial=0\nnonce=\ninitial_mode=%s\ncreated=%s\nmessage=\n' \
        "$_session" "$_token" "$_provider" "$_mode" "$(date +%s)" > "$(z2k_ow_offload_benchmark_state_file)" \
        || { rm -rf "$(z2k_ow_offload_benchmark_lock_dir)" "$_dir"; return 1; }
    printf '%s\n' "$_session" > "$(z2k_ow_offload_benchmark_lock_dir)/session"
    printf '%s\n' "$_session"
}
z2k_ow_offload_benchmark_stop() {
    case "$(z2k_ow_offload_benchmark_field status 2>/dev/null)" in
        starting|applying|awaiting_sample|restoring) : > "$(z2k_ow_offload_benchmark_stop_file)" ;;
        *) return 1 ;;
    esac
}
z2k_ow_offload_benchmark_submit() {
    local _session="$1" _token="$2" _nonce="$3" _server="${12}" _expected_server _provider _value _sample
    [ "$(z2k_ow_offload_benchmark_field session)" = "$_session" ] || return 1
    [ "$(z2k_ow_offload_benchmark_field token)" = "$_token" ] || return 1
    [ "$(z2k_ow_offload_benchmark_field nonce)" = "$_nonce" ] || return 1
    [ "$(z2k_ow_offload_benchmark_field status)" = awaiting_sample ] || return 1
    for _value in "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}"; do
        case "$_value" in ''|*[!0-9.]*) return 1 ;; esac
    done
    _provider=$(z2k_ow_offload_benchmark_field provider 2>/dev/null)
    _expected_server=$(z2k_ow_offload_benchmark_provider_server)
    [ -n "$_expected_server" ] && [ "$_server" = "$_expected_server" ] || return 1
    _sample="$(z2k_ow_offload_benchmark_session_dir)/sample.$_nonce"
    [ ! -e "$_sample" ] || return 1
    printf 'download_mbps=%s\nupload_mbps=%s\nidle_ms=%s\ndownload_loaded_ms=%s\nupload_loaded_ms=%s\njitter_ms=%s\nloss_pct=%s\nduration_s=%s\nserver=%s\n' \
        "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "$_server" > "$_sample.new.$$" && mv "$_sample.new.$$" "$_sample"
}

z2k_ow_offload_benchmark_wait_sample() {
    local _nonce="$3" _sample="$(z2k_ow_offload_benchmark_session_dir)/sample.$3" _n="${Z2K_BENCH_SAMPLE_TIMEOUT:-150}"
    while [ "$_n" -gt 0 ]; do
        [ ! -f "$(z2k_ow_offload_benchmark_stop_file)" ] || return 2
        [ ! -s "$_sample" ] || { cat "$_sample"; return 0; }
        sleep 1; _n=$((_n-1))
    done
    return 1
}
z2k_ow_offload_benchmark_cpu_percent() {
    awk '/^cpu / { idle=$5+$6; total=0; for(i=2;i<=NF;i++) total+=$i; print total, idle; exit }' /proc/stat 2>/dev/null
}
z2k_ow_offload_benchmark_cpu_monitor() {
    local _file="$1" _a _b _v _avg=0 _peak=0 _n=0
    _a=$(z2k_ow_offload_benchmark_cpu_percent)
    while :; do
        sleep 1; _b=$(z2k_ow_offload_benchmark_cpu_percent)
        [ -n "$_a" ] && [ -n "$_b" ] || continue
        _v=$(awk -v a="$_a" -v b="$_b" 'BEGIN {split(a,x);split(b,y);d=y[1]-x[1];if(d>0)printf "%.1f",100*(d-(y[2]-x[2]))/d;else print 0}')
        _a="$_b"; _avg=$(awk -v a="$_avg" -v b="$_v" -v n="$_n" 'BEGIN{printf "%.1f",(a*n+b)/(n+1)}'); _n=$((_n+1))
        _peak=$(awk -v a="$_peak" -v b="$_v" 'BEGIN{if(b>a)a=b;printf "%.1f",a}')
        printf 'avg=%s\npeak=%s\n' "$_avg" "$_peak" > "$_file"
    done
}

z2k_ow_offload_benchmark_metric() {
    local _mode="$1" _key="$2" _i _v _args
    set --
    for _i in 1 2 3 4 5; do
        _v=$(sed -n "s/^${_key}=//p" "$(z2k_ow_offload_benchmark_session_dir)/samples/${_mode}-$_i" 2>/dev/null)
        [ -n "$_v" ] && [ "$(z2k_ow_offload_benchmark_number_or_null "$_v")" != null ] && set -- "$@" "$_v"
    done
    z2k_ow_offload_benchmark_median "$@"
}
z2k_ow_offload_benchmark_result_value() {
    local _mode="$1" _metric="$2"
    case "$_metric" in
        download_mbps|upload_mbps|cpu_avg|cpu_peak|idle_ms|download_loaded_ms|upload_loaded_ms|jitter_ms|loss_pct|duration_s)
            z2k_ow_offload_benchmark_metric "$_mode" "$_metric" ;;
        *) printf null ;;
    esac
}
z2k_ow_offload_benchmark_spread_pct() {
    local _mode="$1" _metric="$2" _i _v _median _mad
    set --
    for _i in 1 2 3 4 5; do
        _v=$(sed -n "s/^${_metric}=//p" "$(z2k_ow_offload_benchmark_session_dir)/samples/${_mode}-$_i" 2>/dev/null)
        [ -n "$_v" ] && [ "$(z2k_ow_offload_benchmark_number_or_null "$_v")" != null ] && set -- "$@" "$_v"
    done
    [ "$#" -eq 5 ] || { printf null; return; }
    _median=$(z2k_ow_offload_benchmark_median "$@")
    _mad=$(for _v in "$@"; do awk -v value="$_v" -v median="$_median" 'BEGIN{d=value-median;if(d<0)d=-d;printf "%.8f\n",d}'; done \
        | LC_ALL=C sort -n \
        | awk '{a[NR]=$1}END{if(NR%2)printf "%.8f",a[(NR+1)/2];else printf "%.8f",(a[NR/2]+a[NR/2+1])/2}')
    awk -v mad="$_mad" -v median="$_median" 'BEGIN{if(median>0)printf "%.1f",100*mad/median;else print "null"}'
}
z2k_ow_offload_benchmark_run_range_pct() {
    local _mode="$1" _metric="$2" _i _v _median
    set --
    for _i in 1 2 3 4 5; do
        _v=$(sed -n "s/^${_metric}=//p" "$(z2k_ow_offload_benchmark_session_dir)/samples/${_mode}-$_i" 2>/dev/null)
        [ -n "$_v" ] && [ "$(z2k_ow_offload_benchmark_number_or_null "$_v")" != null ] && set -- "$@" "$_v"
    done
    [ "$#" -eq 5 ] || { printf null; return; }
    _median=$(z2k_ow_offload_benchmark_median "$@")
    printf '%s\n' "$@" | awk -v median="$_median" 'NR==1{lo=$1;hi=$1}{if($1<lo)lo=$1;if($1>hi)hi=$1}END{if(median>0)printf "%.1f",100*(hi-lo)/median;else print "null"}'
}
z2k_ow_offload_benchmark_outlier_count_pct() {
    local _mode="$1" _metric="$2" _threshold="${3:-10}" _i _v _median
    set --
    for _i in 1 2 3 4 5; do
        _v=$(sed -n "s/^${_metric}=//p" "$(z2k_ow_offload_benchmark_session_dir)/samples/${_mode}-$_i" 2>/dev/null)
        [ -n "$_v" ] && [ "$(z2k_ow_offload_benchmark_number_or_null "$_v")" != null ] && set -- "$@" "$_v"
    done
    [ "$#" -eq 5 ] || { printf null; return; }
    _median=$(z2k_ow_offload_benchmark_median "$@")
    printf '%s\n' "$@" | awk -v median="$_median" -v threshold="$_threshold" 'BEGIN{if(median<=0){print "null";exit}}{d=$1-median;if(d<0)d=-d;if(100*d/median>threshold)n++}END{if(median>0)print n+0}'
}
z2k_ow_offload_benchmark_run_count() {
    local _mode="$1" _i _n=0
    for _i in 1 2 3 4 5; do [ -s "$(z2k_ow_offload_benchmark_session_dir)/samples/${_mode}-$_i" ] && _n=$((_n+1)); done
    printf '%s' "$_n"
}
z2k_ow_offload_benchmark_conflict() {
    local _sqm_enabled _sqm_show _sqm_init _pbr_init
    case "$1" in
        sqm)
            _sqm_enabled=0
            if command -v uci >/dev/null 2>&1; then
                _sqm_show=$(uci -q show sqm 2>/dev/null)
                printf '%s\n' "$_sqm_show" | grep -qE '\.enabled=.?1.?$' && _sqm_enabled=1
                [ "$_sqm_enabled" = 1 ] || [ "$(uci -q get sqm.@queue[0].enabled 2>/dev/null)" = 1 ] && _sqm_enabled=1
            fi
            if [ "$_sqm_enabled" = 1 ]; then
                _sqm_init="${Z2K_SQM_INIT:-/etc/init.d/sqm}"
                if [ -x "$_sqm_init" ] && "$_sqm_init" running >/dev/null 2>&1; then printf confirmed; else printf possible-risk; fi
            else printf none; fi
            ;;
        pbr)
            _pbr_init="${Z2K_PBR_INIT:-/etc/init.d/pbr}"
            if [ -x "$_pbr_init" ] && "$_pbr_init" running >/dev/null 2>&1; then printf possible-risk
            elif command -v uci >/dev/null 2>&1 && [ "$(uci -q get pbr.config.enabled 2>/dev/null)" = 1 ]; then printf possible-risk
            else printf none; fi
            ;;
        warp) if [ "$(read_flag GAME_WARP_ENABLED "${CONFIG_FILE:-${Z2K_CONFIG:-/etc/z2k/config}}" 0 2>/dev/null)" = 1 ]; then printf possible-risk; else printf none; fi ;;
        *) printf unknown ;;
    esac
}
z2k_ow_offload_benchmark_json_text() {
    local _value
    _value=$(printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9 .,_()+:/@-')
    [ -n "$_value" ] && printf '"%s"' "$_value" || printf null
}
z2k_ow_offload_benchmark_system_json() {
    local _model="${Z2K_BENCH_ROUTER_MODEL:-}" _release="${Z2K_BENCH_OPENWRT_VERSION:-}" \
        _version="${Z2K_BENCH_Z2KOW_VERSION:-}" _wan="${Z2K_BENCH_WAN_INTERFACE:-}" _raw _release_file _installed
    if [ -z "$_model" ]; then
        if command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
            _model=$(ubus call system board 2>/dev/null | jsonfilter -e '@.model' 2>/dev/null)
        fi
        [ -n "$_model" ] || _model=$(cat "${Z2K_BENCH_MODEL_FILE:-/tmp/sysinfo/model}" 2>/dev/null)
    fi
    _release_file="${Z2K_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"
    if [ -z "$_release" ]; then
        _release=$(awk -F= '$1=="DISTRIB_DESCRIPTION" {gsub(/[\042\047]/,"",$2); print $2; exit}' "$_release_file" 2>/dev/null)
        [ -n "$_release" ] || _release=$(awk -F= '$1=="DISTRIB_RELEASE" {gsub(/[\042\047]/,"",$2); print $2; exit}' "$_release_file" 2>/dev/null)
    fi
    _installed="${Z2K_OW_INSTALLED_RELEASE_FILE:-${Z2K_STATE:-/etc/z2k/state}/installed-release}"
    if [ -z "$_version" ]; then _version=$(sed -n 's/^tag=//p' "$_installed" 2>/dev/null | head -1); fi
    if [ -z "$_wan" ] && command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
        _raw=$(ubus call network.interface.wan status 2>/dev/null)
        _wan=$(printf '%s' "$_raw" | jsonfilter -e '@.l3_device' 2>/dev/null)
        [ -n "$_wan" ] || _wan=$(printf '%s' "$_raw" | jsonfilter -e '@.device' 2>/dev/null)
    fi
    if [ -z "$_wan" ] && command -v uci >/dev/null 2>&1; then
        _wan=$(uci -q get network.wan.device 2>/dev/null)
        [ -n "$_wan" ] || _wan=$(uci -q get network.wan.ifname 2>/dev/null)
    fi
    printf '{"router_model":%s,"openwrt_version":%s,"z2kow_version":%s,"wan_interface":%s}' \
        "$(z2k_ow_offload_benchmark_json_text "$_model")" \
        "$(z2k_ow_offload_benchmark_json_text "$_release")" \
        "$(z2k_ow_offload_benchmark_json_text "$_version")" \
        "$(z2k_ow_offload_benchmark_json_text "$_wan")"
}
z2k_ow_offload_benchmark_write_result() {
    local _status="$1" _message="$2" _root _mode _metric _sep _i _file _k _actual _runs _dl _sw _hw _recommendation _reason _du _su _dc _sc _hu _hc _hd _hvs _hobs _sqm _pbr _warp _unstable _complete _accepted _sd _scd _hcd _spread _outliers _restored _provider _server
    _root=$(z2k_ow_offload_benchmark_root); mkdir -p "$_root"
    _provider=$(z2k_ow_offload_benchmark_field provider 2>/dev/null)
    _server=$(z2k_ow_offload_benchmark_provider_server)
    _dl=$(z2k_ow_offload_benchmark_result_value none download_mbps)
    _sw=$(z2k_ow_offload_benchmark_result_value software download_mbps)
    _hw=$(z2k_ow_offload_benchmark_result_value hardware download_mbps)
    _du=$(z2k_ow_offload_benchmark_result_value none upload_mbps)
    _su=$(z2k_ow_offload_benchmark_result_value software upload_mbps)
    _dc=$(z2k_ow_offload_benchmark_result_value none cpu_avg)
    _sc=$(z2k_ow_offload_benchmark_result_value software cpu_avg)
    _hu=$(z2k_ow_offload_benchmark_result_value hardware upload_mbps)
    _hc=$(z2k_ow_offload_benchmark_result_value hardware cpu_avg)
    _hd=$(z2k_ow_offload_benchmark_result_value hardware download_mbps)
    _sd=null; _scd=null; _hvs=null; _hcd=null
    _hobs=$(grep -h '^actual=hardware$' "$(z2k_ow_offload_benchmark_session_dir)"/samples/hardware-* 2>/dev/null | wc -l | tr -d ' ')
    _sqm=$(z2k_ow_offload_benchmark_conflict sqm); _pbr=$(z2k_ow_offload_benchmark_conflict pbr); _warp=$(z2k_ow_offload_benchmark_conflict warp)
    _recommendation=null; _reason=
    if [ "$_status" = completed ] && [ "$_dl" != null ] && [ "$_sw" != null ]; then
        _sd=$(z2k_ow_offload_benchmark_delta_pct "$_dl" "$_sw"); _scd=$(z2k_ow_offload_benchmark_delta_pct "$_dc" "$_sc")
        if { [ "$_sd" != null ] && [ "$_sd" -ge 5 ] 2>/dev/null; } || { [ "$_scd" != null ] && [ "$_scd" -le -5 ] 2>/dev/null; }; then
            _recommendation='"software"'; _reason="$( [ "$_sd" != null ] && [ "$_sd" -ge 5 ] 2>/dev/null && printf 'download +%s%% vs none' "$_sd" || printf 'CPU %s%% vs none' "${_scd:-unknown}" )"
        fi
        _hvs=$(z2k_ow_offload_benchmark_delta_pct "$_sw" "$_hw"); _hcd=$(z2k_ow_offload_benchmark_delta_pct "$_sc" "$_hc")
        if [ "$_hobs" -ge 2 ] 2>/dev/null && [ "$_sqm" = none ] && [ "$_pbr" = none ] && [ "$_warp" = none ] \
            && { { [ "$_hvs" != null ] && [ "$_hvs" -ge 5 ] 2>/dev/null; } || { [ "$_hcd" != null ] && [ "$_hcd" -le -10 ] 2>/dev/null; }; }; then
            _recommendation='"hardware"'; _reason="$( [ "$_hvs" != null ] && [ "$_hvs" -ge 5 ] 2>/dev/null && printf 'download +%s%% vs software' "$_hvs" || printf 'CPU %s%% vs software' "${_hcd:-unknown}" )"
        fi
    fi
    _unstable=false
    for _mode in none software hardware; do
        for _metric in download_mbps upload_mbps; do
            _spread=$(z2k_ow_offload_benchmark_spread_pct "$_mode" "$_metric")
            _outliers=$(z2k_ow_offload_benchmark_outlier_count_pct "$_mode" "$_metric" 10)
            if { [ "$_spread" != null ] && awk -v n="$_spread" 'BEGIN{exit !(n>15)}'; } \
                || { [ "$_outliers" != null ] && [ "$_outliers" -gt 1 ] 2>/dev/null; }; then _unstable=true; fi
        done
    done
    _complete=false
    [ "$_status" = completed ] && [ "$(z2k_ow_offload_benchmark_run_count none)" = 5 ] \
        && [ "$(z2k_ow_offload_benchmark_run_count software)" = 5 ] && _complete=true
    # A noisy series is useful as diagnostics but cannot support a winner.
    [ "$_unstable" = false ] || { _recommendation=null; _reason=; }
    _restored=true; [ -f "$(z2k_ow_offload_benchmark_restore_file)" ] && _restored=false
    _accepted=false
    [ "$_status" = completed ] && [ "$_complete" = true ] && [ "$_unstable" = false ] && [ "$_restored" = true ] && _accepted=true
    {
        printf '{"schema":1,"stability_rule":"two_of_five_over_10pct","status":"%s","timestamp":"%s","system":%s,"provider":%s,"server":%s,"original_mode":"%s","restored":%s,"message":"%s","modes":{' \
            "$_status" "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')" \
            "$(z2k_ow_offload_benchmark_system_json)" \
            "$(z2k_ow_offload_benchmark_json_text "$_provider")" \
            "$(z2k_ow_offload_benchmark_json_text "$_server")" \
            "$(z2k_ow_offload_benchmark_field initial_mode 2>/dev/null)" \
            "$_restored" \
            "$(printf '%s' "$_message" | tr '\\"' '  ' | tr '\n' ' ')"
        _sep=
        for _mode in none software hardware; do
            printf '%s"%s":{"runs":[' "$_sep" "$_mode"; _runs=; _i=1
            while [ "$_i" -le 5 ]; do
                _file="$(z2k_ow_offload_benchmark_session_dir)/samples/${_mode}-$_i"
                if [ -r "$_file" ]; then
                    [ -z "$_runs" ] || printf ','
                    printf '{'; _sep=
                    for _k in download_mbps upload_mbps cpu_avg cpu_peak idle_ms download_loaded_ms upload_loaded_ms jitter_ms loss_pct duration_s; do
                        [ -n "$_sep" ] && printf ','; printf '"%s":%s' "$_k" "$(z2k_ow_offload_benchmark_number_or_null "$(sed -n "s/^${_k}=//p" "$_file")")"; _sep=1
                    done
                    _actual=$(sed -n 's/^actual=//p' "$_file")
                    printf ',"actual":"%s","server":%s}' "${_actual:-unknown}" \
                        "$(z2k_ow_offload_benchmark_json_text "$(sed -n 's/^server=//p' "$_file")")"; _runs=1
                fi
                _i=$((_i+1))
            done
            printf '],"available":%s,"run_range_pct":{"download":%s,"upload":%s}' \
                "$([ -n "$_runs" ] && printf true || printf false)" \
                "$(z2k_ow_offload_benchmark_run_range_pct "$_mode" download_mbps)" \
                "$(z2k_ow_offload_benchmark_run_range_pct "$_mode" upload_mbps)"
            for _k in download_mbps upload_mbps cpu_avg cpu_peak idle_ms download_loaded_ms upload_loaded_ms jitter_ms loss_pct duration_s; do
                printf ',"%s":%s' "$_k" "$(z2k_ow_offload_benchmark_result_value "$_mode" "$_k")"
            done
            case "$_mode" in
                hardware) if grep -q '^actual=hardware$' "$(z2k_ow_offload_benchmark_session_dir)/samples/hardware-1" "$(z2k_ow_offload_benchmark_session_dir)/samples/hardware-2" "$(z2k_ow_offload_benchmark_session_dir)/samples/hardware-3" 2>/dev/null; then printf ',"offload_observed":true'; else printf ',"offload_observed":false'; fi ;;
                software) if grep -q '^actual=software$' "$(z2k_ow_offload_benchmark_session_dir)/samples/software-1" "$(z2k_ow_offload_benchmark_session_dir)/samples/software-2" "$(z2k_ow_offload_benchmark_session_dir)/samples/software-3" 2>/dev/null; then printf ',"offload_observed":true'; else printf ',"offload_observed":false'; fi ;;
                *) printf ',"offload_observed":false' ;;
            esac
            printf '}'; _sep=,
        done
        if [ "$_accepted" = true ]; then
            printf '},"comparisons":{"software_vs_none":{"download_pct":%s,"upload_pct":%s,"cpu_pct":%s},"hardware_vs_none":{"download_pct":%s,"upload_pct":%s,"cpu_pct":%s},"hardware_vs_software":{"download_pct":%s,"upload_pct":%s,"cpu_pct":%s}},' \
                "$(z2k_ow_offload_benchmark_delta_pct "$_dl" "$_sw")" "$(z2k_ow_offload_benchmark_delta_pct "$_du" "$_su")" "$(z2k_ow_offload_benchmark_delta_pct "$_dc" "$_sc")" \
                "$(z2k_ow_offload_benchmark_delta_pct "$_dl" "$_hw")" "$(z2k_ow_offload_benchmark_delta_pct "$_du" "$_hu")" "$(z2k_ow_offload_benchmark_delta_pct "$_dc" "$_hc")" \
                "$_hvs" "$(z2k_ow_offload_benchmark_delta_pct "$_su" "$_hu")" "$(z2k_ow_offload_benchmark_delta_pct "$_sc" "$_hc")"
        else
            printf '},"comparisons":{"software_vs_none":{"download_pct":null,"upload_pct":null,"cpu_pct":null},"hardware_vs_none":{"download_pct":null,"upload_pct":null,"cpu_pct":null},"hardware_vs_software":{"download_pct":null,"upload_pct":null,"cpu_pct":null}},'
        fi
        printf '"validity":{"complete":%s,"unstable":%s,"accepted":%s,"warnings":["Внешний тест зависит от выбранного CDN, маршрута и провайдера"' "$_complete" "$_unstable" "$_accepted"
        [ "$_unstable" = false ] || printf ',"Повторные измерения загрузки или отдачи нестабильны: минимум два прогона отклоняются от медианы более чем на 10%%"'
        case "$_sqm" in
            confirmed) printf ',"SQM работает; hardware offload может обходить его обработку"' ;;
            possible-risk) printf ',"SQM настроен; проверьте сохранение queueing при аппаратном offload"' ;;
        esac
        printf ']},"conflicts":{"sqm":"%s","pbr":"%s","warp":"%s"},"recommendation":' "$_sqm" "$_pbr" "$_warp"
        if [ "$_recommendation" = null ]; then printf 'null'; else printf '{"mode":%s,"reason":"%s"}' "$_recommendation" "$_reason"; fi
        printf '}\n'
    } > "$_root/last-result.json.tmp" && mv -f "$_root/last-result.json.tmp" "$_root/last-result.json"
    if [ "$_accepted" = true ]; then
        cp "$_root/last-result.json" "$_root/last-success.json.tmp" \
            && mv -f "$_root/last-success.json.tmp" "$_root/last-success.json"
    fi
}

z2k_ow_offload_benchmark_worker_cleanup() {
    local _status _message _restore="$(z2k_ow_offload_benchmark_restore_file)" _mode
    trap - EXIT HUP INT TERM
    _status=$(z2k_ow_offload_benchmark_field desired_status 2>/dev/null)
    _message=$(z2k_ow_offload_benchmark_field message 2>/dev/null)
    if [ -r "$_restore" ]; then
        _mode=$(sed -n 's/^mode=//p' "$_restore" | head -1)
        if toggle_flowoffload "$_mode" >/dev/null 2>&1 && z2k_ow_offload_benchmark_verify_mode "$_mode"; then
            rm -f "$_restore"
            job_progress "FLOWOFFLOAD: исходный режим $_mode восстановлен"
        else
            _status=failed; _message="не удалось подтвердить восстановление исходного режима"
        fi
    fi
    [ -n "$_status" ] || _status=failed
    z2k_ow_offload_benchmark_write_result "$_status" "${_message:-}"
    # Publish terminal state only after its matching result is atomically
    # written; otherwise a poll can pair the new status with stale JSON.
    z2k_ow_offload_benchmark_set_field message "$(printf '%s' "$_message" | tr '\n' ' ')"
    z2k_ow_offload_benchmark_set_field status "$_status"
    rm -f "$(z2k_ow_offload_benchmark_stop_file)"; rm -rf "$(z2k_ow_offload_benchmark_lock_dir)"
    [ "$_status" = completed ]
}
z2k_ow_offload_benchmark_worker_impl() {
    local _session="$1" _initial _boot _mode _trial _round _order _nonce _rc _sample _cpu _pid _file _actual _flags _ft
    [ "$(z2k_ow_offload_benchmark_field session 2>/dev/null)" = "$_session" ] || return 1
    [ "$(cat "$(z2k_ow_offload_benchmark_lock_dir)/session" 2>/dev/null)" = "$_session" ] || return 1
    _initial=$(z2k_ow_offload_benchmark_field initial_mode); _boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    # POSIX shells keep $$ unchanged inside subshells. Ask a short-lived child
    # for its PPID so stale recovery tracks this actual worker process.
    z2k_ow_offload_benchmark_set_field pid "$(sh -c 'printf %s "$PPID"')"
    printf 'mode=%s\npid=%s\nboot=%s\nsession=%s\n' "$_initial" "$(z2k_ow_offload_benchmark_field pid)" "$_boot" "$_session" > "$(z2k_ow_offload_benchmark_restore_file).tmp" \
        && mv -f "$(z2k_ow_offload_benchmark_restore_file).tmp" "$(z2k_ow_offload_benchmark_restore_file)" || return 1
    trap 'z2k_ow_offload_benchmark_worker_cleanup $?' EXIT
    trap 'z2k_ow_offload_benchmark_set_field desired_status stopped; z2k_ow_offload_benchmark_set_field message stopped; exit 130' HUP INT TERM
    z2k_ow_offload_benchmark_set_field status applying
    # Rotate a balanced order so each mode appears across the five rounds.
    # This reduces bias from time-varying WAN load; five samples also permit a
    # median absolute deviation that tolerates one isolated network outlier.
    for _round in 1 2 3 4 5; do
        case "$_round" in
            1) _order='none software hardware' ;;
            2) _order='software hardware none' ;;
            3) _order='hardware none software' ;;
            4) _order='none hardware software' ;;
            5) _order='hardware software none' ;;
        esac
        for _mode in $_order; do
            [ ! -f "$(z2k_ow_offload_benchmark_stop_file)" ] || { z2k_ow_offload_benchmark_set_field desired_status stopped; z2k_ow_offload_benchmark_set_field message stopped; return 1; }
            job_progress "FLOWOFFLOAD benchmark: применяю $_mode"
            if ! toggle_flowoffload "$_mode"; then
                [ "$_mode" = hardware ] && { job_progress "Hardware не применился, пропускаю"; continue; }
                z2k_ow_offload_benchmark_set_field desired_status failed; z2k_ow_offload_benchmark_set_field message "не удалось применить $_mode"; return 1
            fi
            [ "$(z2k_ow_offload_benchmark_mode_from_config)" = "$_mode" ] || {
                [ "$_mode" = hardware ] && continue
                z2k_ow_offload_benchmark_set_field desired_status failed; z2k_ow_offload_benchmark_set_field message "режим $_mode не подтвердился"; return 1
            }
            sleep "${Z2K_BENCH_SETTLE_SECONDS:-2}"
            _flags=$(z2k_ow_flowoffload_status | sed -n 's/.*flags=\([^;]*\).*/\1/p')
            _ft=$(z2k_ow_flowoffload_status | sed -n 's/.*flowtable=\([^;]*\).*/\1/p')
            if [ "$_mode" != none ] && { [ "$_ft" != present ] || { [ "$_mode" = hardware ] && [ "$_flags" != offload ]; }; }; then
                [ "$_mode" = hardware ] && { job_progress "Hardware flowtable недоступен, пропускаю"; continue; }
                z2k_ow_offload_benchmark_set_field desired_status failed; z2k_ow_offload_benchmark_set_field message "flowtable $_mode не применился"; return 1
            fi
            _trial=$(z2k_ow_offload_benchmark_run_count "$_mode"); _trial=$((_trial+1))
            _nonce=$(z2k_ow_offload_benchmark_new_token)
            z2k_ow_offload_benchmark_set_field status awaiting_sample; z2k_ow_offload_benchmark_set_field mode "$_mode"
            z2k_ow_offload_benchmark_set_field trial "$_trial"; z2k_ow_offload_benchmark_set_field nonce "$_nonce"
            _cpu="$(z2k_ow_offload_benchmark_session_dir)/cpu.$_nonce"
            z2k_ow_offload_benchmark_cpu_monitor "$_cpu" & _pid=$!
            job_progress "FLOWOFFLOAD benchmark: $_mode, прогон $_trial/5 — измерение в браузере"
            _sample=$(z2k_ow_offload_benchmark_wait_sample "$_mode" "$_trial" "$_nonce"); _rc=$?
            kill "$_pid" 2>/dev/null; wait "$_pid" 2>/dev/null
            if [ "$_rc" = 2 ]; then z2k_ow_offload_benchmark_set_field desired_status stopped; z2k_ow_offload_benchmark_set_field message stopped; return 1; fi
            if [ "$_rc" != 0 ]; then z2k_ow_offload_benchmark_set_field desired_status failed; z2k_ow_offload_benchmark_set_field message "тестовый endpoint не ответил"; return 1; fi
            _file="$(z2k_ow_offload_benchmark_session_dir)/samples/${_mode}-$_trial"
            printf '%s\n' "$_sample" > "$_file"
            _actual=$(z2k_ow_offload_benchmark_sample_actual "$_mode")
            printf 'actual=%s\n' "${_actual:-unknown}" >> "$_file"
            printf 'cpu_avg=%s\ncpu_peak=%s\n' "$(sed -n 's/^avg=//p' "$_cpu" 2>/dev/null)" "$(sed -n 's/^peak=//p' "$_cpu" 2>/dev/null)" >> "$_file"
        done
    done
    z2k_ow_offload_benchmark_set_field desired_status completed; z2k_ow_offload_benchmark_set_field message ''
    z2k_ow_offload_benchmark_set_field status restoring
    return 0
}
z2k_ow_offload_benchmark_worker() { ( z2k_ow_offload_benchmark_worker_impl "$1" ); }

z2k_ow_offload_benchmark_status_json() {
    z2k_ow_offload_benchmark_recover >/dev/null 2>&1 || true
    local _status _active _result _last_success _last_success_timestamp
    _status=$(z2k_ow_offload_benchmark_field status 2>/dev/null); _active=false
    case "$_status" in starting|applying|awaiting_sample|restoring) _active=true ;; esac
    _result="$(z2k_ow_offload_benchmark_root)/last-result.json"
    _last_success="$(z2k_ow_offload_benchmark_root)/last-success.json"
    if grep -q '"accepted":true' "$_last_success" 2>/dev/null \
        && grep -q '"stability_rule":"two_of_five_over_10pct"' "$_last_success" 2>/dev/null; then
        _last_success_timestamp=$(sed -n 's/.*"timestamp":"\([^"]*\)".*/\1/p' "$_last_success" 2>/dev/null | head -1)
    else
        _last_success_timestamp=
    fi
    printf '{"ok":true,"active":%s,"session":"%s","token":"%s","status":"%s","mode":"%s","trial":%s,"total_trials":5,"nonce":"%s","provider":"%s","probe_config":' \
        "$_active" "$(z2k_ow_offload_benchmark_field session 2>/dev/null)" "$(z2k_ow_offload_benchmark_field token 2>/dev/null)" \
        "${_status:-idle}" "$(z2k_ow_offload_benchmark_field mode 2>/dev/null)" \
        "$(z2k_ow_offload_benchmark_number_or_null "$(z2k_ow_offload_benchmark_field trial 2>/dev/null)")" \
        "$(z2k_ow_offload_benchmark_field nonce 2>/dev/null)" "$(z2k_ow_offload_benchmark_field provider 2>/dev/null)"
    z2k_ow_offload_benchmark_probe_config_json
    printf ',"result":'
    if [ -s "$_result" ] && grep -q '"stability_rule":"two_of_five_over_10pct"' "$_result" 2>/dev/null; then cat "$_result"; else printf null; fi
    printf ',"last_success_timestamp":"%s"}\n' "$_last_success_timestamp"
}
z2k_ow_offload_benchmark_result_json() {
    local _f="$(z2k_ow_offload_benchmark_root)/last-result.json"
    if [ -s "$_f" ] && grep -q '"stability_rule":"two_of_five_over_10pct"' "$_f" 2>/dev/null; then cat "$_f"; else printf '{"ok":true,"result":null}\n'; fi
}
z2k_ow_offload_benchmark_last_success_json() {
    local _f="$(z2k_ow_offload_benchmark_root)/last-success.json"
    if [ -s "$_f" ] && grep -q '"accepted":true' "$_f" 2>/dev/null \
        && grep -q '"stability_rule":"two_of_five_over_10pct"' "$_f" 2>/dev/null; then cat "$_f"; else printf 'null\n'; fi
}

# One compact API route keeps platform-specific workflow out of the common CGI
# dispatcher. actions.sh supplies read_body/form_value/json helpers and the
# existing svc_action_async runner before a route is invoked.
z2k_ow_offload_benchmark_api() {
    local _view _body _action _provider _session _job _token
    if [ "${REQUEST_METHOD:-GET}" = GET ]; then
        _view=$(form_value "${QUERY_STRING:-}" view)
        json_header
        case "$_view" in
            result) z2k_ow_offload_benchmark_result_json ;;
            last-success) z2k_ow_offload_benchmark_last_success_json ;;
            *) z2k_ow_offload_benchmark_status_json ;;
        esac
        return 0
    fi
    require_method POST
    _body=$(read_body); _action=$(form_value "$_body" action)
    case "$_action" in
        start)
            _provider=$(form_value "$_body" provider); [ -n "$_provider" ] || _provider=yandex-internetometer
            case "$_provider" in yandex-internetometer|cloudflare) ;; *) json_fail "400 Bad Request" "unsupported benchmark provider" ;; esac
            _session=$(z2k_ow_offload_benchmark_start "$_provider" 2>&1) || json_fail "409 Conflict" "${_session:-не удалось запустить benchmark}"
            case "$_session" in ''|*[!0-9]*)
                rm -rf "$(z2k_ow_offload_benchmark_lock_dir)" "$(z2k_ow_offload_benchmark_session_dir)"
                json_fail "500 Internal Server Error" "не удалось создать benchmark session" ;;
            esac
            _job=$(svc_action_async "Сравнение режимов FLOWOFFLOAD" "z2k_ow_offload_benchmark_worker $_session")
            case "$_job" in ''|*[!0-9]*)
                rm -rf "$(z2k_ow_offload_benchmark_lock_dir)" "$(z2k_ow_offload_benchmark_session_dir)"
                json_fail "500 Internal Server Error" "не удалось запустить background job" ;;
            esac
            _token=$(z2k_ow_offload_benchmark_field token)
            json_header; printf '{"ok":true,"job":"%s","session":"%s","token":"%s"}\n' "$_job" "$_session" "$_token"
            ;;
        stop)
            z2k_ow_offload_benchmark_stop || json_fail "409 Conflict" "benchmark is not active"
            json_header; printf '{"ok":true,"stopping":true}\n'
            ;;
        sample)
            z2k_ow_offload_benchmark_submit \
                "$(form_value "$_body" session)" "$(form_value "$_body" token)" "$(form_value "$_body" nonce)" \
                "$(form_value "$_body" download_mbps)" "$(form_value "$_body" upload_mbps)" \
                "$(form_value "$_body" idle_ms)" "$(form_value "$_body" download_loaded_ms)" \
                "$(form_value "$_body" upload_loaded_ms)" "$(form_value "$_body" jitter_ms)" \
                "$(form_value "$_body" loss_pct)" "$(form_value "$_body" duration_s)" "$(form_value "$_body" server)" \
                || json_fail "400 Bad Request" "invalid or stale benchmark sample"
            json_header; printf '{"ok":true}\n'
            ;;
        *) json_fail "400 Bad Request" "action must be start, stop, or sample" ;;
    esac
}
