#!/bin/sh
# tests/openwrt/test_ow_platform_failclosed.sh - audit I: explicit openwrt +
# битый/отсутствующий адаптер = controlled PLATFORM_UNAVAILABLE.
# Мутации fail closed (никакого Keenetic fallback на чужие пути),
# /status деградирован (installed:false), ready/degraded модель (N).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-platform-failclosed"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-pfc.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

export Z2K_PLATFORM=openwrt
cat > "$T/init-stub" <<'EOF'
#!/bin/sh
[ "$1" = "running" ] && { [ -f "$STUB_RUNNING" ] && exit 0 || exit 1; }
exit 0
EOF
chmod +x "$T/init-stub"
export STUB_RUNNING="$T/running" Z2K_INIT="$T/init-stub"

# --- 1. битый адаптер (пустой root): UNAVAILABLE + всё закрыто ---
export Z2K_ROOT="$T/empty" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
mkdir -p "$T/empty" "$T/etc" "$T/tmp"
unset Z2K_CONFIG CONFIG_FILE Z2K_CORE_READY Z2K_RUN Z2K_PLATFORM_STATUS
# shellcheck disable=SC1090,SC1091
. "$REPO/webpanel/cgi/platform.sh" || { echo "FAIL[ow-platform-failclosed]: source" >&2; exit 1; }
assert_eq "broken status" "PLATFORM_UNAVAILABLE" "$Z2K_PLATFORM_STATUS"
is_installed >/dev/null 2>&1 && _t_bad "broken: installed true" || _t_ok
for _f in svc_start svc_stop svc_restart restart_service_if_running regenerate_config; do
    $_f >/dev/null 2>&1 && _t_bad "broken: $_f прошёл" || _t_ok
done
# ready/degraded при битом: running=false (init-stub без флага) -> degraded=false, ready=false.
_j="$(wp_capabilities_json)"
case "$_j" in
    *'"platform":"openwrt"'*) _t_ok ;;
    *) _t_bad "broken: нет platform-фрагмента: [$_j]" ;;
esac
case "$_j" in
    *'"ready":false'*'"degraded":false'*) _t_ok ;;
    *) _t_bad "broken: ready/degraded не false/false: [$_j]" ;;
esac

# --- 2. здоровый адаптер (симлинки на настоящее): ok ---
mkdir -p "$T/okroot/platform/openwrt" "$T/okroot/webpanel/cgi" "$T/okroot/share" "$T/oketc" "$T/oktmp"
for _f in paths.sh env.sh webpanel.sh panel.sh; do
    ln -s "$REPO/platform/openwrt/$_f" "$T/okroot/platform/openwrt/$_f"
done
cp "$REPO/webpanel/cgi/actions.sh" "$REPO/webpanel/cgi/platform.sh" "$T/okroot/webpanel/cgi/"
cp "$REPO/package/openwrt/PANEL_API" "$T/okroot/share/panel.api"
mkdir -p "$T/okroot/bin"
ln -s "$REPO/platform/openwrt/tg.sh" "$T/okroot/platform/openwrt/tg.sh"
export Z2K_ROOT="$T/okroot" Z2K_ETC="$T/oketc" Z2K_TMP="$T/oktmp"
unset Z2K_CONFIG CONFIG_FILE Z2K_CORE_READY Z2K_RUN Z2K_PLATFORM_STATUS
unset Z2K_PAYLOAD_MARKER Z2K_PANEL_DIR Z2K_PANEL_CONFIG Z2K_STATE STATE_FILE
unset Z2K_USER_LISTS Z2K_LISTS_DIR Z2K_LUA_DIR Z2K_FAKE_DIR Z2K_BIN Z2K_STATE_DIR_OVERRIDE
. "$REPO/webpanel/cgi/platform.sh" || { echo "FAIL[ow-platform-failclosed]: source ok" >&2; exit 1; }
assert_eq "healthy status" "ok" "$Z2K_PLATFORM_STATUS"
# без marker — не installed (честно), с marker — installed.
is_installed >/dev/null 2>&1 && _t_bad "healthy без marker: installed" || _t_ok
: > "$Z2K_ETC/.payload-initialized"
is_installed >/dev/null 2>&1 && _t_ok || _t_bad "healthy с marker: не installed"

# --- 3. N: running=true + ready absent = degraded ---
: > "$T/running"
rm -f "$Z2K_RUN/core-ready" 2>/dev/null
_j="$(wp_capabilities_json)"
case "$_j" in
    *'"ready":false'*'"degraded":true'*) _t_ok ;;
    *) _t_bad "running без ready не degraded: [$_j]" ;;
esac
# running + ready = healthy.
mkdir -p "$Z2K_RUN" 2>/dev/null
: > "$Z2K_RUN/core-ready"
printf '%s\n' "$$" > "$Z2K_RUN/nfqws2.pid"
printf '200 %s 0 0\n' "$$" > "$T/nfqueue"
export Z2K_NFQUEUE_PROC="$T/nfqueue"
_j="$(wp_capabilities_json)"
case "$_j" in
    *'"ready":true'*'"degraded":false'*) _t_ok ;;
    *) _t_bad "running+ready не healthy: [$_j]" ;;
esac
# stopped + no ready = обычное stopped, не degraded.
rm -f "$T/running" "$Z2K_RUN/core-ready"
_j="$(wp_capabilities_json)"
case "$_j" in
    *'"ready":false'*'"degraded":false'*) _t_ok ;;
    *) _t_bad "stopped не clean-stopped: [$_j]" ;;
esac

# --- 4. keenetic untouched: NOOP ---
(
    unset Z2K_PLATFORM Z2K_PLATFORM_STATUS
    Z2K_ROOT="$T/empty"
    . "$REPO/webpanel/cgi/platform.sh" || exit 1
    [ -z "${Z2K_PLATFORM_STATUS:-}" ] && exit 0 || exit 1
) && _t_ok || _t_bad "keenetic: не NOOP"

_t_done
