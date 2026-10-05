#!/bin/sh
# tests/openwrt/test_ow_webpanel_restart_job.sh - audit H: mutation jobs fail
# closed, когда required restart/apply провалился. Раньше
# restart_service_if_running глушил rc (|| true) и джоба отвечала "Готово"
# при мёртвом рестарте. Едем настоящим api.sh через CGI-env (паттерн
# tests/test_webpanel_api_contract.sh), is_running=true, INIT_SCRIPT-стаб.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-webpanel-restart-job"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-wrj.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

SB="$T/sb"; mkdir -p "$SB"
export ZAPRET2_DIR="$SB/opt/zapret2" CONFIG_FILE="$SB/opt/zapret2/config"
export LISTS_DIR="$SB/opt/zapret2/lists" CUSTOM_STRAT_DIR="$SB/opt/zapret2/lists/custom-strategies"
export INIT_SCRIPT="$SB/init-stub"
mkdir -p "$LISTS_DIR" "$CUSTOM_STRAT_DIR" "$ZAPRET2_DIR/lib"
printf 'ENABLED=1\nZ2K_DYNAMIC_TTL=0\n' > "$CONFIG_FILE"
printf '#!/bin/sh\ncreate_official_config() { return 0; }\n' > "$ZAPRET2_DIR/lib/config_official.sh"
printf '#!/bin/sh\nsafe_config_read() { return 0; }\n' > "$ZAPRET2_DIR/lib/utils.sh"
# INIT_SCRIPT: режим через флаг (fail = restart валится).
printf '#!/bin/sh\n[ "$1" = "restart" ] && { [ -f "%s/fail" ] && exit 3; exit 0; }\nexit 0\n' "$SB" > "$INIT_SCRIPT"
chmod +x "$INIT_SCRIPT"
# CGI-копия с подменённым is_running (всегда запущен).
STUBDIR="$SB/cgi"; mkdir -p "$STUBDIR"
cp "$REPO/webpanel/cgi/api.sh" "$REPO/webpanel/cgi/auth.sh" \
   "$REPO/webpanel/cgi/actions.sh" "$STUBDIR/"
printf '\nis_running() { return 0; }\n' >> "$STUBDIR/actions.sh"

_cgi_post() { # $1 PATH_INFO, $2 body
    printf '%s' "$2" > "$T/body"
    _cl=$(wc -c < "$T/body" | tr -d ' ')
    env REQUEST_METHOD="POST" PATH_INFO="$1" QUERY_STRING="" \
        HTTP_HOST="192.168.1.1" HTTP_X_Z2K_PANEL="1" CONTENT_LENGTH="$_cl" \
        sh "$STUBDIR/api.sh" < "$T/body" 2>/dev/null
}
_job_wait() { # $1 jobid -> exit code (ждём появления .exit до 15с)
    _i=0
    while [ ! -f "/tmp/z2k-job-$1.exit" ] && [ "$_i" -lt 15 ]; do sleep 1; _i=$((_i + 1)); done
    cat "/tmp/z2k-job-$1.exit" 2>/dev/null || echo "NOEXIT"
}

# --- 1. restart падает: job failure, без "Готово" ---
: > "$SB/fail"
_out="$(_cgi_post "/toggle/dynamic-ttl" "value=1")"
_jid="$(printf '%s' "$_out" | sed -n 's/.*"job":"\([^"]*\)".*/\1/p')"
[ -n "$_jid" ] || { _t_bad "нет job id: [$_out]"; _jid="none"; }
_rc="$(_job_wait "$_jid")"
# toggle нормализует провал в 1 (|| return 1); важно nonzero + нет "Готово".
if [ -n "$_rc" ] && [ "$_rc" != "0" ] && [ "$_rc" != "NOEXIT" ]; then _t_ok
else _t_bad "failed restart -> job exit != 0, got [$_rc]"; fi
if grep -q "Готово" "/tmp/z2k-job-$_jid.log" 2>/dev/null; then
    _t_bad "failed restart с 'Готово' в логе"
else
    _t_ok
fi
assert_contains "failed job logs an explicit action start" "/tmp/z2k-job-$_jid.log" 'Запущено: Включаю Динамический TTL'
assert_contains "failed job log gives a concrete final error code" "/tmp/z2k-job-$_jid.log" 'ошибка выполнения, код 1'
rm -f "/tmp/z2k-job-$_jid.log" "/tmp/z2k-job-$_jid.pid" "/tmp/z2k-job-$_jid.exit"

# --- 2. restart ok: job success с "Готово" ---
rm -f "$SB/fail"
_out="$(_cgi_post "/toggle/dynamic-ttl" "value=1")"
_jid="$(printf '%s' "$_out" | sed -n 's/.*"job":"\([^"]*\)".*/\1/p')"
_rc="$(_job_wait "$_jid")"
assert_eq "ok restart -> job exit 0" "0" "$_rc"
if grep -q "Готово" "/tmp/z2k-job-$_jid.log" 2>/dev/null; then
    _t_ok
else
    _t_bad "ok restart без 'Готово'"
fi
assert_contains "successful job log includes a final result and duration" "/tmp/z2k-job-$_jid.log" 'Итог: Включаю Динамический TTL — команда завершена успешно'
rm -f "/tmp/z2k-job-$_jid.log" "/tmp/z2k-job-$_jid.pid" "/tmp/z2k-job-$_jid.exit"

# --- 3. A quiet long-running action still updates the live modal log ---
. "$STUBDIR/actions.sh"
_jid="$(svc_action_async "heartbeat regression" "sleep 12")"
[ -n "$_jid" ] || { _t_bad "heartbeat regression has a job id"; _jid="none"; }
_wait=0
while ! grep -q 'Выполняется: heartbeat regression' "/tmp/z2k-job-$_jid.log" 2>/dev/null \
    && [ "$_wait" -lt 12 ]; do
    sleep 1
    _wait=$((_wait + 1))
done
assert_contains "quiet running job writes an intermediate heartbeat" "/tmp/z2k-job-$_jid.log" \
    'Выполняется: heartbeat regression; прошло около 10 с'
_rc="$(_job_wait "$_jid")"
assert_eq "heartbeat job completes normally" "0" "$_rc"
rm -f "/tmp/z2k-job-$_jid.log" "/tmp/z2k-job-$_jid.pid" "/tmp/z2k-job-$_jid.exit"

_t_done
