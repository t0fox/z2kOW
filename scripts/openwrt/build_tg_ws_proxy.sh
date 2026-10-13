#!/bin/sh
# Собрать локальный прозрачный Telegram MTProto → WSS crate для OpenWrt.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
CRATE="$ROOT/platform/openwrt/tg-proxy"
TABLE="$ROOT/platform/openwrt/tg-rust-targets.tsv"
OUT="${1:-}"
_test="${2:-}"
_requested_variants="${Z2K_TG_VARIANTS:-}"
_zig_version=0.15.2
_zig_sha256=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239
_arm_toolchain_url=https://downloads.openwrt.org/releases/25.12.5/targets/kirkwood/generic/openwrt-toolchain-25.12.5-kirkwood-generic_gcc-14.3.0_musl_eabi.Linux-x86_64.tar.zst
_arm_toolchain_sha256=b9478f8179e296f6606180f80163ffccd5f127adda2d2cae22271f2fb9bbe707
_mips_be_toolchain_url=https://downloads.openwrt.org/releases/25.12.5/targets/malta/be/openwrt-toolchain-25.12.5-malta-be_gcc-14.3.0_musl.Linux-x86_64.tar.zst
_mips_be_toolchain_sha256=7c3131d9a924946ec30aecbb265cbd08e92fe65e458495a6c7f2ad8b6db2b91c
_mips_le_toolchain_url=https://downloads.openwrt.org/releases/25.12.5/targets/malta/le/openwrt-toolchain-25.12.5-malta-le_gcc-14.3.0_musl.Linux-x86_64.tar.zst
_mips_le_toolchain_sha256=5a02d679c1ff052745b419b564624380dd3e5f6218db64c65b8ec9df56e2c263
_mips_toolchain=nightly-2026-07-21

[ -n "$OUT" ] || { echo "использование: build_tg_ws_proxy.sh OUTPUT_DIR [--test]" >&2; exit 2; }
case "$_test" in ''|--test) ;; *) echo "использование: build_tg_ws_proxy.sh OUTPUT_DIR [--test]" >&2; exit 2 ;; esac
[ -f "$CRATE/Cargo.toml" ] && [ -f "$CRATE/Cargo.lock" ] && [ -s "$TABLE" ] \
    || { echo "сборка TG: локальный crate или таблица ABI неполны" >&2; exit 1; }
for _tool in cargo rustc rustup curl sha256sum tar awk sort paste readelf xz zstd python3; do
    command -v "$_tool" >/dev/null 2>&1 || { echo "сборка TG: требуется $_tool" >&2; exit 1; }
done
case "$(uname -s)-$(uname -m)" in Linux-x86_64) ;; *)
    echo "сборка TG: закреплённые Zig и OpenWrt SDK предназначены для Linux x86_64" >&2
    exit 1
    ;;
esac
if [ -e "$OUT" ] && [ -n "$(find "$OUT" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    echo "сборка TG: выходной каталог должен быть пустым: $OUT" >&2
    exit 1
fi

_stable="$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$CRATE/rust-toolchain.toml" | head -1 | tr -d '\r\n')"
[ -n "$_stable" ] || { echo "сборка TG: неверный rust-toolchain.toml" >&2; exit 1; }
rustup toolchain list | grep -q "^${_stable}[- ]" \
    || { echo "сборка TG: набор Rust $_stable не установлен" >&2; exit 1; }

_tmp="$(mktemp -d "${TMPDIR:-/tmp}/z2k-tg-rust.XXXXXX")"
trap 'rm -rf "$_tmp"' EXIT HUP INT TERM
_cache="${Z2K_TG_TOOLCHAIN_CACHE:-${TMPDIR:-/tmp}/z2k-tg-toolchains}"
mkdir -p "$_cache" "$_cache/linkers" "$_tmp/output"
_target_dir="${Z2K_TG_CARGO_TARGET_DIR:-$_cache/cargo-target}"
mkdir -p "$_target_dir"

_all_variants="$(awk 'NF == 10 && $1 !~ /^#/ {print $3}' "$TABLE" | sort -u | tr '\n' ' ')"
if [ -n "$_requested_variants" ]; then
    _requested_variants="$(printf '%s' "$_requested_variants" | tr ',' ' ')"
    _selected_variants=""
    for _variant in $_requested_variants; do
        case "$_variant" in *[!A-Za-z0-9_-]*|'')
            echo "сборка TG: неверный вариант ABI: $_variant" >&2; exit 1 ;;
        esac
        case " $_all_variants " in *" $_variant "*) ;; *)
            echo "сборка TG: неизвестный вариант ABI: $_variant" >&2; exit 1 ;;
        esac
        case " $_selected_variants " in *" $_variant "*)
            echo "сборка TG: вариант ABI повторён: $_variant" >&2; exit 1 ;;
        esac
        _selected_variants="$_selected_variants $_variant"
    done
    [ -n "$_selected_variants" ] || { echo "сборка TG: список ABI пуст" >&2; exit 1; }
    _selected_variants="$(printf '%s\n' $_selected_variants | sort -u | tr '\n' ' ')"
else
    _selected_variants="$_all_variants"
fi

_need_zig=0 _need_arm=0 _need_mips_be=0 _need_mips_le=0 _mips_needed=0
while read -r _pattern _family _variant _target _abi _linker _zig_target _cpu _std _flags; do
    case "$_pattern" in ''|\#*) continue ;; esac
    case " $_selected_variants " in *" $_variant "*) ;; *) continue ;; esac
    case "$_linker" in
        zig) _need_zig=1 ;;
        openwrt-armv5) _need_arm=1 ;;
        openwrt-mips) _need_mips_be=1; _mips_needed=1 ;;
        openwrt-mipsel) _need_mips_le=1; _mips_needed=1 ;;
        *) echo "сборка TG: неизвестный linker из таблицы ABI: $_linker" >&2; exit 1 ;;
    esac
done < "$TABLE"

_fetch_verified() {
    _url="$1" _sha="$2" _destination="$3"
    if [ ! -s "$_destination" ] || [ "$(sha256sum "$_destination" | awk '{print $1}')" != "$_sha" ]; then
        _download="$_destination.part.$$"
        rm -f "$_download"
        curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$_url" -o "$_download"
        [ "$(sha256sum "$_download" | awk '{print $1}')" = "$_sha" ] \
            || { rm -f "$_download"; echo "сборка TG: SHA-256 закреплённого toolchain не совпал: $_url" >&2; return 1; }
        mv -f "$_download" "$_destination"
    fi
}

if [ "$_need_zig" = 1 ]; then
    _zig_archive="$_cache/zig-x86_64-linux-$_zig_version.tar.xz"
    _fetch_verified "https://ziglang.org/download/$_zig_version/zig-x86_64-linux-$_zig_version.tar.xz" \
        "$_zig_sha256" "$_zig_archive"
    _zig_root="$_cache/zig-$_zig_version"
    if [ ! -x "$_zig_root/zig" ]; then
        mkdir -p "$_tmp/zig"
        tar -xJf "$_zig_archive" -C "$_tmp/zig" --strip-components=1
        mv "$_tmp/zig" "$_zig_root"
    fi
    _zig="$_zig_root/zig"
    [ -x "$_zig" ] && [ "$("$_zig" version)" = "$_zig_version" ] \
        || { echo "сборка TG: неверная версия закреплённого Zig" >&2; exit 1; }
fi

if [ "$_need_arm" = 1 ]; then
    _arm_archive="$_cache/openwrt-kirkwood-toolchain.tar.zst"
    _fetch_verified "$_arm_toolchain_url" "$_arm_toolchain_sha256" "$_arm_archive"
    _arm_root="$_cache/openwrt-kirkwood-toolchain"
    if [ ! -d "$_arm_root" ]; then
        mkdir -p "$_tmp/openwrt-arm"
        tar --zstd -xf "$_arm_archive" -C "$_tmp/openwrt-arm"
        mv "$_tmp/openwrt-arm" "$_arm_root"
    fi
    _arm_gcc="$(find "$_arm_root" -path '*/bin/arm-openwrt-linux-muslgnueabi-gcc' -print -quit)"
    _arm_ar="$(find "$_arm_root" -path '*/bin/arm-openwrt-linux-muslgnueabi-ar' -print -quit)"
    [ -x "$_arm_gcc" ] && [ -x "$_arm_ar" ] \
        || { echo "сборка TG: в проверенном OpenWrt ARMv5 toolchain нет gcc/ar" >&2; exit 1; }
fi

if [ "$_test" = --test ]; then
    (
        cd "$CRATE"
        CARGO_TARGET_DIR="$_target_dir" cargo "+$_stable" fmt --all -- --check
        CARGO_TARGET_DIR="$_target_dir" cargo "+$_stable" test --locked --package z2kow-tg-transparent
        CARGO_TARGET_DIR="$_target_dir" cargo "+$_stable" clippy --locked --all-targets -- -D warnings
    )
fi

if [ "$_mips_needed" = 1 ]; then
    rustup toolchain install "$_mips_toolchain" --profile minimal --component rust-src
    if [ "$_need_mips_be" = 1 ]; then
        _mips_be_archive="$_cache/openwrt-mips-be-toolchain.tar.zst"
        _fetch_verified "$_mips_be_toolchain_url" "$_mips_be_toolchain_sha256" "$_mips_be_archive"
        _mips_be_root="$_cache/openwrt-mips-be-toolchain"
        if [ ! -d "$_mips_be_root" ]; then
            mkdir -p "$_tmp/openwrt-mips-be"
            tar --zstd -xf "$_mips_be_archive" -C "$_tmp/openwrt-mips-be"
            mv "$_tmp/openwrt-mips-be" "$_mips_be_root"
        fi
        _mips_be_gcc="$(find "$_mips_be_root" -path '*/bin/mips-openwrt-linux-musl-gcc' -print -quit)"
        _mips_be_ar="$(find "$_mips_be_root" -path '*/bin/mips-openwrt-linux-musl-ar' -print -quit)"
        [ -x "$_mips_be_gcc" ] && [ -x "$_mips_be_ar" ] \
            || { echo "сборка TG: в OpenWrt MIPS BE toolchain нет gcc/ar" >&2; exit 1; }
    fi
    if [ "$_need_mips_le" = 1 ]; then
        _mips_le_archive="$_cache/openwrt-mips-le-toolchain.tar.zst"
        _fetch_verified "$_mips_le_toolchain_url" "$_mips_le_toolchain_sha256" "$_mips_le_archive"
        _mips_le_root="$_cache/openwrt-mips-le-toolchain"
        if [ ! -d "$_mips_le_root" ]; then
            mkdir -p "$_tmp/openwrt-mips-le"
            tar --zstd -xf "$_mips_le_archive" -C "$_tmp/openwrt-mips-le"
            mv "$_tmp/openwrt-mips-le" "$_mips_le_root"
        fi
        _mips_le_gcc="$(find "$_mips_le_root" -path '*/bin/mipsel-openwrt-linux-musl-gcc' -print -quit)"
        _mips_le_ar="$(find "$_mips_le_root" -path '*/bin/mipsel-openwrt-linux-musl-ar' -print -quit)"
        [ -x "$_mips_le_gcc" ] && [ -x "$_mips_le_ar" ] \
            || { echo "сборка TG: в OpenWrt MIPS LE toolchain нет gcc/ar" >&2; exit 1; }
    fi
fi

_seen="$_tmp/seen-variants"
_build_records="$_tmp/build-records.tsv"
: > "$_seen"
: > "$_build_records"
while read -r _pattern _family _variant _target _abi _linker _zig_target _cpu _std _flags; do
    case "$_pattern" in ''|\#*) continue ;; esac
    case " $_selected_variants " in *" $_variant "*) ;; *) continue ;; esac
    if grep -Fqx "$_variant|$_target|$_linker|$_zig_target|$_cpu|$_std|$_flags" "$_seen"; then
        continue
    fi
    printf '%s\n' "$_variant|$_target|$_linker|$_zig_target|$_cpu|$_std|$_flags" >> "$_seen"

    if [ "$_std" = build-std ]; then
        _toolchain="$_mips_toolchain"
    else
        _toolchain="$_stable"
        rustup target add --toolchain "$_toolchain" "$_target"
    fi

    _linker_script="$_cache/linkers/linker-$_variant"
    _cc_script="$_cache/linkers/cc-$_variant"
    _ar_script="$_cache/linkers/ar-$_variant"
    case "$_linker" in
        zig)
            printf '#!/usr/bin/env python3\nimport os, sys\n_zig = "%s"\n_start = {"crt1.o", "rcrt1.o", "Scrt1.o", "crti.o", "crtbegin.o", "crtbeginS.o", "crtbeginT.o", "crtend.o", "crtendS.o", "crtn.o"}\n_args = [arg for arg in sys.argv[1:] if not arg.startswith("--target=") and arg not in ("-Wl,--fix-cortex-a53-843419", "-Wl,-melf_i386") and arg not in ("-nostartfiles", "-nostdlib") and arg.rsplit("/", 1)[-1] not in _start]\nos.execv(_zig, [_zig, "cc", "-target", "%s", "-mcpu=%s", "-static"] + _args)\n' \
                "$_zig" "$_zig_target" "$_cpu" > "$_linker_script"
            printf '#!/usr/bin/env python3\nimport os, sys\n_zig = "%s"\n_args = [arg for arg in sys.argv[1:] if not arg.startswith("--target=")]\nos.execv(_zig, [_zig, "cc", "-target", "%s", "-mcpu=%s"] + _args)\n' \
                "$_zig" "$_zig_target" "$_cpu" > "$_cc_script"
            printf '#!/bin/sh\nexec "%s" ar "$@"\n' "$_zig" > "$_ar_script"
            ;;
        openwrt-armv5)
            printf '#!/usr/bin/env python3\nimport os, sys\n_cc = "%s"\n_start = {"crt1.o", "rcrt1.o", "Scrt1.o", "crti.o", "crtbegin.o", "crtbeginS.o", "crtbeginT.o", "crtend.o", "crtendS.o", "crtn.o"}\n_args = [arg for arg in sys.argv[1:] if not arg.startswith("--target=") and arg not in ("-nostartfiles", "-nostdlib") and arg.rsplit("/", 1)[-1] not in _start]\nos.execv(_cc, [_cc, "-march=armv5te", "-mtune=xscale", "-mfloat-abi=soft"] + _args)\n' \
                "$_arm_gcc" > "$_linker_script"
            printf '#!/usr/bin/env python3\nimport os, sys\n_cc = "%s"\n_args = [arg for arg in sys.argv[1:] if not arg.startswith("--target=")]\nos.execv(_cc, [_cc, "-march=armv5te", "-mtune=xscale", "-mfloat-abi=soft"] + _args)\n' \
                "$_arm_gcc" > "$_cc_script"
            printf '#!/bin/sh\nexec "%s" "$@"\n' "$_arm_ar" > "$_ar_script"
            ;;
        openwrt-mips|openwrt-mipsel)
            if [ "$_linker" = openwrt-mips ]; then
                _mips_gcc="$_mips_be_gcc" _mips_ar="$_mips_be_ar"
            else
                _mips_gcc="$_mips_le_gcc" _mips_ar="$_mips_le_ar"
            fi
            printf '#!/usr/bin/env python3\nimport os, sys\n_cc = "%s"\n_args = ["-lgcc_eh" if arg == "-lgcc_s" else arg for arg in sys.argv[1:] if not arg.startswith("--target=") and arg not in ("-mhard-float", "-msoft-float", "-Wl,-Bdynamic", "-Wl,-Bstatic")]\nif "-lc" in _args:\n    _at = _args.index("-lc")\n    _args.insert(_at, "-lpthread")\n    _args.insert(_at + 2, "-lgcc")\nos.execv(_cc, [_cc, "-mabi=32", "-march=mips32r2", "-Wl,-Bstatic"] + _args + ["-static", "-msoft-float", "-Wl,--no-dynamic-linker"])\n' \
                "$_mips_gcc" > "$_linker_script"
            printf '#!/usr/bin/env python3\nimport os, sys\n_cc = "%s"\n_args = [arg for arg in sys.argv[1:] if not arg.startswith("--target=") and arg not in ("-mhard-float", "-msoft-float")]\nos.execv(_cc, [_cc, "-mabi=32", "-march=mips32r2"] + _args + ["-msoft-float"])\n' \
                "$_mips_gcc" > "$_cc_script"
            printf '#!/bin/sh\nexec "%s" "$@"\n' "$_mips_ar" > "$_ar_script"
            ;;
        *) echo "сборка TG: неизвестный linker из таблицы ABI: $_linker" >&2; exit 1 ;;
    esac
    chmod 0755 "$_linker_script" "$_cc_script" "$_ar_script"
    _env_target="$(printf '%s' "$_target" | tr 'abcdefghijklmnopqrstuvwxyz-' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ_')"
    _cc_key="CC_$(printf '%s' "$_target" | tr '-' '_')"
    _ar_key="AR_$(printf '%s' "$_target" | tr '-' '_')"
    _rustflags=""
    case ",$_flags," in *,-latomic,*) _rustflags='-C link-arg=-latomic' ;; esac
    case ",$_flags," in *,-static,*)
        [ -z "$_rustflags" ] || _rustflags="$_rustflags "
        _rustflags="${_rustflags}-C link-arg=-static"
        ;;
    esac
    _build_std_args=""
    [ "$_std" != build-std ] || _build_std_args='-Z build-std=std,panic_abort'
    _panic_mode=unwind
    [ "$_std" != build-std ] || _panic_mode=abort
    mkdir -p "$_tmp/output/linux-$_variant"
    (
        cd "$CRATE"
        env \
            "CARGO_TARGET_${_env_target}_LINKER=$_linker_script" \
            "CARGO_TARGET_${_env_target}_RUSTFLAGS=$_rustflags" \
            "$_cc_key=$_cc_script" \
            "$_ar_key=$_ar_script" \
            "CARGO_TARGET_DIR=$_target_dir" \
            CARGO_PROFILE_RELEASE_STRIP=symbols \
            CARGO_PROFILE_RELEASE_LTO=true \
            CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
            "CARGO_PROFILE_RELEASE_PANIC=$_panic_mode" \
            cargo "+$_toolchain" build --locked --release --package z2kow-tg-transparent \
                --bin tg-ws-proxy --target "$_target" $_build_std_args
    )
    cp "$_target_dir/$_target/release/tg-ws-proxy" "$_tmp/output/linux-$_variant/tg-ws-proxy"
    chmod 0755 "$_tmp/output/linux-$_variant/tg-ws-proxy"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_variant" "$_target" "$_abi" "$_linker" "$_cpu" "$_std" "$_flags" "$_toolchain" \
        >> "$_build_records"
done < "$TABLE"

_variants="$(printf '%s\n' $_selected_variants | sed 's/^linux-//')"
_actual="$(find "$_tmp/output" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)"
[ "$(printf '%s\n' "$_variants" | sed 's/^/linux-/')" = "$_actual" ] \
    || { echo "сборка TG: собранный набор не совпал с таблицей ABI" >&2; exit 1; }

for _variant in $_variants; do
    _binary="$_tmp/output/linux-$_variant/tg-ws-proxy"
    if readelf -l "$_binary" 2>/dev/null | grep -q 'INTERP'; then
        echo "сборка TG: бинарник linux-$_variant неожиданно зависит от динамического загрузчика" >&2
        exit 1
    fi
done
python3 "$ROOT/tests/openwrt/verify_tg_elf.py" "$_tmp/output" --variants "$_variants" \
    || { echo "сборка TG: ELF/ABI проверка артефактов не прошла" >&2; exit 1; }
cp "$CRATE/LICENSE" "$_tmp/output/LICENSE"
_source_sha="${Z2K_SOURCE_SHA:-${GITHUB_SHA:-}}"
[ -n "$_source_sha" ] || _source_sha="$(git -C "$ROOT" rev-parse HEAD)"
case "$_source_sha" in *[!0-9a-f]*|'') echo "сборка TG: source SHA должен быть SHA-1 в нижнем регистре" >&2; exit 1 ;; esac
[ "${#_source_sha}" -eq 40 ] || { echo "сборка TG: source SHA должен содержать 40 знаков" >&2; exit 1; }
_cargo_lock_sha="$(sha256sum "$CRATE/Cargo.lock" | awk '{print $1}')"
_rust_toolchain_sha="$(sha256sum "$CRATE/rust-toolchain.toml" | awk '{print $1}')"
_target_table_sha="$(sha256sum "$TABLE" | awk '{print $1}')"
_build_script_sha="$(sha256sum "$ROOT/scripts/openwrt/build_tg_ws_proxy.sh" | awk '{print $1}')"
_toolchain_fingerprint="$(printf '%s\n' "$_stable|$_mips_toolchain|$_zig_version|$_zig_sha256|$_arm_toolchain_sha256|$_mips_be_toolchain_sha256|$_mips_le_toolchain_sha256" | sha256sum | awk '{print $1}')"
_stable_rustc="$(rustc "+$_stable" --version)"
_ci_run_id="${GITHUB_RUN_ID:-0}"
if [ -n "${Z2K_TG_BUILD_GROUP:-}" ]; then
    _build_group="$Z2K_TG_BUILD_GROUP"
elif [ "$_selected_variants" = "$_all_variants" ]; then
    _build_group=merged
else
    _build_group=local
fi
{
    printf 'crate=platform/openwrt/tg-proxy\nbinary=tg-ws-proxy\nupstream=valnesfjord/tg-ws-proxy-rs@53c8bfe5e9efa561cf61a862c0371f1f8ba33869\nlicense=MIT\n'
    printf 'target_table=platform/openwrt/tg-rust-targets.tsv\n'
    printf 'artifact_schema=1\nsource_sha=%s\nci_run_id=%s\nmatrix_group=%s\n' \
        "$_source_sha" "$_ci_run_id" "$_build_group"
    _license_sha="$(sha256sum "$CRATE/LICENSE" | awk '{print $1}')"
    printf 'cargo_lock_sha256=%s\nrust_toolchain_sha256=%s\ntarget_table_sha256=%s\nbuild_script_sha256=%s\nlicense_sha256=%s\n' \
        "$_cargo_lock_sha" "$_rust_toolchain_sha" "$_target_table_sha" "$_build_script_sha" "$_license_sha"
    printf 'toolchain_fingerprint=%s\nstable_rustc=%s\nmips_rust_toolchain=%s\n' \
        "$_toolchain_fingerprint" "$_stable_rustc" "$_mips_toolchain"
    printf 'release_profile=strip=symbols,lto=true,codegen-units=1,panic=target-dependent\n'
    printf 'zig_version=%s\nzig_sha256=%s\narm_toolchain_sha256=%s\n' \
        "$_zig_version" "$_zig_sha256" "$_arm_toolchain_sha256"
    printf 'mips_be_toolchain_sha256=%s\nmips_le_toolchain_sha256=%s\n' \
        "$_mips_be_toolchain_sha256" "$_mips_le_toolchain_sha256"
    printf 'armv5_openwrt_toolchain_sha256=%s\n' "$_arm_toolchain_sha256"
    printf 'variants='
    printf '%s\n' $_selected_variants | paste -sd, -
    printf 'targets='
    awk -v variants="$(printf '%s\n' $_selected_variants | paste -sd' ' -)" \
        'BEGIN {n=split(variants, selected, " ")} NF == 10 && $1 !~ /^#/ {for (i=1;i<=n;i++) if ($3==selected[i] && !seen[$4]++) {if (count++) printf ","; printf "%s",$4}} END {printf "\n"}' "$TABLE"
    while IFS="$(printf '\t')" read -r _variant _target _abi _linker _cpu _std _flags _toolchain; do
        _rustc_version="$(rustc "+$_toolchain" --version)"
        printf 'target_%s=%s\nabi_%s=%s\nlinker_%s=%s\ncpu_%s=%s\nstd_%s=%s\nflags_%s=%s\n' \
            "$_variant" "$_target" "$_variant" "$_abi" "$_variant" "$_linker" \
            "$_variant" "$_cpu" "$_variant" "$_std" "$_variant" "$_flags"
        printf 'toolchain_%s=%s\nrustc_%s=%s\nbinary_sha256_%s=%s\n' \
            "$_variant" "$_toolchain" "$_variant" "$_rustc_version" "$_variant" \
            "$(sha256sum "$_tmp/output/linux-$_variant/tg-ws-proxy" | awk '{print $1}')"
    done < "$_build_records"
} > "$_tmp/output/PROVENANCE"
mkdir -p "$OUT"
cp -a "$_tmp/output/." "$OUT/"
echo "сборка TG: создано $(printf '%s\n' "$_variants" | wc -l | tr -d ' ') ABI-вариантов"
