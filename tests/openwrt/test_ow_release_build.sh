#!/bin/sh
# tests/openwrt/test_ow_release_build.sh - Stage 7: build gates + provenance.
# R1/R2 (§25): dirty-отказ, arg-гейты, SDK-отказ (настоящий SDK-билд без SDK
# невозможен — PARTIAL §68, гейт отказа доказан здесь). Coherence §47:
# seed.tag == manifest.current, ref существует, API-окно <= packaged API.
# write-provenance.sh — поведенческий тест формы.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-release-build"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-rbuild.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
BUILD="$REPO/scripts/openwrt/build-release.sh"

# --- R2: dirty tree -> production-отказ (детерминированно: временный мусор) ---
printf 'stage7-dirty-probe\n' > "$REPO/.stage7-dirty-probe"
_out="$(sh "$BUILD" --sdk "$T/no-sdk" --target mediatek/filogic --arch aarch64_cortex-a53 \
    --manifest "$REPO/UPDATES.json" --out "$T/dist" 2>&1)"
_rc=$?
rm -f "$REPO/.stage7-dirty-probe"
assert_eq "R2 dirty rc" "1" "$_rc"
case "$_out" in
    *"грязн"*) _t_ok ;;
    *) _t_bad "R2: отказ без слова про грязное дерево" ;;
esac
# --dev проходит МИМО dirty-гейта дальше (до следующего гейта, не в прод)
_out="$(sh "$BUILD" --dev --skip-tests --sdk "$T/no-sdk" --target mediatek/filogic \
    --arch aarch64_cortex-a53 --manifest "$REPO/UPDATES.json" --out "$T/dist" 2>&1)"
_rc=$?
assert_eq "R2 dev идёт дальше dirty" "1" "$_rc"
case "$_out" in
    *"ВНИМАНИЕ"*) _t_ok ;;
    *) _t_bad "R2: dev без громкого предупреждения" ;;
esac

# --- arg-гейты (dev+skip, чтобы не гнать сьют) ---
sh "$BUILD" --dev --skip-tests --target mediatek/filogic \
    --manifest "$REPO/UPDATES.json" --out "$T/dist" >/dev/null 2>&1
assert_eq "arch обязателен" "1" "$?"
sh "$BUILD" --dev --skip-tests --sdk "$T/no-sdk" --target mediatek/filogic \
    --arch aarch64_cortex-a53 --out "$T/dist" >/dev/null 2>&1
assert_eq "manifest обязателен" "1" "$?"

# --- SDK-гейт: нет SDK = громкий отказ, НЕ mock (R1/PARTIAL-доказательство) ---
# current фикстуры = настоящий tree current, чтобы coherence-гейты прошли
# и тест доехал ровно до SDK-отказа (а не упал раньше на seed mismatch).
_tree_cur="$(sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO/UPDATES.json" | head -1)"
printf '{\n"current": "%s",\n"platform": "openwrt",\n"install_map": {\n},\n"files_sha256": {\n},\n"history": [\n]\n}\n' \
    "$_tree_cur" > "$T/manifest.json"
_out="$(sh "$BUILD" --dev --skip-tests --sdk "$T/no-sdk" --target mediatek/filogic \
    --arch aarch64_cortex-a53 --manifest "$T/manifest.json" --out "$T/dist" 2>&1)"
_rc=$?
assert_eq "SDK-missing rc" "1" "$_rc"
case "$_out" in
    *"Mock"*) _t_ok ;;
    *) _t_bad "SDK-отказ без запрета mock-сборки" ;;
esac
# bogus-SDK (каталог без rules.mk/staging_dir) — тоже отказ
mkdir -p "$T/fake-sdk"
_out="$(sh "$BUILD" --dev --skip-tests --sdk "$T/fake-sdk" --target mediatek/filogic \
    --arch aarch64_cortex-a53 --manifest "$T/manifest.json" --out "$T/dist" 2>&1)"
assert_eq "bogus-SDK rc" "1" "$?"

# --- coherence §47: seed.tag == manifest.current (настоящий make-seed) ---
sh "$REPO/package/openwrt/make-seed.sh" "$REPO" "$T/seed.tar.gz" >/dev/null 2>&1 \
    || { echo "FAIL[ow-release-build]: make-seed" >&2; exit 1; }
_seed_tag="$(tar -xzOf "$T/seed.tar.gz" usr/lib/z2k/share/seed.meta 2>/dev/null | sed -n 's/^tag=//p' | head -1)"
_seed_ref="$(tar -xzOf "$T/seed.tar.gz" usr/lib/z2k/share/seed.meta 2>/dev/null | sed -n 's/^ref=//p' | head -1)"
_tree_cur="$(sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO/UPDATES.json" | head -1)"
assert_eq "seed.tag == tree current" "$_tree_cur" "$_seed_tag"
case "$_seed_ref" in
    ''|unknown) _t_bad "seed.ref пуст/unknown: $_seed_ref" ;;
    *) _t_ok ;;
esac
git -C "$REPO" cat-file -e "${_seed_ref}^{commit}" 2>/dev/null \
    && _t_ok || _t_bad "seed.ref нет локально: $_seed_ref"
# seed.meta внутри tarball — та же, что стартует payload (payload.meta копия)
_seed_meta="$(tar -xzOf "$T/seed.tar.gz" usr/lib/z2k/share/seed.meta 2>/dev/null)"
_pay_meta="$(tar -xzOf "$T/seed.tar.gz" usr/lib/z2k/share/payload.meta 2>/dev/null)"
assert_eq "seed.meta == payload.meta" "$_seed_meta" "$_pay_meta"

# --- write-provenance.sh: форма + обязательность полей ---
OW_RELEASE="25.12.5" SDK_URL="https://example.com/sdk.tar.zst" SDK_SHA256="UNPINNED"
SDK_DIR="/sdk" TARGET="mediatek/filogic" ARCH="aarch64_cortex-a53"
SRC_COMMIT="abc123" PKG_VERSION="0.1.0" PKG_RELEASE="1" ADAPTER_API="1"
SEED_TAG="p-2" SEED_REF="p-2" VERIFIED_REMOTE="false" MANIFEST_CURRENT="p-2"
OUT="$T/provenance.json"
export OW_RELEASE SDK_URL SDK_SHA256 SDK_DIR TARGET ARCH SRC_COMMIT
export PKG_VERSION PKG_RELEASE ADAPTER_API SEED_TAG SEED_REF
export VERIFIED_REMOTE MANIFEST_CURRENT OUT
sh "$REPO/scripts/openwrt/write-provenance.sh" >/dev/null 2>&1
assert_eq "provenance rc" "0" "$?"
python3 - "$T/provenance.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
need = ('openwrt_release sdk_url sdk_sha256 sdk_dir target arch source_commit '
        'package_version package_release adapter_api seed_tag seed_ref '
        'seed_ref_verified_remote manifest_current built_at_utc').split()
miss = [k for k in need if k not in d or d[k] in (None, '')]
if miss:
    sys.stderr.write('MISSING: %s\n' % ' '.join(miss))
    sys.exit(1)
assert d['seed_ref_verified_remote'] is False, 'bool, not string'
assert d['adapter_api'] == '1' and d['arch'] == 'aarch64_cortex-a53'
print('provenance shape ok')
PYEOF
[ "$?" = "0" ] && _t_ok || _t_bad "provenance shape"
# обязательность: без одного поля — отказ
unset ARCH
sh "$REPO/scripts/openwrt/write-provenance.sh" >/dev/null 2>&1 \
    && _t_bad "provenance: пропуск поля принят" || _t_ok

# --- §47: API-окно seed.tag над реальным манифестом <= packaged API ---
_req47="$(sh -c '. "$1/lib/auto_update.sh" >/dev/null 2>&1; . "$1/platform/openwrt/reinstall.sh" >/dev/null 2>&1; z2k_ow_manifest_api_required "$2" "$3"' sh "$REPO" "$REPO/UPDATES.json" "$_seed_tag" 2>/dev/null)"
_api47="$(grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' "$REPO/package/openwrt/ADAPTER_API" 2>/dev/null | tr -d '[:space:]')"
[ -n "$_req47" ] && [ -n "$_api47" ] && [ "$_req47" -le "$_api47" ] 2>/dev/null \
    && _t_ok || _t_bad "API-окно seed.tag ($_req47) > packaged ($_api47)"

_t_done
