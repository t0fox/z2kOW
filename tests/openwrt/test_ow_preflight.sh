#!/bin/sh
# tests/openwrt/test_ow_preflight.sh - update.sh pre-flight состояний.
# Один sysroot: lib = stub'ы (сорсятся launcher'ом И удовлетворяют payload_ok
# как непустые файлы); platform — симлинки на настоящее дерево.
#   marker отсутствует -> rc 1, au_run_apply НЕ вызван (common resync
#     first-run тем самым тоже не запущен — никакого false-current);
#   tag отсутствует + marker + payload ok -> tag из seed.meta, apply идёт;
#   tag отсутствует + payload неполон -> rc 1.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-preflight"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-pre.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin"
printf '#!/bin/sh\necho "sleep:$*" >> "%s/calls"\n' "$T" > "$T/bin/sleep"
chmod +x "$T/bin/sleep"
unset Z2K_AU_MANUAL Z2K_AU_NO_JITTER
export PATH="$T/bin:$PATH"

_mkpayload() {
    rm -rf "$T/sys"
    SYS="$T/sys"; export SYS
    export Z2K_ROOT="$SYS/usr/lib/z2k" Z2K_ETC="$SYS/etc/z2k" Z2K_TMP="$SYS/tmp/z2k"
    mkdir -p "$Z2K_ROOT/lib" "$Z2K_ROOT/lua" "$Z2K_ROOT/manifests" \
             "$Z2K_ROOT/extra_strats/TCP/RKN" "$Z2K_ROOT/extra_strats/TCP/YT" \
             "$Z2K_ROOT/extra_strats/TCP/YT_GV" "$Z2K_ROOT/extra_strats/UDP/YT" \
             "$Z2K_ROOT/share" "$Z2K_ROOT/lists" \
             "$Z2K_ROOT/platform/openwrt" "$Z2K_ETC/state" "$Z2K_TMP"
    for _f in paths.sh env.sh bootstrap.sh update.sh reinstall.sh; do
        ln -s "$REPO/platform/openwrt/$_f" "$Z2K_ROOT/platform/openwrt/$_f"
    done
    cat > "$Z2K_ROOT/lib/utils.sh" <<'EOF'
#!/bin/sh
safe_config_read() {
    if [ "$1" = "Z2K_AUTO_UPDATE_ENABLED" ]; then
        grep -m1 '^Z2K_AUTO_UPDATE_ENABLED=' "$2" 2>/dev/null | cut -d= -f2 | tr -d ' "\047'
        return 0
    fi
    printf '%s' "$3"
}
z2k_host_jitter() { printf '0'; }
EOF
    cat > "$Z2K_ROOT/lib/auto_update.sh" <<EOF
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
    printf '#!/bin/sh\n# stub\n' > "$Z2K_ROOT/lib/config_official.sh"
    printf '#!/bin/sh\n# stub\n' > "$Z2K_ROOT/lib/strategies.sh"
    for _f in lua/z2k-alert.lua lua/z2k-state-persist.lua strats_new2.txt \
               extra_strats/TCP/RKN/Strategy.txt extra_strats/TCP/YT/Strategy.txt \
               extra_strats/TCP/YT_GV/Strategy.txt extra_strats/UDP/YT/Strategy.txt; do
        printf 'x\n' > "$Z2K_ROOT/$_f"
    done
    printf 'platform=openwrt\ntag=p-84.7\nref=abc123\n' > "$Z2K_ROOT/share/seed.meta"
    printf 'platform=openwrt\ntag=p-84.7\nref=abc123\n' > "$Z2K_ROOT/share/payload.meta"
    printf 'ENABLED=1\n' > "$Z2K_ETC/config"
}
_call() {
    local _action="$1"; shift
    : > "$T/calls"
    ( unset Z2K_AU_MANUAL Z2K_AU_NO_JITTER
      export Z2K_ROOT Z2K_ETC Z2K_TMP
      _v=; for _v in "$@"; do export "$_v"; done
      < /dev/null sh "$Z2K_ROOT/platform/openwrt/update.sh" "$_action" >/dev/null 2>&1
      echo "rc=$?" >> "$T/calls" )
}

# --- 1. marker отсутствует + payload ok + tag ok -> complete + mark, apply идёт ---
# (seed_ensure достраивает недостающее; отказ — только если нечего достроить)
_mkpayload
rm -f "$Z2K_ETC/.payload-initialized"
_call apply Z2K_AU_MANUAL=1 Z2K_AU_NO_JITTER=1
assert_contains "без marker, но всё цело: rc 0" "$T/calls" "rc=0"
assert_eq "marker доставлен" "1" "$([ -f "$Z2K_ETC/.payload-initialized" ] && echo 1 || echo 0)"
assert_contains "apply идёт" "$T/calls" "apply-called"
# --- 1b. marker отсутствует + чинить нечем (payload partial, tarball нет) ---
# Ломаем только НЕ sourced-файлы (см. комментарий к кейсу 3): удаление
# lib/utils.sh убило бы сам launcher на строке source (rc 2 из dash),
# а не проверяемый путь seed_ensure (rc 1).
_mkpayload
rm -f "$Z2K_ETC/.payload-initialized" "$Z2K_ETC/state/installed-tag"
rm -rf "$Z2K_ROOT/lua" "$Z2K_ROOT/extra_strats" "$Z2K_ROOT/strats_new2.txt"
_call apply Z2K_AU_MANUAL=1 Z2K_AU_NO_JITTER=1
assert_contains "partial без tarball: rc 1" "$T/calls" "rc=1"
if grep -q "apply-called" "$T/calls"; then
    _t_bad "partial без tarball дошли до apply"
else
    _t_ok
fi
assert_eq "partial без tarball: tag не создан" "0" "$([ -f "$Z2K_ETC/state/installed-tag" ] && echo 1 || echo 0)"

# --- 2. tag отсутствует + marker + payload ok -> tag из meta, apply идёт ---
_mkpayload
: > "$Z2K_ETC/.payload-initialized"
rm -f "$Z2K_ETC/state/installed-tag"
_call apply Z2K_AU_MANUAL=1 Z2K_AU_NO_JITTER=1
assert_eq "tag восстановлен из meta" "p-84.7" "$(cat "$Z2K_ETC/state/installed-tag" 2>/dev/null)"
assert_contains "apply идёт после restore" "$T/calls" "apply-called"

# --- 3. tag отсутствует + payload неполон -> отказ ---
# (ломаем НЕ sourced-файл: удаление lib/utils.sh убило бы сам launcher
# на строке source — это тоже отказ, но не тот, что проверяем)
_mkpayload
: > "$Z2K_ETC/.payload-initialized"
rm -f "$Z2K_ETC/state/installed-tag" "$Z2K_ROOT/lua/z2k-alert.lua"
_call apply Z2K_AU_MANUAL=1 Z2K_AU_NO_JITTER=1
assert_contains "битый payload: rc 1" "$T/calls" "rc=1"
if grep -q "apply-called" "$T/calls"; then
    _t_bad "с битым payload дошли до apply"
else
    _t_ok
fi

_t_done
