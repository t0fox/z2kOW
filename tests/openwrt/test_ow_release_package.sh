#!/bin/sh
# tests/openwrt/test_ow_release_package.sh - Stage 7: пакет как артефакт.
# §20 arch-proof (ELF-scan seed), §58 metadata, §52 binary ownership,
# R4 upgrade-no-reseed, R16 uninstall/reinstall, R17 WARP absent, R18
# webpanel independence.
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/lc_harness.sh"
_t_plan "ow-release-package"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-rpkg.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
MK="$REPO/package/openwrt/Makefile"

# --- §20: PKGARCH:=all + ELF-proof seed ---
assert_contains "pkg arch all" "$MK" "PKGARCH:=all"
# явный sh: индекс хранит 100644, прямой запуск в Linux-чекауте
# падает Permission denied (см. drift-тест)
sh "$REPO/package/openwrt/make-seed.sh" --list "$REPO" > "$T/seedlist.txt" 2>/dev/null \
    || { echo "FAIL[ow-release-package]: seed list" >&2; exit 1; }
python3 - "$T/seedlist.txt" "$REPO" <<'PYEOF'
import sys
bad = []
names = ('tg-mtproxy-client', 'z2k-rt-proxy', 'z2k-detect', 'z2k-warpd', 'z2k-verify')
for ln in open(sys.argv[1], encoding='utf-8'):
    ln = ln.rstrip('\n')
    if not ln or '\t' not in ln:
        continue
    src, _dst = ln.split('\t', 1)
    p = sys.argv[2] + '/' + src
    try:
        with open(p, 'rb') as f:
            head = f.read(4)
    except OSError:
        bad.append(src + ' (unreadable)')
        continue
    if head[:4] == b'\x7fELF':
        bad.append(src + ' (ELF!)')
    base = src.rsplit('/', 1)[-1]
    if base in names:
        bad.append(src + ' (engine binary in seed!)')
    if '/builds/' in src or '/bin/' in src:
        bad.append(src + ' (build/bin path in seed!)')
if bad:
    sys.stderr.write('SEED-BAD:\n' + '\n'.join(bad) + '\n')
    sys.exit(1)
print('seed: arch-independent, no engine binaries')
PYEOF
[ "$?" = "0" ] && _t_ok || _t_bad "seed: arch/binaries proof"

# --- §58: metadata статика ---
assert_contains "pkg postinst" "$MK" "Package/z2k-adapter/postinst"
assert_contains "pkg prerm" "$MK" "Package/z2k-adapter/prerm"
assert_contains "pkg core deps" "$MK" "DEPENDS:=+kmod-nft-queue +kmod-tun +conntrack"
assert_contains "pkg webpanel deps" "$MK" "DEPENDS:=z2k-adapter +lighttpd"
assert_contains "pkg seed stanza" "$MK" "seed.tar.gz"
assert_contains "pkg adapter.api stanza" "$MK" "share/adapter.api"
# install-станзы без /opt (пакет не пишет в keenetic-корни)
awk '/^define Package.*\/install/{inb=1} inb{print} /^endef/{if(inb) inb=0}' "$MK" \
    | grep -q '/opt' 2>/dev/null \
    && _t_bad "pkg: /opt в install-станзах" || _t_ok
# webpanel-станза ставит ТОЛЬКО init (R18: удаление пакета не трогает core).
# Считаем файловые установки (INSTALL_BIN/DATA), не INSTALL_DIR каталогов.
_nwp="$(awk '/^define Package\/z2k-webpanel\/install/{inb=1; next} inb&&/^endef/{inb=0} inb&&/INSTALL_(BIN|DATA)/{c++} END{print c+0}' "$MK")"
assert_eq "pkg webpanel: только init" "1" "$_nwp"

# --- R4: upgrade при здоровом payload = noop (байты + tag) ---
LC_REPO="$REPO"
lc_init || { echo "FAIL[ow-release-package]: init" >&2; exit 1; }
lc_fresh_sysroot || exit 1
SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"
# seed.tar.gz — package-owned: across upgrade он ДРУГОЙ by design, из сравнения вон.
_before="$(cd "$LC_SYS" && find ./usr/lib/z2k ./etc/z2k -type f -not -name 'seed.tar.gz' -exec sha256sum {} + 2>/dev/null | LC_ALL=C sort | sha256sum | awk '{print $1}')"
_tag_before="$(lc_tag)"
# package upgrade со СТАРЫМ seed внутри: подменяем tarball мусором
printf 'stale-seed-bytes\n' > "$Z2K_ROOT/share/seed.tar.gz"
lc_postinst || exit 1
_after="$(cd "$LC_SYS" && find ./usr/lib/z2k ./etc/z2k -type f -not -name 'seed.tar.gz' -exec sha256sum {} + 2>/dev/null | LC_ALL=C sort | sha256sum | awk '{print $1}')"
assert_eq "R4 tag цел" "$_tag_before" "$(lc_tag)"
assert_eq "R4 payload байт-в-байт" "$_before" "$_after"
lc_invariant "R4" || _t_bad "R4 invariant"

# --- R5: old updater-owned panel + new package snapshot ----------------------
# Reproduce the live defect: package files are new, but an initialized payload
# still has the old executable CGI. The CI snapshot must use the existing
# verified reinstall path; without a snapshot the package must fail closed and
# leave the old CGI untouched.
lc_fresh_sysroot || exit 1
cp -f "$REPO/package/openwrt/PANEL_API" "$Z2K_ROOT/share/panel.api" || exit 1
. "$Z2K_ROOT/platform/openwrt/webpanel.sh" || exit 1
. "$Z2K_ROOT/platform/openwrt/reinstall.sh" || exit 1
_old_actions="$(sha256sum "$Z2K_ROOT/webpanel/cgi/actions.sh" | awk '{print $1}')"
sed -i 's/^Z2K_OPENWRT_PANEL_CONTRACT=1$/# old updater-owned payload/' \
    "$Z2K_ROOT/webpanel/cgi/actions.sh"
sed -i 's/local engine="${Z2K_NFQWS2:-\$ZAPRET2_DIR\/nfq2\/nfqws2}"/local engine="\$ZAPRET2_DIR\/nfq2\/nfqws2"/' \
    "$Z2K_ROOT/webpanel/cgi/actions.sh"
sed -i '/^Z2K_NFQWS2=/d' "$Z2K_ROOT/webpanel/cgi/platform.sh"
_stale_actions="$(sha256sum "$Z2K_ROOT/webpanel/cgi/actions.sh" | awk '{print $1}')"
if z2k_ow_panel_payload_compatible; then _t_bad "R5 old panel was accepted"; else _t_ok; fi

# Origin contains only the two updater-owned bytes needed to repair this
# regression. The real full manifest format is still parsed by common
# reinstall code; the WARP digest is a structural snapshot witness.
for _f in webpanel/cgi/actions.sh webpanel/cgi/platform.sh; do
    mkdir -p "$LC_ORIGIN/files/$(dirname "$_f")"
    cp -f "$REPO/$_f" "$LC_ORIGIN/files/$_f" || exit 1
done
printf 'p-85.2|patch|snapshot-ref|webpanel/cgi/actions.sh,webpanel/cgi/platform.sh||false|false\n' \
    | lc_manifest p-85.2
python3 - "$LC_ORIGIN/manifest.json" <<'PYEOF'
import sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    s = f.read()
needle = '  "files_sha256": {\n'
entry = '    "z2k-warpd/builds/z2k-warpd-linux-arm64": "' + ('0' * 64) + '",\n'
if needle not in s:
    raise SystemExit('files_sha256 block is not in production format')
with open(p, 'w', encoding='utf-8') as f:
    f.write(s.replace(needle, needle + entry, 1))
PYEOF
cp -f "$LC_ORIGIN/manifest.json" "$Z2K_ROOT/share/snapshot-manifest.json"
printf '0123456789abcdef0123456789abcdef01234567\n' > "$Z2K_ROOT/share/snapshot-commit"
# A stale initialized payload may still carry every structural marker.  The
# embedded snapshot must reject its changed bytes before reinstall is attempted.
cp -f "$REPO/webpanel/cgi/actions.sh" "$Z2K_ROOT/webpanel/cgi/actions.sh"
cp -f "$REPO/webpanel/cgi/platform.sh" "$Z2K_ROOT/webpanel/cgi/platform.sh"
printf '\n# stale initialized panel payload\n' >> "$Z2K_ROOT/webpanel/cgi/actions.sh"
if z2k_ow_panel_payload_compatible; then _t_bad "R5 hash-stale panel was accepted"; else _t_ok; fi
_out="$(z2k_ow_panel_payload_sync 2>&1)"; _rc=$?
assert_eq "R5 snapshot repair rc" "0" "$_rc"
assert_contains "R5 marker restored" "$Z2K_ROOT/webpanel/cgi/actions.sh" 'Z2K_OPENWRT_PANEL_CONTRACT=1'
assert_contains "R5 canonical engine restored" "$Z2K_ROOT/webpanel/cgi/actions.sh" 'Z2K_NFQWS2'
assert_eq "R5 panel payload changed" "0" "$([ "$_stale_actions" = "$(sha256sum "$Z2K_ROOT/webpanel/cgi/actions.sh" | awk '{print $1}')" ] && echo 1 || echo 0)"

# No embedded snapshot: production delivery is the signed updater's job, so
# package postinst reports an incompatibility and preserves stale executable.
sed -i 's/^Z2K_OPENWRT_PANEL_CONTRACT=1$/# old updater-owned payload/' \
    "$Z2K_ROOT/webpanel/cgi/actions.sh"
rm -f "$Z2K_ROOT/share/snapshot-manifest.json" "$Z2K_ROOT/share/snapshot-commit"
_stale_after="$(sha256sum "$Z2K_ROOT/webpanel/cgi/actions.sh" | awk '{print $1}')"
_out="$(z2k_ow_panel_payload_sync 2>&1)"; _rc=$?
assert_eq "R5 production mismatch rc" "1" "$_rc"
case "$_out" in *PANEL_PAYLOAD_MISMATCH*) _t_ok ;; *) _t_bad "R5 mismatch message" ;; esac
assert_eq "R5 stale payload preserved" "$_stale_after" "$(sha256sum "$Z2K_ROOT/webpanel/cgi/actions.sh" | awk '{print $1}')"

# --- R16: uninstall/reinstall — данные целы, дубликатов нет ---
lc_fresh_sysroot || exit 1
SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"
printf 'ENABLED=1\nMYOPT=42\n' > "$Z2K_ETC/config"
printf 'aa:bb:cc:dd:ee:ff\n' > "$Z2K_USER_LISTS/whitelist.txt"
mkdir -p "$Z2K_STATE/warp" "$Z2K_ETC/webpanel"
printf '{"id":"warp-id-keep","addr":"172.16.9.9"}\n' > "$Z2K_STATE/warp/device.json"
printf '8088\n' > "$Z2K_ETC/webpanel/port"
_cfg_before="$(sha256sum "$Z2K_ETC/config" | awk '{print $1}')"
_wl_before="$(sha256sum "$Z2K_USER_LISTS/whitelist.txt" | awk '{print $1}')"
_dev_before="$(sha256sum "$Z2K_STATE/warp/device.json" | awk '{print $1}')"
_wp_before="$(sha256sum "$Z2K_ETC/webpanel/port" | awk '{print $1}')"
lc_prerm || exit 1
assert_eq "R16 payload снесён" "0" "$([ -d "$Z2K_ROOT" ] && echo 1 || echo 0)"
assert_eq "R16 tag снесён" "0" "$([ -f "$Z2K_ETC/state/installed-tag" ] && echo 1 || echo 0)"
assert_eq "R16 config цел" "$_cfg_before" "$(sha256sum "$Z2K_ETC/config" | awk '{print $1}')"
assert_eq "R16 user-lists целы" "$_wl_before" "$(sha256sum "$Z2K_USER_LISTS/whitelist.txt" | awk '{print $1}')"
assert_eq "R16 WARP identity цел" "$_dev_before" "$(sha256sum "$Z2K_STATE/warp/device.json" | awk '{print $1}')"
assert_eq "R16 webpanel settings целы" "$_wp_before" "$(sha256sum "$Z2K_ETC/webpanel/port" | awk '{print $1}')"
# переустановка пакета: opkg снова кладёт adapter + seed (роль opkg) + postinst
mkdir -p "$Z2K_ROOT/platform/openwrt" "$Z2K_ROOT/share"
for _f in "$REPO"/platform/openwrt/*.sh; do cp -f "$_f" "$Z2K_ROOT/platform/openwrt/"; done
cp -f "$REPO/package/openwrt/files/etc/z2k/config.default" "$Z2K_ROOT/share/"
cp -f "$LC_SEED_TARBALL" "$Z2K_ROOT/share/seed.tar.gz"
export Z2K_SEED_TARBALL="$Z2K_ROOT/share/seed.tar.gz"
lc_postinst || exit 1
assert_eq "R16 config reused" "$_cfg_before" "$(sha256sum "$Z2K_ETC/config" | awk '{print $1}')"
assert_eq "R16 device reused" "$_dev_before" "$(sha256sum "$Z2K_STATE/warp/device.json" | awk '{print $1}')"
assert_eq "R16 tag=seed" "$SEEDTAG" "$(lc_tag)"
# cron без дублей: все четыре install — дважды, маркеров по одному
. "$Z2K_ROOT/platform/openwrt/schedule.sh" 2>/dev/null || exit 1
z2k_ow_cron_install >/dev/null 2>&1; z2k_ow_tg_cron_install >/dev/null 2>&1
z2k_ow_rt_cron_install >/dev/null 2>&1; z2k_ow_warp_cron_install >/dev/null 2>&1
z2k_ow_cron_install >/dev/null 2>&1; z2k_ow_tg_cron_install >/dev/null 2>&1
z2k_ow_rt_cron_install >/dev/null 2>&1; z2k_ow_warp_cron_install >/dev/null 2>&1
for _m in "# z2k-updater" "# z2k-tg-health" "# z2k-rt-health" "# z2k-warp-health"; do
    _c="$(grep -c "$_m" "$Z2K_CRON_TAB" 2>/dev/null || echo 0)"
    assert_eq "R16 cron single: $_m" "1" "$_c"
done
lc_invariant "R16" || _t_bad "R16 invariant"

# --- R17: WARP absent stays absent; present stays present ---
lc_fresh_sysroot || exit 1
lc_postinst || exit 1
assert_eq "R17 warpd отсутствует" "0" "$([ -x "$Z2K_BIN/z2k-warpd" ] && echo 1 || echo 0)"
_gw="$(grep -m1 '^GAME_WARP_ENABLED=' "$Z2K_ETC/config" 2>/dev/null | cut -d= -f2 | tr -d '" ')"
[ -z "$_gw" ] && _gw=0
assert_eq "R17 флаг 0" "0" "$_gw"
mkdir -p "$Z2K_BIN"
printf '#!/bin/sh\nexit 0\n' > "$Z2K_BIN/z2k-warpd"
chmod +x "$Z2K_BIN/z2k-warpd"
lc_postinst || exit 1
assert_eq "R17 установленный бинарь цел" "1" "$([ -x "$Z2K_BIN/z2k-warpd" ] && echo 1 || echo 0)"

# --- R18: удаление webpanel-пакета не трогает core ---
# Пути — через LC_SYS (harness-allowlist forbidden-guard; Z2K_ROOT в файле
# не присваивается, а rm -rf по неприсвоенной переменной запрещён).
lc_fresh_sysroot || exit 1
mkdir -p "$LC_SYS/etc/init.d" "$Z2K_ROOT/webpanel/cgi" "$Z2K_ROOT/www"
cp -f "$REPO/package/openwrt/files/etc/init.d/z2k-webpanel" "$LC_SYS/etc/init.d/z2k-webpanel"
: > "$Z2K_ROOT/webpanel/cgi/api.sh"
: > "$Z2K_ROOT/www/app.js"
_core_lib_before="$(sha256sum "$Z2K_ROOT/lib/utils.sh" | awk '{print $1}')"
# удаление = только webpanel-пути (как ставит stanza: один init)
rm -f "$LC_SYS/etc/init.d/z2k-webpanel"
rm -rf "$LC_SYS/usr/lib/z2k/webpanel" "$LC_SYS/usr/lib/z2k/www"
assert_eq "R18 core init цел" "1" "$([ -f "$LC_SYS/etc/init.d/z2k" ] && echo 1 || echo 0)"
assert_eq "R18 core lib цел" "$_core_lib_before" "$(sha256sum "$Z2K_ROOT/lib/utils.sh" | awk '{print $1}')"
assert_eq "R18 config цел" "1" "$([ -f "$Z2K_ETC/config" ] && echo 1 || echo 0)"
assert_eq "R18 state цел" "1" "$([ -d "$Z2K_ETC/state" ] && echo 1 || echo 0)"

_t_done
