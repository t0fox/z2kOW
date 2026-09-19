#!/bin/sh
# test_ow_offload.sh - global fw4 ownership and exact UCI restoration.
# The adapter must let stock zapret2 own selective offload while NFQUEUE is
# active, and must return the user's original UCI shape after stop/rollback.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-offload"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-offload.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/etc/state" "$T/run"
export PATH="$T/bin:/usr/bin:/bin"
export Z2K_ROOT="$REPO" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp" Z2K_RUN="$T/run"
export Z2K_STATE="$T/etc/state" Z2K_FW4_OFFLOAD_STATE="$T/etc/state/fw4-offload.state"
export Z2K_FW4_RELOAD="$T/firewall" INIT_APPLY_FW=1

printf 'flow_offloading=1\nflow_offloading_hw=0\n' > "$T/uci.db"
: > "$T/uci.log"
cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
db=${UCI_DB:?}
while [ "$1" = -q ]; do shift; done
case "$1" in
    get)
        key=${2##*.}
        sed -n "s/^${key}=//p" "$db" | tail -1
        [ -s "$db" ] && grep -q "^${key}=" "$db"
        ;;
    set)
        assignment=$2; key=${assignment%%=*}; value=${assignment#*=}
        sed "/^${key}=/d" "$db" > "$db.new"
        printf '%s=%s\n' "$key" "$value" >> "$db.new"
        mv "$db.new" "$db"
        echo "set:$assignment" >> "$UCI_LOG"
        ;;
    delete)
        key=${2##*.}
        sed "/^${key}=/d" "$db" > "$db.new"
        mv "$db.new" "$db"
        echo "delete:$key" >> "$UCI_LOG"
        ;;
    commit) echo commit >> "$UCI_LOG" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/uci"
cat > "$T/firewall" <<EOF
#!/bin/sh
echo "reload:\$1" >> "$T/uci.log"
exit 0
EOF
chmod +x "$T/firewall"
export UCI_DB="$T/uci.db" UCI_LOG="$T/uci.log"

. "$REPO/platform/openwrt/paths.sh" || exit 1
. "$REPO/platform/openwrt/env.sh" || exit 1
. "$REPO/platform/openwrt/firewall.sh" || exit 1

# Reproduce the conflict: global fw4 offload is enabled before z2k starts.
z2k_ow_offload_prepare
assert_eq "prepare rc" "0" "$?"
assert_contains "software global disabled" "$T/uci.db" "flow_offloading=0"
assert_contains "hardware global disabled" "$T/uci.db" "flow_offloading_hw=0"
assert_contains "snapshot preserves original software" "$T/etc/state/fw4-offload.state" "$(printf 'flow_offloading\t1\t1')"
assert_contains "snapshot preserves original hardware" "$T/etc/state/fw4-offload.state" "$(printf 'flow_offloading_hw\t1\t0')"
assert_contains "fw4 reloaded after disable" "$T/uci.log" "reload:reload"

# Restore after runtime teardown: both values must be byte-for-byte equivalent
# to the original UCI state and the ownership snapshot must be consumed.
z2k_ow_offload_restore
assert_eq "restore rc" "0" "$?"
assert_contains "software restored" "$T/uci.db" "flow_offloading=1"
assert_contains "hardware restored" "$T/uci.db" "flow_offloading_hw=0"
[ ! -f "$T/etc/state/fw4-offload.state" ] && _t_ok || _t_bad "snapshot не удалён после restore"

# Absent options are part of the user's state too: restore must delete the
# temporary option rather than materialize a new `flow_offloading_hw=0`.
printf 'flow_offloading=1\n' > "$T/uci.db"
z2k_ow_offload_prepare
assert_contains "snapshot records absent hardware" "$T/etc/state/fw4-offload.state" "$(printf 'flow_offloading_hw\t0\t')"
z2k_ow_offload_restore
assert_not_contains "absent hardware restored as absent" "$T/uci.db" '^flow_offloading_hw='

# An already-disabled global configuration is not touched and does not create
# a restoration obligation.
printf 'flow_offloading=0\n' > "$T/uci.db"
: > "$T/uci.log"
z2k_ow_offload_prepare
assert_eq "already disabled prepare" "0" "$?"
[ ! -f "$T/etc/state/fw4-offload.state" ] && _t_ok || _t_bad "лишний snapshot для disabled UCI"
[ ! -s "$T/uci.log" ] && _t_ok || _t_bad "disabled UCI без причины перезагружен"

_t_done
