#!/bin/sh
# tests/openwrt/test_ow_restart.sh - §6: restart-service семантика + procd исполнитель.
# Тот же шаг, другой исполнитель: env.sh выставляет INIT_SCRIPT, который уже
# уважают и utils.sh, и au_step_restart_service (нулевых правок common).
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/fixture.sh"
_t_plan "ow-restart"
ow_fixture_init || { echo "FAIL[ow-restart]: fixture" >&2; exit 1; }
trap ow_fixture_done EXIT INT TERM

AD="$REPO/platform/openwrt"
. "$AD/paths.sh"
. "$AD/env.sh"
assert_eq "INIT_SCRIPT из env" "/etc/init.d/z2k" "$INIT_SCRIPT"
assert_eq "Z2K_CONFIG_FILE из env" "$T/etc/config" "$Z2K_CONFIG_FILE"
assert_eq "Z2K_AU_SBIN из env" "$T/root/bin" "$Z2K_AU_SBIN"

# функционально: au_step_restart_service дёргает именно $INIT_SCRIPT.
# shellcheck disable=SC1090,SC1091
. "$Z2K_LIB/utils.sh" >/dev/null 2>&1 || exit 1
. "$REPO/lib/auto_update.sh" >/dev/null 2>&1 || exit 1

T2="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-rs.XXXXXX")" || exit 1
trap 'ow_fixture_done; rm -rf "$T2"' EXIT INT TERM
export Z2K_AU_LOG_FILE="$T2/au.log" Z2K_AU_TMP_DIR="$T2/au"
mkdir -p "$T2/bin"
cat > "$T2/bin/fake-init" <<EOF
#!/bin/sh
echo "init-called:\$*" >> "$T2/calls"
exit 0
EOF
chmod +x "$T2/bin/fake-init"
printf 'ENABLED=1\n' > "$T/etc/config"
INIT_SCRIPT="$T2/bin/fake-init" Z2K_CONFIG_FILE="$T/etc/config" \
    au_step_restart_service >/dev/null 2>&1
assert_eq "шаг зовёт restart исполнителя" "init-called:restart" "$(cat "$T2/calls" 2>/dev/null)"

# ENABLED=0: пользователь выключил — не трогаем, но и не валим (rc 0)
printf 'ENABLED=0\n' > "$T/etc/config"
: > "$T2/calls"
INIT_SCRIPT="$T2/bin/fake-init" Z2K_CONFIG_FILE="$T/etc/config" \
    au_step_restart_service >/dev/null 2>&1
_rc=$?
assert_eq "выключенный обход: rc 0" "0" "$_rc"
assert_eq "выключенный обход: restart не звали" "" "$(cat "$T2/calls" 2>/dev/null)"

_t_done
