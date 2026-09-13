#!/bin/sh
# tests/openwrt/test_ow_update_entry.sh - §1-2: тонкий launcher, не форк.
# Статика: порядок сорсинга, отсутствие форка/branch-gate/dev-ветки.
# Функционально (stub-lib): apply/check/manual/gates/jitter-ветки.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-update-entry"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
UPD="$REPO/platform/openwrt/update.sh"

# --- статика (по строкам сорсинга `. "path"`, не по упоминаниям в rationale) ---
_code() { sed 's/#.*$//' "$UPD"; }
_lp="$(_code | grep -n 'platform/openwrt/paths\.sh' | head -1 | cut -d: -f1)"
_le="$(_code | grep -n 'platform/openwrt/env\.sh' | head -1 | cut -d: -f1)"
_lu="$(_code | grep -n 'utils\.sh' | head -1 | cut -d: -f1)"
_la="$(_code | grep -n 'auto_update\.sh' | head -1 | cut -d: -f1)"
[ -n "$_lp" ] && [ -n "$_le" ] && [ -n "$_lu" ] && [ -n "$_la" ] \
    && [ "$_lp" -lt "$_le" ] && [ "$_le" -lt "$_lu" ] && [ "$_lu" -lt "$_la" ] \
    && _t_ok || _t_bad "порядок сорсинга не paths->env->utils->auto_update ($_lp,$_le,$_lu,$_la)"
if grep -qE '^(au_run_apply|au_repo_base|au_apply_reinstall|au_run_step)\(\)' "$UPD"; then
    _t_bad "launcher переопределяет common-функции (форк)"
else
    _t_ok
fi
assert_contains "launcher зовёт au_run_apply" "$UPD" "au_run_apply"
assert_contains "launcher зовёт au_run_check" "$UPD" "au_run_check"
if _code | grep -q 'z2k-branch'; then
    _t_bad "branch-file gate притащен на OpenWrt"
else
    _t_ok
fi
if grep -q 'feat/' "$UPD"; then
    _t_bad "dev-ветка захардкожена"
else
    _t_ok
fi
if _code | grep -q 'z2k\.sh'; then
    _t_bad "launcher упоминает z2k.sh"
else
    _t_ok
fi

# --- функционально на stub-lib ---
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-entry.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/root/lib" "$T/root/platform/openwrt" "$T/etc"
for _f in paths.sh env.sh bootstrap.sh update.sh schedule.sh reinstall.sh; do
    ln -s "$REPO/platform/openwrt/$_f" "$T/root/platform/openwrt/$_f"
done
cat > "$T/root/lib/utils.sh" <<'EOF'
#!/bin/sh
safe_config_read() {
    if [ "$1" = "Z2K_AUTO_UPDATE_ENABLED" ]; then
        grep -m1 '^Z2K_AUTO_UPDATE_ENABLED=' "$2" 2>/dev/null | cut -d= -f2 | tr -d ' "\047'
        return 0
    fi
    printf '%s' "$3"
}
z2k_host_jitter() { printf '7'; }
EOF
cat > "$T/root/lib/auto_update.sh" <<EOF
#!/bin/sh
au_log() { echo "aulog:\$*" >> "$T/calls"; }
au_run_apply() { echo "apply-called" >> "$T/calls"; }
au_run_check() { echo "check-called" >> "$T/calls"; }
# adapter-gate fetch: минимальный манифест без api-требований (окно=1).
au_fetch_manifest() {
    mkdir -p "\$Z2K_AU_TMP_DIR" 2>/dev/null || return 1
    printf '{"current": "p-84.7", "history": []}\n' > "\$Z2K_AU_TMP_DIR/UPDATES.json" 2>/dev/null
}
EOF
# config_official/strategies сорсятся launcher'ом? нет, но оба — в
# Z2K_PAYLOAD_REQUIRED: без них payload_ok ложен и seed_ensure не пустит.
printf '#!/bin/sh\n# stub\n' > "$T/root/lib/config_official.sh"
printf '#!/bin/sh\n# stub\n' > "$T/root/lib/strategies.sh"
printf 'ENABLED=1\n' > "$T/etc/config"
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "sleep:$*" >> "%s/calls"\n' "$T" > "$T/bin/sleep"
chmod +x "$T/bin/sleep"
unset Z2K_AU_MANUAL Z2K_AU_NO_JITTER
export PATH="$T/bin:$PATH"
# pre-flight update.sh (seed_ensure) требует целый payload: добиваем stub-root
# dummy-файлами + seed.meta/tag в согласии (payload_ok + reconcile проходят)
mkdir -p "$T/root/lua" "$T/root/extra_strats/TCP/RKN" "$T/root/extra_strats/TCP/YT" \
         "$T/root/extra_strats/TCP/YT_GV" "$T/root/extra_strats/UDP/YT" \
         "$T/root/share" "$T/root/lists" "$T/etc/state"
printf 'x\n' > "$T/root/lua/z2k-alert.lua"
printf 'x\n' > "$T/root/lua/z2k-state-persist.lua"
printf 'x\n' > "$T/root/strats_new2.txt"
for _p in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
    printf 'x\n' > "$T/root/extra_strats/$_p/Strategy.txt"
done
printf 'platform=openwrt\ntag=p-84.7\nref=test\n' > "$T/root/share/seed.meta"
printf 'platform=openwrt\ntag=p-84.7\nref=test\n' > "$T/root/share/payload.meta"
# pre-flight update.sh: marker + tag (восстановление tag — в preflight-тесте)
: > "$T/etc/.payload-initialized"
printf 'p-84.7\n' > "$T/etc/state/installed-tag"

_call() {
    # _call <action> [VAR=val ...]: unattended-контекст (stdin /dev/null).
    local _action="$1"; shift
    : > "$T/calls"
    ( unset Z2K_AU_MANUAL Z2K_AU_NO_JITTER
      export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
      # Имена намеренно динамические (VAR=val из "$@"; :? роняет пустое вслух).
      _v=; for _v in "$@"; do export "${_v?}"; done
      < /dev/null sh "$T/root/platform/openwrt/update.sh" "$_action" >/dev/null 2>&1
      echo "rc=$?" >> "$T/calls" )
}

_call apply Z2K_AU_MANUAL=1 Z2K_AU_NO_JITTER=1
assert_contains "manual apply идёт" "$T/calls" "apply-called"
_call check Z2K_AU_MANUAL=1 Z2K_AU_NO_JITTER=1
assert_contains "check идёт" "$T/calls" "check-called"
if grep -q "^sleep:" "$T/calls"; then
    _t_bad "manual/check спят (jitter не только плановым)"
else
    _t_ok
fi

printf 'Z2K_AUTO_UPDATE_ENABLED=0\n' > "$T/etc/config"
_call apply
assert_contains "unattended при выключенном: rc 0" "$T/calls" "rc=0"
if grep -q "apply-called" "$T/calls"; then
    _t_bad "выключенный unattended дошёл до apply"
else
    _t_ok
fi
_call apply Z2K_AU_MANUAL=1 Z2K_AU_NO_JITTER=1
assert_contains "ручной при выключенном идёт" "$T/calls" "apply-called"

printf 'ENABLED=1\n' > "$T/etc/config"
_call apply
assert_contains "плановый apply идёт" "$T/calls" "apply-called"
assert_contains "плановый jitter 7с" "$T/calls" "sleep:7"

# MANUAL=1 сам означает no jitter (баг C): БЕЗ отдельного NO_JITTER
_call apply Z2K_AU_MANUAL=1
assert_contains "manual apply идёт" "$T/calls" "apply-called"
if grep -q "^sleep:" "$T/calls"; then
    _t_bad "MANUAL=1 спит без NO_JITTER"
else
    _t_ok
fi

_t_done
