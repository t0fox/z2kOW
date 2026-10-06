#!/bin/sh
# Strategy telemetry has been retired from the product. Preserve only the
# OpenWrt one-time cleanup path for stale installations.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }
absent() {
    if [ -e "$ROOT/$1" ]; then bad "retired path is still present: $1"; else ok "retired path is absent: $1"; fi
}
no_match() {
    _desc="$1" _file="$2" _pattern="$3"
    if grep -Eq -- "$_pattern" "$ROOT/$_file" 2>/dev/null; then
        bad "$_desc: active reference remains in $_file"
    else
        ok "$_desc"
    fi
}

for _file in files/z2k-stats-upload.sh \
    webpanel/www/js/pages/telemetry.js \
    vps-stats tests/test_stats_ack.sh tests/test_stats_collector.sh \
    tests/openwrt/test_ow_stats_upload.sh \
    vps/config/systemd/z2k-stats-collector.service; do
    absent "$_file"
done

_pattern='Z2K_STATS(_ACK|_TOKEN|_ENDPOINT)?|menu_stats|toggle_stats|/stats/ack|/toggle/stats|STATS_ENDPOINT|telemetry\.js|run_task[[:space:]]+stats-upload'
for _file in lib/config_official.sh lib/menu.sh lib/install.sh lib/release_map.sh \
    files/z2k-scheduler.sh webpanel/cgi/actions.sh webpanel/cgi/api.sh \
    webpanel/www/js/core/toast.js webpanel/www/js/pages/dashboard.js \
    webpanel/www/js/pages/toggles.js z2k.sh; do
    no_match "strategy telemetry controls and upload path are retired" "$_file" "$_pattern"
done

no_match "CLI no longer advertises the removed strategy telemetry option" lib/menu.sh 'Сбор статистики стратегий|\[C\]|,C,'

no_match "release installer no longer deploys the uploader" lib/install.sh 'z2k-stats-upload'
no_match "OpenWrt payload map no longer contains the uploader" lib/release_map.sh 'z2k-stats-upload'
no_match "OpenWrt panel API has no stats routes or response fields" webpanel/cgi/api.sh 'stats_ack|/stats|toggle/stats|Z2K_STATS'
no_match "VPS verification no longer deploys a collector" vps/bin/verify.sh 'stats-collector|vps-stats'
no_match "VPS Nginx no longer routes a stats receiver" vps/config/nginx-http-z2k.conf 'location[[:space:]]+=?[[:space:]]+/stats'
no_match "VPS monitoring no longer watches the removed collector" vps/observability/collect.sh 'z2k-stats-collector'
no_match "security guide no longer describes active strategy telemetry" SECURITY.md 'strategy telemetry|Z2K_STATS|stats-upload'
no_match "README no longer lists a telemetry component" README.md 'z2k-stats-upload|vps-stats|strategy telemetry'

for _file in lib/install.sh files/S99zapret2.new; do
    if grep -q 'telemetry.tsv' "$ROOT/$_file"; then
        ok "local autocircular telemetry state remains available in $_file"
    else
        bad "local autocircular telemetry state must remain in $_file"
    fi
done

printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
