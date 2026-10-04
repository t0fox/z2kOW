#!/bin/sh
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tiktok-cli"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tiktok-cli.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/state" "$T/tmp"
printf 'Z2K_TIKTOK_FEED_ENABLED=0\n' > "$T/config"
Z2K_ROOT="$REPO" Z2K_CONFIG="$T/config" Z2K_TIKTOK_CONFIG="$T/config" \
Z2K_STATE="$T/state" Z2K_TMP="$T/tmp" Z2K_CRON_TAB="$T/crontab" \
Z2K_TIKTOK_STATE_FILE="$T/state/tiktok.state" \
Z2K_TIKTOK_HOSTS_FILE="$T/state/tiktok-hosts" \
Z2K_TIKTOK_UCI_MARKER="$T/state/tiktok-owner" \
    sh "$REPO/platform/openwrt/z2kow.sh" tiktok enable || _t_bad "CLI tiktok enable succeeds while service is stopped"
assert_contains "CLI enable persists the canonical feature flag" "$T/config" 'Z2K_TIKTOK_FEED_ENABLED=1'

printf 'Z2K_TIKTOK_FEED_ENABLED=1\n' > "$T/config"
Z2K_ROOT="$REPO" Z2K_CONFIG="$T/config" Z2K_TIKTOK_CONFIG="$T/config" \
Z2K_STATE="$T/state" Z2K_TMP="$T/tmp" Z2K_CRON_TAB="$T/crontab" \
Z2K_TIKTOK_STATE_FILE="$T/state/tiktok.state" \
Z2K_TIKTOK_HOSTS_FILE="$T/state/tiktok-hosts" \
Z2K_TIKTOK_UCI_MARKER="$T/state/tiktok-owner" \
    sh "$REPO/platform/openwrt/z2kow.sh" tiktok disable || _t_bad "CLI tiktok disable succeeds"
assert_contains "CLI disable persists the canonical feature flag" "$T/config" 'Z2K_TIKTOK_FEED_ENABLED=0'
assert_not_contains "CLI disable removes TikTok cron entry" "$T/crontab" 'z2k-tiktok-health'
_t_done
