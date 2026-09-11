#!/bin/sh
# platform/openwrt/arch.sh - OpenWrt arch/target -> GOARCH (имена upstream).
#
# Upstream GOARCH-имена НЕ меняем (arm64, mipsle, ...): эта функция лишь
# опознаёт их по строкам, которые встречаются на OpenWrt, где `uname -m`
# недоступен (сборка пакета/фида) или недостаточно точен.
# $1 — строка (OpenWrt target, e.g. aarch64_cortex-a53) или пусто (=uname -m).
# Печатает GOARCH; неизвестное — провал без вывода (fail-safe).

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
        *mipsel*|*24kc*|*74kc*|*1004kc*)
            echo "mipsle" ;;
        *mips*)
            echo "mips" ;;
        *riscv64*)
            echo "riscv64" ;;
        *) return 1 ;;
    esac
}
