#!/bin/sh
# Yandex Internetometer probe discovery is strict; only the LAN browser runs
# the measurement transfers against the selected CDN host.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-offload-yandex-probes"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/platform/openwrt/offload-benchmark.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-yandex-probes.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

jsonfilter() {
    local _file= _expr= _type=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -i) _file="$2"; shift 2 ;;
            -e) _expr="$2"; shift 2 ;;
            -t) _type=1; _expr="$2"; shift 2 ;;
            -q) shift ;;
            *) shift ;;
        esac
    done
    python3 - "$_file" "$_expr" "$_type" <<'PY'
import json, re, sys
try:
    value = json.load(open(sys.argv[1], encoding='utf-8'))
    expression = sys.argv[2]
    tokens = re.findall(r'([A-Za-z_][A-Za-z0-9_]*)(?:\[(\d+)\])?', expression.removeprefix('@.'))
    for key, index in tokens:
        value = value[key]
        if index != '':
            value = value[int(index)]
    if sys.argv[3] == '1':
        print('null' if value is None else 'array' if isinstance(value, list) else 'object' if isinstance(value, dict) else 'boolean' if isinstance(value, bool) else 'string' if isinstance(value, str) else 'int' if isinstance(value, int) else 'double')
    if value is None:
        if sys.argv[3] != '1': print('null')
    elif isinstance(value, (dict, list)):
        if sys.argv[3] != '1': print(json.dumps(value, separators=(',', ':')))
    elif isinstance(value, bool):
        if sys.argv[3] != '1': print('true' if value else 'false')
    elif sys.argv[3] != '1':
        print(value)
except (OSError, ValueError, KeyError, IndexError, TypeError):
    pass
PY
}
curl() {
    local _out=
    while [ "$#" -gt 0 ]; do
        case "$1" in -o) _out="$2"; shift 2 ;; *) shift ;; esac
    done
    [ "${BENCH_PROBE_FETCH_FAIL:-0}" = 0 ] || return 1
    cp "$BENCH_PROBE_FIXTURE" "$_out"
}

_fixture="$REPO/tests/openwrt/fixtures/yandex-internetometer-get-probes-valid.json"
_target="$T/selected.json"
z2k_ow_offload_benchmark_validate_yandex_probes "$_fixture" "$_target" \
    && _t_ok || _t_bad "valid Yandex probes are accepted"
assert_eq "selected host and endpoint config" \
    '{"provider":"yandex-internetometer","server":"edge-01.cdn.yandex.net","mid":"fixturemid123456789","latency_url":"https://edge-01.cdn.yandex.net/cdnrph/ping?mid=fixturemid123456789&lid=123","download_url":"https://edge-01.cdn.yandex.net/cdnrph/probes/50mb?lid=123&mid=fixturemid123456789","upload_url":"https://edge-01.cdn.yandex.net/cdnrph/upload?mid=fixturemid123456789&size=30720"}' \
    "$(cat "$_target")"
python3 -m json.tool "$_target" >/dev/null 2>&1 && _t_ok || _t_bad "selected Yandex config is valid JSON"

_mutate_fixture() {
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
case=sys.argv[3]
if case == 'foreign-host':
    x['download']['probes'][0]['url']=x['download']['probes'][0]['url'].replace('edge-01.cdn.yandex.net','evil.example')
elif case == 'foreign-mid':
    x['upload']['probes'][0]['url']=x['upload']['probes'][0]['url'].replace('fixturemid123456789','othermid123456789')
elif case == 'no-common-host':
    x['upload']['probes'][0]['url']=x['upload']['probes'][0]['url'].replace('edge-01.cdn.yandex.net','edge-02.cdn.yandex.net')
elif case == 'lid-not-listed':
    x['latency']['probes'][0]['url']=x['latency']['probes'][0]['url'].replace('&lid=123','&lid=456')
elif case == 'wrong-shape':
    x['latency']['probes']={'0': x['latency']['probes'][0]}
elif case == 'wrong-timeout-type':
    x['download']['probes'].append({'url':x['download']['probes'][0]['url'].replace('/50mb','/100kb')+'&timeout=100','timeout':'100'})
elif case == 'wrong-size':
    x['upload']['probes'][0]['size']=4096
elif case == 'no-full-download':
    x['download']['probes'][0]['url']=x['download']['probes'][0]['url'].replace('/50mb','/100kb')
open(sys.argv[2], 'w').write(json.dumps(x,separators=(',',':')))
PY
}
for _case in foreign-host foreign-mid no-common-host lid-not-listed wrong-shape wrong-timeout-type wrong-size no-full-download; do
    _bad="$T/$_case.json"; _bad_target="$T/$_case-selected.json"
    _mutate_fixture "$_fixture" "$_bad" "$_case"
    if z2k_ow_offload_benchmark_validate_yandex_probes "$_bad" "$_bad_target" >/dev/null 2>&1; then
        _t_bad "malformed get-probes response rejected: $_case"
    else
        _t_ok
    fi
done

Z2K_STATE="$T/state" Z2K_TMP="$T/tmp"
export Z2K_STATE Z2K_TMP
mkdir -p "$Z2K_STATE" "$Z2K_TMP"
printf 'FLOWOFFLOAD=software\n' > "$T/config"
Z2K_CONFIG="$T/config" CONFIG_FILE="$T/config"; export Z2K_CONFIG CONFIG_FILE
z2k_ow_flowoffload_available() { return 0; }
z2k_ow_flowoffload_mode() { sed -n 's/^FLOWOFFLOAD=//p' "$Z2K_CONFIG"; }
is_running() { return 0; }
BENCH_PROBE_FIXTURE="$_fixture"; export BENCH_PROBE_FIXTURE
_session=$(z2k_ow_offload_benchmark_start yandex-internetometer 2>"$T/start.err") \
    && _t_ok || _t_bad "Yandex benchmark starts from a valid dynamic probe response"
assert_eq "Yandex provider is stored in the session" yandex-internetometer "$(z2k_ow_offload_benchmark_field provider)"
assert_contains "session config uses the actual CDN host" "$(z2k_ow_offload_benchmark_session_dir)/probe-config.json" '"server":"edge-01.cdn.yandex.net"'
z2k_ow_offload_benchmark_set_field status awaiting_sample
z2k_ow_offload_benchmark_set_field nonce fixture-nonce
if z2k_ow_offload_benchmark_submit "$_session" "$(z2k_ow_offload_benchmark_field token)" fixture-nonce \
    80 20 10 30 32 1 0 12 wrong.cdn.yandex.net >/dev/null 2>&1; then
    _t_bad "a sample cannot claim a CDN other than the selected Yandex host"
else _t_ok; fi
z2k_ow_offload_benchmark_submit "$_session" "$(z2k_ow_offload_benchmark_field token)" fixture-nonce \
    80 20 10 30 32 1 0 12 edge-01.cdn.yandex.net && _t_ok || _t_bad "browser sample accepts its selected Yandex CDN host"
z2k_ow_offload_benchmark_set_field nonce fixture-no-pings
z2k_ow_offload_benchmark_submit "$_session" "$(z2k_ow_offload_benchmark_field token)" fixture-no-pings \
    80 20 null null null null 100 12 edge-01.cdn.yandex.net \
    && _t_ok || _t_bad "speed sample remains valid when all optional latency probes fail"
z2k_ow_offload_benchmark_set_field nonce fixture-invalid-speed
if z2k_ow_offload_benchmark_submit "$_session" "$(z2k_ow_offload_benchmark_field token)" fixture-invalid-speed \
    null 20 null null null null 100 12 edge-01.cdn.yandex.net >/dev/null 2>&1; then
    _t_bad "sample with missing download speed is rejected"
else _t_ok; fi
z2k_ow_offload_benchmark_write_result failed fixture-result
assert_contains "raw result names the Yandex provider" "$(z2k_ow_offload_benchmark_root)/last-result.json" '"provider":"yandex-internetometer"'
assert_contains "raw result names the actual CDN server" "$(z2k_ow_offload_benchmark_root)/last-result.json" '"server":"edge-01.cdn.yandex.net"'
assert_contains "raw run retains the actual CDN server" "$(z2k_ow_offload_benchmark_root)/last-result.json" '"server":"edge-01.cdn.yandex.net"'

rm -rf "$(z2k_ow_offload_benchmark_lock_dir)" "$(z2k_ow_offload_benchmark_session_dir)"
BENCH_PROBE_FIXTURE="$T/no-common-host.json"; export BENCH_PROBE_FIXTURE
_bad_start=$(z2k_ow_offload_benchmark_start yandex-internetometer 2>&1)
[ -n "$_bad_start" ] && _t_ok || _t_bad "invalid Yandex probes fail visibly instead of silently falling back"
[ ! -d "$(z2k_ow_offload_benchmark_lock_dir)" ] && _t_ok || _t_bad "invalid Yandex probes leave no benchmark lock"

_t_done
