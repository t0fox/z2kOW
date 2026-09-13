#!/bin/sh
# tests/openwrt/test_ow_seed.sh - seed transaction + reconcile матрица.
# Функционально на РЕАЛЬНОМ tarball (make-seed.sh) в sysroot:
#   fresh -> extract + marker + tag=seed + meta;
#   повтор/upgrade (без re-seed) -> payload+tag+meta побайтово целы;
#   failed bootstrap -> без marker; retry идёт;
#   marker + partial -> invalidate marker + fail;
#   re-seed ВСЕГДА переписывает tag := seed.meta.tag (I3);
#   mismatch tag/meta -> reconcile; adopt без meta; crash на каждом шаге.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-seed"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-seed.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

AD="$REPO/platform/openwrt"
SYS="$T/sys"
export Z2K_ROOT="$SYS/usr/lib/z2k" Z2K_ETC="$SYS/etc/z2k" Z2K_TMP="$SYS/tmp/z2k"
export Z2K_SEED_TARBALL="$T/seed.tar.gz" Z2K_SEED_DEST="$SYS"
unset ZAPRET2_DIR CONFIG_DIR LISTS_DIR Z2K_CONFIG_FILE
. "$AD/paths.sh"
. "$AD/env.sh"
. "$AD/bootstrap.sh"

# настоящий seed из дерева (явный sh: индекс хранит 100644, прямой запуск
# в Linux-чекауте падает Permission denied — см. drift-тест)
sh "$REPO/package/openwrt/make-seed.sh" "$REPO" "$Z2K_SEED_TARBALL" >/dev/null 2>&1 \
    || { echo "FAIL[ow-seed]: make-seed" >&2; exit 1; }
assert_file "seed собран" "$Z2K_SEED_TARBALL"
# share/ для bootstrap (config.default; сам tarball не нужен внутри sysroot)
mkdir -p "$Z2K_ROOT/share"
ln -s "$REPO/package/openwrt/files/etc/z2k/config.default" "$Z2K_ROOT/share/config.default"
_want_tag="$(sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO/UPDATES.json" | head -1)"

# --- 1. fresh install: extract + marker + tag=seed + meta ---
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-seed]: fresh ensure" >&2; exit 1; }
_t_ok
assert_eq "marker встал" "1" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
assert_eq "config из дефолта" "1" "$([ -f "$Z2K_CONFIG" ] && echo 1 || echo 0)"
z2k_ow_payload_ok && _t_ok || _t_bad "payload не верифицируется после fresh"
assert_file "seed.meta" "$Z2K_ROOT/share/seed.meta"
assert_file "payload.meta" "$Z2K_ROOT/share/payload.meta"
assert_contains "meta platform" "$Z2K_ROOT/share/payload.meta" "platform=openwrt"
assert_eq "tag из seed" "$_want_tag" "$(cat "$Z2K_ETC/state/installed-tag" 2>/dev/null)"
assert_eq "meta.tag из seed" "$_want_tag" "$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/payload.meta" | head -1)"

# --- 2+3. повтор и upgrade БЕЗ re-seed: всё побайтово цело (I5) ---
echo "# updater modification" >> "$Z2K_ROOT/lib/utils.sh"
echo "# updater modification" >> "$Z2K_ROOT/lua/z2k-alert.lua"
_sum_lib="$(cksum "$Z2K_ROOT/lib/utils.sh")"
_sum_lua="$(cksum "$Z2K_ROOT/lua/z2k-alert.lua")"
_sum_tag="$(cksum "$Z2K_ETC/state/installed-tag")"
_sum_meta="$(cksum "$Z2K_ROOT/share/payload.meta")"
sh "$REPO/package/openwrt/make-seed.sh" "$REPO" "$T/seed2.tar.gz" >/dev/null 2>&1 || exit 1
Z2K_SEED_TARBALL="$T/seed2.tar.gz"; export Z2K_SEED_TARBALL
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-seed]: upgrade ensure" >&2; exit 1; }
assert_eq "updater-правка lib цела" "$_sum_lib" "$(cksum "$Z2K_ROOT/lib/utils.sh")"
assert_eq "updater-правка lua цела" "$_sum_lua" "$(cksum "$Z2K_ROOT/lua/z2k-alert.lua")"
assert_eq "tag не тронут без re-seed" "$_sum_tag" "$(cksum "$Z2K_ETC/state/installed-tag")"
assert_eq "meta не тронута без re-seed" "$_sum_meta" "$(cksum "$Z2K_ROOT/share/payload.meta")"

# --- 4+5. failed bootstrap -> без marker; retry идёт ---
rm -f "$Z2K_ETC/.payload-initialized" "$Z2K_ROOT/share/config.default" "$Z2K_CONFIG"
Z2K_SEED_TARBALL="$T/seed.tar.gz"; export Z2K_SEED_TARBALL
rm -rf "${SYS:?}/usr" # будто ничего не было (кроме /etc без marker)
mkdir -p "$Z2K_ROOT/share"
if z2k_ow_seed_ensure >/dev/null 2>&1; then
    _t_bad "ensure успешен без config.default (должен падать)"
else
    _t_ok
fi
assert_eq "marker отсутствует после провала" "0" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
ln -s "$REPO/package/openwrt/files/etc/z2k/config.default" "$Z2K_ROOT/share/config.default"
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-seed]: retry" >&2; exit 1; }
assert_eq "retry ставит marker" "1" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"

# --- 6. marker + partial -> invalidate marker + fail (не preserve!) ---
rm -f "$Z2K_ROOT/lib/utils.sh"
if z2k_ow_seed_ensure >/dev/null 2>&1; then
    _t_bad "битый payload с marker молча принят"
else
    _t_ok
fi
assert_eq "marker СНЯТ (не verified)" "0" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
assert_eq "payload НЕ восстановлен тихо" "0" "$([ -f "$Z2K_ROOT/lib/utils.sh" ] && echo 1 || echo 0)"

# --- 7. re-seed ПЕРЕПИСЫВАЕТ tag := seed (I3), даже поверх более нового ---
# (repair после кейса 6: marker нет + partial -> re-seed с нуля)
printf 'p-99.99\n' > "$Z2K_ETC/state/installed-tag"
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-seed]: reseed ensure" >&2; exit 1; }
assert_eq "tag стал seed (не p-99.99)" "$_want_tag" "$(cat "$Z2K_ETC/state/installed-tag")"
assert_eq "meta стала seed" "$_want_tag" "$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/payload.meta" | head -1)"
assert_eq "marker снова встал" "1" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"

# --- 8. prerm-purge/sysupgrade repair: marker + пустой payload ---
# -> re-seed, tag := seed (НЕ preserve! старое поведение удалено как
# false-current, см. I3).
rm -rf "${SYS:?}/usr"
mkdir -p "$Z2K_ROOT/share"
ln -s "$REPO/package/openwrt/files/etc/z2k/config.default" "$Z2K_ROOT/share/config.default"
printf 'p-99.99\n' > "$Z2K_ETC/state/installed-tag"
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-seed]: purge repair" >&2; exit 1; }
_t_ok
assert_eq "tag стал seed после purge" "$_want_tag" "$(cat "$Z2K_ETC/state/installed-tag")"
z2k_ow_payload_ok && _t_ok || _t_bad "payload не восстановлен после purge"

# --- 9. mismatch tag/meta чинится reconcile (meta новее) ---
printf 'p-00.00\n' > "$Z2K_ETC/state/installed-tag"
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-seed]: reconcile ensure" >&2; exit 1; }
assert_eq "tag подтянут к meta" "$_want_tag" "$(cat "$Z2K_ETC/state/installed-tag")"

# --- 10. adopt: meta нет + tag есть + payload ok -> meta := tag ---
rm -f "$Z2K_ROOT/share/payload.meta"
printf 'p-88.88\n' > "$Z2K_ETC/state/installed-tag"
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-seed]: adopt ensure" >&2; exit 1; }
assert_eq "meta усыновлена из tag" "p-88.88" "$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/payload.meta" | head -1)"
assert_eq "tag не тронут при adopt" "p-88.88" "$(cat "$Z2K_ETC/state/installed-tag")"
# возврат к консистентности для следующих кейсов
tar -xzf "$Z2K_SEED_TARBALL" -C "$Z2K_SEED_DEST" >/dev/null 2>&1
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-seed]: re-sync" >&2; exit 1; }

# --- 11. crash-матрица re-seed: после каждого провала marker отсутствует ---
# (a) битый tarball
printf 'p-88.88\n' > "$Z2K_ETC/state/installed-tag"
rm -rf "${SYS:?}/usr"; mkdir -p "$Z2K_ROOT/share"
ln -s "$REPO/package/openwrt/files/etc/z2k/config.default" "$Z2K_ROOT/share/config.default"
rm -f "$Z2K_ETC/.payload-initialized"
printf 'NOT-A-TARBALL' > "$T/bad.tar.gz"
Z2K_SEED_TARBALL="$T/bad.tar.gz"; export Z2K_SEED_TARBALL
z2k_ow_seed_ensure >/dev/null 2>&1 && _t_bad "битый tarball принят" || _t_ok
assert_eq "a: marker absent" "0" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
# (b) read-only state dir (tag-write падает)
Z2K_SEED_TARBALL="$T/seed.tar.gz"; export Z2K_SEED_TARBALL
chmod 555 "$Z2K_ETC/state" || exit 1
z2k_ow_seed_ensure >/dev/null 2>&1 && _t_bad "ro-state принят" || _t_ok
assert_eq "b: marker absent" "0" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
chmod 755 "$Z2K_ETC/state" || exit 1
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-seed]: retry после ro" >&2; exit 1; }
assert_eq "b: retry ставит marker" "1" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
# (c) meta нет + tag нет + payload иначе ok -> re-seed восстанавливает ОБА
# (meta приезжает с extract; это recovery, не провал: marker absent означает,
# что verified-версий терять нечего)
rm -f "$Z2K_ROOT/share/payload.meta" "$Z2K_ROOT/share/seed.meta" "$Z2K_ETC/state/installed-tag"
rm -f "$Z2K_ETC/.payload-initialized"
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-seed]: meta+tag recovery" >&2; exit 1; }
assert_eq "c: tag восстановлен" "$_want_tag" "$(cat "$Z2K_ETC/state/installed-tag" 2>/dev/null)"
assert_eq "c: marker встал" "1" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
# (d) reconcile-fail изолированно: meta битая + tag нет (payload ok) -> fail
printf 'garbage-no-tag-line\n' > "$Z2K_ROOT/share/payload.meta"
rm -f "$Z2K_ETC/state/installed-tag" "$Z2K_ETC/.payload-initialized"
z2k_ow_seed_ensure >/dev/null 2>&1 && _t_bad "битая meta + нет tag приняты" || _t_ok
assert_eq "d: marker absent" "0" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"

_t_done
