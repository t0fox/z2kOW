#!/bin/sh
# tests/openwrt/test_ow_release_reinstall.sh - Stage 7 Layer B: reinstall.
# R7 patch, R8 full reinstall, R9 download-fail, R11 hash-mismatch,
# R12 API-too-old, reset_state 0/1, crash-order (§9/§44/§45). Harness:
# lc (file://-транспорт, настоящий converge/steps/rollback/tag).
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/lc_harness.sh"
_t_plan "ow-release-reinstall"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LC_REPO="$REPO"
lc_init || { echo "FAIL[ow-release-reinstall]: init" >&2; exit 1; }
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/reinstall.sh" || exit 1

_new_sysroot() {
    lc_fresh_sysroot || exit 1
    Z2K_AU_REINSTALL_EXECUTOR="z2k_ow_payload_reinstall"
    export Z2K_AU_REINSTALL_EXECUTOR
    SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"
}

# --- R8: full reinstall доставляет ВЕСЬ план, шаги, meta, tag LAST ---
_new_sysroot
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
# R8 witness
R8_UTILS=1
EOF
lc_origin_put "files/lists/telegram_ips.txt" <<'EOF'
1.1.1.1
EOF
printf 'p-84.0|reinstall|refR80|lib/utils.sh||true|false\n%s|reinstall|refR81|lib/utils.sh,files/lists/telegram_ips.txt|restart-service|true|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
lc_set_version "p-84.0" || exit 1
lc_begin
au_run_apply >/dev/null 2>&1
assert_eq "R8 rc" "0" "$?"
assert_eq "R8 tag" "$SEEDTAG" "$(lc_tag)"
assert_eq "R8 meta" "$SEEDTAG" "$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/payload.meta" | head -1)"
assert_contains "R8 utils новый" "$Z2K_ROOT/lib/utils.sh" "R8_UTILS=1"
assert_contains "R8 список новый" "$Z2K_ROOT/lists/telegram_ips.txt" "1.1.1.1"
assert_eq "R8 marker цел" "1" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
if grep -q "init:restart" "$LC_T/calls-init" 2>/dev/null; then _t_ok; else _t_bad "R8: restart-service не отработал"; fi
lc_invariant "R8" || _t_bad "R8 invariant"

# --- R8 + reset_state=1: состояние снесено; reset=0: сохранено ---
_new_sysroot
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
R8R_UTILS=1
EOF
printf 'p-84.0|reinstall|refRS0|lib/utils.sh||true|false\n%s|reinstall|refRS1|lib/utils.sh||true|true\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
printf 'stale-stats\n' > "$Z2K_STATE/state.tsv"
lc_set_version "p-84.0" || exit 1
au_run_apply >/dev/null 2>&1
assert_eq "R8reset1 rc" "0" "$?"
assert_eq "R8reset1 state снесён" "0" "$([ -f "$Z2K_STATE/state.tsv" ] && echo 1 || echo 0)"
assert_eq "R8reset1 tag" "$SEEDTAG" "$(lc_tag)"
_new_sysroot
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
R8R0_UTILS=1
EOF
printf 'p-84.0|reinstall|refRS00|lib/utils.sh||true|false\n%s|reinstall|refRS01|lib/utils.sh||true|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
printf 'keep-me\n' > "$Z2K_STATE/state.tsv"
lc_set_version "p-84.0" || exit 1
au_run_apply >/dev/null 2>&1
assert_eq "R8reset0 rc" "0" "$?"
assert_contains "R8reset0 state цел" "$Z2K_STATE/state.tsv" "keep-me"

# --- R7: patch — changed едет, unchanged байт-в-байт, тег движется ---
_new_sysroot
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
R7_UTILS=1
EOF
printf 'p-84.0|patch|refR70|lib/utils.sh||false|false\n%s|patch|refR71|lib/utils.sh||false|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
_untouched_before="$(sha256sum "$Z2K_ROOT/lib/strategies.sh" | awk '{print $1}')"
lc_set_version "p-84.0" || exit 1
au_run_apply >/dev/null 2>&1
assert_eq "R7 rc" "0" "$?"
assert_eq "R7 tag" "$SEEDTAG" "$(lc_tag)"
assert_contains "R7 changed новый" "$Z2K_ROOT/lib/utils.sh" "R7_UTILS=1"
assert_eq "R7 untouched цел" "$_untouched_before" "$(sha256sum "$Z2K_ROOT/lib/strategies.sh" | awk '{print $1}')"

# --- R9: обрыв загрузки — ноль мутаций, tag/meta старые ---
_new_sysroot
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
R9_UTILS=1
EOF
printf 'p-84.0|reinstall|refR90|lib/utils.sh||true|false\n%s|reinstall|refR91|lib/utils.sh||true|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
lc_set_version "p-84.0" || exit 1
_before_utils="$(sha256sum "$Z2K_ROOT/lib/utils.sh" | awk '{print $1}')"
_before_meta="$(cat "$Z2K_ROOT/share/payload.meta")"
export LC_FETCH_FAIL="lib/utils.sh" Z2K_AU_FILE_TRIES=1
au_run_apply >/dev/null 2>&1
assert_eq "R9 rc" "1" "$?"
unset LC_FETCH_FAIL Z2K_AU_FILE_TRIES
assert_eq "R9 tag стоит" "p-84.0" "$(lc_tag)"
assert_eq "R9 файл цел" "$_before_utils" "$(sha256sum "$Z2K_ROOT/lib/utils.sh" | awk '{print $1}')"
assert_eq "R9 meta цела" "$_before_meta" "$(cat "$Z2K_ROOT/share/payload.meta")"
lc_invariant "R9" || _t_bad "R9 invariant"

# --- R11: sha не сошлась — отказ + rollback (старый контент на месте) ---
_new_sysroot
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
R11_UTILS=1
EOF
printf 'p-84.0|reinstall|refR110|lib/utils.sh||true|false\n%s|reinstall|refR111|lib/utils.sh||true|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
# origin меняем ПОСЛЕ манифеста: sha в манифесте протухла
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
TAMPERED-BYTES
EOF
lc_set_version "p-84.0" || exit 1
printf 'sentinel-old\n' > "$Z2K_ROOT/lib/utils.sh"
_before_tag="p-84.0"
# настоящий curl (без harness-z2k_fetch): bytes доедут, sha — нет
unset -f z2k_fetch 2>/dev/null
_SAVED_PATH="$PATH"
PATH="/usr/bin:/bin"
export Z2K_AU_FILE_TRIES=1
au_run_apply >/dev/null 2>&1
_rc=$?
export PATH="$_SAVED_PATH"
unset Z2K_AU_FILE_TRIES
assert_eq "R11 rc" "1" "$_rc"
assert_eq "R11 tag стоит" "$_before_tag" "$(lc_tag)"
assert_contains "R11 rollback вернул старое" "$Z2K_ROOT/lib/utils.sh" "sentinel-old"

# --- R12: adapter API too old — отказ ДО загрузки payload ---
_new_sysroot
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
R12_UTILS=1
EOF
printf 'p-84.0|reinstall|refR120|lib/utils.sh||true|false\n%s|reinstall|refR121|lib/utils.sh||true|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
# shellcheck disable=SC2016
sed -i 's/\("v": "'"$SEEDTAG"'[^}]*\)}/\1, "openwrt_adapter_api_min": "2"}/' "$LC_ORIGIN/manifest.json"
cp -f "$LC_ORIGIN/manifest.json" "$LC_ORIGIN/files/UPDATES.json"
lc_set_version "p-84.0" || exit 1
: > "$LC_T/fetch.log"
au_run_apply >/dev/null 2>&1
assert_eq "R12 rc" "1" "$?"
assert_eq "R12 tag стоит" "p-84.0" "$(lc_tag)"
if grep -q "lib/utils.sh" "$LC_T/fetch.log" 2>/dev/null; then
    _t_bad "R12: payload качали до гейта"
else
    _t_ok
fi

# --- crash-order F1: mid-replace (partial + marker + старый tag) ---
_new_sysroot
rm -f "$Z2K_ROOT/lib/utils.sh"
if z2k_ow_seed_ensure >/dev/null 2>&1; then
    _t_bad "F1: partial+marker принят"
else
    _t_ok
fi
assert_eq "F1 marker снят" "0" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
z2k_ow_seed_ensure >/dev/null 2>&1
assert_eq "F1 reseed rc" "0" "$?"
assert_eq "F1 tag=seed" "$SEEDTAG" "$(lc_tag)"
assert_eq "F1 meta=seed" "$SEEDTAG" "$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/payload.meta" | head -1)"
assert_eq "F1 marker снова" "1" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
lc_invariant "F1" || _t_bad "F1 invariant"

# --- crash-order F2: post-meta pre-tag (файлы+meta новые, tag старый) ---
_new_sysroot
printf '#!/bin/sh\nF2-NEW-BYTES=1\n' > "$Z2K_ROOT/lib/utils.sh"
{ printf 'platform=openwrt\n'; printf 'tag=%s\n' "p-99.0"; printf 'ref=\n'; } > "$Z2K_ROOT/share/payload.meta"
z2k_ow_seed_ensure >/dev/null 2>&1
assert_eq "F2 rc" "0" "$?"
assert_eq "F2 tag двинулся вперёд" "p-99.0" "$(lc_tag)"
lc_invariant "F2" || _t_bad "F2 invariant"

_t_done
