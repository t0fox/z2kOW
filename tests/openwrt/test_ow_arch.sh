#!/bin/sh
# tests/openwrt/test_ow_arch.sh - §7: arch mapping без переименования GOARCH.
#   1. z2k_ow_goarch: OpenWrt target-строки -> те же upstream-имена;
#      неизвестное — провал (fail-safe, не угадываем).
#   2. цепочка: uname -m=aarch64 -> au_bin_goarch=arm64 (нетронутый код).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-arch"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
assert_contains "WARP MIPS targets use soft-float ABI" "$REPO/scripts/openwrt/build-release.sh" \
    'mips|mipsle) GOTOOLCHAIN=local GOOS=linux GOARCH="$goarch" GOMIPS=softfloat'
. "$REPO/platform/openwrt/arch.sh"

assert_eq "целевой таргет" "arm64" "$(z2k_ow_goarch aarch64_cortex-a53)"
assert_eq "голый aarch64" "arm64" "$(z2k_ow_goarch aarch64)"
assert_eq "x86_64" "amd64" "$(z2k_ow_goarch x86_64)"
assert_eq "mipsel_24kc" "mipsle" "$(z2k_ow_goarch mipsel_24kc)"
assert_eq "mips64el" "mips64le" "$(z2k_ow_goarch mips64el)"
assert_eq "armv7" "arm" "$(z2k_ow_goarch arm_cortex-a7_neon-vfpv4)"
assert_eq "TG binary arm64" "/payload/bin/linux-arm64/tg-mtproxy-client" \
    "$(z2k_ow_tg_bin_path /payload/bin aarch64)"
assert_eq "TG binary mipsel" "/payload/bin/linux-mipsel/tg-mtproxy-client" \
    "$(z2k_ow_tg_bin_path /payload/bin mipsel_24kc)"
assert_eq "RT binary MIPS uses OpenWrt subtarget" "/payload/bin/linux-mipsel/z2k-rt-proxy" \
    "$(z2k_ow_arch_bin_path /payload/bin z2k-rt-proxy mipsel_24kc)"
assert_eq "detector binary ARM64" "/payload/bin/linux-arm64/z2k-detect" \
    "$(z2k_ow_arch_bin_path /payload/bin z2k-detect aarch64_cortex-a53)"
z2k_ow_tg_bin_path /payload/bin mips64el >/dev/null 2>&1 \
    && _t_bad "отсутствующая в runtime MIPS64LE арка ошибочно поддержана" || _t_ok
z2k_ow_goarch "mips_r2_gcc" >/dev/null 2>&1 && _t_ok || _t_bad "mips (be) не маппится"
z2k_ow_goarch "something-unknown-xyz" >/dev/null 2>&1 \
    && _t_bad "неизвестная арка угадана" || _t_ok

# цепочка upstream: get_arch/uname -> map_arch_to_bin_arch -> au_bin_goarch.
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/utils.sh" >/dev/null 2>&1 || exit 1
. "$REPO/lib/auto_update.sh" >/dev/null 2>&1 || exit 1
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-arch.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
printf "DISTRIB_ARCH='mips_24kc'\n" > "$T/openwrt_release"
Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release"
export Z2K_OW_OPENWRT_RELEASE_FILE
assert_eq "DISTRIB_ARCH keeps big-endian MIPS OpenWrt target" "mips" "$(z2k_ow_detect_goarch)"
assert_eq "default binary picker selects big-endian MIPS runtime" "/payload/bin/linux-mips/z2k-detect" \
    "$(z2k_ow_arch_bin_path /payload/bin z2k-detect)"
printf "DISTRIB_ARCH='mipsel_24kc'\n" > "$T/openwrt_release"
assert_eq "DISTRIB_ARCH selects little-endian MIPS runtime" "mipsle" "$(z2k_ow_detect_goarch)"
assert_eq "little-endian MIPS binary picker" "/payload/bin/linux-mipsel/z2k-detect" \
    "$(z2k_ow_arch_bin_path /payload/bin z2k-detect)"
mkdir -p "$T/bin"
printf '#!/bin/sh\necho aarch64\n' > "$T/bin/uname"
chmod +x "$T/bin/uname"
# hermetic PATH: только stub-uname, затем fallback к OpenWrt target mapping.
_got="$(PATH="$T/bin:/usr/bin:/bin" au_bin_goarch 2>/dev/null)"
assert_eq "aarch64 -> arm64 сквозь нетронутый код" "arm64" "$_got"

_t_done
