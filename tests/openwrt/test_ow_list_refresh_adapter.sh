#!/bin/sh
. "$(dirname "$0")/helper.sh"
_t_plan "ow-list-refresh-adapter"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-list-refresh.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

ROOT="$T/root"
mkdir -p "$ROOT/platform/openwrt" "$T/etc" "$T/tmp"
cp "$REPO/platform/openwrt/paths.sh" "$ROOT/platform/openwrt/paths.sh"
cp "$REPO/platform/openwrt/env.sh" "$ROOT/platform/openwrt/env.sh"
cat > "$ROOT/z2k-update-lists.sh" <<'STUB'
#!/bin/sh
{
    printf 'args=%s\n' "$*"
    env | sort
} > "$LIST_REFRESH_CAPTURE"
STUB
chmod 0755 "$ROOT/z2k-update-lists.sh"

LIST_REFRESH_CAPTURE="$T/captured.env" \
Z2K_ROOT="$ROOT" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp" \
    sh "$REPO/platform/openwrt/list-refresh.sh" || _t_bad "native list-refresh adapter failed"

assert_contains "full refresh invokes upstream all mode" "$T/captured.env" 'args=all'
assert_contains "full refresh uses OpenWrt service restart" "$T/captured.env" "INIT_SCRIPT=/etc/init.d/z2k"
assert_contains "full refresh supplies OpenWrt WARP list hook" "$T/captured.env" "Z2K_WARP_IPSET_SCRIPT=$ROOT/platform/openwrt/warp.sh"
assert_contains "full refresh uses canonical autocircular state" "$T/captured.env" "STATE_FILE=$T/etc/state/state.tsv"
assert_contains "full refresh geosite purge uses the same state file" "$T/captured.env" "Z2K_GEOSITE_STATE_FILE=$T/etc/state/state.tsv"
assert_contains "full refresh keeps merged extra domains in persistent user lists" "$T/captured.env" "Z2K_EXTRA_DOMAINS_RUNTIME=$T/etc/user-lists/extra-domains.txt"
assert_contains "full refresh keeps autohostlist ledger in persistent state" "$T/captured.env" "Z2K_AUTOHOSTLIST_DOMAINS_FILE=$T/etc/state/autohostlist-domains.txt"
assert_contains "Google migration marker survives payload replacement" "$T/captured.env" "Z2K_GEOSITE_GOOGLE_PURGE_MARKER=$T/etc/state/.geosite-google-purge-2026-05-24.done"
assert_contains "Instagram migration marker survives payload replacement" "$T/captured.env" "Z2K_GEOSITE_INSTAGRAM_PURGE_MARKER=$T/etc/state/.geosite-instagram-purge-2026-05-28.done"

_t_done
