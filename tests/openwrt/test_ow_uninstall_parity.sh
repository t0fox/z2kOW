#!/bin/sh
# Upstream p-86.15 uninstall parity and OpenWrt ownership-boundary regression.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-uninstall-parity"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

# The comparison source is the exact commit approved by the controlled manifest.
assert_contains "parity source is pinned upstream commit" "$REPO/UPDATES.json" \
    '"commit": "b90611f52ae5ba034d0181a3252efda6ecc95671"'
assert_contains "CLI exposes upstream uninstall action" "$REPO/platform/openwrt/z2kow.sh" \
    'uninstall|remove'
assert_contains "CLI delegates to canonical uninstaller" "$REPO/platform/openwrt/z2kow.sh" \
    'platform/openwrt/uninstall.sh'
assert_contains "WebPanel capability enables the installed backend" "$REPO/webpanel/cgi/platform.sh" \
    '"uninstall":%s'
assert_contains "WebPanel delegates to canonical uninstaller helper" "$REPO/webpanel/cgi/platform.sh" \
    'z2k_ow_uninstall_async'
assert_not_contains "old package-manager-only message is gone" \
    "$REPO/webpanel/cgi/platform.sh" 'удаление z2k на OpenWrt — через пакетный менеджер'
assert_contains "uninstall removes the single canonical release record" \
    "$REPO/platform/openwrt/uninstall.sh" 'Z2K_OW_INSTALLED_RELEASE_FILE'
assert_contains "uninstall preserves WARP device identity" \
    "$REPO/platform/openwrt/uninstall.sh" 'device.json'
assert_contains "uninstall does not expose a second purge mode" \
    "$REPO/platform/openwrt/uninstall.sh" 'Z2K_UNINSTALL_CONFIRMED'
unset Z2K_OW_SYSROOT
. "$REPO/platform/openwrt/uninstall.sh"
(
    . "$REPO/platform/openwrt/paths.sh"
    _z2k_ow_uninstall_path_is_safe /usr/lib/z2k "$Z2K_OW_CANON_ROOT_SUFFIX" || exit 1
    ! _z2k_ow_uninstall_path_is_safe /tmp/foreign/usr/lib/z2k "$Z2K_OW_CANON_ROOT_SUFFIX"
) && _t_ok || _t_bad "path guard accepts only canonical paths or an explicit sysroot"

T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-uninstall.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

export Z2K_ROOT="$T/usr/lib/z2k"
export Z2K_ADAPTER_DIR="$Z2K_ROOT/platform/openwrt"
export Z2K_ETC="$T/etc/z2k"
export Z2K_CONFIG="$Z2K_ETC/config"
export Z2K_STATE="$Z2K_ETC/state"
export Z2K_USER_LISTS="$Z2K_ETC/user-lists"
export Z2K_OW_INSTALLED_RELEASE_FILE="$Z2K_STATE/installed-release"
export Z2K_TMP="$T/tmp/z2k"
export Z2K_OW_INSTALL_TMP="$T/tmp/z2kow-install-stage"
export Z2K_WARP_TMP="$T/tmp/z2k-warp"
export Z2K_ZAPRET2_RUNTIME="$T/opt/zapret2"
export WARP_DEVICE="$Z2K_STATE/warp/device.json"
export Z2K_UNINSTALL_TEST_LOG="$T/uninstall.log"
export Z2K_CRON_TAB="$T/etc/crontabs/root"
export Z2K_OW_CORE_INIT="$T/etc/init.d/z2k"
export Z2K_OW_PANEL_INIT="$T/etc/init.d/z2k-webpanel"
export Z2K_OW_HOTPLUG_FILE="$T/etc/hotplug.d/iface/90-z2k"
export Z2K_OW_SYSCTL_FILE="$T/etc/sysctl.d/99-z2k.conf"
export Z2K_OW_WARP_NFT_FILE="$T/usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft"
export Z2K_OW_CLI_FILE="$T/usr/bin/z2kow"
export Z2K_OW_INSTALL_RELEASE_FILE="$T/usr/sbin/install_release"
export Z2K_OW_ROLLBACK_DIR="$T/opt/z2k-rollback"
export Z2K_OW_INSTALL_WORK="$T/usr/lib/.z2k-install"
export Z2K_OW_INSTALL_LOCK="$T/usr/lib/.z2k-install.lock"
export Z2K_FW4_OFFLOAD_STATE="$Z2K_STATE/fw4-offload.state"
export Z2K_OW_NFT_STATE="$T/nft-state"
export Z2K_OW_FW4_STATE="$T/fw4-state"
export Z2K_OW_NFT_BIN="$T/bin/nft"
export Z2K_FW4_RELOAD="$T/etc/init.d/firewall"
export Z2K_OW_PROC_ROOT="$T/proc"
export Z2K_OW_DHCP_UCI="$T/etc/config/dhcp"
export Z2K_OW_FAIL_CLEANUP=""
export Z2K_OW_TESTING=1
export Z2K_OW_SYSROOT="$T"

mkdir -p "$Z2K_ROOT/platform/openwrt" "$Z2K_ETC/conf" "$Z2K_ETC/webpanel" \
    "$Z2K_USER_LISTS/custom-strategies" "$Z2K_STATE/autocircular" \
    "$(dirname "$WARP_DEVICE")" "$Z2K_ZAPRET2_RUNTIME/nfq2" \
    "$(dirname "$Z2K_CRON_TAB")" "$(dirname "$Z2K_OW_CORE_INIT")" \
    "$(dirname "$Z2K_OW_HOTPLUG_FILE")" "$(dirname "$Z2K_OW_SYSCTL_FILE")" \
    "$(dirname "$Z2K_OW_WARP_NFT_FILE")" "$(dirname "$Z2K_OW_CLI_FILE")" \
    "$(dirname "$Z2K_OW_INSTALL_RELEASE_FILE")" "$Z2K_OW_ROLLBACK_DIR" \
    "$Z2K_OW_INSTALL_WORK" "$(dirname "$Z2K_OW_NFT_BIN")" \
    "$(dirname "$Z2K_FW4_RELOAD")" "$T/etc/rc.d" \
    "$T/www/cgi-bin" "$T/www/luci-static/resources" \
    "$(dirname "$Z2K_OW_DHCP_UCI")" || exit 1
for _f in paths.sh env.sh release.sh release_state.sh webpanel.sh uninstall.sh; do
    cp "$REPO/platform/openwrt/$_f" "$Z2K_ADAPTER_DIR/$_f"
done
mkdir -p "$T/bin" "$T/etc/config" "$T/etc/rc.d"

# Replace adapter files only inside this disposable fixture. These stand-ins
# record each platform cleanup and remove only tagged z2k entries, preserving
# unrelated firewall/UCI/cron state.
cat > "$Z2K_ROOT/platform/openwrt/schedule.sh" <<'EOF'
_remove_z2k_cron() {
    [ -f "$Z2K_CRON_TAB" ] || return 0
    awk '!/# z2k-/' "$Z2K_CRON_TAB" > "$Z2K_CRON_TAB.new" || return 1
    mv -f "$Z2K_CRON_TAB.new" "$Z2K_CRON_TAB"
}
z2k_ow_cron_remove() { echo cron >> "$Z2K_UNINSTALL_TEST_LOG"; _remove_z2k_cron; }
z2k_ow_tg_cron_remove() { echo tg-cron >> "$Z2K_UNINSTALL_TEST_LOG"; _remove_z2k_cron; }
z2k_ow_rt_cron_remove() { echo rt-cron >> "$Z2K_UNINSTALL_TEST_LOG"; _remove_z2k_cron; }
z2k_ow_warp_cron_remove() { echo warp-cron >> "$Z2K_UNINSTALL_TEST_LOG"; _remove_z2k_cron; }
z2k_ow_fw_cron_remove() { echo fw-cron >> "$Z2K_UNINSTALL_TEST_LOG"; _remove_z2k_cron; }
z2k_ow_tcp16_cron_remove() { echo tcp16-cron >> "$Z2K_UNINSTALL_TEST_LOG"; _remove_z2k_cron; }
z2k_ow_tiktok_cron_remove() { echo tiktok-cron >> "$Z2K_UNINSTALL_TEST_LOG"; _remove_z2k_cron; }
EOF
cat > "$Z2K_ROOT/platform/openwrt/firewall.sh" <<'EOF'
z2k_ow_fw_remove() {
    echo fw-cleanup >> "$Z2K_UNINSTALL_TEST_LOG"
    grep -v 'z2kOW' "$Z2K_OW_NFT_STATE" > "$Z2K_OW_NFT_STATE.new" || return 1
    mv -f "$Z2K_OW_NFT_STATE.new" "$Z2K_OW_NFT_STATE"
}
z2k_ow_stop_verify() { ! grep -q 'z2kOW' "$Z2K_OW_NFT_STATE"; }
z2k_ow_offload_restore() {
    echo offload-restore >> "$Z2K_UNINSTALL_TEST_LOG"
    rm -f "$Z2K_FW4_OFFLOAD_STATE"
}
EOF
cat > "$Z2K_ROOT/platform/openwrt/tg.sh" <<'EOF'
z2k_ow_tg() {
    echo "tg-$1" >> "$Z2K_UNINSTALL_TEST_LOG"
    [ "$1" = cleanup ] || return 0
    sed '/z2k_tg/d' "$Z2K_OW_NFT_STATE" > "$Z2K_OW_NFT_STATE.new" || return 1
    mv -f "$Z2K_OW_NFT_STATE.new" "$Z2K_OW_NFT_STATE"
    [ "${Z2K_OW_FAIL_CLEANUP:-}" != tg ]
}
z2k_ow_tg_running() { [ -f "$Z2K_TG_PROCESS" ]; }
z2k_ow_tg_pids() { [ ! -f "$Z2K_TG_PROCESS" ] || cat "$Z2K_TG_PROCESS"; }
EOF
cat > "$Z2K_ROOT/platform/openwrt/rt.sh" <<'EOF'
z2k_ow_rt() {
    echo "rt-$1" >> "$Z2K_UNINSTALL_TEST_LOG"
    [ "$1" = cleanup ] || return 0
    sed -e '/z2k_rt/d' "$Z2K_OW_NFT_STATE" > "$Z2K_OW_NFT_STATE.new" || return 1
    mv -f "$Z2K_OW_NFT_STATE.new" "$Z2K_OW_NFT_STATE"
    sed -e '/z2k_rt/d' "$Z2K_OW_DHCP_UCI" > "$Z2K_OW_DHCP_UCI.new" || return 1
    mv -f "$Z2K_OW_DHCP_UCI.new" "$Z2K_OW_DHCP_UCI"
    [ "${Z2K_OW_FAIL_CLEANUP:-}" != rt ]
}
z2k_ow_rt_running() { [ -f "$Z2K_RT_PROCESS" ]; }
z2k_ow_rt_pids() { [ ! -f "$Z2K_RT_PROCESS" ] || cat "$Z2K_RT_PROCESS"; }
EOF
cat > "$Z2K_ROOT/platform/openwrt/warp.sh" <<'EOF'
warp_running() { [ -f "$Z2K_WARP_PROCESS" ]; }
warp_pids() { [ ! -f "$Z2K_WARP_PROCESS" ] || cat "$Z2K_WARP_PROCESS"; }
z2k_ow_warp() {
    echo "warp-$1" >> "$Z2K_UNINSTALL_TEST_LOG"
    [ "$1" = cleanup ] || return 0
    sed -e '/z2k_warp/d' "$Z2K_OW_NFT_STATE" > "$Z2K_OW_NFT_STATE.new" || return 1
    mv -f "$Z2K_OW_NFT_STATE.new" "$Z2K_OW_NFT_STATE"
    rm -f "$Z2K_WARP_PROCESS"
    [ "${Z2K_OW_FAIL_CLEANUP:-}" != warp ]
}
EOF
cat > "$Z2K_ROOT/platform/openwrt/insta-ip.sh" <<'EOF'
z2k_ow_insta_uninstall() {
    echo insta-cleanup >> "$Z2K_UNINSTALL_TEST_LOG"
    sed -e '/z2k-insta-hosts/d' "$Z2K_OW_DHCP_UCI" > "$Z2K_OW_DHCP_UCI.new" || return 1
    mv -f "$Z2K_OW_DHCP_UCI.new" "$Z2K_OW_DHCP_UCI"
}
EOF
cat > "$Z2K_ROOT/platform/openwrt/tiktok.sh" <<'EOF'
z2k_ow_tiktok_uninstall() { echo tiktok-cleanup >> "$Z2K_UNINSTALL_TEST_LOG"; }
EOF
cat > "$Z2K_ROOT/platform/openwrt/panel.sh" <<'EOF'
wp_panel_running() { [ -f "$Z2K_PANEL_PROCESS" ]; }
EOF

cat > "$Z2K_OW_NFT_BIN" <<'EOF'
#!/bin/sh
[ "$1" = list ] && [ "$2" = ruleset ] || exit 2
cat "$Z2K_OW_FW4_STATE"
EOF
cat > "$Z2K_FW4_RELOAD" <<'EOF'
#!/bin/sh
echo "firewall-$1" >> "$Z2K_UNINSTALL_TEST_LOG"
[ -e "$Z2K_OW_WARP_NFT_FILE" ] && exit 0
if [ "${Z2K_OW_KEEP_FW4_RULE:-0}" != 1 ]; then
    grep -vF '!z2k: WARP forwarded traffic' "$Z2K_OW_FW4_STATE" > "$Z2K_OW_FW4_STATE.new"
    _rc=$?
    [ "$_rc" -le 1 ] || exit 1
    mv -f "$Z2K_OW_FW4_STATE.new" "$Z2K_OW_FW4_STATE"
fi
exit 0
EOF
chmod +x "$Z2K_OW_NFT_BIN" "$Z2K_FW4_RELOAD"

cat > "$Z2K_OW_CORE_INIT" <<'EOF'
#!/bin/sh
echo "core-$1" >> "$Z2K_UNINSTALL_TEST_LOG"
case "$1" in
    disable) rm -f "$Z2K_RC_CORE" ;;
    stop) rm -f "$Z2K_CORE_PROCESS" "$Z2K_TG_PROCESS" "$Z2K_RT_PROCESS" "$Z2K_WARP_PROCESS" ;;
esac
exit 0
EOF
cat > "$Z2K_OW_PANEL_INIT" <<'EOF'
#!/bin/sh
echo "panel-$1" >> "$Z2K_UNINSTALL_TEST_LOG"
case "$1" in
    disable) rm -f "$Z2K_RC_PANEL" ;;
    stop) rm -f "$Z2K_PANEL_PROCESS" ;;
esac
exit 0
EOF
chmod +x "$Z2K_OW_CORE_INIT" "$Z2K_OW_PANEL_INIT"
export Z2K_RC_CORE="$T/etc/rc.d/S90z2k" Z2K_RC_PANEL="$T/etc/rc.d/S95z2k-webpanel"
ln -s ../init.d/z2k "$Z2K_RC_CORE"
ln -s ../init.d/z2k-webpanel "$Z2K_RC_PANEL"
export Z2K_CORE_PROCESS="$T/core.process" Z2K_PANEL_PROCESS="$T/panel.process"
export Z2K_TG_PROCESS="$T/tg.process" Z2K_RT_PROCESS="$T/rt.process" Z2K_WARP_PROCESS="$T/warp.process"

# Upstream user data is deleted with CONFIG_DIR and the product tree; the
# registered WARP identity is the one explicit exception.
printf 'ENABLED=1\nUSER_SETTING=keep-only-for-test\n' > "$Z2K_ETC/config"
printf 'user.example\n' > "$Z2K_USER_LISTS/whitelist.txt"
printf 'custom.example\n' > "$Z2K_USER_LISTS/extra-domains.txt"
printf 'custom strategy\n' > "$Z2K_USER_LISTS/custom-strategies/rkn_tcp.txt"
printf 'autocircular\n' > "$Z2K_STATE/autocircular/state.tsv"
printf 'tcp16\n' > "$Z2K_STATE/tcp16_sni.txt"
printf 'tag=p-86.13\nseq=136\n' > "$Z2K_STATE/installed-release"
printf '8099\n' > "$Z2K_ETC/webpanel/port"
printf '{"id":"warp-device-preserved"}\n' > "$WARP_DEVICE"
printf '{"account":"preserve"}\n' > "$(dirname "$WARP_DEVICE")/account.json"
printf 'license-preserve\n' > "$(dirname "$WARP_DEVICE")/license"
chmod 600 "$WARP_DEVICE"
printf 'payload\n' > "$Z2K_ROOT/runtime-file"
printf 'nfqws2\n' > "$Z2K_ZAPRET2_RUNTIME/nfq2/nfqws2"
printf 'rollback snapshot\n' > "$Z2K_OW_ROLLBACK_DIR/metadata"
printf 'flow_offloading=1\nflow_offloading_hw=0\n' > "$Z2K_FW4_OFFLOAD_STATE"
mkdir -p "$T/opt/z2k-upgrade-backup" "$T/opt/zapret"
printf 'upstream leaves this backup\n' > "$T/opt/z2k-upgrade-backup/keep"
printf 'foreign runtime\n' > "$T/opt/zapret/keep"

printf '%s\n' \
    '* * * * * foreign-job # user-owned' \
    '0 3 * * * /usr/lib/z2k/update.sh # z2k-updater' \
    '0 4 * * * /usr/lib/z2k/list-refresh.sh # z2k-lists' \
    '*/5 * * * * /usr/lib/z2k/tg-check.sh # z2k-tg-health' > "$Z2K_CRON_TAB"
printf 'chain foreign keep\nrule z2kOW core\nrule z2k_tg owned\nrule z2k_rt owned\nrule z2k_warp owned\n' \
    > "$Z2K_OW_NFT_STATE"
printf '%s\n' 'table inet fw4 {' ' chain forward {' \
    '  comment "!z2k: WARP forwarded traffic";' ' }' '}' > "$Z2K_OW_FW4_STATE"
printf 'config dnsmasq\nlist dhcp.@dnsmasq[0].addnhosts=/etc/z2k/state/insta-hosts # z2k-insta-hosts\nconfig domain z2k_rt_rutracker\nconfig domain foreign\n' \
    > "$Z2K_OW_DHCP_UCI"
printf 'foreign firewall config\n' > "$T/etc/config/firewall"
printf 'foreign uhttpd settings\n' > "$T/etc/config/uhttpd"
printf 'foreign luci CGI\n' > "$T/www/cgi-bin/luci"
printf 'foreign LuCI static\n' > "$T/www/luci-static/resources/main.css"
printf 'foreign hotplug\n' > "$T/etc/hotplug.d/iface/99-foreign"
printf 'foreign init\n' > "$T/etc/init.d/S80lighttpd"
for _f in "$Z2K_OW_HOTPLUG_FILE" "$Z2K_OW_SYSCTL_FILE" "$Z2K_OW_WARP_NFT_FILE" \
         "$Z2K_OW_CLI_FILE" "$Z2K_OW_INSTALL_RELEASE_FILE"; do
    printf 'z2kow-owned\n' > "$_f"
done
touch "$Z2K_CORE_PROCESS" "$Z2K_PANEL_PROCESS" "$Z2K_TG_PROCESS" "$Z2K_RT_PROCESS" "$Z2K_WARP_PROCESS"

. "$REPO/platform/openwrt/uninstall.sh"
printf 'no\n' > "$T/confirm.txt"
Z2K_UNINSTALL_TTY="$T/confirm.txt" z2k_ow_uninstall_main cli >/dev/null
assert_file "cancel leaves installed payload untouched" "$Z2K_ROOT/runtime-file"
mkdir "$Z2K_OW_INSTALL_LOCK"
printf '%s\n' "$$" > "$Z2K_OW_INSTALL_LOCK/pid"
printf 'yes\n' > "$T/confirm.txt"
_locked_rc=0; Z2K_UNINSTALL_TTY="$T/confirm.txt" z2k_ow_uninstall_main cli >/dev/null 2>&1 || _locked_rc=$?
assert_eq "uninstall refuses a concurrent release transaction" "1" "$_locked_rc"
[ -e "$Z2K_CORE_PROCESS" ] && _t_ok || _t_bad "lock conflict does not stop the service"
rm -rf "$Z2K_OW_INSTALL_LOCK"
Z2K_UNINSTALL_TTY="$T/confirm.txt" z2k_ow_uninstall_main cli || _t_bad "fresh install uninstall succeeds"
assert_contains "uninstall stops core service" "$Z2K_UNINSTALL_TEST_LOG" 'core-stop'
assert_contains "uninstall stops panel service before deleting it" "$Z2K_UNINSTALL_TEST_LOG" 'panel-stop'
assert_contains "uninstall removes upstream core scheduled work" "$Z2K_UNINSTALL_TEST_LOG" 'cron'
assert_contains "uninstall removes Telegram integration" "$Z2K_UNINSTALL_TEST_LOG" 'tg-cleanup'
assert_contains "uninstall removes RT integration" "$Z2K_UNINSTALL_TEST_LOG" 'rt-cleanup'
assert_contains "uninstall removes WARP integration" "$Z2K_UNINSTALL_TEST_LOG" 'warp-cleanup'
assert_contains "uninstall removes Insta host integration" "$Z2K_UNINSTALL_TEST_LOG" 'insta-cleanup'
assert_contains "uninstall removes TikTok DNS integration" "$Z2K_UNINSTALL_TEST_LOG" 'tiktok-cleanup'
[ ! -e "$Z2K_ROOT" ] && _t_ok || _t_bad "owned product payload removed"
[ ! -e "$Z2K_ZAPRET2_RUNTIME" ] && _t_ok || _t_bad "owned dataplane removed"
[ ! -e "$Z2K_OW_ROLLBACK_DIR" ] && _t_ok || _t_bad "owned rollback snapshot removed"
[ ! -e "$Z2K_ETC/config" ] && _t_ok || _t_bad "user config follows upstream uninstall semantics"
[ ! -e "$Z2K_USER_LISTS/whitelist.txt" ] && _t_ok || _t_bad "whitelist follows upstream uninstall semantics"
[ ! -e "$Z2K_USER_LISTS/extra-domains.txt" ] && _t_ok || _t_bad "extra-domains follows upstream uninstall semantics"
[ ! -e "$Z2K_USER_LISTS/custom-strategies/rkn_tcp.txt" ] && _t_ok || _t_bad "custom strategies follow upstream uninstall semantics"
[ ! -e "$Z2K_STATE/autocircular/state.tsv" ] && _t_ok || _t_bad "autocircular state removed"
[ ! -e "$Z2K_STATE/tcp16_sni.txt" ] && _t_ok || _t_bad "TCP16 state removed"
[ ! -e "$Z2K_STATE/installed-release" ] && _t_ok || _t_bad "canonical release state removed"
[ ! -e "$Z2K_ETC/webpanel/port" ] && _t_ok || _t_bad "WebPanel settings follow upstream uninstall semantics"
assert_contains "WARP identity is retained byte-for-byte" "$WARP_DEVICE" 'warp-device-preserved'
[ "$(stat -c %a "$WARP_DEVICE" 2>/dev/null)" = 600 ] && _t_ok || _t_bad "WARP identity permissions retained"
assert_contains "WARP account sidecar is preserved" "$(dirname "$WARP_DEVICE")/account.json" 'preserve'
assert_contains "WARP license sidecar is preserved" "$(dirname "$WARP_DEVICE")/license" 'license-preserve'
assert_contains "fw4 reload removed only the WARP include rule" "$Z2K_OW_FW4_STATE" 'table inet fw4'
assert_not_contains "fw4 WARP include is no longer active" "$Z2K_OW_FW4_STATE" '!z2k: WARP forwarded traffic'
assert_contains "saved global offload setting is restored" "$Z2K_UNINSTALL_TEST_LOG" 'offload-restore'
[ ! -e "$Z2K_FW4_OFFLOAD_STATE" ] && _t_ok || _t_bad "offload backup state is retired after restore"
assert_contains "foreign cron entries remain" "$Z2K_CRON_TAB" 'foreign-job'
assert_not_contains "all z2k cron entries are removed" "$Z2K_CRON_TAB" '# z2k-'
assert_contains "foreign nft state remains" "$Z2K_OW_NFT_STATE" 'chain foreign keep'
assert_not_contains "z2k-owned nft state is removed" "$Z2K_OW_NFT_STATE" 'z2k_'
assert_contains "foreign DHCP/UCI state remains" "$Z2K_OW_DHCP_UCI" 'config domain foreign'
assert_not_contains "z2k RT DNS section removed" "$Z2K_OW_DHCP_UCI" 'z2k_rt'
assert_contains "foreign firewall file is untouched" "$T/etc/config/firewall" 'foreign firewall config'
assert_contains "uhttpd config is untouched" "$T/etc/config/uhttpd" 'foreign uhttpd settings'
assert_contains "LuCI CGI is untouched" "$T/www/cgi-bin/luci" 'foreign luci CGI'
assert_contains "LuCI static files are untouched" "$T/www/luci-static/resources/main.css" 'foreign LuCI static'
assert_file "foreign hotplug remains" "$T/etc/hotplug.d/iface/99-foreign"
assert_file "foreign init remains" "$T/etc/init.d/S80lighttpd"
assert_contains "upstream upgrade backup remains untouched" "$T/opt/z2k-upgrade-backup/keep" 'leaves this backup'
assert_file "foreign legacy /opt/zapret is not claimed" "$T/opt/zapret/keep"
[ ! -e "$Z2K_OW_HOTPLUG_FILE" ] && _t_ok || _t_bad "z2k hotplug removed"
[ ! -e "$Z2K_OW_SYSCTL_FILE" ] && _t_ok || _t_bad "z2k sysctl drop-in removed"
[ ! -e "$Z2K_OW_WARP_NFT_FILE" ] && _t_ok || _t_bad "z2k WARP nft include removed"
[ ! -e "$Z2K_OW_CLI_FILE" ] && _t_ok || _t_bad "z2k CLI removed"
[ ! -e "$Z2K_OW_INSTALL_RELEASE_FILE" ] && _t_ok || _t_bad "release updater removed"
[ ! -e "$Z2K_TMP" ] && _t_ok || _t_bad "transient runtime/log/cache removed"
[ ! -e "$Z2K_OW_INSTALL_TMP" ] && _t_ok || _t_bad "install transaction staging removed"
[ ! -e "$Z2K_RC_CORE" ] && _t_ok || _t_bad "core procd enable link removed"
[ ! -e "$Z2K_RC_PANEL" ] && _t_ok || _t_bad "WebPanel procd enable link removed"
_repeat_rc=0; Z2K_UNINSTALL_CONFIRMED=1 z2k_ow_uninstall || _repeat_rc=$?
assert_eq "repeated uninstall is idempotent" "0" "$_repeat_rc"
assert_file "repeated uninstall keeps WARP identity" "$WARP_DEVICE"

# Recreate a new release payload and run the real OpenWrt config bootstrap.
# The old config/lists stay deleted; only upstream's registered WARP identity
# is reused by reinstall.
mkdir -p "$Z2K_ROOT/share" "$Z2K_ROOT/lists" \
    "$Z2K_ROOT/extra_strats/TCP/YT" "$Z2K_ROOT/extra_strats/TCP/YT_GV" \
    "$Z2K_ROOT/extra_strats/TCP/RKN" "$Z2K_ROOT/extra_strats/UDP/YT" \
    "$Z2K_ZAPRET2_RUNTIME/binaries/linux-uninstall-test"
printf 'ENABLED=1\nGAME_WARP_ENABLED=0\nDEFAULT_ONLY=1\n' > "$Z2K_ROOT/share/config.default"
printf 'shipped.example\n' > "$Z2K_ROOT/lists/extra-domains.txt"
for _f in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
    printf 'strategy\n' > "$Z2K_ROOT/extra_strats/$_f/Strategy.txt"
done
for _name in nfqws2 ip2net mdig; do
    printf 'binary\n' > "$Z2K_ZAPRET2_RUNTIME/binaries/linux-uninstall-test/$_name"
    chmod +x "$Z2K_ZAPRET2_RUNTIME/binaries/linux-uninstall-test/$_name"
done
z2k_ow_arch_name() { printf '%s\n' uninstall-test; }
export Z2K_OW_LEGACY_DETECT_INIT="$T/no-z2k-detect"
. "$REPO/platform/openwrt/bootstrap.sh"
z2k_ow_bootstrap || _t_bad "reinstall bootstrap succeeds"
assert_contains "reinstall uses fresh default config" "$Z2K_CONFIG" 'DEFAULT_ONLY=1'
[ -f "$Z2K_USER_LISTS/whitelist.txt" ] && _t_ok || _t_bad "reinstall creates a new user whitelist"
assert_contains "reinstall seeds shipped extra-domains" "$Z2K_USER_LISTS/extra-domains.txt" 'shipped.example'
assert_contains "reinstall keeps upstream WARP device identity" "$WARP_DEVICE" 'warp-device-preserved'
assert_contains "reinstall keeps WARP account sidecar" "$(dirname "$WARP_DEVICE")/account.json" 'preserve'
assert_contains "reinstall keeps WARP license sidecar" "$(dirname "$WARP_DEVICE")/license" 'license-preserve'
[ ! -s "$Z2K_STATE/tcp16_sni.txt" ] && _t_ok || _t_bad "removed TCP16 user state starts fresh"

# The second uninstall is the already-stopped-service case. No process marker
# is created; service stop still converges and removes the same owned surfaces.
mkdir -p "$(dirname "$Z2K_OW_CORE_INIT")" "$(dirname "$Z2K_OW_PANEL_INIT")" \
    "$(dirname "$Z2K_OW_HOTPLUG_FILE")" "$(dirname "$Z2K_OW_SYSCTL_FILE")" \
    "$(dirname "$Z2K_OW_WARP_NFT_FILE")" "$(dirname "$Z2K_OW_CLI_FILE")" \
    "$(dirname "$Z2K_OW_INSTALL_RELEASE_FILE")" "$Z2K_OW_ROLLBACK_DIR"
cat > "$Z2K_OW_CORE_INIT" <<'EOF'
#!/bin/sh
echo "core-$1" >> "$Z2K_UNINSTALL_TEST_LOG"
case "$1" in
    disable) rm -f "$Z2K_RC_CORE" ;;
    stop) rm -f "$Z2K_CORE_PROCESS" "$Z2K_TG_PROCESS" "$Z2K_RT_PROCESS" "$Z2K_WARP_PROCESS" ;;
esac
exit 0
EOF
cat > "$Z2K_OW_PANEL_INIT" <<'EOF'
#!/bin/sh
echo "panel-$1" >> "$Z2K_UNINSTALL_TEST_LOG"
case "$1" in
    disable) rm -f "$Z2K_RC_PANEL" ;;
    stop) rm -f "$Z2K_PANEL_PROCESS" ;;
esac
exit 0
EOF
chmod +x "$Z2K_OW_CORE_INIT" "$Z2K_OW_PANEL_INIT"
ln -s ../init.d/z2k "$Z2K_RC_CORE"
ln -s ../init.d/z2k-webpanel "$Z2K_RC_PANEL"
printf 'tag=r-86.13\nseq=136\n' > "$Z2K_OW_INSTALLED_RELEASE_FILE"
printf 'z2kow-owned\n' > "$Z2K_OW_HOTPLUG_FILE"
printf 'z2kow-owned\n' > "$Z2K_OW_SYSCTL_FILE"
printf 'z2kow-owned\n' > "$Z2K_OW_WARP_NFT_FILE"
printf 'z2kow-owned\n' > "$Z2K_OW_CLI_FILE"
printf 'z2kow-owned\n' > "$Z2K_OW_INSTALL_RELEASE_FILE"
printf '%s\n' 'table inet fw4 {' ' chain forward {' \
    '  comment "!z2k: WARP forwarded traffic";' ' }' '}' > "$Z2K_OW_FW4_STATE"
printf '1 4 * * * /usr/lib/z2k/list-refresh.sh # z2k-lists\n' >> "$Z2K_CRON_TAB"
printf 'yes\n' > "$T/confirm.txt"
_stopped_rc=0; Z2K_UNINSTALL_CONFIRMED=1 z2k_ow_uninstall || _stopped_rc=$?
assert_eq "uninstall succeeds with services already stopped" "0" "$_stopped_rc"
[ ! -e "$Z2K_ROOT" ] && _t_ok || _t_bad "stopped-service uninstall removes payload"
assert_file "stopped-service uninstall retains only WARP identity" "$WARP_DEVICE"

# Upstream only preserves WARP registration when that directory exists. A
# router without WARP must still lose config/lists/state on ordinary uninstall.
mkdir -p "$T/no-warp/etc/z2k/user-lists"
printf 'ordinary user config\n' > "$T/no-warp/etc/z2k/config"
(
    export Z2K_ETC="$T/no-warp/etc/z2k"
    export Z2K_CONFIG="$Z2K_ETC/config"
    export Z2K_STATE="$Z2K_ETC/state"
    export Z2K_OW_INSTALLED_RELEASE_FILE="$Z2K_STATE/installed-release"
    export WARP_DEVICE="$Z2K_STATE/warp/device.json"
    . "$REPO/platform/openwrt/uninstall.sh"
    _z2k_ow_uninstall_preserve_warp_move
) || _t_bad "no-WARP state cleanup succeeds"
[ ! -e "$T/no-warp/etc/z2k" ] && _t_ok || _t_bad "config is removed when no WARP identity exists"

# A cleanup error is loud and leaves product/user metadata available for retry.
mkdir -p "$Z2K_ROOT/platform/openwrt" "$Z2K_ETC/state/warp" "$Z2K_ZAPRET2_RUNTIME"
for _f in schedule firewall tg rt warp insta-ip tiktok; do
    cp "$REPO/platform/openwrt/$_f.sh" "$Z2K_ROOT/platform/openwrt/$_f.sh"
done
cp "$REPO/platform/openwrt/uninstall.sh" "$Z2K_ROOT/platform/openwrt/uninstall.sh"
printf 'tag=p-86.13\nseq=136\n' > "$Z2K_STATE/installed-release"
printf '{"id":"warp-device-preserved"}\n' > "$WARP_DEVICE"
export Z2K_OW_FAIL_CLEANUP=rt
_failure_rc=0; Z2K_UNINSTALL_CONFIRMED=1 z2k_ow_uninstall >/dev/null 2>&1 || _failure_rc=$?
assert_eq "cleanup failure returns an error" "1" "$_failure_rc"
assert_file "cleanup failure preserves product for retry" "$Z2K_ROOT/platform/openwrt/uninstall.sh"
assert_file "cleanup failure preserves canonical release metadata" "$Z2K_STATE/installed-release"
assert_file "cleanup failure preserves WARP identity" "$WARP_DEVICE"
unset Z2K_OW_FAIL_CLEANUP

# If fw4 cannot converge after removing the include, put the include back and
# retain the install so the retry has no orphaned live rule.
printf 'z2kow-owned\n' > "$Z2K_OW_WARP_NFT_FILE"
printf '%s\n' 'table inet fw4 {' ' chain forward {' \
    '  comment "!z2k: WARP forwarded traffic";' ' }' '}' > "$Z2K_OW_FW4_STATE"
export Z2K_OW_KEEP_FW4_RULE=1
_fw4_rc=0; Z2K_UNINSTALL_CONFIRMED=1 z2k_ow_uninstall >/dev/null 2>&1 || _fw4_rc=$?
assert_eq "fw4 cleanup failure stops uninstall" "1" "$_fw4_rc"
assert_file "fw4 cleanup failure restores the active include" "$Z2K_OW_WARP_NFT_FILE"
assert_contains "fw4 cleanup failure retains its live rule with the install" \
    "$Z2K_OW_FW4_STATE" '!z2k: WARP forwarded traffic'
assert_file "fw4 cleanup failure retains the release state" "$Z2K_STATE/installed-release"
unset Z2K_OW_KEEP_FW4_RULE

_t_done
