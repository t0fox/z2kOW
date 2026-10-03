#!/bin/sh
# tests/openwrt/test_ow_diag.sh - diagnostics platform seam.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-diag"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DIAG="$REPO/files/z2k-diag.sh"
AD="$REPO/platform/openwrt/diag.sh"
ENV="$REPO/platform/openwrt/env.sh"
STAGE="$REPO/scripts/openwrt/stage-rootfs.sh"

assert_file "OpenWrt diagnostics adapter exists" "$AD"
assert_contains "common diagnostic has neutral hook" "$DIAG" 'Z2K_DIAG_HOOK='
assert_contains "health delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" health'
assert_contains "firewall delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" firewall'
assert_contains "telegram delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" tunnel'
assert_contains "WARP delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" warp'
assert_contains "platform delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" platform'
assert_contains "offload delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" offload'
assert_contains "autocircular delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" autocircular'
assert_contains "lists delegate through hook" "$DIAG" '"$Z2K_DIAG_HOOK" lists'
assert_contains "network path delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" netpath'
assert_contains "adapter hook exported" "$ENV" 'Z2K_DIAG_HOOK='
assert_contains "adapter hook reads procd state" "$AD" '"$_init" running'
assert_contains "p-86.10 diagnostic reports queued Telegram CONNECT drops" "$AD" 'CONNECT throttled'
assert_contains "OpenWrt diagnostic falls back to procd logread" "$AD" 'logread'
assert_contains "adapter hook uses canonical core-ready predicate" "$AD" 'z2k_ow_core_ready'
assert_contains "adapter hook checks nft NFQUEUE" "$AD" 'queue flags bypass to 200'
assert_contains "adapter hook uses OpenWrt nfq path" "$AD" 'Z2K_NFQWS2'
assert_contains "common diagnostic uses canonical nfq path" "$DIAG" 'Z2K_NFQWS2:-'
assert_contains "direct OpenWrt diagnostic bootstraps platform env" "$DIAG" 'platform/openwrt/paths.sh'
assert_contains "direct OpenWrt diagnostic loads hook" "$DIAG" 'platform/openwrt/env.sh'
assert_contains "canonical nfq path is exported" "$ENV" 'export Z2K_NFQWS2'
assert_contains "adapter hook selects architecture TG binary" "$REPO/platform/openwrt/tg.sh" \
    'z2k_ow_tg_bin_path "${Z2K_BIN:-/usr/lib/z2k/bin}"'
assert_contains "adapter hook resolves architecture WARP runtime path" "$AD" 'z2k_ow_warp_bin_path "$_warp_adapter"'
assert_contains "adapter hook uses explicit disabled/unknown states" "$AD" 'conclusion=disabled'
assert_contains "adapter hook reports unavailable backend" "$AD" 'backend=unavailable'
assert_contains "adapter hook reports selected FLOWOFFLOAD" "$AD" 'flowoffload mode'
assert_contains "adapter hook reports zapret2 flowtable" "$AD" 'zapret2 flowtable'
assert_contains "adapter hook reports exemptions" "$AD" 'exemptions'
assert_contains "adapter hook reports owner conflict" "$AD" 'owner conflict'
assert_contains "adapter hook separates packet visibility" "$AD" 'packet visibility'
assert_contains "adapter hook does not claim circular proof" "$AD" 'circular'
assert_contains "offload mode trim is BusyBox-safe" "$AD" "tr -d ' \t\r\n'"
assert_contains "adapter hook checks fastroute presence" "$AD" 'nf_conntrack_fastroute'
assert_contains "adapter hook uses canonical WARP status" "$AD" 'warp/status.json'
assert_not_contains "adapter hook never prints WARP key" "$AD" 'WARP_PLUS_KEY'
assert_not_contains "adapter hook never prints private key" "$AD" 'private_key'
assert_contains "complete rootfs stages diagnostic hook source" "$STAGE" 'files/z2k-diag.sh" usr/lib/z2k/z2k-diag.sh'
assert_contains "complete rootfs marks diagnostic hook executable" "$STAGE" 'usr/lib/z2k/z2k-diag.sh 0755'
assert_contains "complete rootfs stages adapter diag hook" "$STAGE" 'platform/openwrt/*.sh'

T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-diag-version.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/root" "$T/etc/z2k/state"
printf 'tag=p-86.11\nseq=134\n' > "$T/etc/z2k/state/installed-release"
_diag=$(Z2K_PLATFORM=openwrt Z2K_ROOT="$T/root" Z2K_ETC="$T/etc/z2k" \
    Z2K_STATE="$T/etc/z2k/state" \
    ZAPRET2_DIR="$T/root" sh "$DIAG" --short 2>/dev/null)
printf '%s\n' "$_diag" > "$T/diag-short.txt"
assert_contains "short OpenWrt diagnostics reads the one installed-release state" \
    "$T/diag-short.txt" 'z2kOW=p-86.11 '
_diag_json=$(Z2K_PLATFORM=openwrt Z2K_ROOT="$T/root" Z2K_ETC="$T/etc/z2k" \
    Z2K_STATE="$T/etc/z2k/state" \
    ZAPRET2_DIR="$T/root" sh "$DIAG" --json 2>/dev/null)
printf '%s\n' "$_diag_json" > "$T/diag.json"
assert_contains "JSON diagnostics includes only installed release version" "$T/diag.json" '"version":"p-86.11"'
assert_not_contains "JSON diagnostics has no secondary version axes" "$T/diag.json" '"(engine|build|product)"'

_t_done
