#!/bin/sh
# Stage the complete OpenWrt product filesystem directly from source inputs.
# No z2kOW APK is built or extracted here.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
STAGE="${1:-}"
RUNTIME_ARCHIVE="${2:-}"
WARPD_DIR="${3:-}"
TG_DIR="${4:-}"
RT_DIR="${5:-}"
DETECT_DIR="${6:-}"
RELEASE_KEYS_DIR="${7:-$ROOT/scripts/openwrt/release-keys}"

die() { printf 'stage-rootfs: %s\n' "$*" >&2; exit 1; }
copy_data() {
    src="$1"; dst="$2"; mode="${3:-0644}"
    [ -f "$src" ] || die "required source file is missing: $src"
    mkdir -p "$(dirname -- "$STAGE/$dst")"
    cp -p "$src" "$STAGE/$dst"
    chmod "$mode" "$STAGE/$dst"
}

[ -n "$STAGE" ] && [ -n "$RUNTIME_ARCHIVE" ] && [ -n "$WARPD_DIR" ] \
    && [ -n "$TG_DIR" ] && [ -n "$RT_DIR" ] && [ -n "$DETECT_DIR" ] \
    || die "usage: $0 STAGING_ROOT ZAPRET2_RUNTIME_TARBALL Z2K_WARPD_DIR TG_DIR RT_DIR DETECT_DIR"
[ -f "$RUNTIME_ARCHIVE" ] || die "zapret2 runtime archive is missing"
[ -d "$WARPD_DIR" ] || die "z2k-warpd architecture directory is missing"
[ -d "$TG_DIR" ] || die "Telegram client architecture directory is missing"
[ -d "$RT_DIR" ] || die "RT proxy architecture directory is missing"
[ -d "$DETECT_DIR" ] || die "diagnostic detector architecture directory is missing"
case "$STAGE" in /|/etc|/usr|/usr/lib|/www) die "unsafe staging root: $STAGE" ;; esac
mkdir -p "$STAGE"
[ -z "$(find "$STAGE" -mindepth 1 -print -quit 2>/dev/null)" ] \
    || die "staging root must be empty: $STAGE"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/z2k-stage.XXXXXX")" || die "cannot create temporary directory"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Materialize common mapped files directly into the one staging root. No
# install-time seed archive or payload/version marker is produced.
sh "$ROOT/scripts/openwrt/stage-common-payload.sh" "$ROOT" "$STAGE" \
    || die "could not materialize the OpenWrt payload"

# OpenWrt lifecycle and platform adapters are part of the same release tree.
mkdir -p "$STAGE/usr/lib/z2k/platform/openwrt" "$STAGE/usr/lib/z2k/share"
for src in "$ROOT"/platform/openwrt/*.sh; do
    [ -f "$src" ] || continue
    copy_data "$src" "usr/lib/z2k/platform/openwrt/$(basename "$src")" 0644
done
copy_data "$ROOT/platform/openwrt/owned-paths.txt" usr/lib/z2k/platform/openwrt/owned-paths.txt
for src in "$ROOT"/platform/openwrt/custom.d/*; do
    [ -f "$src" ] || continue
    copy_data "$src" "usr/lib/z2k/platform/openwrt/custom.d/$(basename "$src")" 0755
done
for src in "$ROOT"/platform/openwrt/webpanel-brand/*; do
    [ -f "$src" ] || continue
    copy_data "$src" "usr/lib/z2k/www/assets/openwrt/$(basename "$src")" 0644
done

copy_data "$ROOT/platform/openwrt/files/etc/init.d/z2k" etc/init.d/z2k 0755
copy_data "$ROOT/platform/openwrt/files/etc/init.d/z2k-webpanel" etc/init.d/z2k-webpanel 0755
copy_data "$ROOT/platform/openwrt/files/etc/hotplug.d/iface/90-z2k" etc/hotplug.d/iface/90-z2k 0755
copy_data "$ROOT/platform/openwrt/files/etc/sysctl.d/99-z2k.conf" etc/sysctl.d/99-z2k.conf
copy_data "$ROOT/platform/openwrt/files/usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft" \
    usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft
copy_data "$ROOT/platform/openwrt/files/etc/z2k/config.default" usr/lib/z2k/share/config.default
copy_data "$ROOT/platform/openwrt/z2kow.sh" usr/bin/z2kow 0755
copy_data "$ROOT/scripts/openwrt/install_release.sh" usr/sbin/install_release 0755
copy_data "$ROOT/files/z2k-warp-list-filter.awk" usr/lib/z2k/z2k-warp-list-filter.awk
copy_data "$ROOT/files/z2k-diag.sh" usr/lib/z2k/z2k-diag.sh 0755
for _key in "$RELEASE_KEYS_DIR"/*.pub; do
    [ -f "$_key" ] || continue
    _key_id=${_key##*/}
    _key_id=${_key_id%.pub}
    printf '%s' "$_key_id" | grep -Eq '^[0-9a-f]{64}$' \
        || die "release public key filename must be its lowercase SHA-256 fingerprint: $_key_id"
    copy_data "$_key" "usr/lib/z2k/platform/openwrt/release-keys/$_key_id.pub"
done
_warpd_count=0
for _warpd in "$WARPD_DIR"/linux-*/z2k-warpd; do
    [ -f "$_warpd" ] || continue
    _arch=${_warpd#*/linux-}
    _arch=${_arch%/z2k-warpd}
    copy_data "$_warpd" "usr/lib/z2k/platform/openwrt/bin/linux-$_arch/z2k-warpd" 0755
    _warpd_count=$((_warpd_count + 1))
done
[ "$_warpd_count" -eq 7 ] || die "expected 7 architecture-specific z2k-warpd binaries; found $_warpd_count"
_tg_count=0
for _tg in "$TG_DIR"/linux-*/tg-mtproxy-client; do
    [ -f "$_tg" ] || continue
    _arch=${_tg#*/linux-}
    _arch=${_arch%/tg-mtproxy-client}
    copy_data "$_tg" "usr/lib/z2k/bin/linux-$_arch/tg-mtproxy-client" 0755
    _tg_count=$((_tg_count + 1))
done
[ "$_tg_count" -eq 7 ] || die "expected 7 verified architecture-specific Telegram client binaries; found $_tg_count"

_rt_count=0
for _rt in "$RT_DIR"/linux-*/z2k-rt-proxy; do
    [ -f "$_rt" ] || continue
    _arch=${_rt#*/linux-}
    _arch=${_arch%/z2k-rt-proxy}
    copy_data "$_rt" "usr/lib/z2k/bin/linux-$_arch/z2k-rt-proxy" 0755
    _rt_count=$((_rt_count + 1))
done
[ "$_rt_count" -eq 7 ] || die "expected 7 architecture-specific RT proxy binaries; found $_rt_count"
_detect_count=0
for _detect in "$DETECT_DIR"/linux-*/z2k-detect; do
    [ -f "$_detect" ] || continue
    _arch=${_detect#*/linux-}
    _arch=${_arch%/z2k-detect}
    copy_data "$_detect" "usr/lib/z2k/bin/linux-$_arch/z2k-detect" 0755
    _detect_count=$((_detect_count + 1))
done
[ "$_detect_count" -eq 7 ] || die "expected 7 architecture-specific detector binaries; found $_detect_count"
copy_data "$ROOT/platform/openwrt/bin/z2k-rt-proxy" usr/lib/z2k/bin/z2k-rt-proxy 0755
copy_data "$ROOT/platform/openwrt/bin/z2k-detect" usr/lib/z2k/bin/z2k-detect 0755

# The pinned dataplane tarball is unpacked straight into the one release tree.
mkdir -p "$TMP/runtime"
tar -xzf "$RUNTIME_ARCHIVE" -C "$TMP/runtime" --strip-components=1 \
    || die "could not unpack the pinned zapret2 runtime"
runtime="$TMP/runtime"
for path in \
    init.d/openwrt/functions:opt/zapret2/init.d/openwrt/functions \
    common/base.sh:opt/zapret2/common/base.sh \
    common/fwtype.sh:opt/zapret2/common/fwtype.sh \
    common/linux_iphelper.sh:opt/zapret2/common/linux_iphelper.sh \
    common/ipt.sh:opt/zapret2/common/ipt.sh \
    common/nft.sh:opt/zapret2/common/nft.sh \
    common/linux_fw.sh:opt/zapret2/common/linux_fw.sh \
    common/linux_daemons.sh:opt/zapret2/common/linux_daemons.sh \
    common/list.sh:opt/zapret2/common/list.sh \
    common/custom.sh:opt/zapret2/common/custom.sh \
    ipset/create_ipset.sh:opt/zapret2/ipset/create_ipset.sh \
    ipset/def.sh:opt/zapret2/ipset/def.sh; do
    src="${path%%:*}"; dst="${path#*:}"
    case "$src" in binaries/*|ipset/create_ipset.sh) mode=0755 ;; *) mode=0644 ;; esac
    copy_data "$runtime/$src" "$dst" "$mode"
done
mkdir -p "$STAGE/opt/zapret2/binaries"
cp -a "$runtime/binaries/." "$STAGE/opt/zapret2/binaries/" \
    || die "could not stage the complete upstream multi-architecture runtime"
for lua in zapret-lib zapret-antidpi zapret-auto; do
    src="$runtime/lua/$lua.lua.gz"
    [ -s "$src" ] || die "runtime archive is missing $src"
    mkdir -p "$STAGE/opt/zapret2/lua"
    gzip -dc "$src" > "$STAGE/opt/zapret2/lua/$lua.lua" || die "cannot unpack $lua"
    chmod 0644 "$STAGE/opt/zapret2/lua/$lua.lua"
done

# The archive must remain a complete data payload, not carry update authority,
# package state, user configuration, or any LuCI/uhttpd files.
if find "$STAGE" -type f \( -name '*.apk' -o -name 'packages.adb' \) -print -quit | grep -q .; then
    die "z2kOW APK/feed artifact found in staged payload"
fi
if [ -e "$STAGE/www/cgi-bin/luci" ] || [ -e "$STAGE/www/luci-static" ] \
    || [ -e "$STAGE/etc/config/uhttpd" ] || [ -e "$STAGE/etc/apk" ]; then
    die "forbidden LuCI/uhttpd or package/feed path in staged payload"
fi
printf 'staged OpenWrt release root: %s\n' "$STAGE"
