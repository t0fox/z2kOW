#!/bin/sh
# tests/openwrt/test_ow_arch.sh - §7: arch mapping без переименования GOARCH.
#   1. z2k_ow_goarch: OpenWrt target-строки -> те же upstream-имена;
#      неизвестное — провал (fail-safe, не угадываем).
#   2. цепочка: uname -m=aarch64 -> au_bin_goarch=arm64 (нетронутый код).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-arch"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/platform/openwrt/arch.sh"

assert_eq "целевой таргет" "arm64" "$(z2k_ow_goarch aarch64_cortex-a53)"
assert_eq "голый aarch64" "arm64" "$(z2k_ow_goarch aarch64)"
assert_eq "x86_64" "amd64" "$(z2k_ow_goarch x86_64)"
assert_eq "mipsel_24kc" "mipsle" "$(z2k_ow_goarch mipsel_24kc)"
assert_eq "mips64el" "mips64le" "$(z2k_ow_goarch mips64el)"
assert_eq "armv7" "arm" "$(z2k_ow_goarch arm_cortex-a7_neon-vfpv4)"
z2k_ow_goarch "mips_r2_gcc" >/dev/null 2>&1 && _t_ok || _t_bad "mips (be) не маппится"
z2k_ow_goarch "something-unknown-xyz" >/dev/null 2>&1 \
    && _t_bad "неизвестная арка угадана" || _t_ok

# цепочка upstream: get_arch/uname -> map_arch_to_bin_arch -> au_bin_goarch.
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/utils.sh" >/dev/null 2>&1 || exit 1
. "$REPO/lib/auto_update.sh" >/dev/null 2>&1 || exit 1
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-arch.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin"
printf '#!/bin/sh\necho aarch64\n' > "$T/bin/uname"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/opkg"
chmod +x "$T/bin/uname" "$T/bin/opkg"
# hermetic PATH: stub-opkg (vendor-arch probe гаснет) + stub-uname впереди.
_got="$(PATH="$T/bin:/usr/bin:/bin" au_bin_goarch 2>/dev/null)"
assert_eq "aarch64 -> arm64 сквозь нетронутый код" "arm64" "$_got"

_t_done
