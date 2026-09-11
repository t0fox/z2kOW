#!/bin/sh
# tests/openwrt/test_ow_lc_ops.sh - Level C: package-операции и user-data.
# S4 upgrade после updater-правок -> payload цел; S5 старый seed + живой
# payload -> никакого rollback; S9/S18 uninstall (cron/payload/tmp vs /etc);
# S16 user-data сквозь install->update->upgrade.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-lc-ops"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LC_REPO="$REPO"; export LC_REPO
. "$(dirname "$0")/lc_harness.sh"
lc_init || { echo "FAIL[ow-lc-ops]: init" >&2; exit 1; }
trap 'rm -rf "$LC_T"' EXIT INT TERM

# --- S4+S5: package upgrade не трогает updater-payload (даже старым seed) ---
lc_fresh_sysroot || { echo "FAIL[ow-lc-ops]: sysroot s4" >&2; exit 1; }
SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"
# updater-правка payload (как после обновления)
printf '\n# updater change s4\n' >> "$Z2K_ROOT/lib/utils.sh"
printf '\n# updater change s4\n' >> "$Z2K_ROOT/lua/z2k-alert.lua"
_sum_lib="$(cksum "$Z2K_ROOT/lib/utils.sh")"
_sum_lua="$(cksum "$Z2K_ROOT/lua/z2k-alert.lua")"
# "новый пакет": adapter v2 + СТАРЫЙ seed (собран из pristine-корня симуляцией:
# перестраиваем tarball из ТЕКУЩЕГО дерева — контент тот же seed, mtime новый)
"$LC_REPO/package/openwrt/make-seed.sh" "$LC_REPO" "$Z2K_ROOT/share/seed.tar.gz" >/dev/null 2>&1 || exit 1
printf '# v2 adapter\n' >> "$Z2K_ROOT/platform/openwrt/update.sh"
lc_begin; lc_snap s4-before
lc_postinst
assert_eq "S4 postinst rc" "0" "$?"
assert_eq "S4 lib цел" "$_sum_lib" "$(cksum "$Z2K_ROOT/lib/utils.sh")"
assert_eq "S4 lua цел" "$_sum_lua" "$(cksum "$Z2K_ROOT/lua/z2k-alert.lua")"
assert_contains "S4 adapter v2 встал" "$Z2K_ROOT/platform/openwrt/update.sh" "v2 adapter"
assert_eq "S4 tag стоит" "$SEEDTAG" "$(lc_tag)"
lc_snap s4-after
lc_mutlog s4-before s4-after "S4/S5 upgrade preserves payload"
lc_invariant "S4/S5" || _t_bad "S4/S5 invariant"

# --- S16: user-data сквозь install->update->upgrade ---
lc_fresh_sysroot || { echo "FAIL[ow-lc-ops]: sysroot s16" >&2; exit 1; }
SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"
printf '\nZ2K_DYNAMIC_TTL=0\n' >> "$Z2K_ETC/config"
printf 'user-domain.example\n' >> "$Z2K_ETC/user-lists/whitelist.txt"
printf 'user-domain.example\n' >> "$Z2K_ETC/user-lists/extra-domains.txt"
_c0="$(cksum "$Z2K_ETC/config")"; _w0="$(cksum "$Z2K_ETC/user-lists/whitelist.txt")"
_e0="$(cksum "$Z2K_ETC/user-lists/extra-domains.txt")"
_s0="$(cksum "$Z2K_ETC/state/discovered-domains.txt")"
# update с regen-config шагом (трогает конфиг!) + merge extra-domains
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
# s16 witness
Z2K_LC_S16=1
EOF
lc_origin_put "files/lists/extra-domains.txt" <<'EOF'
# origin shipped extras s16
s16-origin.example
EOF
printf 'p-84.0|patch|ref840|lib/utils.sh,files/lists/extra-domains.txt|regen-config|false|false\n%s|patch|ref847|lib/utils.sh,files/lists/extra-domains.txt|regen-config|false|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
lc_set_version "p-84.0" || exit 1
lc_begin; lc_snap s16-before
lc_apply
assert_eq "S16 update rc" "0" "$LC_RC"
assert_contains "S16 флаг жив" "$Z2K_ETC/config" "Z2K_DYNAMIC_TTL=0"
assert_contains "S16 whitelist жив" "$Z2K_ETC/user-lists/whitelist.txt" "user-domain.example"
assert_contains "S16 extras пользователя живы" "$Z2K_ETC/user-lists/extra-domains.txt" "user-domain.example"
assert_contains "S16 shipped extras приехали" "$Z2K_ETC/user-lists/extra-domains.txt" "s16-origin.example"
# upgrade поверх
lc_postinst
assert_eq "S16 postinst rc" "0" "$?"
assert_contains "S16 флаг после upgrade" "$Z2K_ETC/config" "Z2K_DYNAMIC_TTL=0"
assert_eq "S16 whitelist после upgrade" "$_w0" "$(cksum "$Z2K_ETC/user-lists/whitelist.txt")"
lc_snap s16-after
lc_mutlog s16-before s16-after "S16 user-data cycle"
lc_invariant "S16" || _t_bad "S16 invariant"

# --- S9/S18: uninstall (cron/payload/tmp vs /etc) + reinstall ---
lc_fresh_sysroot || { echo "FAIL[ow-lc-ops]: sysroot s9" >&2; exit 1; }
printf 'FOREIGN-LINE\n' >> "$Z2K_CRON_TAB"
printf 'user-config-value=1\n' >> "$Z2K_ETC/config"
# сохраняем package-owned для симуляции opkg-reinstall позже
cp -f "$Z2K_ROOT/share/seed.tar.gz" "$LC_T/seed-keep.tar.gz"
cp -f "$Z2K_ROOT/share/config.default" "$LC_T/config.default-keep"
SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"
# поднимаем live-версию до Y КОНСИСТЕНТНО (tag+meta, как после update) —
# reinstall обязан вернуть X (I3), а не preserve Y
printf 'p-99.99\n' > "$Z2K_AU_INSTALLED_TAG_FILE"
sed 's/^tag=.*/tag=p-99.99/' "$Z2K_ROOT/share/payload.meta" > "$Z2K_ROOT/share/payload.meta.new" \
    && mv -f "$Z2K_ROOT/share/payload.meta.new" "$Z2K_ROOT/share/payload.meta"
lc_begin; lc_snap s9-before
lc_prerm
assert_eq "S9 prerm rc" "0" "$?"
assert_eq "S9 cron наш убран" "0" "$(grep -c 'z2k-updater' "$Z2K_CRON_TAB" || true)"
assert_contains "S9 cron чужой цел" "$Z2K_CRON_TAB" "FOREIGN-LINE"
assert_eq "S9 payload снесён" "0" "$([ -e "$Z2K_ROOT/lib/utils.sh" ] && echo 1 || echo 0)"
assert_eq "S9 tmp снесён" "0" "$([ -e "$Z2K_TMP" ] && echo 1 || echo 0)"
assert_eq "S9 config цел" "1" "$(grep -q 'user-config-value=1' "$Z2K_ETC/config" && echo 1 || echo 0)"
# active installation metadata УДАЛЕНА (иначе ложь о снесённом payload — I1/I2)
assert_eq "S9 marker удалён" "0" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
assert_eq "S9 active tag удалён" "0" "$([ -f "$Z2K_AU_INSTALLED_TAG_FILE" ] && echo 1 || echo 0)"
lc_snap s9-after
lc_mutlog s9-before s9-after "S9 uninstall"
lc_invariant "S9" || _t_bad "S9 invariant"
# reinstall после uninstall: marker/tag отсутствуют + payload empty ->
# re-seed: payload=X, meta=X, tag=X (I3). Чтобы доказать, что re-seed НЕ
# preserve'ит: до uninstall поднимаем версию до p-99.99 КОНСИСТЕНТНО
# (tag+meta вместе, как после настоящего update).
lc_snap s9b-before
mkdir -p "$Z2K_ROOT/share"
cp -f "$LC_T/seed-keep.tar.gz" "$Z2K_ROOT/share/seed.tar.gz"
cp -f "$LC_T/config.default-keep" "$Z2K_ROOT/share/config.default"
export Z2K_SEED_TARBALL="$Z2K_ROOT/share/seed.tar.gz"
lc_postinst
assert_eq "S18 reinstall rc" "0" "$?"
assert_eq "S18 payload вернулся" "1" "$([ -f "$Z2K_ROOT/lib/utils.sh" ] && echo 1 || echo 0)"
assert_eq "S18 config пережил" "1" "$(grep -q 'user-config-value=1' "$Z2K_ETC/config" && echo 1 || echo 0)"
assert_eq "S18 tag стал seed (не preserved p-99.99)" "$SEEDTAG" "$(cat "$Z2K_AU_INSTALLED_TAG_FILE" 2>/dev/null)"
assert_eq "S18 meta стала seed" "$SEEDTAG" "$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/payload.meta" | head -1)"
lc_snap s18-after
lc_mutlog s9-after s18-after "S18 reinstall-after-uninstall"
lc_invariant "S18" || _t_bad "S18 invariant"

_t_done
