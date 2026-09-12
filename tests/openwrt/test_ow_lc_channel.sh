#!/bin/sh
# tests/openwrt/test_ow_lc_channel.sh - Level C: канал и reinstall-входы.
# S6 wrong-platform manifest -> отказ в fetch, ноль мутаций, tag стоит;
# S7 fork manifest + immutable ref -> только t0fox-URLs, converge идёт;
# S8 все входы в reinstall-required -> fail-closed (sentinel z2k.sh цел).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-lc-channel"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LC_REPO="$REPO"; export LC_REPO
. "$(dirname "$0")/lc_harness.sh"
lc_init || { echo "FAIL[ow-lc-channel]: init" >&2; exit 1; }
trap 'rm -rf "$LC_T"' EXIT INT TERM

# --- S6: чужой манифест (без platform, keenetic-цели incl. S99) ---
# Ручной keenetic-манифест (не lc_manifest — тот всегда пишет platform=openwrt).
lc_fresh_sysroot || { echo "FAIL[ow-lc-channel]: sysroot s6" >&2; exit 1; }
SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"
_keen_sha="0000000000000000000000000000000000000000000000000000000000000000"
cat > "$LC_ORIGIN/manifest.json" <<EOF
{"current": "$SEEDTAG",
 "install_map": {
  "files/S99zapret2.new": ["/opt/etc/init.d/S99zapret2"],
  "lib/utils.sh": ["/opt/zapret2/lib/utils.sh"]
 },
 "files_sha256": {
  "lib/utils.sh": "$_keen_sha"
 },
 "history": [
 {"v": "p-84.0", "type": "patch", "ref": "ref840", "changed_files": ["lib/utils.sh"], "steps": [], "full_install": false, "reset_state": false},
 {"v": "$SEEDTAG", "type": "patch", "ref": "ref847", "changed_files": ["lib/utils.sh", "files/S99zapret2.new"], "steps": [], "full_install": false, "reset_state": false}
 ]}
EOF
cp -f "$LC_ORIGIN/manifest.json" "$LC_ORIGIN/files/UPDATES.json"
printf '%s\n' "$SEEDTAG" > "$Z2K_AU_INSTALLED_TAG_FILE"
lc_begin; lc_snap s6-before
lc_apply
assert_eq "S6 rc" "1" "$LC_RC"
assert_eq "S6 tag стоит" "$SEEDTAG" "$(lc_tag)"
lc_snap s6-after
lc_mutlog s6-before s6-after "S6 wrong-platform refused"
lc_invariant "S6" || _t_bad "S6 invariant"
# мутаций payload нет вообще (только tmp/логи): MODIFIED пуст
if lc_mutlog s6-before s6-after S6x 2>/dev/null | grep -E '^MODIFIED: [^ ]'; then
    _t_bad "S6 мутировал payload до отказа"
else
    _t_ok
fi

# --- S7: fork manifest + immutable ref -> только t0fox-URLs ---
lc_fresh_sysroot || { echo "FAIL[ow-lc-channel]: sysroot s7" >&2; exit 1; }
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
# fork-line payload (immutable ref target)
Z2K_LC_S7=1
EOF
printf 'p-84.0|patch|forkref001|lib/utils.sh||false|false\n%s|patch|forkref002|lib/utils.sh||false|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
lc_set_version "p-84.0" || exit 1
: > "$LC_T/fetch.log"
lc_begin; lc_snap s7-before
lc_apply
assert_eq "S7 rc" "0" "$LC_RC"
assert_eq "S7 tag" "$SEEDTAG" "$(lc_tag)"
if grep -q "necronicle" "$LC_T/fetch.log"; then
    _t_bad "S7: ref ушёл в necronicle"
else
    _t_ok
fi
assert_contains "S7 ref в URL" "$LC_T/fetch.log" "forkref002"
assert_contains "S7 payload новый" "$Z2K_ROOT/lib/utils.sh" "Z2K_LC_S7=1"
lc_snap s7-after
lc_mutlog s7-before s7-after "S7 fork ref t0fox-only"
lc_invariant "S7" || _t_bad "S7 invariant"

# --- S8: reinstall-входы — точная семантика modern flow ---
# type=reinstall САМ ПО СЕБЕ reinstall не вызывает (converge его покрывает —
# legacy-значение типа живо только на старом пути без карты). Настоящие
# входы в au_apply_reinstall: converge rc 2, legacy+decide=reinstall,
# full_install+decide=reinstall. Executor — НАСТОЯЩИЙ
# z2k_ow_payload_reinstall из platform/openwrt/reinstall.sh (Stage 7;
# только функции — сорсить безопасно, сам update.sh сорсить нельзя,
# он выполнится).
lc_fresh_sysroot || { echo "FAIL[ow-lc-channel]: sysroot s8" >&2; exit 1; }
mkdir -p "$LC_ORIGIN/files"
printf '#!/bin/sh\necho "SENTINEL-EXECUTED" >> "%s/sentinel"\n' "$LC_T" > "$LC_ORIGIN/files/z2k.sh"
chmod +x "$LC_ORIGIN/files/z2k.sh"
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/reinstall.sh"
command -v z2k_ow_payload_reinstall >/dev/null 2>&1 || { echo "FAIL[ow-lc-channel]: executor" >&2; exit 1; }
Z2K_AU_REINSTALL_EXECUTOR="z2k_ow_payload_reinstall"
export Z2K_AU_REINSTALL_EXECUTOR
SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"

_s8case() {
    # $1 имя; окно НЕПУСТО (tag позади current), ждёт rc!=0, tag стоит,
    # з2k.sh не трогали, sentinel нет
    lc_set_version "p-84.0" || exit 1
    : > "$LC_T/fetch.log"
    rm -f "$LC_T/sentinel"
    lc_begin
    au_run_apply >/dev/null 2>&1
    local _rc=$?
    [ "$_rc" != "0" ] && _t_ok || _t_bad "S8/$1: rc=0 при reinstall-required"
    assert_eq "S8/$1 tag стоит" "p-84.0" "$(lc_tag)"
    if grep -q "z2k.sh" "$LC_T/fetch.log"; then
        _t_bad "S8/$1: z2k.sh скачивали"
    else
        _t_ok
    fi
    assert_eq "S8/$1 sentinel нет" "0" "$([ -f "$LC_T/sentinel" ] && echo 1 || echo 0)"
}
# (a) type=reinstall БЕЗ full_install -> converge покрывает (by design):
# rc 0, тег двинулся, sentinel нет. Доказывает, что тип сам по себе
# установщик не дёргает.
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
# type-reinstall converge witness
Z2K_LC_S8A=1
EOF
printf 'p-84.0|reinstall|refR|lib/utils.sh||false|false\n%s|reinstall|refR2|lib/utils.sh||false|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
lc_set_version "p-84.0" || exit 1
: > "$LC_T/fetch.log"
rm -f "$LC_T/sentinel"
lc_begin
au_run_apply >/dev/null 2>&1
assert_eq "S8a rc" "0" "$?"
assert_eq "S8a tag двинулся" "$SEEDTAG" "$(lc_tag)"
assert_contains "S8a payload новый" "$Z2K_ROOT/lib/utils.sh" "Z2K_LC_S8A=1"
if grep -q "z2k.sh" "$LC_T/fetch.log"; then
    _t_bad "S8a: z2k.sh скачивали"
else
    _t_ok
fi
assert_eq "S8a sentinel нет" "0" "$([ -f "$LC_T/sentinel" ] && echo 1 || echo 0)"
# (b) full_install=true + type=patch -> legacy au_apply_patch (шагов нет):
# rc 0, тег двинулся, без установщика
printf 'p-84.0|patch|refF|lib/utils.sh||true|false\n%s|patch|refF2|lib/utils.sh||true|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
lc_set_version "p-84.0" || exit 1
: > "$LC_T/fetch.log"
rm -f "$LC_T/sentinel"
lc_begin
au_run_apply >/dev/null 2>&1
assert_eq "S8b rc" "0" "$?"
assert_eq "S8b tag двинулся" "$SEEDTAG" "$(lc_tag)"
if grep -q "z2k.sh" "$LC_T/fetch.log"; then
    _t_bad "S8b: z2k.sh скачивали"
else
    _t_ok
fi
# (c) unknown step: executor доставляет файлы, но шаг из будущего валит
# прогон уже после доставки → rollback, rc 1, тег стоит, z2k.sh не тронут.
printf 'p-84.0|patch|refU|lib/utils.sh|future-step-xyz|false|false\n%s|patch|refU2|lib/utils.sh|future-step-xyz|false|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
_s8case "unknown-step"
# (d) dirty marker preset: reinstall — лекарство, не приговор. Converge
# отказывается (rc 2), executor сходится полностью: rc 0, тег двинулся,
# dirty снят вызывающим, payload новый.
printf 'p-84.0|patch|refD|lib/utils.sh||false|false\n%s|patch|refD2|lib/utils.sh||false|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
printf 'partial-patch from=p-84.0 to=%s\n' "$SEEDTAG" > "$Z2K_AU_DIRTY_TREE_FILE"
lc_set_version "p-84.0" || exit 1
: > "$LC_T/fetch.log"
rm -f "$LC_T/sentinel"
lc_begin
au_run_apply >/dev/null 2>&1
assert_eq "S8d rc" "0" "$?"
assert_eq "S8d tag двинулся" "$SEEDTAG" "$(lc_tag)"
assert_eq "S8d dirty снят" "0" "$([ -s "$Z2K_AU_DIRTY_TREE_FILE" ] && echo 1 || echo 0)"
assert_contains "S8d payload новый" "$Z2K_ROOT/lib/utils.sh" "Z2K_LC_S8A=1"
if grep -q "z2k.sh" "$LC_T/fetch.log"; then
    _t_bad "S8d: z2k.sh скачивали"
else
    _t_ok
fi
assert_eq "S8d sentinel нет" "0" "$([ -f "$LC_T/sentinel" ] && echo 1 || echo 0)"
# (e) missing install_map (старый формат): au_run_apply старым путём;
# changed file без карты -> наш fail-safe (return 1), не skip+advance.
# Без python: вырезаем блок install_map диапазонным sed (формат генератора).
sed '/"install_map": {/,/^  },$/d' "$LC_ORIGIN/manifest.json" > "$LC_ORIGIN/manifest.json.nomap" \
    && mv -f "$LC_ORIGIN/manifest.json.nomap" "$LC_ORIGIN/manifest.json"
cp -f "$LC_ORIGIN/manifest.json" "$LC_ORIGIN/files/UPDATES.json"
_s8case "missing-map"

# (f) full_install=true + type=reinstall -> au_apply_reinstall ->
# настоящий executor: rc 0, тег двинулся, payload новый, z2k.sh не тронут.
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
# full-reinstall witness
Z2K_LC_S8F=1
EOF
printf 'p-84.0|reinstall|refFR|lib/utils.sh||true|false\n%s|reinstall|refFR2|lib/utils.sh||true|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
lc_set_version "p-84.0" || exit 1
: > "$LC_T/fetch.log"
rm -f "$LC_T/sentinel"
lc_begin
au_run_apply >/dev/null 2>&1
assert_eq "S8f rc" "0" "$?"
assert_eq "S8f tag двинулся" "$SEEDTAG" "$(lc_tag)"
assert_contains "S8f payload новый" "$Z2K_ROOT/lib/utils.sh" "Z2K_LC_S8F=1"
if grep -q "z2k.sh" "$LC_T/fetch.log"; then
    _t_bad "S8f: z2k.sh скачивали"
else
    _t_ok
fi
assert_eq "S8f sentinel нет" "0" "$([ -f "$LC_T/sentinel" ] && echo 1 || echo 0)"

# control без hook: legacy-путь скачивает sentinel-z2k.sh и ИСПОЛНЯЕТ его
# (доказывает, что именно hook блокирует исполнение + Keenetic-путь цел).
# Фикстура — как (f): full+reinstall, иначе modern flow сойдётся без reinstall.
unset Z2K_AU_REINSTALL_EXECUTOR
printf 'p-84.0|reinstall|refR|lib/utils.sh||true|false\n%s|reinstall|refR2|lib/utils.sh||true|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
lc_set_version "p-84.0" || exit 1
rm -f "$LC_T/sentinel"
lc_begin
au_run_apply >/dev/null 2>&1
assert_eq "control: legacy исполнил скачанное" "1" "$([ -f "$LC_T/sentinel" ] && echo 1 || echo 0)"
assert_eq "control: тег двинулся" "$SEEDTAG" "$(lc_tag)"

_t_done
