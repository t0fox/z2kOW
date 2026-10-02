#!/bin/sh
# platform/openwrt/arch.sh - OpenWrt arch/target -> GOARCH (имена upstream).
#
# Upstream GOARCH-имена НЕ меняем (arm64, mipsle, ...): эта функция лишь
# опознаёт их по строкам OpenWrt target/subtarget, когда `uname -m`
# недостаточно точен для выбора общей release-бинарной сборки.
# $1 — строка (OpenWrt target, e.g. aarch64_cortex-a53); empty prefers
# /etc/openwrt_release DISTRIB_ARCH and then falls back to uname -m.
# Печатает GOARCH; неизвестное — провал без вывода (fail-safe).

# OpenWrt's target triplet distinguishes endian/ABI cases that uname -m often
# collapses (notably 24Kc MIPS). Prefer the router's own target metadata.
z2k_ow_detect_arch() {
    local _release="${Z2K_OW_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}" _value=""
    if [ -r "$_release" ]; then
        _value=$(sed -n 's/^DISTRIB_ARCH=//p' "$_release" 2>/dev/null | head -1 | sed "s/^['\"]//; s/['\"]$//" | tr -d '\r')
    fi
    if [ -n "$_value" ]; then
        printf '%s\n' "$_value"
    else
        uname -m 2>/dev/null
    fi
}

z2k_ow_arch_name() {
    local _arch
    _arch="$(z2k_ow_goarch "${1:-$(z2k_ow_detect_arch)}")" || return 1
    case "$_arch" in
        arm64|arm|mips|riscv64) printf '%s\n' "$_arch" ;;
        amd64) printf '%s\n' x86_64 ;;
        386) printf '%s\n' x86 ;;
        mipsle) printf '%s\n' mipsel ;;
        *) return 1 ;;
    esac
}

# Resolve an executable from the complete multi-architecture release payload.
z2k_ow_arch_bin_path() {
    local _root="$1" _name="$2" _arch
    _arch="$(z2k_ow_arch_name "${3:-$(z2k_ow_detect_arch)}")" || return 1
    printf '%s/linux-%s/%s\n' "${_root%/}" "$_arch" "$_name"
}

z2k_ow_detect_goarch() {
    z2k_ow_goarch "$(z2k_ow_detect_arch)"
}

z2k_ow_goarch() {
    local _in="${1:-$(uname -m 2>/dev/null)}" _s
    # OpenWrt target — "<arch>_<subtarget>": арка слева, остальное не важно.
    _s="$(printf '%s' "$_in" | tr 'A-Z' 'a-z')"
    case "$_s" in
        *aarch64*|*arm64*|*cortex-a53*|*cortex-a72*|*cortex-a76*)
            echo "arm64" ;;
        *armv7*|*cortex-a7*|*cortex-a9*|*cortex-a15*)
            echo "arm" ;;
        *x86_64*|*amd64*)
            echo "amd64" ;;
        *i386*|*i686*|*x86*|*pentium*)
            echo "386" ;;
        *mips64el*|*mips64le*)
            echo "mips64le" ;;
        *mips_24kc*|*mips_74kc*|*mips_1004kc*)
            echo "mips" ;;
        *mipsel*|*mipsle*|*24kc*|*74kc*|*1004kc*)
            echo "mipsle" ;;
        *mips*)
            echo "mips" ;;
        *riscv64*)
            echo "riscv64" ;;
        *) return 1 ;;
    esac
}

# Return the architecture-specific WARP engine path inside the one full payload.
# The directory names follow the upstream zapret2 runtime layout exactly.
z2k_ow_warp_bin_path() {
    local _root="$1" _input="${2:-$(z2k_ow_detect_arch)}" _arch
    _arch="$(z2k_ow_goarch "$_input")" || return 1
    case "$_arch" in
        arm64) _arch=arm64 ;;
        arm) _arch=arm ;;
        amd64) _arch=x86_64 ;;
        386) _arch=x86 ;;
        mips) _arch=mips ;;
        mipsle) _arch=mipsel ;;
        riscv64) _arch=riscv64 ;;
        # The pinned zapret2 runtime has no little-endian MIPS64 binaries.
        *) return 1 ;;
    esac
    printf '%s/bin/linux-%s/z2k-warpd\n' "${_root%/}" "$_arch"
}

# Select the Telegram tunnel binary from the same complete architecture bundle.
# The installer ships every supported OpenWrt arch under one payload root.
z2k_ow_tg_bin_path() {
    local _root="$1" _input="${2:-$(z2k_ow_detect_arch)}" _arch
    _arch="$(z2k_ow_goarch "$_input")" || return 1
    case "$_arch" in
        arm64) _arch=arm64 ;;
        arm) _arch=arm ;;
        amd64) _arch=x86_64 ;;
        386) _arch=x86 ;;
        mips) _arch=mips ;;
        mipsle) _arch=mipsel ;;
        riscv64) _arch=riscv64 ;;
        *) return 1 ;;
    esac
    printf '%s/linux-%s/tg-mtproxy-client\n' "${_root%/}" "$_arch"
}
