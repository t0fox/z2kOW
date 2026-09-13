#!/bin/sh
# tests/openwrt/test_ow_release_api.sh - Stage 7 Layer A: adapter API + gate.
# OPENWRT_ADAPTER_API, требование манифеста, гейт до mutation (§6/§7/§57),
# trust-пути без /opt (§43). Манифест — локальная фикстура, fetch — stub.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-release-api"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-rapi.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/root/share" "$T/etc/state" "$T/tmp/update"
export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_STATE="$T/etc/state" Z2K_CONFIG="$T/etc/config"
export Z2K_AU_TMP_DIR="$T/tmp/update"
export Z2K_AU_INSTALLED_TAG_FILE="$T/etc/state/installed-tag"
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/paths.sh" || exit 1
. "$REPO/platform/openwrt/env.sh" || exit 1
. "$REPO/lib/utils.sh" >/dev/null 2>&1 || exit 1
. "$REPO/lib/auto_update.sh" >/dev/null 2>&1 || exit 1
. "$REPO/platform/openwrt/reinstall.sh" || exit 1

# --- source of truth: package/openwrt/ADAPTER_API ---
assert_file "ADAPTER_API существует" "$REPO/package/openwrt/ADAPTER_API"
_api_src="$(grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' "$REPO/package/openwrt/ADAPTER_API" | tr -d ' \t\r\n')"
assert_eq "ADAPTER_API == 1" "1" "$_api_src"

# --- installed: нет файла (pre-API пакет) = 1 ---
assert_eq "installed default 1" "1" "$(z2k_ow_adapter_api_installed)"
# --- installed: файл с комментариями + версия ---
printf '# truth\n1\n' > "$T/root/share/adapter.api"
assert_eq "installed read 1" "1" "$(z2k_ow_adapter_api_installed)"
printf '# truth\n2\n' > "$T/root/share/adapter.api"
assert_eq "installed read 2" "2" "$(z2k_ow_adapter_api_installed)"
# --- installed: битый = fail closed ---
printf 'two\n' > "$T/root/share/adapter.api"
z2k_ow_adapter_api_installed >/dev/null 2>&1 && _t_bad "installed: мусор принят" || _t_ok
printf '1\n2\n' > "$T/root/share/adapter.api"
z2k_ow_adapter_api_installed >/dev/null 2>&1 && _t_bad "installed: две версии приняты" || _t_ok
printf '1\n' > "$T/root/share/adapter.api"

# --- api_min: отсутствие = 1; строка/число читаются; мусор = отказ ---
assert_eq "api_min absent" "1" "$(z2k_ow_manifest_api_min '{"v": "p-1"}')"
assert_eq "api_min string" "2" "$(z2k_ow_manifest_api_min '{"v": "p-2", "openwrt_adapter_api_min": "2"}')"
assert_eq "api_min bare" "3" "$(z2k_ow_manifest_api_min '{"v": "p-3","openwrt_adapter_api_min":3}')"
z2k_ow_manifest_api_min '{"v": "p-4", "openwrt_adapter_api_min": "two"}' >/dev/null 2>&1 \
    && _t_bad "api_min: мусор принят" || _t_ok
z2k_ow_manifest_api_min '{"v": "p-5", "openwrt_adapter_api_min": 0}' >/dev/null 2>&1 \
    && _t_bad "api_min: ноль принят" || _t_ok

# --- required: max окна; незнакомый tag = всё окно; битое поле = отказ ---
cat > "$T/manifest.json" <<'EOF'
{"current": "p-3",
"platform": "openwrt",
"install_map": {
},
"files_sha256": {
},
"history": [
{"v": "p-1", "type": "patch", "ref": "p-1", "changed_files": [], "steps": []},
{"v": "p-2", "type": "patch", "ref": "p-2", "changed_files": [], "steps": [], "openwrt_adapter_api_min": "2"},
{"v": "p-3", "type": "patch", "ref": "p-3", "changed_files": [], "steps": []}
]}
EOF
assert_eq "required p-1 window" "2" "$(z2k_ow_manifest_api_required "$T/manifest.json" "p-1")"
assert_eq "required p-2 window" "1" "$(z2k_ow_manifest_api_required "$T/manifest.json" "p-2")"
assert_eq "required unknown tag" "2" "$(z2k_ow_manifest_api_required "$T/manifest.json" "p-9")"
cat > "$T/manifest-bad.json" <<'EOF'
{"current": "p-2",
"history": [
{"v": "p-1", "type": "patch", "ref": "p-1", "changed_files": [], "steps": []},
{"v": "p-2", "type": "patch", "ref": "p-2", "changed_files": [], "steps": [], "openwrt_adapter_api_min": "x"}
]}
EOF
z2k_ow_manifest_api_required "$T/manifest-bad.json" "p-1" >/dev/null 2>&1 \
    && _t_bad "required: битое поле принято" || _t_ok

# --- gate: fetch stub (manifest кладём сами, sentinel доказывает вызов) ---
au_fetch_manifest() {
    : > "$T/fetch-called"
    cp -f "$T/gate-manifest.json" "$Z2K_AU_TMP_DIR/UPDATES.json" 2>/dev/null
}
cp -f "$T/manifest.json" "$T/gate-manifest.json"
# нет tag-файла: skip БЕЗ fetch
rm -f "$T/etc/state/installed-tag" "$T/fetch-called"
z2k_ow_adapter_gate "apply" >/dev/null 2>&1
assert_eq "gate: no tag rc" "0" "$?"
assert_eq "gate: no tag без fetch" "0" "$([ -f "$T/fetch-called" ] && echo 1 || echo 0)"
# ok: req(1) <= inst(1)
printf 'p-2\n' > "$T/etc/state/installed-tag"
printf '1\n' > "$T/root/share/adapter.api"
rm -f "$T/fetch-called"
z2k_ow_adapter_gate "apply" >/dev/null 2>&1
assert_eq "gate: ok apply rc" "0" "$?"
assert_eq "gate: ok fetch был" "1" "$([ -f "$T/fetch-called" ] && echo 1 || echo 0)"
# too old + apply: rc 1
printf 'p-1\n' > "$T/etc/state/installed-tag"
rm -f "$T/fetch-called"
_out="$(z2k_ow_adapter_gate "apply" 2>&1)"; _rc=$?
assert_eq "gate: too-old apply rc" "1" "$_rc"
case "$_out" in
    *"z2k-adapter"*) _t_ok ;;
    *) _t_bad "gate: apply без package-инструкции" ;;
esac
# too old + check: rc 2 + ADAPTER_UPDATE_REQUIRED
_out="$(z2k_ow_adapter_gate "check" 2>&1)"; _rc=$?
assert_eq "gate: too-old check rc" "2" "$_rc"
case "$_out" in
    *"ADAPTER_UPDATE_REQUIRED"*) _t_ok ;;
    *) _t_bad "gate: check без ADAPTER_UPDATE_REQUIRED" ;;
esac
# fetch fail: rc 1 в обоих режимах (не вердикт, а отсутствие данных)
au_fetch_manifest() { return 1; }
z2k_ow_adapter_gate "apply" >/dev/null 2>&1
assert_eq "gate: fetch-fail apply rc" "1" "$?"
z2k_ow_adapter_gate "check" >/dev/null 2>&1
assert_eq "gate: fetch-fail check rc" "1" "$?"

# --- §43: эффективные trust-пути без /opt ---
case "$Z2K_AU_TRUST_PIN" in
    *"/opt"*) _t_bad "trust pin через /opt: $Z2K_AU_TRUST_PIN" ;;
    *) _t_ok ;;
esac
assert_eq "trust pin openwrt" "$T/etc/.trust/pinned" "$Z2K_AU_TRUST_PIN"
_pub="${ZAPRET2_DIR}/etc/z2k-update-pub.pem"
case "$_pub" in
    *"/opt"*) _t_bad "pubkey через /opt: $_pub" ;;
    *) _t_ok ;;
esac
if grep -q 'Z2K_AU_VERIFY_BIN:-\${ZAPRET2_DIR:-' "$REPO/lib/auto_update.sh" 2>/dev/null; then
    _t_ok
else
    _t_bad "VERIFY_BIN дефолт не через ZAPRET2_DIR"
fi

# --- §56: updater НИКОГДА не делает blanket upgrade и не ставит пакеты сам ---
# Запрет узкий и точный: `apk upgrade`/`opkg upgrade` (blanket) — нигде в
# updater-коде; install-хелпер pkg.sh дремлет (вызывающих нет — иначе это был
# бы auto-install из updater). Точные инструкции человеку в сообщениях
# (gate: "обновите пакет ...") разрешены и обязательны.
if grep -rn -- 'apk upgrade\|opkg upgrade' "$REPO/lib/auto_update.sh" \
        "$REPO/platform/openwrt/"*.sh "$REPO/webpanel/cgi/"*.sh 2>/dev/null | grep -q .; then
    _t_bad "§56: blanket upgrade в updater-коде"
else
    _t_ok
fi
if grep -rn -- 'z2k_ow_pkg_install' "$REPO/lib/auto_update.sh" \
        "$REPO/platform/openwrt/update.sh" "$REPO/platform/openwrt/reinstall.sh" \
        "$REPO/platform/openwrt/schedule.sh" "$REPO/webpanel/cgi/"*.sh 2>/dev/null | grep -q .; then
    _t_bad "§56: auto-install пакетов из updater"
else
    _t_ok
fi

_t_done
