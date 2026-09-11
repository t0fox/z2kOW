#!/bin/sh
# tests/openwrt/test_ow_lc_update.sh - Level C: update-исполнение.
# S2b полный цикл шагов на sysroot (regen/validate/restart настоящим кодом);
# S12 обрыв закачки -> payload цел, tag стоит; S13 replace-fail -> rollback,
# dirty, следующий вердикт reinstall; S14 health-fail -> rollback корректен;
# S15 ENABLED=0 -> payload обновляется, сервис стоит.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-lc-update"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LC_REPO="$REPO"; export LC_REPO
. "$(dirname "$0")/lc_harness.sh"
lc_init || { echo "FAIL[ow-lc-update]: init" >&2; exit 1; }
trap 'rm -rf "$LC_T"' EXIT INT TERM

# --- S2b: шаги regen-config/validate-config/restart-service по-настоящему ---
lc_fresh_sysroot || { echo "FAIL[ow-lc-update]: sysroot s2b" >&2; exit 1; }
SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"
# Origin обязан быть валидным lua с детекторами (иначе validate справедливо
# ветирует): берём настоящий файл + маркер. Путь — ПОЛНЫЙ repo-path
# (origin зеркалит дерево: files/<repo-path>, см. lc_origin_put).
{ cat "$REPO/files/lua/z2k-alert.lua"; printf '\n-- Z2K_LC_S2B origin marker\n'; } \
    | lc_origin_put "files/lua/z2k-alert.lua"
printf 'p-84.0|patch|ref840|files/lua/z2k-alert.lua|regen-config,validate-config,restart-service|false|false\n%s|patch|ref847|files/lua/z2k-alert.lua|regen-config,validate-config,restart-service|false|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
lc_set_version "p-84.0" || exit 1
lc_begin; lc_snap s2b-before
lc_apply
assert_eq "S2b rc" "0" "$LC_RC"
assert_eq "S2b tag" "$SEEDTAG" "$(lc_tag)"
assert_contains "S2b lua доставлена" "$Z2K_ROOT/lua/z2k-alert.lua" "Z2K_LC_S2B"
assert_contains "S2b конфиг регенерирован" "$Z2K_CONFIG_FILE" "NFQWS2_OPT"
assert_contains "S2b restart был" "$LC_T/calls-init" "init:restart"
[ -f "$LC_T/daemon-alive" ] && _t_ok || _t_bad "S2b демон не поднят restart-степом"
lc_snap s2b-after
lc_mutlog s2b-before s2b-after "S2b full steps"
lc_invariant "S2b" || _t_bad "S2b invariant"

# --- S12: обрыв закачки -> live payload нетронут, tag стоит ---
lc_fresh_sysroot || { echo "FAIL[ow-lc-update]: sysroot s12" >&2; exit 1; }
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
# origin newer (never arrives: download fails)
EOF
printf 'p-84.0|patch|ref840|lib/utils.sh||false|false\n%s|patch|ref847|lib/utils.sh||false|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
lc_set_version "p-84.0" || exit 1
export LC_FETCH_FAIL="lib/utils.sh"
lc_begin; lc_snap s12-before
lc_apply
unset LC_FETCH_FAIL
assert_eq "S12 rc" "1" "$LC_RC"
assert_eq "S12 tag стоит" "p-84.0" "$(lc_tag)"
if grep -q "Z2K_LC" "$Z2K_ROOT/lib/utils.sh" 2>/dev/null; then
    _t_bad "S12 частично доставлено"
else
    _t_ok
fi
lc_snap s12-after
lc_mutlog s12-before s12-after "S12 download fail"
lc_invariant "S12" || _t_bad "S12 invariant"

# --- S13: replace-fail -> rollback + dirty + reinstall-вердикт ---
# Блокируем runtime-цель merge ПРАВАМИ (chmod 555, pre-state ЦЕЛ — в отличие
# от rm -rf, который выводил файл из-под снапшота и делал rollback "полным"):
# merge падает, rollback восстанавливает shipped+utils, но НЕ runtime
# (запись заблокирована) -> partial -> dirty -> reinstall-вердикт.
# Non-root в песочнице обязателен (root игнорирует r-x) — enforced ниже.
lc_fresh_sysroot || { echo "FAIL[ow-lc-update]: sysroot s13" >&2; exit 1; }
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
# origin newer (rollback witness)
Z2K_LC_S13=1
EOF
lc_origin_put "files/lists/extra-domains.txt" <<'EOF'
# origin shipped extras
origin-domain.example
EOF
printf 'p-84.0|patch|ref840|lib/utils.sh,files/lists/extra-domains.txt||false|false\n%s|patch|ref847|lib/utils.sh,files/lists/extra-domains.txt||false|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
lc_set_version "p-84.0" || exit 1
if [ "$(id -u)" = "0" ]; then
    echo "SKIP[ow-lc-update]: S13 needs non-root (r-x enforcement)"
else
chmod 555 "$Z2K_ETC/user-lists" || exit 1
lc_begin; lc_snap s13-before
lc_apply
assert_eq "S13 rc" "1" "$LC_RC"
assert_eq "S13 tag стоит" "p-84.0" "$(lc_tag)"
assert_eq "S13 dirty выставлен" "1" "$([ -s "$Z2K_AU_DIRTY_TREE_FILE" ] && echo 1 || echo 0)"
assert_eq "S13 utils откачен" "0" "$(grep -c Z2K_LC_S13 "$Z2K_ROOT/lib/utils.sh" 2>/dev/null || true)"
_decide_out="$(au_decide "$(lc_tag)" "$Z2K_AU_TMP_DIR/UPDATES.json" 2>/dev/null | head -1 | awk '{print $1}')"
assert_eq "S13 следующий вердикт reinstall" "reinstall" "$_decide_out"
lc_snap s13-after
lc_mutlog s13-before s13-after "S13 replace fail + dirty"
lc_invariant "S13" || _t_bad "S13 invariant"
fi
# (sysroot одноразовый: следующий сценарий делает свой fresh)

# --- S14: health-fail (restart убивает демона) -> rollback корректен ---
lc_fresh_sysroot || { echo "FAIL[ow-lc-update]: sysroot s14" >&2; exit 1; }
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
# origin newer (health-fail witness)
Z2K_LC_S14=1
EOF
printf 'p-84.0|patch|ref840|lib/utils.sh|restart-service|false|false\n%s|patch|ref847|lib/utils.sh|restart-service|false|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
lc_set_version "p-84.0" || exit 1
: > "$LC_T/daemon-alive" # демон ЖИВ до обновления
export LC_INIT_KILLS=1    # ...а restart-степ его уронит
lc_begin; lc_snap s14-before
lc_apply
unset LC_INIT_KILLS
assert_eq "S14 rc" "1" "$LC_RC"
assert_eq "S14 tag стоит" "p-84.0" "$(lc_tag)"
assert_eq "S14 payload откачен" "0" "$(grep -c Z2K_LC_S14 "$Z2K_ROOT/lib/utils.sh" 2>/dev/null || true)"
lc_snap s14-after
lc_mutlog s14-before s14-after "S14 health fail + rollback"
lc_invariant "S14" || _t_bad "S14 invariant"

# --- S15: ENABLED=0 -> payload обновляется, сервис НЕ стартует ---
lc_fresh_sysroot || { echo "FAIL[ow-lc-update]: sysroot s15" >&2; exit 1; }
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
# origin newer (disabled-service witness)
Z2K_LC_S15=1
EOF
printf 'p-84.0|patch|ref840|lib/utils.sh|restart-service|false|false\n%s|patch|ref847|lib/utils.sh|restart-service|false|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
lc_set_version "p-84.0" || exit 1
printf 'ENABLED=0\n' > "$Z2K_ETC/config"
rm -f "$LC_T/daemon-alive"
lc_begin; lc_snap s15-before
lc_apply
assert_eq "S15 rc" "0" "$LC_RC"
assert_eq "S15 tag двинулся" "$SEEDTAG" "$(lc_tag)"
assert_contains "S15 payload новый" "$Z2K_ROOT/lib/utils.sh" "Z2K_LC_S15=1"
assert_eq "S15 демон не поднят" "0" "$([ -f "$LC_T/daemon-alive" ] && echo 1 || echo 0)"
if grep -q "init:restart" "$LC_T/calls-init" 2>/dev/null || grep -q "init:start" "$LC_T/calls-init" 2>/dev/null; then
    _t_bad "S15 сервис дёрнули при ENABLED=0"
else
    _t_ok
fi
lc_snap s15-after
lc_mutlog s15-before s15-after "S15 disabled update"
lc_invariant "S15" || _t_bad "S15 invariant"

_t_done
