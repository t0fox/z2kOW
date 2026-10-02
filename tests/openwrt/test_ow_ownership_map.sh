#!/bin/sh
# The full rootfs owns only explicit product paths; user and LuCI data are outside it.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-owned-paths"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OWNED="$REPO/platform/openwrt/owned-paths.txt"
BUILDER="$REPO/scripts/openwrt/stage-rootfs.sh"
RELEASE="$REPO/platform/openwrt/release.sh"
assert_file "owned path list exists" "$OWNED"
assert_contains "payload root is release-owned" "$OWNED" '/usr/lib/z2k'
assert_contains "canonical installer is release-owned" "$OWNED" '/usr/sbin/install_release'
assert_contains "core init is release-owned" "$OWNED" '/etc/init.d/z2k'
assert_contains "panel init is release-owned" "$OWNED" '/etc/init.d/z2k-webpanel'
assert_not_contains "LuCI and uhttpd are outside the ownership list" "$OWNED" '^/?(www(/|$)|etc/config/uhttpd)'
_dups=$(sed 's/#.*$//' "$OWNED" | grep -v '^[[:space:]]*$' | sort | uniq -d)
[ -z "$_dups" ] && _t_ok || _t_bad "owned paths contain duplicates: $_dups"
for _source in \
    'platform/openwrt/files/etc/init.d/z2k' \
    'platform/openwrt/files/etc/init.d/z2k-webpanel' \
    'platform/openwrt/files/etc/hotplug.d/iface/90-z2k' \
    'platform/openwrt/files/etc/sysctl.d/99-z2k.conf'; do
    assert_contains "full rootfs stages $_source" "$BUILDER" "$_source"
done
assert_contains "release transaction reads the canonical owned-path list" "$RELEASE" 'owned-paths.txt'
[ ! -e "$REPO/package/openwrt/ownership.map" ] && _t_ok || _t_bad "legacy package ownership map remains"
[ ! -e "$REPO/package/openwrt/Makefile" ] && _t_ok || _t_bad "component APK build recipe remains"
_t_done
