#!/bin/sh
# Собрать локальный прозрачный Telegram MTProto → WSS crate для OpenWrt.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
CRATE="$ROOT/platform/openwrt/tg-proxy"
OUT="${1:-}"
[ -n "$OUT" ] || { echo "использование: build_tg_ws_proxy.sh OUTPUT_DIR [--test]" >&2; exit 2; }
_test="${2:-}"
case "$_test" in ''|--test) ;; *) echo "использование: build_tg_ws_proxy.sh OUTPUT_DIR [--test]" >&2; exit 2 ;; esac
[ -f "$CRATE/Cargo.toml" ] && [ -f "$CRATE/Cargo.lock" ] || { echo "сборка TG: локальный crate неполон" >&2; exit 1; }
command -v cargo >/dev/null 2>&1 || { echo "сборка TG: требуется cargo" >&2; exit 1; }
command -v rustup >/dev/null 2>&1 || { echo "сборка TG: требуется rustup" >&2; exit 1; }
_arm64_gcc="$(command -v aarch64-linux-gnu-gcc 2>/dev/null || true)"
[ -n "$_arm64_gcc" ] || { echo "сборка TG: требуется aarch64-linux-gnu-gcc для ARM64" >&2; exit 1; }
_host_cc="$(command -v cc 2>/dev/null || true)"
_host_ar="$(command -v ar 2>/dev/null || true)"
[ -n "$_host_cc" ] && [ -n "$_host_ar" ] || { echo "сборка TG: требуются cc и ar для x86_64" >&2; exit 1; }

_toolchain="$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$CRATE/rust-toolchain.toml" | head -1 | tr -d '\r\n')"
[ -n "$_toolchain" ] || { echo "сборка TG: неверный rust-toolchain.toml" >&2; exit 1; }
rustup toolchain list | grep -q "^${_toolchain}[- ]" \
    || { echo "сборка TG: набор Rust $_toolchain не установлен" >&2; exit 1; }

_tmp="$(mktemp -d "${TMPDIR:-/tmp}/z2k-tg-rust.XXXXXX")"
trap 'rm -rf "$_tmp"' EXIT HUP INT TERM
_target_dir="$_tmp/target"
mkdir -p "$OUT"

if [ "$_test" = --test ]; then
    (
        cd "$CRATE"
        CARGO_TARGET_DIR="$_target_dir" cargo "+$_toolchain" fmt --all -- --check
        CARGO_TARGET_DIR="$_target_dir" cargo "+$_toolchain" test --locked --package z2kow-tg-transparent
        CARGO_TARGET_DIR="$_target_dir" cargo "+$_toolchain" clippy --locked --all-targets -- -D warnings
    )
fi

_targets='aarch64-unknown-linux-musl:arm64:arm64-gcc x86_64-unknown-linux-musl:x86_64:host-gcc'
for _entry in $_targets; do
    _target=${_entry%%:*}
    _rest=${_entry#*:}
    _arch=${_rest%%:*}
    _rest=${_rest#*:}
    _builder=$_rest
    rustup target add --toolchain "$_toolchain" "$_target"
    _linker="$_tmp/linker-$_arch"
    _cc="$_tmp/cc-$_arch"
    _ar="$_tmp/ar-$_arch"
    if [ "$_builder" = arm64-gcc ]; then
        printf '#!/bin/sh\nexec "%s" "$@"\n' "$_arm64_gcc" > "$_linker"
        _cc_compiler=$_arm64_gcc
    else
        printf '#!/bin/sh\nexec "%s" "$@"\n' "$_host_cc" > "$_linker"
        _cc_compiler=$_host_cc
    fi
    {
        printf '#!/bin/sh\nfilter_target_args() {\n'
        printf 'case "$1" in __Z2K_ARGS_END__) shift; exec "%s" "$@" ;; --target=*) shift; filter_target_args "$@" ;; *) _arg=$1; shift; filter_target_args "$@" "$_arg" ;; esac\n}\n' \
            "$_cc_compiler"
        printf 'filter_target_args "$@" __Z2K_ARGS_END__\n'
    } > "$_cc"
    if [ "$_builder" = arm64-gcc ]; then
        printf '#!/bin/sh\nexec aarch64-linux-gnu-ar "$@"\n' > "$_ar"
    else
        printf '#!/bin/sh\nexec "%s" "$@"\n' "$_host_ar" > "$_ar"
    fi
    chmod 0755 "$_linker" "$_cc" "$_ar"
    _env_target="$(printf '%s' "$_target" | tr 'abcdefghijklmnopqrstuvwxyz-' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ_')"
    _cc_key="CC_$(printf '%s' "$_target" | tr '-' '_')"
    _ar_key="AR_$(printf '%s' "$_target" | tr '-' '_')"
    (
        cd "$CRATE"
        env \
            "CARGO_TARGET_${_env_target}_LINKER=$_linker" \
            "$_cc_key=$_cc" \
            "$_ar_key=$_ar" \
            "CARGO_TARGET_DIR=$_target_dir" \
            CARGO_PROFILE_RELEASE_STRIP=symbols \
            cargo "+$_toolchain" build --locked --release \
                --package z2kow-tg-transparent --bin tg-ws-proxy --target "$_target"
    )
    mkdir -p "$OUT/linux-$_arch"
    cp "$_target_dir/$_target/release/tg-ws-proxy" "$OUT/linux-$_arch/tg-ws-proxy"
    chmod 0755 "$OUT/linux-$_arch/tg-ws-proxy"
done

cp "$CRATE/LICENSE" "$OUT/LICENSE"
printf 'crate=platform/openwrt/tg-proxy\nbinary=tg-ws-proxy\nupstream=valnesfjord/tg-ws-proxy-rs@53c8bfe5e9efa561cf61a862c0371f1f8ba33869\nlicense=MIT\ntargets=aarch64-unknown-linux-musl,x86_64-unknown-linux-musl\n' > "$OUT/PROVENANCE"
