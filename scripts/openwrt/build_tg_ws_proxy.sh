#!/bin/sh
# Собрать прозрачный Telegram-адаптер из закреплённого MIT-upstream и
# небольшого проверенного патча из patches/tg-ws-proxy-rs.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
OUT="${1:-}"
[ -n "$OUT" ] || { echo "использование: build_tg_ws_proxy.sh OUTPUT_DIR" >&2; exit 2; }
_test="${2:-}"
case "$_test" in ''|--test) ;; *) echo "использование: build_tg_ws_proxy.sh OUTPUT_DIR [--test]" >&2; exit 2 ;; esac
command -v git >/dev/null 2>&1 || { echo "сборка TG: требуется git" >&2; exit 1; }
command -v cargo >/dev/null 2>&1 || { echo "сборка TG: требуется cargo" >&2; exit 1; }
command -v rustup >/dev/null 2>&1 || { echo "сборка TG: требуется rustup" >&2; exit 1; }
_arm64_gcc="$(command -v aarch64-linux-gnu-gcc 2>/dev/null || true)"
[ -n "$_arm64_gcc" ] || { echo "сборка TG: требуется компилятор aarch64-linux-gnu-gcc для корректной ARM64-сборки" >&2; exit 1; }
_host_cc="$(command -v cc 2>/dev/null || true)"
_host_ar="$(command -v ar 2>/dev/null || true)"
[ -n "$_host_cc" ] && [ -n "$_host_ar" ] || { echo "сборка TG: требуются системные cc и ar для x86_64" >&2; exit 1; }

_pin="$ROOT/platform/openwrt/tg-ws-proxy.pin"
_repo="$(sed -n 's/^REPOSITORY=//p' "$_pin" | head -1 | tr -d '\r\n')"
_commit="$(sed -n 's/^COMMIT=//p' "$_pin" | head -1 | tr -d '\r\n')"
_toolchain="$(sed -n 's/^TOOLCHAIN=//p' "$_pin" | head -1 | tr -d '\r\n')"
case "$_commit" in *[!0-9a-f]*|'') echo "сборка TG: неверный формат коммита upstream" >&2; exit 1 ;; esac
[ "${#_commit}" -eq 40 ] || { echo "сборка TG: нужен полный SHA-1 коммита upstream" >&2; exit 1; }
[ -n "$_repo" ] && [ -n "$_toolchain" ] || { echo "сборка TG: неверная запись закреплённого upstream" >&2; exit 1; }
rustup toolchain list | grep -q "^${_toolchain}[- ]" \
    || { echo "сборка TG: набор Rust $_toolchain не установлен" >&2; exit 1; }

_tmp="$(mktemp -d "${TMPDIR:-/tmp}/z2k-tg-rust.XXXXXX")"
trap 'rm -rf "$_tmp"' EXIT HUP INT TERM
_src="$_tmp/source"
git clone --quiet --no-checkout "$_repo" "$_src"
git -C "$_src" checkout --quiet --detach "$_commit"
[ "$(git -C "$_src" rev-parse HEAD)" = "$_commit" ] \
    || { echo "сборка TG: полученный upstream не совпадает с закреплённым коммитом" >&2; exit 1; }

_patch="$ROOT/patches/tg-ws-proxy-rs/0001-transparent-openwrt.patch"
git -C "$_src" apply --unidiff-zero --check "$_patch"
git -C "$_src" apply --unidiff-zero "$_patch"

if [ "$_test" = --test ]; then
    (cd "$_src" && CARGO_TARGET_DIR="$_src/target" cargo "+$_toolchain" fmt --all -- --check)
    (cd "$_src" && CARGO_TARGET_DIR="$_src/target" cargo "+$_toolchain" test --locked --package tg-ws-proxy-rs --lib)
    (cd "$_src" && CARGO_TARGET_DIR="$_src/target" cargo "+$_toolchain" test --locked --package tg-ws-proxy-rs --test transparent)
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
        cd "$_src"
        env \
            "CARGO_TARGET_${_env_target}_LINKER=$_linker" \
            "$_cc_key=$_cc" \
            "$_ar_key=$_ar" \
            "CARGO_TARGET_DIR=$_src/target" \
            CARGO_PROFILE_RELEASE_STRIP=symbols \
            cargo "+$_toolchain" build --locked --release \
                --package tg-ws-proxy-rs --bin tg-ws-proxy --target "$_target"
    )
    mkdir -p "$OUT/linux-$_arch"
    cp "$_src/target/$_target/release/tg-ws-proxy" "$OUT/linux-$_arch/tg-ws-proxy"
    chmod 0755 "$OUT/linux-$_arch/tg-ws-proxy"
done
cp "$_src/LICENSE" "$OUT/LICENSE"
printf 'upstream=%s\npatch=%s\ntargets=%s\n' "$_commit" \
    "patches/tg-ws-proxy-rs/0001-transparent-openwrt.patch" \
    "aarch64-unknown-linux-musl,x86_64-unknown-linux-musl" > "$OUT/PROVENANCE"
