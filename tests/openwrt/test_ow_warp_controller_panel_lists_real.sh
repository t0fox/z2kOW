#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
CRATE="$ROOT/platform/openwrt/warp-controller"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-warp-panel-lists.XXXXXX")"
trap 'rm -rf "$T"' EXIT HUP INT TERM
_cargo_out="$T/cargo-target"
CARGO_TARGET_DIR="$_cargo_out" cargo build \
    --manifest-path "$CRATE/Cargo.toml" --bin z2k-warp-controller

export Z2K_PLATFORM=openwrt Z2K_ROOT="$ROOT" Z2K_ADAPTER_DIR="$ROOT/platform/openwrt"
export Z2K_TMP="$T/tmp" WARP_LOCK_DIR="$T/tmp/warp/mutate.lock"
export WARP_CONTROLLER_BIN="$_cargo_out/debug/z2k-warp-controller"
export WARP_LISTS_DIR="$T/lists/warp" WARP_GAMES_DIR="$T/lists/warp/games"
export WARP_ENABLED_FILE="$WARP_LISTS_DIR/.enabled" WARP_SCRIPT="$ROOT/platform/openwrt/warp.sh"
export CONFIG_FILE="$T/config" ZAPRET2_DIR="$ROOT"
mkdir -p "$WARP_GAMES_DIR"
touch "$WARP_LISTS_DIR/.legacy-aggregate-purged"
printf 'GAME_WARP_ENABLED=0\n' > "$CONFIG_FILE"
. "$ROOT/webpanel/cgi/actions.sh"

warp_wdtt_set 1
[ "$(grep '^Z2K_WARP_WDTT=' "$CONFIG_FILE" | cut -d= -f2)" = 1 ]
if warp_wdtt_set true; then
    echo 'некорректное значение WDTT было принято' >&2
    exit 1
fi
[ "$(grep '^Z2K_WARP_WDTT=' "$CONFIG_FILE" | cut -d= -f2)" = 1 ]

scope() {
    "$WARP_CONTROLLER_BIN" policy-scope \
        "$WARP_LISTS_DIR" "$WARP_GAMES_DIR" "$WARP_ENABLED_FILE" "$WARP_LISTS_DIR/devices.txt"
}

check_scope() {
    _got=$(scope)
    [ "$_got" = "$1" ] || {
        echo "ожидалась область WARP '$1', получено '$_got'" >&2
        exit 1
    }
}

check_scope all
printf '# offline device\n' > "$WARP_LISTS_DIR/devices.txt"
check_scope all
printf 'aa:bb:cc:dd:ee:ff\n' > "$WARP_LISTS_DIR/devices.txt"
check_scope full
touch "$WARP_LISTS_DIR/empty.txt"
check_scope devices
rm -f "$WARP_LISTS_DIR/devices.txt"
check_scope lists
printf 'missing-game\n' > "$WARP_ENABLED_FILE"
rm -f "$WARP_LISTS_DIR/empty.txt"
check_scope lists
rm -f "$WARP_ENABLED_FILE"
check_scope all

PASS=0
check() {
    if "$@"; then PASS=$((PASS + 1)); else echo "FAIL: $*" >&2; exit 1; fi
}

_saved="$(printf 'Example.COM\n8.8.8.8\ninvalid\n' | warp_list_save custom create)"
check test "$_saved" = 'saved=2 saved_ip=1 saved_domain=1 skipped_invalid=1'
check grep -qxF 'example.com' "$WARP_LISTS_DIR/custom.txt"
warp_list_toggle custom 0
check grep -qxF custom "$WARP_LISTS_DIR/.disabled"
warp_list_toggle custom 1
check test ! -s "$WARP_LISTS_DIR/.disabled"

printf '1.1.1.1\n' > "$WARP_GAMES_DIR/steam.txt"
warp_game_toggle steam 1
check grep -qxF steam "$WARP_ENABLED_FILE"
warp_game_toggle steam 0
check test ! -s "$WARP_ENABLED_FILE"

warp_list_toggle custom 0
warp_list_delete custom
check test ! -e "$WARP_LISTS_DIR/custom.txt"
check test ! -s "$WARP_LISTS_DIR/.disabled"

printf '# вручную\n192.168.1.7\nAA-BB-CC-DD-EE-FF\n' > "$WARP_LISTS_DIR/devices.txt"
warp_device_toggle aa:bb:cc:dd:ee:ff 1
check test "$(cat "$WARP_LISTS_DIR/devices.txt")" = "$(printf '# вручную\n192.168.1.7\naa:bb:cc:dd:ee:ff')"
warp_device_toggle AA-BB-CC-DD-EE-FF 0
check test "$(cat "$WARP_LISTS_DIR/devices.txt")" = "$(printf '# вручную\n192.168.1.7')"

_devices="$(printf 'AA-BB-CC-DD-EE-FF\n192.168.1.8\n8.8.8.8\n' | warp_devices_save)"
check test "$_devices" = 'entries=2 dropped=1'
check test "$(cat "$WARP_LISTS_DIR/devices.txt")" = "$(printf 'aa:bb:cc:dd:ee:ff\n192.168.1.8')"

# Ошибка применения после атомарной записи должна восстановить прежний выбор.
cp "$WARP_LISTS_DIR/devices.txt" "$T/devices.before"
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_WDTT=0\n' > "$CONFIG_FILE"
cat > "$T/fail-warp" <<'EOF_FAIL'
#!/bin/sh
exit 1
EOF_FAIL
chmod 0755 "$T/fail-warp"
WARP_SCRIPT="$T/fail-warp"; export WARP_SCRIPT
if warp_wdtt_set 1; then
    echo 'ошибка применения WDTT была принята' >&2
    exit 1
fi
[ "$(grep '^Z2K_WARP_WDTT=' "$CONFIG_FILE" | cut -d= -f2)" = 0 ]
if warp_device_toggle 11:22:33:44:55:66 1; then
    echo 'сбой применения списка устройств был принят' >&2
    exit 1
fi
check cmp "$T/devices.before" "$WARP_LISTS_DIR/devices.txt"

printf 'SUITE[ow-warp-controller-panel-lists-real]: pass=%s fail=0\n' "$PASS"
