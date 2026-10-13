#!/bin/sh
# platform/openwrt/arch.sh — сопоставление архитектуры/цели OpenWrt с GOARCH.
#
# Имена GOARCH проекта upstream не меняем (arm64, mipsle и другие): функция
# распознаёт их по цели и подцели OpenWrt, когда `uname -m` недостаточно точен.
# $1 — строка цели OpenWrt, например aarch64_cortex-a53; пустое значение
# сначала использует DISTRIB_ARCH из /etc/openwrt_release, затем `uname -m`.
# Возвращает GOARCH; неизвестная архитектура означает безопасный отказ без вывода.

# Целевая тройка OpenWrt различает ABI и порядок байтов, которые `uname -m`
# иногда объединяет (в частности MIPS 24Kc). Предпочитаем метаданные роутера.
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

# Найти исполняемый файл в полном релизном наборе для разных архитектур.
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
        *armv5*|*armv6*|*armv7*|*arm_xscale*|*arm_arm926ej-s*|*cortex-a*)
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
    # Имена каталогов точно соответствуют раскладке runtime zapret2 upstream.
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
        # В закреплённом runtime zapret2 нет сборок MIPS64 с обратным порядком байтов.
        *) return 1 ;;
    esac
    printf '%s/bin/linux-%s/z2k-warpd\n' "${_root%/}" "$_arch"
}


# Rust TG использует единый декларативный список для runtime-выбора и сборки.
z2k_ow_tg_rust_lookup() {
    local _source _field _table _pattern _family _variant _target _abi _linker _zig_target _cpu _std _flags
    _source="$(printf '%s' "${1:-$(z2k_ow_detect_arch)}" | tr 'A-Z' 'a-z')"
    _field="${2:-target}"
    _table="${Z2K_OW_TG_TARGETS_FILE:-${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}/tg-rust-targets.tsv}"
    [ -r "$_table" ] || return 1
    while read -r _pattern _family _variant _target _abi _linker _zig_target _cpu _std _flags; do
        case "$_pattern" in ''|\#*) continue ;; esac
        case "$_source" in
            $_pattern)
                case "$_field" in
                    family) printf '%s\n' "$_family" ;;
                    variant) printf '%s\n' "$_variant" ;;
                    target) printf '%s\n' "$_target" ;;
                    abi) printf '%s\n' "$_abi" ;;
                    linker) printf '%s\n' "$_linker" ;;
                    zig_target) printf '%s\n' "$_zig_target" ;;
                    cpu) printf '%s\n' "$_cpu" ;;
                    std) printf '%s\n' "$_std" ;;
                    flags) printf '%s\n' "$_flags" ;;
                    *) return 1 ;;
                esac
                return 0
                ;;
        esac
    done < "$_table"
    return 1
}

z2k_ow_tg_rust_target() { z2k_ow_tg_rust_lookup "${1:-$(z2k_ow_detect_arch)}" target; }
z2k_ow_tg_rust_variant() { z2k_ow_tg_rust_lookup "${1:-$(z2k_ow_detect_arch)}" variant; }
z2k_ow_tg_rust_abi() { z2k_ow_tg_rust_lookup "${1:-$(z2k_ow_detect_arch)}" abi; }

z2k_ow_tg_rust_bin_path() {
    local _root="$1" _variant
    _variant="$(z2k_ow_tg_rust_variant "${2:-$(z2k_ow_detect_arch)}")" || return 1
    printf '%s/linux-%s/tg-ws-proxy\n' "${_root%/}" "$_variant"
}
