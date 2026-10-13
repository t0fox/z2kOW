#!/bin/sh
# Проверяет общую ABI-матрицу сборщика и отсутствие сетевого upstream crate.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tg-local-build"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BUILDER="$REPO/scripts/openwrt/build_tg_ws_proxy.sh"
TABLE="$REPO/platform/openwrt/tg-rust-targets.tsv"
Z2K_OW_TG_TARGETS_FILE="$TABLE"
export Z2K_OW_TG_TARGETS_FILE
. "$REPO/platform/openwrt/arch.sh"

for _spec in \
    'aarch64_cortex-a53|aarch64-unknown-linux-musl|arm64|AArch64-LP64-musl' \
    'arm_xscale|armv5te-unknown-linux-musleabi|arm|ARMv5TE-EABI-soft-musl' \
    'arm_cortex-a7|armv5te-unknown-linux-musleabi|arm|ARMv5TE-EABI-soft-musl' \
    'arm_cortex-a5|armv5te-unknown-linux-musleabi|arm|ARMv5TE-EABI-soft-musl' \
    'armv6l|armv5te-unknown-linux-musleabi|arm|ARMv5TE-EABI-soft-musl' \
    'i386_pentium4|i686-unknown-linux-musl|x86|i686-Pentium4-SSE2-musl' \
    'mips_24kc|mips-unknown-linux-musl|mips|MIPS32r2-O32-soft-big-musl' \
    'mipsel_24kc|mipsel-unknown-linux-musl|mipsel|MIPS32r2-O32-soft-little-musl' \
    'riscv64_rva22|riscv64gc-unknown-linux-musl|riscv64|RV64GC-LP64D-musl'; do
    _arch=${_spec%%|*}; _rest=${_spec#*|}
    _target=${_rest%%|*}; _rest=${_rest#*|}
    _variant=${_rest%%|*}; _abi=${_rest#*|}
    assert_eq "Rust target $_arch" "$_target" "$(z2k_ow_tg_rust_target "$_arch")"
    assert_eq "output variant $_arch" "linux-$_variant" \
        "$(z2k_ow_tg_rust_bin_path /tmp/bin "$_arch" | sed 's#/tmp/bin/##; s#/tg-ws-proxy##')"
    assert_eq "ABI declaration $_arch" "$_abi" "$(z2k_ow_tg_rust_abi "$_arch")"
done
for _unsupported in arm armv4 arm_cortex-m4 mips mipsel riscv64 i386_geode i386_pentium-mmx i386_pentium; do
    z2k_ow_tg_rust_target "$_unsupported" >/dev/null 2>&1 \
        && _t_bad "32-битный x86 без SSE2 ошибочно принят: $_unsupported" || _t_ok
done

grep -q -- '--locked --release --package z2kow-tg-transparent' "$BUILDER" \
    && _t_ok || _t_bad "builder компилирует локальный crate в режиме --locked"
grep -q 'platform/openwrt/tg-proxy' "$BUILDER" \
    && ! grep -Eq 'git clone|cargo install.*git' "$BUILDER" \
    && _t_ok || _t_bad "builder не клонирует внешний proxy"
grep -q '02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239' "$BUILDER" \
    && grep -q 'b9478f8179e296f6606180f80163ffccd5f127adda2d2cae22271f2fb9bbe707' "$BUILDER" \
    && grep -q '7c3131d9a924946ec30aecbb265cbd08e92fe65e458495a6c7f2ad8b6db2b91c' "$BUILDER" \
    && grep -q '5a02d679c1ff052745b419b564624380dd3e5f6218db64c65b8ec9df56e2c263' "$BUILDER" \
    && _t_ok || _t_bad "builder закрепляет cross toolchain по SHA-256"
grep -q -- '-Z build-std=std,panic_abort' "$BUILDER" \
    && _t_ok || _t_bad "MIPS использует сборку Rust std из исходников"
grep -q 'target_table=platform/openwrt/tg-rust-targets.tsv' "$BUILDER" \
    && _t_ok || _t_bad "provenance указывает общую ABI-таблицу"
assert_file "crate MIT license сохраняется в payload" "$REPO/platform/openwrt/tg-proxy/LICENSE"
_t_done
