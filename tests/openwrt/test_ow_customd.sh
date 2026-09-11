#!/bin/sh
# tests/openwrt/test_ow_customd.sh - Step 5: точка расширения custom.d работает.
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/fixture.sh"
_t_plan "ow-customd"
ow_fixture_init || { echo "FAIL[ow-customd]: fixture" >&2; exit 1; }
trap ow_fixture_done EXIT INT TERM

AD="$REPO/platform/openwrt"
. "$AD/paths.sh"
Z2K_CUSTOM_DIR="$T/custom.d"
export Z2K_CUSTOM_DIR
mkdir -p "$Z2K_CUSTOM_DIR"
. "$AD/firewall.sh"

# пустой custom.d, DISABLE_CUSTOM unset (=1 дефолт upstream) — тихо
unset DISABLE_CUSTOM
z2k_ow_custom_daemons 1 && _t_ok || _t_bad "пустой custom.d"

# хук вызывается с 1/0
cat > "$Z2K_CUSTOM_DIR/10-test.sh" <<EOF
#!/bin/sh
z2k_custom_daemons() { echo "hook:\$1" >> "$T/calls"; }
EOF
DISABLE_CUSTOM=0; export DISABLE_CUSTOM
: > "$T/calls"
z2k_ow_custom_daemons 1 && z2k_ow_custom_daemons 0
assert_eq "хук вызван start+stop" "hook:1
hook:0" "$(cat "$T/calls")"

# DISABLE_CUSTOM=1 гасит раннер целиком
DISABLE_CUSTOM=1; export DISABLE_CUSTOM
: > "$T/calls"
z2k_ow_custom_daemons 1
assert_eq "DISABLE_CUSTOM=1 — хук не вызван" "" "$(cat "$T/calls")"

# файл без функции — пропускается без ошибки
cat > "$Z2K_CUSTOM_DIR/20-empty.sh" <<'EOF'
#!/bin/sh
# no z2k_custom_daemons here
EOF
DISABLE_CUSTOM=0; export DISABLE_CUSTOM
z2k_ow_custom_daemons 1 && _t_ok || _t_bad "файл без хука роняет раннер"

_t_done
