#!/bin/sh
# tests/openwrt/test_ow_seed.sh - Gap 1: seed только для пустой установки.
# Функционально на РЕАЛЬНОМ tarball (make-seed.sh) в sysroot:
#   fresh -> extract + marker; повтор -> без извлечения;
#   upgrade (новый seed + updater-правки) -> payload побайтово цел;
#   failed bootstrap -> без marker; retry -> снова идёт;
#   marker + битый payload -> громкий провал без авто-recovery.
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

# настоящий seed из дерева
"$REPO/package/openwrt/make-seed.sh" "$REPO" "$Z2K_SEED_TARBALL" >/dev/null 2>&1 \
    || { echo "FAIL[ow-seed]: make-seed" >&2; exit 1; }
assert_file "seed собран" "$Z2K_SEED_TARBALL"
# share/ для bootstrap (config.default; сам tarball не нужен внутри sysroot)
mkdir -p "$Z2K_ROOT/share"
ln -s "$REPO/package/openwrt/files/etc/z2k/config.default" "$Z2K_ROOT/share/config.default"

# --- 1. fresh install ---
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-seed]: fresh ensure" >&2; exit 1; }
_t_ok
assert_eq "marker встал" "1" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
assert_eq "config из дефолта" "1" "$([ -f "$Z2K_CONFIG" ] && echo 1 || echo 0)"
z2k_ow_payload_ok && _t_ok || _t_bad "payload не верифицируется после fresh"
# seed.meta извлечён и описывает seed
assert_file "seed.meta" "$Z2K_ROOT/share/seed.meta"
assert_contains "meta platform" "$Z2K_ROOT/share/seed.meta" "platform=openwrt"
_want_tag="$(sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO/UPDATES.json" | head -1)"
assert_contains "meta tag" "$Z2K_ROOT/share/seed.meta" "tag=$_want_tag"
# installed-tag записан ИЗ meta (фаза A: никакого false-current)
assert_eq "tag из seed" "$_want_tag" "$(cat "$Z2K_ETC/state/installed-tag" 2>/dev/null)"

# --- 2+3. повтор и upgrade: updater-пayload сохраняется побайтово ---
echo "# updater modification" >> "$Z2K_ROOT/lib/utils.sh"
echo "# updater modification" >> "$Z2K_ROOT/lua/z2k-alert.lua"
_sum_lib="$(cksum "$Z2K_ROOT/lib/utils.sh")"
_sum_lua="$(cksum "$Z2K_ROOT/lua/z2k-alert.lua")"
# "новый seed из пакета": другой tarball — извлечение всё равно пропущено
# (иначе распаковка затерла бы updater-правки: cksum бы изменился).
"$REPO/package/openwrt/make-seed.sh" "$REPO" "$T/seed2.tar.gz" >/dev/null 2>&1 || exit 1
Z2K_SEED_TARBALL="$T/seed2.tar.gz"; export Z2K_SEED_TARBALL
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-seed]: upgrade ensure" >&2; exit 1; }
assert_eq "updater-правка lib цела" "$_sum_lib" "$(cksum "$Z2K_ROOT/lib/utils.sh")"
assert_eq "updater-правка lua цела" "$_sum_lua" "$(cksum "$Z2K_ROOT/lua/z2k-alert.lua")"

# --- 4+5. failed bootstrap -> без marker; retry идёт ---
rm -f "$Z2K_ETC/.payload-initialized" "$Z2K_ROOT/share/config.default" "$Z2K_CONFIG"
Z2K_SEED_TARBALL="$T/seed.tar.gz"; export Z2K_SEED_TARBALL
rm -rf "$SYS/usr" # будто ничего не было (кроме /etc без marker)
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

# --- 6. marker + битый payload -> громко, без авто-recovery ---
rm -f "$Z2K_ROOT/lib/utils.sh"
if z2k_ow_seed_ensure >/dev/null 2>&1; then
    _t_bad "битый payload с marker молча принят"
else
    _t_ok
fi
assert_eq "marker на месте (repair вручную)" "1" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
assert_eq "payload НЕ восстановлен тихо" "0" "$([ -f "$Z2K_ROOT/lib/utils.sh" ] && echo 1 || echo 0)"

# --- 7. существующий tag никогда не перетирается seed (иначе upgrade со
# старым seed откатил бы версию молча) ---
printf 'p-99.99\n' > "$Z2K_ETC/state/installed-tag"
tar -xzf "$Z2K_SEED_TARBALL" -C "$Z2K_SEED_DEST" >/dev/null 2>&1 # чиним payload вручную (repair)
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-seed]: repair ensure" >&2; exit 1; }
assert_eq "tag не тронут seed" "p-99.99" "$(cat "$Z2K_ETC/state/installed-tag")"

# --- 8. prerm-purge/sysupgrade repair: marker + пустой payload + tag цел ---
# -> extract, tag PRESERVED (никакого отката версии), marker остаётся
rm -rf "$SYS/usr"
mkdir -p "$Z2K_ROOT/share"
ln -s "$REPO/package/openwrt/files/etc/z2k/config.default" "$Z2K_ROOT/share/config.default"
z2k_ow_seed_ensure >/dev/null 2>&1 || { echo "FAIL[ow-seed]: purge repair" >&2; exit 1; }
_t_ok
assert_eq "tag пережил purge-repair" "p-99.99" "$(cat "$Z2K_ETC/state/installed-tag")"
z2k_ow_payload_ok && _t_ok || _t_bad "payload не восстановлен после purge"

_t_done
