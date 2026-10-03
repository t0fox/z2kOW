#!/bin/sh
. "$(dirname "$0")/helper.sh"
_t_plan "ow-geosite-adapter"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-geosite.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/root/lists" "$T/root/extra_strats/cache/autocircular" "$T/etc/state" "$T/etc/user-lists"
printf 'google.com\nkeep.example\n' > "$T/etc/user-lists/extra-domains.txt"
printf 'google.com\nauto.example\n' > "$T/etc/state/autohostlist-domains.txt"
printf 'rkn_tcp\tgoogle.com\t2\t1\trotator\nrkn_tcp\tinstagram.com\t3\t1\trotator\nrkn_tcp\tkeep.example\t4\t1\trotator\n' \
    > "$T/etc/state/state.tsv"

Z2K_GEOSITE_SOURCE_ONLY=1 ZAPRET2_DIR="$T/root" \
    Z2K_EXTRA_DOMAINS_RUNTIME="$T/etc/user-lists/extra-domains.txt" \
    Z2K_AUTOHOSTLIST_DOMAINS_FILE="$T/etc/state/autohostlist-domains.txt" \
    Z2K_GEOSITE_STATE_FILE="$T/etc/state/state.tsv" \
    Z2K_GEOSITE_GOOGLE_PURGE_MARKER="$T/etc/state/google-purge.done" \
    Z2K_GEOSITE_INSTAGRAM_PURGE_MARKER="$T/etc/state/instagram-purge.done" \
    sh -c '. "$1"; clean_google_domains; purge_stale_google_state; purge_stale_instagram_state' \
    sh "$REPO/files/z2k-geosite.sh"

assert_not_contains "user extra-domain list drops protected Google domain" "$T/etc/user-lists/extra-domains.txt" '^google\.com$'
assert_contains "user extra-domain list keeps unrelated entries" "$T/etc/user-lists/extra-domains.txt" 'keep.example'
assert_not_contains "persistent autohostlist ledger drops protected Google domain" "$T/etc/state/autohostlist-domains.txt" '^google\.com$'
assert_contains "persistent autohostlist ledger keeps unrelated entries" "$T/etc/state/autohostlist-domains.txt" 'auto.example'
assert_not_contains "OpenWrt autocircular Google migration is applied" "$T/etc/state/state.tsv" '^rkn_tcp[[:space:]]+google\.com'
assert_not_contains "OpenWrt autocircular Instagram migration is applied" "$T/etc/state/state.tsv" '^rkn_tcp[[:space:]]+instagram\.com'
assert_contains "unrelated persistent autocircular entries survive" "$T/etc/state/state.tsv" 'keep.example'
[ -f "$T/etc/state/google-purge.done" ] \
    && _t_ok || _t_bad "Google cleanup marker persists outside payload"
[ -f "$T/etc/state/instagram-purge.done" ] \
    && _t_ok || _t_bad "Instagram cleanup marker persists outside payload"
_t_done
