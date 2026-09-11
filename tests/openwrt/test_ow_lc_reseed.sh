#!/bin/sh
# tests/openwrt/test_ow_lc_reseed.sh - Level C: re-seed crash matrix (§11).
# Каждый провал обязан оставить marker ABSENT (I1); повтор сходится или
# fails loudly, но никогда не заявляет verified. Плюс mismatch/adopt.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-lc-reseed"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LC_REPO="$REPO"; export LC_REPO
. "$(dirname "$0")/lc_harness.sh"
lc_init || { echo "FAIL[ow-lc-reseed]: init" >&2; exit 1; }
trap 'rm -rf "$LC_T"' EXIT INT TERM
# SYS — алиас harness-рута. КРИТИЧНО: без него rm -rf "$SYS/..." превращается
# в rm -rf "/..." (уже чуть не снесло /usr в WSL — ловит tripwire ниже).
SYS="$LC_T/sys"; export SYS
[ "$SYS" = "$LC_SYS" ] || { echo "FAIL[ow-lc-reseed]: SYS!=LC_SYS" >&2; exit 1; }

_new_sysroot() {
    lc_fresh_sysroot || { echo "FAIL[ow-lc-reseed]: sysroot" >&2; exit 1; }
    SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"
    export Z2K_SEED_DEST="$LC_SYS"
}

# --- crash 1: tarball отсутствует (extract невозможен) ---
# tag НАМЕРЕННО оставляем stale: провал re-seed обязан его снять (I2)
_new_sysroot
rm -rf "$SYS/usr"; mkdir -p "$Z2K_ROOT/share"
rm -f "$Z2K_ETC/.payload-initialized"
Z2K_SEED_TARBALL="$LC_T/no-such.tar.gz"; export Z2K_SEED_TARBALL
z2k_ow_seed_ensure >/dev/null 2>&1 && _t_bad "без tarball принято" || _t_ok
assert_eq "c1 marker absent" "0" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
assert_eq "c1 stale tag снят" "0" "$([ -f "$Z2K_ETC/state/installed-tag" ] && echo 1 || echo 0)"
lc_invariant "c1-post" || _t_bad "c1 invariant"

# --- crash 2: tarball битый (extract падает на полпути), tag stale ---
_new_sysroot
rm -rf "$SYS/usr"; mkdir -p "$Z2K_ROOT/share"
ln -s "$REPO/package/openwrt/files/etc/z2k/config.default" "$Z2K_ROOT/share/config.default"
rm -f "$Z2K_ETC/.payload-initialized"
printf 'NOT-A-TARBALL' > "$LC_T/bad.tar.gz"
Z2K_SEED_TARBALL="$LC_T/bad.tar.gz"; export Z2K_SEED_TARBALL
z2k_ow_seed_ensure >/dev/null 2>&1 && _t_bad "битый tarball принят" || _t_ok
assert_eq "c2 marker absent" "0" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
assert_eq "c2 tag снят (не stale)" "0" "$([ -f "$Z2K_ETC/state/installed-tag" ] && echo 1 || echo 0)"
lc_invariant "c2-post" || _t_bad "c2 invariant"

# --- crash 3: bootstrap падает (нет config.default) -> retry чинит ---
# tag stale оставляем: провал должен его снять, retry — записать seed
_new_sysroot
rm -rf "$SYS/usr"; mkdir -p "$Z2K_ROOT/share"
rm -f "$Z2K_ETC/.payload-initialized" "$Z2K_ETC/config"
Z2K_SEED_TARBALL="$Z2K_ROOT/share/seed.tar.gz"; export Z2K_SEED_TARBALL
cp -f "$LC_SEED_TARBALL" "$Z2K_SEED_TARBALL" 2>/dev/null || true
# tarball есть (положим настоящий), а config.default НЕТ
rm -f "$Z2K_ROOT/share/config.default"
cp -f "$LC_SEED_TARBALL" "$LC_T/good.tar.gz"
Z2K_SEED_TARBALL="$LC_T/good.tar.gz"; export Z2K_SEED_TARBALL
z2k_ow_seed_ensure >/dev/null 2>&1 && _t_bad "без config.default принято" || _t_ok
assert_eq "c3 marker absent" "0" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
assert_eq "c3 stale tag снят" "0" "$([ -f "$Z2K_ETC/state/installed-tag" ] && echo 1 || echo 0)"
ln -s "$REPO/package/openwrt/files/etc/z2k/config.default" "$Z2K_ROOT/share/config.default"
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-lc-reseed]: c3 retry" >&2; exit 1; }
assert_eq "c3 retry marker" "1" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
lc_invariant "c3-post" || _t_bad "c3 invariant"

# --- crash 4: verify падает (seed без required файла) ---
_new_sysroot
rm -rf "$SYS/usr"; mkdir -p "$Z2K_ROOT/share"
ln -s "$REPO/package/openwrt/files/etc/z2k/config.default" "$Z2K_ROOT/share/config.default"
rm -f "$Z2K_ETC/.payload-initialized" "$Z2K_ETC/state/installed-tag"
# tarball без lib/utils.sh: extract ok, verify — нет
T4="$LC_T/thin"; rm -rf "$T4"; mkdir -p "$T4/usr/lib/z2k/share"
tar -xzf "$LC_SEED_TARBALL" -C "$T4" 2>/dev/null
rm -f "$T4/usr/lib/z2k/lib/utils.sh"
tar -czf "$LC_T/thin.tar.gz" -C "$T4" usr 2>/dev/null
Z2K_SEED_TARBALL="$LC_T/thin.tar.gz"; export Z2K_SEED_TARBALL
z2k_ow_seed_ensure >/dev/null 2>&1 && _t_bad "неполный seed принят" || _t_ok
assert_eq "c4 marker absent" "0" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
lc_invariant "c4-post" || _t_bad "c4 invariant"

# --- crash 5: tag-write падает (read-only state) -> marker absent; retry ok ---
_new_sysroot
rm -rf "$SYS/usr"; mkdir -p "$Z2K_ROOT/share"
ln -s "$REPO/package/openwrt/files/etc/z2k/config.default" "$Z2K_ROOT/share/config.default"
rm -f "$Z2K_ETC/.payload-initialized" "$Z2K_ETC/state/installed-tag"
cp -f "$LC_SEED_TARBALL" "$LC_T/good2.tar.gz"
Z2K_SEED_TARBALL="$LC_T/good2.tar.gz"; export Z2K_SEED_TARBALL
chmod 555 "$Z2K_ETC/state" || exit 1
z2k_ow_seed_ensure >/dev/null 2>&1 && _t_bad "ro-state принят" || _t_ok
assert_eq "c5 marker absent" "0" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
chmod 755 "$Z2K_ETC/state" || exit 1
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-lc-reseed]: c5 retry" >&2; exit 1; }
assert_eq "c5 retry marker" "1" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
lc_invariant "c5-post" || _t_bad "c5 invariant"

# --- mismatch: tag/stale + meta fresh -> reconcile к meta ---
_new_sysroot
printf 'p-00.00\n' > "$Z2K_ETC/state/installed-tag"
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-lc-reseed]: mismatch" >&2; exit 1; }
SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"
assert_eq "mismatch tag:=meta" "$SEEDTAG" "$(cat "$Z2K_ETC/state/installed-tag")"
lc_invariant "mismatch-post" || _t_bad "mismatch invariant"

_t_done
