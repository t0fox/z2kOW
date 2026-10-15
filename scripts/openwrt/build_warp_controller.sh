#!/bin/sh
# Сборка статического одноразового Rust-контроллера для ABI OpenWrt payload.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
CRATE="$ROOT/platform/openwrt/warp-controller"
TABLE="$CRATE/rust-targets.tsv"
OUT="${1:-}"
_zig_version=0.15.2
_zig_sha256=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239
_arm_url=https://downloads.openwrt.org/releases/25.12.5/targets/kirkwood/generic/openwrt-toolchain-25.12.5-kirkwood-generic_gcc-14.3.0_musl_eabi.Linux-x86_64.tar.zst
_arm_sha256=b9478f8179e296f6606180f80163ffccd5f127adda2d2cae22271f2fb9bbe707
_mips_be_url=https://downloads.openwrt.org/releases/25.12.5/targets/malta/be/openwrt-toolchain-25.12.5-malta-be_gcc-14.3.0_musl.Linux-x86_64.tar.zst
_mips_be_sha256=7c3131d9a924946ec30aecbb265cbd08e92fe65e458495a6c7f2ad8b6db2b91c
_mips_le_url=https://downloads.openwrt.org/releases/25.12.5/targets/malta/le/openwrt-toolchain-25.12.5-malta-le_gcc-14.3.0_musl.Linux-x86_64.tar.zst
_mips_le_sha256=5a02d679c1ff052745b419b564624380dd3e5f6218db64c65b8ec9df56e2c263
_mips_toolchain=nightly-2026-07-21
_stable=1.98.0
_requested="${Z2K_WARP_CONTROLLER_VARIANTS:-}"

[ -n "$OUT" ] || { echo "использование: $0 OUTPUT_DIR [--test]" >&2; exit 2; }
_test="${2:-}"
case "$_test" in ''|--test) ;; *) echo "использование: $0 OUTPUT_DIR [--test]" >&2; exit 2 ;; esac
[ -f "$CRATE/Cargo.toml" ] && [ -f "$CRATE/Cargo.lock" ] && [ -s "$TABLE" ] \
    || { echo "сборка WARP: crate или таблица Rust ABI отсутствуют" >&2; exit 1; }
for _tool in cargo rustc rustup curl sha256sum tar awk readelf; do
    command -v "$_tool" >/dev/null 2>&1 || { echo "сборка WARP: требуется $_tool" >&2; exit 1; }
done
case "$(uname -s)-$(uname -m)" in Linux-x86_64) ;; *)
    echo "сборка WARP: закреплённые Zig и OpenWrt SDK предназначены для Linux x86_64" >&2
    exit 1
    ;;
esac
if [ -e "$OUT" ] && [ -n "$(find "$OUT" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    echo "сборка WARP: выходной каталог должен быть пустым: $OUT" >&2
    exit 1
fi

_tmp="$(mktemp -d "${TMPDIR:-/tmp}/z2k-warp-rust.XXXXXX")"
trap 'rm -rf "$_tmp"' EXIT HUP INT TERM
_cache="${Z2K_WARP_TOOLCHAIN_CACHE:-${TMPDIR:-/tmp}/z2k-tg-toolchains}"
mkdir -p "$_cache/linkers" "$_tmp/output"
_target_dir="${Z2K_WARP_CARGO_TARGET_DIR:-$_cache/cargo-target}"
mkdir -p "$_target_dir"
_all_variants="$(awk 'NF == 6 && $1 !~ /^#/ {print $1}' "$TABLE" | sort -u | tr '\n' ' ')"
if [ -n "$_requested" ]; then
    _requested="$(printf '%s' "$_requested" | tr ',' ' ')"
    _selected=""
    for _variant in $_requested; do
        case "$_variant" in *[!A-Za-z0-9_-]*|'') echo "сборка WARP: неверный ABI $_variant" >&2; exit 1 ;; esac
        case " $_all_variants " in *" $_variant "*) ;; *) echo "сборка WARP: неизвестный ABI $_variant" >&2; exit 1 ;; esac
        case " $_selected " in *" $_variant "*) echo "сборка WARP: ABI повторён $_variant" >&2; exit 1 ;; esac
        _selected="$_selected $_variant"
    done
else
    _selected="$_all_variants"
fi
[ -n "$_selected" ] || { echo "сборка WARP: пустой набор ABI" >&2; exit 1; }

_fetch_verified() {
    _url="$1" _sha="$2" _destination="$3"
    if [ ! -s "$_destination" ] || [ "$(sha256sum "$_destination" | awk '{print $1}')" != "$_sha" ]; then
        _download="$_destination.part.$$"
        rm -f "$_download"
        curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$_url" -o "$_download"
        [ "$(sha256sum "$_download" | awk '{print $1}')" = "$_sha" ] \
            || { rm -f "$_download"; echo "сборка WARP: SHA-256 закреплённого toolchain не совпал: $_url" >&2; return 1; }
        mv -f "$_download" "$_destination"
    fi
}

_need_zig=0 _need_arm=0 _need_mips_be=0 _need_mips_le=0
while IFS="$(printf '\t')" read -r _variant _target _linker _zig_target _cpu _std; do
    case "$_variant" in ''|\#*) continue ;; esac
    case " $_selected " in *" $_variant "*) ;; *) continue ;; esac
    case "$_linker" in zig) _need_zig=1 ;; openwrt-armv5) _need_arm=1 ;;
        openwrt-mips) _need_mips_be=1 ;; openwrt-mipsel) _need_mips_le=1 ;;
        *) echo "сборка WARP: неизвестный linker $_linker" >&2; exit 1 ;;
    esac
done < "$TABLE"

if [ "$_need_zig" = 1 ]; then
    _zig_archive="$_cache/zig-x86_64-linux-$_zig_version.tar.xz"
    _fetch_verified "https://ziglang.org/download/$_zig_version/zig-x86_64-linux-$_zig_version.tar.xz" "$_zig_sha256" "$_zig_archive"
    _zig_root="$_cache/zig-$_zig_version"
    if [ ! -x "$_zig_root/zig" ]; then
        mkdir -p "$_tmp/zig"; tar -xJf "$_zig_archive" -C "$_tmp/zig" --strip-components=1; mv "$_tmp/zig" "$_zig_root"
    fi
    _zig="$_zig_root/zig"
    [ -x "$_zig" ] && [ "$("$_zig" version)" = "$_zig_version" ] || { echo "сборка WARP: неверная версия Zig" >&2; exit 1; }
fi
if [ "$_need_arm" = 1 ]; then
    _archive="$_cache/openwrt-kirkwood-toolchain.tar.zst"
    _fetch_verified "$_arm_url" "$_arm_sha256" "$_archive"
    _root="$_cache/openwrt-kirkwood-toolchain"
    if [ ! -d "$_root" ]; then mkdir -p "$_tmp/arm"; tar --zstd -xf "$_archive" -C "$_tmp/arm"; mv "$_tmp/arm" "$_root"; fi
    _arm_gcc="$(find "$_root" -path '*/bin/arm-openwrt-linux-muslgnueabi-gcc' -print -quit)"
    _arm_ar="$(find "$_root" -path '*/bin/arm-openwrt-linux-muslgnueabi-ar' -print -quit)"
    [ -x "$_arm_gcc" ] && [ -x "$_arm_ar" ] || { echo "сборка WARP: в ARMv5 SDK нет gcc/ar" >&2; exit 1; }
fi
if [ "$_need_mips_be$_need_mips_le" != 00 ]; then
    rustup toolchain install "$_mips_toolchain" --profile minimal --component rust-src
fi
if [ "$_need_mips_be" = 1 ]; then
    _archive="$_cache/openwrt-mips-be-toolchain.tar.zst"
    _fetch_verified "$_mips_be_url" "$_mips_be_sha256" "$_archive"
    _root="$_cache/openwrt-mips-be-toolchain"
    if [ ! -d "$_root" ]; then mkdir -p "$_tmp/mips-be"; tar --zstd -xf "$_archive" -C "$_tmp/mips-be"; mv "$_tmp/mips-be" "$_root"; fi
    _mips_be_gcc="$(find "$_root" -path '*/bin/mips-openwrt-linux-musl-gcc' -print -quit)"
    _mips_be_ar="$(find "$_root" -path '*/bin/mips-openwrt-linux-musl-ar' -print -quit)"
    [ -x "$_mips_be_gcc" ] && [ -x "$_mips_be_ar" ] || { echo "сборка WARP: в MIPS BE SDK нет gcc/ar" >&2; exit 1; }
fi
if [ "$_need_mips_le" = 1 ]; then
    _archive="$_cache/openwrt-mips-le-toolchain.tar.zst"
    _fetch_verified "$_mips_le_url" "$_mips_le_sha256" "$_archive"
    _root="$_cache/openwrt-mips-le-toolchain"
    if [ ! -d "$_root" ]; then mkdir -p "$_tmp/mips-le"; tar --zstd -xf "$_archive" -C "$_tmp/mips-le"; mv "$_tmp/mips-le" "$_root"; fi
    _mips_le_gcc="$(find "$_root" -path '*/bin/mipsel-openwrt-linux-musl-gcc' -print -quit)"
    _mips_le_ar="$(find "$_root" -path '*/bin/mipsel-openwrt-linux-musl-ar' -print -quit)"
    [ -x "$_mips_le_gcc" ] && [ -x "$_mips_le_ar" ] || { echo "сборка WARP: в MIPS LE SDK нет gcc/ar" >&2; exit 1; }
fi

if [ "$_test" = --test ]; then
    (
        cd "$CRATE"
        cargo "+$_stable" fmt --all -- --check
        CARGO_TARGET_DIR="$_target_dir" cargo "+$_stable" test --locked
        CARGO_TARGET_DIR="$_target_dir" cargo "+$_stable" clippy --locked --all-targets -- -D warnings
    )
fi

while IFS="$(printf '\t')" read -r _variant _target _linker _zig_target _cpu _std; do
    case "$_variant" in ''|\#*) continue ;; esac
    case " $_selected " in *" $_variant "*) ;; *) continue ;; esac
    _linker_script="$_cache/linkers/warp-linker-$_variant"
    _cc_script="$_cache/linkers/warp-cc-$_variant"
    _ar_script="$_cache/linkers/warp-ar-$_variant"
    case "$_linker" in
        zig)
            printf '#!/usr/bin/env python3\nimport os,sys\n_zig="%s"\n_start={"crt1.o","rcrt1.o","Scrt1.o","crti.o","crtbegin.o","crtbeginS.o","crtbeginT.o","crtend.o","crtendS.o","crtn.o"}\n_args=[a for a in sys.argv[1:] if not a.startswith("--target=") and a not in ("-nostartfiles","-nostdlib","-Wl,--fix-cortex-a53-843419","-Wl,-melf_i386") and a.rsplit("/",1)[-1] not in _start]\nos.execv(_zig,[ _zig,"cc","-target","%s","-mcpu=%s","-static"]+_args)\n' "$_zig" "$_zig_target" "$_cpu" > "$_linker_script"
            printf '#!/usr/bin/env python3\nimport os,sys\n_zig="%s"\nos.execv(_zig,[_zig,"cc","-target","%s","-mcpu=%s"]+[a for a in sys.argv[1:] if not a.startswith("--target=")])\n' "$_zig" "$_zig_target" "$_cpu" > "$_cc_script"
            printf '#!/bin/sh\nexec "%s" ar "$@"\n' "$_zig" > "$_ar_script"
            ;;
        openwrt-armv5)
            printf '#!/usr/bin/env python3\nimport os,sys\n_cc="%s"\n_start={"crt1.o","rcrt1.o","Scrt1.o","crti.o","crtbegin.o","crtbeginS.o","crtbeginT.o","crtend.o","crtendS.o","crtn.o"}\n_args=[a for a in sys.argv[1:] if not a.startswith("--target=") and a not in ("-nostartfiles","-nostdlib") and a.rsplit("/",1)[-1] not in _start]\nos.execv(_cc,[_cc,"-march=armv5te","-mtune=xscale","-mfloat-abi=soft"]+_args)\n' "$_arm_gcc" > "$_linker_script"
            printf '#!/usr/bin/env python3\nimport os,sys\n_cc="%s"\nos.execv(_cc,[_cc,"-march=armv5te","-mtune=xscale","-mfloat-abi=soft"]+[a for a in sys.argv[1:] if not a.startswith("--target=")])\n' "$_arm_gcc" > "$_cc_script"
            printf '#!/bin/sh\nexec "%s" "$@"\n' "$_arm_ar" > "$_ar_script"
            ;;
        openwrt-mips|openwrt-mipsel)
            if [ "$_linker" = openwrt-mips ]; then _gcc="$_mips_be_gcc" _ar="$_mips_be_ar"; else _gcc="$_mips_le_gcc" _ar="$_mips_le_ar"; fi
            printf '#!/usr/bin/env python3\nimport os,sys\n_cc="%s"\n_args=["-lgcc_eh" if a=="-lgcc_s" else a for a in sys.argv[1:] if not a.startswith("--target=") and a not in ("-mhard-float","-msoft-float","-Wl,-Bdynamic","-Wl,-Bstatic")]\nif "-lc" in _args:\n i=_args.index("-lc");_args[i:i]=["-lpthread"];_args.insert(i+2,"-lgcc")\nos.execv(_cc,[_cc,"-mabi=32","-march=mips32r2","-Wl,-Bstatic"]+_args+["-static","-msoft-float","-Wl,--no-dynamic-linker"])\n' "$_gcc" > "$_linker_script"
            printf '#!/usr/bin/env python3\nimport os,sys\n_cc="%s"\nos.execv(_cc,[_cc,"-mabi=32","-march=mips32r2"]+[a for a in sys.argv[1:] if not a.startswith("--target=") and a not in ("-mhard-float","-msoft-float")]+["-msoft-float"])\n' "$_gcc" > "$_cc_script"
            printf '#!/bin/sh\nexec "%s" "$@"\n' "$_ar" > "$_ar_script"
            ;;
    esac
    chmod 0755 "$_linker_script" "$_cc_script" "$_ar_script"
    _env_target="$(printf '%s' "$_target" | tr 'abcdefghijklmnopqrstuvwxyz-' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ_')"
    _cc_key="CC_$(printf '%s' "$_target" | tr '-' '_')"
    _ar_key="AR_$(printf '%s' "$_target" | tr '-' '_')"
    _rustflags="-C link-arg=-static"
    [ "$_std" = build-std ] || rustup target add --toolchain "$_stable" "$_target"
    _tc="$_stable" _std_args= _panic=abort
    if [ "$_std" = build-std ]; then _tc="$_mips_toolchain" _std_args='-Z build-std=std,panic_abort'; fi
    (
        cd "$CRATE"
        env "CARGO_TARGET_${_env_target}_LINKER=$_linker_script" "CARGO_TARGET_${_env_target}_RUSTFLAGS=$_rustflags" \
            "$_cc_key=$_cc_script" "$_ar_key=$_ar_script" CARGO_TARGET_DIR="$_target_dir" \
            CARGO_PROFILE_RELEASE_STRIP=symbols CARGO_PROFILE_RELEASE_LTO=true CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
            CARGO_PROFILE_RELEASE_PANIC="$_panic" cargo "+$_tc" build --locked --release --package z2k-warp-controller \
            --bin z2k-warp-controller --target "$_target" $_std_args
    )
    _binary="$_target_dir/$_target/release/z2k-warp-controller"
    [ -s "$_binary" ] && [ -x "$_binary" ] || { echo "сборка WARP: бинарник отсутствует для linux-$_variant" >&2; exit 1; }
    if readelf -l "$_binary" 2>/dev/null | grep -q INTERP; then echo "сборка WARP: linux-$_variant зависит от динамического загрузчика" >&2; exit 1; fi
    case "$_variant" in arm) _qemu=qemu-arm ;; arm64) _qemu=qemu-aarch64 ;; x86_64) _qemu=qemu-x86_64 ;; x86) _qemu=qemu-i386 ;; mips) _qemu=qemu-mips ;; mipsel) _qemu=qemu-mipsel ;; riscv64) _qemu=qemu-riscv64 ;; esac
    command -v "$_qemu" >/dev/null 2>&1 || { echo "сборка WARP: требуется $_qemu для проверки запуска linux-$_variant" >&2; exit 1; }
    "$_qemu" "$_binary" version >/dev/null || { echo "сборка WARP: linux-$_variant не запускается в $_qemu" >&2; exit 1; }
    mkdir -p "$_tmp/output/linux-$_variant"
    cp "$_binary" "$_tmp/output/linux-$_variant/z2k-warp-controller"
    chmod 0755 "$_tmp/output/linux-$_variant/z2k-warp-controller"
done < "$TABLE"

mkdir -p "$OUT"
_source_sha="${Z2K_SOURCE_SHA:-${GITHUB_SHA:-}}"
[ -n "$_source_sha" ] || _source_sha="$(git -C "$ROOT" rev-parse HEAD)"
case "$_source_sha" in *[!0-9a-f]*|'') echo "сборка WARP: source SHA должен быть строчным SHA-1" >&2; exit 1 ;; esac
[ "${#_source_sha}" -eq 40 ] || { echo "сборка WARP: source SHA должен содержать 40 знаков" >&2; exit 1; }
_source_run="${GITHUB_RUN_ID:-0}"
case "$_source_run" in *[!0-9]*|'') echo "сборка WARP: неверный Actions run ID" >&2; exit 1 ;; esac
_table_sha="$(sha256sum "$TABLE" | awk '{print $1}')"
_lock_sha="$(sha256sum "$CRATE/Cargo.lock" | awk '{print $1}')"
_script_sha="$(sha256sum "$ROOT/scripts/openwrt/build_warp_controller.sh" | awk '{print $1}')"
_variants="$(printf '%s\n' $_selected | sort -u | tr '\n' ',')"
_variants=${_variants%,}
_provenance_group="${Z2K_WARP_CONTROLLER_GROUP:-local}"
_all_variants_csv="$(awk 'NF == 6 && $1 !~ /^#/ {print $1}' "$TABLE" | sort -u | tr '\n' ',')"
_all_variants_csv=${_all_variants_csv%,}
if [ -z "${Z2K_WARP_CONTROLLER_GROUP:-}" ] && [ "$_variants" = "$_all_variants_csv" ]; then
    _provenance_group=merged
fi
{
    printf 'artifact_schema=1\nsource_sha=%s\nci_run_id=%s\nmatrix_group=%s\n' \
        "$_source_sha" "$_source_run" "$_provenance_group"
    if [ "$_provenance_group" = merged ]; then
        printf 'artifact_groups=arm,mips,mipsel,zig\n'
    fi
    printf 'crate=platform/openwrt/warp-controller\nbinary=z2k-warp-controller\n'
    printf 'cargo_lock_sha256=%s\ntarget_table_sha256=%s\nbuild_script_sha256=%s\n' \
        "$_lock_sha" "$_table_sha" "$_script_sha"
    printf 'stable_rustc=%s\nmips_rust_toolchain=%s\n' "$(rustc "+$_stable" --version)" "$_mips_toolchain"
    printf 'zig_version=%s\nzig_sha256=%s\narm_toolchain_sha256=%s\n' \
        "$_zig_version" "$_zig_sha256" "$_arm_sha256"
    printf 'mips_be_toolchain_sha256=%s\nmips_le_toolchain_sha256=%s\nvariants=%s\n' \
        "$_mips_be_sha256" "$_mips_le_sha256" "$_variants"
    printf 'release_profile=strip=symbols,lto=true,codegen-units=1,panic=abort\n'
    while IFS="$(printf '\t')" read -r _variant _target _linker _zig_target _cpu _std; do
        case "$_variant" in ''|\#*) continue ;; esac
        case " $_selected " in *" $_variant "*) ;; *) continue ;; esac
        printf 'target_%s=%s\nlinker_%s=%s\nzig_target_%s=%s\ncpu_%s=%s\nstd_%s=%s\n' \
            "$_variant" "$_target" "$_variant" "$_linker" "$_variant" "$_zig_target" \
            "$_variant" "$_cpu" "$_variant" "$_std"
        printf 'toolchain_%s=%s\nbinary_sha256_%s=%s\n' \
            "$_variant" "$([ "$_std" = build-std ] && printf '%s' "$_mips_toolchain" || printf '%s' "$_stable")" \
            "$_variant" "$(sha256sum "$_tmp/output/linux-$_variant/z2k-warp-controller" | awk '{print $1}')"
    done < "$TABLE"
} > "$_tmp/output/PROVENANCE"
cp -a "$_tmp/output/." "$OUT/"
echo "сборка WARP: созданы и запущены $(printf '%s\n' $_selected | wc -w | tr -d ' ') ABI-вариантов"
