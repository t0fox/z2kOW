#!/bin/sh
# scripts/openwrt/build-release.sh - Stage 7: каноническая сборка APK-релиза.
#
# Единственный entrypoint (§25). Порядок — гейты, потом работа:
#   1. clean tree (иначе отказ; обход только --dev)
#   2. Stage-тесты tests/openwrt/run.sh (иначе отказ; --dev пропускает вслух)
#   3. manifest/seed coherence (seed.tag == manifest current; ref существует;
#      API-окно seed <= packaged API; adapter.api числовой)
#   4. exact SDK (URL+sha зафиксированы ниже; нет SDK/не сошёлся sha —
#      громкий отказ, НЕ mock-сборка)
#   5. build package(s) тулчейном SDK
#   6. dist/: *.apk, sha256sums, provenance.json, METADATA.txt
#
# Использование:
#   build-release.sh --sdk DIR|auto --target mediatek/filogic --arch aarch64_cortex-a53
#     --manifest openwrt-UPDATES.json --out dist/ [--dev] [--skip-tests]
# Версия пакета — из package/openwrt/Makefile (package-only релиз =
# version-bump commit, §19/§53). dist/ НЕ коммитится (§63).
#
# POSIX sh + python3. Сеть нужна только для ls-remote ref-проверки (без сети —
# отказ, кроме --dev, где фиксируется verified_remote=false).

set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

die() { printf 'build-release: %s\n' "$1" >&2; exit 1; }
note() { printf 'build-release: %s\n' "$1"; }

SDK="auto"; TARGET=""; ARCH=""; MANIFEST=""; OUT=""; DEV=0; SKIP_TESTS=0; CI_SNAPSHOT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --sdk) SDK="$2"; shift 2 ;;
        --target) TARGET="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --dev) DEV=1; shift ;;
        --skip-tests) SKIP_TESTS=1; shift ;;
        --ci-snapshot) CI_SNAPSHOT=1; shift ;;
        --print-sdk-pin) _pin_mode=1; shift ;;
        *) die "неизвестный флаг $1" ;;
    esac
done

[ -n "$TARGET" ] || die "--target обязателен (например mediatek/filogic)"
# --- 0. SDK pin query: раньше всех остальных гейтов (ему нужен только target).
_sdk_pin_url() { _t="$1"; _f="$(printf '%s' "$_t" | tr '/' '-')"; printf 'https://downloads.openwrt.org/releases/25.12.5/targets/%s/openwrt-sdk-25.12.5-%s_gcc-14.3.0_musl.Linux-x86_64.tar.zst' "$_t" "$_f"; }
_sdk_pin_sha() { printf 'ff4a38a397caa2cfe1c39e18f84ddede14878221b3593c3f2c4cfe24e3ec4c25'; }
if [ "${_pin_mode:-0}" = "1" ]; then
    printf '%s|%s\n' "$(_sdk_pin_url "$TARGET")" "$(_sdk_pin_sha)"
    exit 0
fi
[ -n "$ARCH" ] || die "--arch обязателен явно, угадывать запрещено (§20)"
[ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || die "--manifest: нужен OpenWrt-манифест релиза"
[ -n "$OUT" ] || die "--out: нужен каталог dist"
command -v python3 >/dev/null 2>&1 || die "нужен python3"
# SEED_TMP — рано: нужен уже секции Stage-тестов (лог сьюта), а не только
# секции seed coherence. Один mktemp на весь прогон, trap — один.
SEED_TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$SEED_TMP"' EXIT INT TERM
# Версия — один источник: Makefile (package-only релиз = version-bump commit).
PKG_VERSION="$(sed -n 's/^PKG_VERSION:=\(.*\)/\1/p' "$ROOT/package/openwrt/Makefile" | head -1 | tr -d '[:space:]')"
PKG_RELEASE="$(sed -n 's/^PKG_RELEASE:=\(.*\)/\1/p' "$ROOT/package/openwrt/Makefile" | head -1 | tr -d '[:space:]')"
[ -n "$PKG_VERSION" ] && [ -n "$PKG_RELEASE" ] || die "нет PKG_VERSION/PKG_RELEASE в package/openwrt/Makefile"
note "package version: $PKG_VERSION-$PKG_RELEASE"

# --- 1. clean tree (R2) -------------------------------------------------------
# Сравнение — контентное (--ignore-cr-at-eol): stat-кэш dual-git окружения
# даёт фантомную грязь, CRLF-шум — не грязь. Настоящую грязь ловит diff.
# Плюс untracked-мусор: `git diff` его не видит вовсе, а Makefile-глобы
# (platform/openwrt/*.sh) упаковали бы его молча — R2-тест держит обе ветки.
_tree_dirty() {
    git -C "$ROOT" diff --ignore-cr-at-eol --quiet 2>/dev/null || return 0
    git -C "$ROOT" status --porcelain -uall 2>/dev/null | grep -q '^??' && return 0
    return 1
}
if _tree_dirty; then
    if [ "$DEV" = "1" ]; then
        note "ВНИМАНИЕ: грязное дерево, продолжаю только как --dev"
    else
        printf 'build-release: в дереве есть незакоммиченные правки:\n' >&2
        git -C "$ROOT" diff --ignore-cr-at-eol --name-only 2>/dev/null | sed 's/^/  /' >&2
        die "production build из грязного дерева запрещён (R2)"
    fi
fi
SRC_COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || die "не git-репозиторий"
note "source commit: $SRC_COMMIT"

# --- 2. Stage-тесты ------------------------------------------------------------
# Лог сьюта — в артефакт (не в /dev/null: иначе падение в CI недиагностируемо;
# FAIL-строки дублируем в stdout сразу).
OW_TESTS_LOG="$SEED_TMP/ow-tests.log"
if [ "$SKIP_TESTS" = "1" ]; then
    [ "$DEV" = "1" ] || die "--skip-tests только вместе с --dev"
    note "ВНИМАНИЕ: Stage-тесты пропущены (--dev)"
else
    note "Stage-тесты: sh tests/openwrt/run.sh (лог: ow-tests.log)"
    if sh "$ROOT/tests/openwrt/run.sh" >"$OW_TESTS_LOG" 2>&1; then
        note "Stage-тесты зелёные"
    else
        grep -E '^(SUITE.*fail=[1-9]|FAIL|OPENWRT)' "$OW_TESTS_LOG" 2>/dev/null | head -30 >&2 || true
        die "tests/openwrt/run.sh упал — production build запрещён (см. ow-tests.log в dist)"
    fi
fi

# --- 3. manifest/seed coherence -------------------------------------------------
MANIFEST_CURRENT="$(sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -1)"
[ -n "$MANIFEST_CURRENT" ] || die "в манифесте нет current"
# seed собираем ТУТ же, из ЭТОГО дерева (не из артефакта): состав обязан
# совпасть с тем, что поедет в пакет.
sh "$ROOT/package/openwrt/make-seed.sh" "$ROOT" "$SEED_TMP/seed.tar.gz" >/dev/null 2>&1 \
    || die "make-seed.sh упал"
SEED_TAG="$(tar -xzOf "$SEED_TMP/seed.tar.gz" usr/lib/z2k/share/seed.meta 2>/dev/null | sed -n 's/^tag=//p' | head -1)"
SEED_REF="$(tar -xzOf "$SEED_TMP/seed.tar.gz" usr/lib/z2k/share/seed.meta 2>/dev/null | sed -n 's/^ref=//p' | head -1)"
[ -n "$SEED_TAG" ] || die "в seed нет tag"
[ "$SEED_TAG" = "$MANIFEST_CURRENT" ] \
    || die "seed.tag ($SEED_TAG) != manifest current ($MANIFEST_CURRENT)"
note "seed coherence: tag=$SEED_TAG ref=$SEED_REF"
case "$SEED_REF" in
    ''|unknown|*[!0-9a-f]*) die "seed.ref не immutable ref: [$SEED_REF] (§17)" ;;
esac
git -C "$ROOT" cat-file -e "${SEED_REF}^{commit}" 2>/dev/null \
    || die "seed.ref $SEED_REF нет локально"
# remote-resolvable (§49): без сети — отказ, кроме --dev с честной пометкой.
VERIFIED_REMOTE="false"
if git ls-remote origin "$SEED_REF" 2>/dev/null | grep -q .; then
    VERIFIED_REMOTE="true"
    note "seed.ref существует на origin"
elif [ "$DEV" = "1" ]; then
    note "ВНИМАНИЕ: remote-проверка ref невозможна (--dev, verified_remote=false)"
else
    die "seed.ref $SEED_REF не виден на origin (ls-remote пуст) — immutable ref обязан скачиваться после релиза (§49)"
fi
# API-окно seed <= packaged API (§47 coherence).
ADAPTER_API="$(grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' "$ROOT/package/openwrt/ADAPTER_API" 2>/dev/null | tr -d '[:space:]')"
case "$ADAPTER_API" in
    ''|*[!0-9]*) die "package/openwrt/ADAPTER_API не целое" ;;
esac
_api_need="$(sh -c '. "$1/lib/auto_update.sh" >/dev/null 2>&1; . "$1/platform/openwrt/reinstall.sh" >/dev/null 2>&1; z2k_ow_manifest_api_required "$2" "$3"' sh "$ROOT" "$MANIFEST" "$SEED_TAG" 2>/dev/null)"
[ -n "$_api_need" ] || die "не вычислилось API-требование окна seed.tag ($SEED_TAG)"
[ "$_api_need" -le "$ADAPTER_API" ] 2>/dev/null \
    || die "окну манифеста нужен adapter API $_api_need, в пакете $ADAPTER_API — сначала поднимите ADAPTER_API (§8)"
note "adapter API coherence: need=$_api_need packaged=$ADAPTER_API"

# --- 4. exact SDK ---------------------------------------------------------------
# Пин — из функций выше (единственное место правды). Проверяется дважды:
# tarball при скачивании (CI шаг) + receipt в распакованном SDK (этот шаг —
# и на cache-hit: каталогу из кеша без чека не доверяем, §7).
OW_RELEASE="25.12.5"
SDK_URL="$(_sdk_pin_url "$TARGET")"
SDK_SHA256="$(_sdk_pin_sha)"
if [ "$SDK" = "auto" ]; then
    for _cand in "$HOME/openwrt-sdk-${OW_RELEASE}-${TARGET}" "$ROOT/.sdk"; do
        if [ -f "$_cand/rules.mk" ] && [ -d "$_cand/staging_dir" ]; then SDK="$_cand"; break; fi
    done
fi
[ -d "$SDK" ] || die "SDK не найден ($SDK). Скачайте $SDK_URL, сверьте sha256 ($SDK_SHA256), распакуйте, запишите sha в \$SDK/.sdk-sha256-verified. Mock-сборки запрещены (§68)."
[ -f "$SDK/rules.mk" ] && [ -d "$SDK/staging_dir" ] && [ -d "$SDK/package" ] \
    || die "$SDK не похож на OpenWrt SDK (нет rules.mk/staging_dir/package)"
# Receipt identity (§7): кем бы каталог ни был положен (скачивание, кеш),
# его sha обязана совпасть с пином — иначе это не тот SDK.
_sdk_receipt="$(cat "$SDK/.sdk-sha256-verified" 2>/dev/null | tr -d '[:space:]')"
if [ "$_sdk_receipt" = "$SDK_SHA256" ]; then
    note "SDK identity verified (receipt)"
    VERIFIED_SDK="true"
elif [ "$DEV" = "1" ]; then
    note "ВНИМАНИЕ: SDK receipt отсутствует/чужой (--dev, verified_sdk=false)"
    VERIFIED_SDK="false"
else
    die "SDK identity не подтверждена: нет \$SDK/.sdk-sha256-verified с $SDK_SHA256 (запишите его после сверки тарболла; кешу без чека не доверяем)"
fi
export VERIFIED_SDK
note "SDK: $SDK"

# --- 5. build --------------------------------------------------------------------
# Пакет в SDK-дерево — симлинком (исходник остаётся деревом релиза).
if [ -e "$SDK/package/z2k" ] && [ ! -L "$SDK/package/z2k" ]; then
    die "$SDK/package/z2k существует и не симлинк — уберите вручную"
fi
ln -sfn "$ROOT/package/openwrt" "$SDK/package/z2k"
note "package linked: $SDK/package/z2k -> $ROOT/package/openwrt"
# Версия пакета — из Makefile (дерево зафиксировано гейтом чистоты выше).
SDK_LOG="$SEED_TMP/sdk-build.log"
# Pristine SDK без .config собирать не умеет; дефолт SDK — его же таргет
# (явно в provenance через TARGET/ARCH, .PKGINFO-аудит ловит чужую арку).
if [ ! -f "$SDK/.config" ]; then
    note "SDK без .config — make defconfig (дефолт таргета SDK)"
    make -C "$SDK" defconfig >"$SDK_LOG.defconfig" 2>&1 \
        || die "make defconfig в SDK упал, лог: $SDK_LOG.defconfig"
fi
note "make package/z2k-adapter/compile + package/z2k-webpanel/compile ..."
if ! make -C "$SDK" "package/z2k-adapter/compile" "package/z2k-webpanel/compile" V=s >"$SDK_LOG" 2>&1; then
    die "сборка в SDK упала, лог: $SDK_LOG"
fi
note "SDK build ok"

# --- 6. dist ----------------------------------------------------------------------
rm -rf "$OUT"
mkdir -p "$OUT" || die "нет $OUT"
_found="$(find "$SDK/bin/packages" -name 'z2k-*.apk' 2>/dev/null | LC_ALL=C sort)"
[ -n "$_found" ] || die "SDK отработал, но z2k-*.apk не найдены в $SDK/bin/packages"
printf '%s\n' "$_found" | while IFS= read -r _a; do cp -f "$_a" "$OUT/" || exit 1; done
# inspect metadata БЕЗ apk-тулчейна: .apk — tar, .PKGINFO внутри читается.
# Цикл — редиректом из файла, НЕ пайпом: die/exit внутри тела обязаны ронять
# скрипт, а не молча умирать в подоболочке.
printf '%s\n' "$_found" > "$SEED_TMP/apks.txt"
: > "$OUT/METADATA.txt" || die "нет $OUT/METADATA.txt"
while IFS= read -r _a; do
    [ -n "$_a" ] || continue
    printf 'package from %s built %s\nmetadata:\n' "$_a" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$OUT/METADATA.txt"
    tar -tzf "$_a" 2>/dev/null | LC_ALL=C sort >> "$OUT/METADATA.txt" || \
        die "не читается tar-список $_a"
    printf '\n.PKGINFO:\n' >> "$OUT/METADATA.txt"
    tar -xzOf "$_a" .PKGINFO 2>/dev/null >> "$OUT/METADATA.txt" \
        || tar -xzOf "$_a" ./.PKGINFO 2>/dev/null >> "$OUT/METADATA.txt" \
        || die "в $_a нет .PKGINFO"
    printf '\n---\n' >> "$OUT/METADATA.txt"
done < "$SEED_TMP/apks.txt"
( cd "$OUT" && sha256sum z2k-*.apk > sha256sums )
if [ -f "$OW_TESTS_LOG" ]; then
    cp -f "$OW_TESTS_LOG" "$OUT/ow-tests.log" 2>/dev/null || true
fi
note "dist: $(ls "$OUT" | tr '\n' ' ')"
# provenance.json — machine-readable (§24, формат владеет write-provenance.sh).
# CI snapshot (§4): тот же implementation, но provenance честно маркирует
# disposable-артефакт (ci_snapshot=true, production_release=false);
# production_release=true — только не-dev и не-ci прогон до конца.
export OW_RELEASE SDK_URL SDK_SHA256
export SDK_DIR="$SDK" TARGET ARCH SRC_COMMIT PKG_VERSION PKG_RELEASE
export ADAPTER_API SEED_TAG SEED_REF VERIFIED_REMOTE MANIFEST_CURRENT
export CI_SNAPSHOT="$CI_SNAPSHOT"
if [ "$CI_SNAPSHOT" = "1" ] || [ "$DEV" = "1" ]; then
    PRODUCTION_RELEASE="0"
else
    PRODUCTION_RELEASE="1"
fi
export PRODUCTION_RELEASE
export OUT="$OUT/provenance.json"
sh "$ROOT/scripts/openwrt/write-provenance.sh" || die "provenance не записался"
note "dist готов: $OUT (provenance.json + sha256sums + METADATA.txt)"