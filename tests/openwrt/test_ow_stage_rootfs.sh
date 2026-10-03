#!/bin/sh
# The release staging path must produce every runtime binary dispatch needs.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-stage-rootfs-binaries"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
for _dep in tar gzip; do
    command -v "$_dep" >/dev/null 2>&1 || {
        echo "SKIP[ow-stage-rootfs-binaries]: $_dep is required for the stage simulation"
        exit 0
    }
done
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-stage-rootfs.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
printf 'probe\n' > "$T/symlink-probe"
if ! ln -s "$T/symlink-probe" "$T/symlink-check" 2>/dev/null || [ ! -L "$T/symlink-check" ]; then
    echo "SKIP[ow-stage-rootfs-binaries]: host cannot create the symlinks required by staged aliases"
    exit 0
fi

R="$T/runtime"
mkdir -p "$R/init.d/openwrt" "$R/common" "$R/ipset" "$R/nfq2" \
    "$R/ip2net" "$R/mdig" "$R/binaries/linux-amd64" "$R/lua"
for _f in init.d/openwrt/functions common/base.sh common/fwtype.sh \
    common/linux_iphelper.sh common/ipt.sh common/nft.sh common/linux_fw.sh \
    common/linux_daemons.sh common/list.sh common/custom.sh ipset/def.sh; do
    mkdir -p "$R/$(dirname "$_f")"
    : > "$R/$_f"
done
for _f in nfq2/nfqws2 ip2net/ip2net mdig/mdig ipset/create_ipset.sh binaries/linux-amd64/nfqws2; do
    mkdir -p "$R/$(dirname "$_f")"
    printf '#!/bin/sh\nexit 0\n' > "$R/$_f"
    chmod 0755 "$R/$_f"
done
for _f in zapret-lib zapret-antidpi zapret-auto; do
    printf 'fixture\n' | gzip -c > "$R/lua/$_f.lua.gz"
done
tar -czf "$T/runtime.tar.gz" -C "$T" runtime || exit 1

for _name in warpd tg rt detect; do mkdir -p "$T/$_name"; done
for _arch in arm64 arm x86_64 x86 mips mipsel riscv64; do
    mkdir -p "$T/warpd/linux-$_arch" "$T/tg/linux-$_arch" \
        "$T/rt/linux-$_arch" "$T/detect/linux-$_arch"
    for _spec in "warpd:z2k-warpd" "tg:tg-mtproxy-client" \
        "rt:z2k-rt-proxy" "detect:z2k-detect"; do
        _kind=${_spec%%:*}; _bin=${_spec#*:}
        printf '#!/bin/sh\nprintf "%%s\\n" "%s-%s" "$*"\n' "$_kind" "$_arch" > "$T/$_kind/linux-$_arch/$_bin"
        chmod 0755 "$T/$_kind/linux-$_arch/$_bin"
    done
done
mkdir -p "$T/release-keys"
openssl genpkey -algorithm Ed25519 -out "$T/release-keys/test.key" >/dev/null 2>&1 || exit 1
openssl pkey -in "$T/release-keys/test.key" -pubout -out "$T/release-keys/test.pub" >/dev/null 2>&1 || exit 1
_key_id="$(openssl pkey -pubin -in "$T/release-keys/test.pub" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
mv "$T/release-keys/test.pub" "$T/release-keys/$_key_id.pub"

mkdir -p "$T/stage"
sh "$ROOT/scripts/openwrt/stage-rootfs.sh" "$T/stage" "$T/runtime.tar.gz" \
    "$T/warpd" "$T/tg" "$T/rt" "$T/detect" "$T/release-keys" || exit 1
tar -czf "$T/openwrt-rootfs.tar.gz" -C "$T/stage" . || exit 1
_diag_mode=$(tar -tvzf "$T/openwrt-rootfs.tar.gz" \
    | awk '$NF ~ /platform\/openwrt\/diag\.sh$/ { print $1 }')
assert_eq "final release tarball keeps the OpenWrt diagnostics adapter executable" \
    "-rwxr-xr-x" "$_diag_mode"
[ -x "$T/stage/usr/lib/z2k/platform/openwrt/update.sh" ] \
    && _t_ok || _t_bad "canonical update.sh remains executable for CLI and cron"
cmp -s "$T/release-keys/$_key_id.pub" \
    "$T/stage/usr/lib/z2k/platform/openwrt/release-keys/$_key_id.pub" \
    && _t_ok || _t_bad "current release trust key is included in the complete payload"
[ ! -e "$T/stage/opt/zapret2/etc/z2k-update-pub.pem" ] \
    && _t_ok || _t_bad "obsolete generic update key is not shipped as a second authority"

for _kind in tg rt detect; do
    case "$_kind" in
        tg) _bin=tg-mtproxy-client ;;
        rt) _bin=z2k-rt-proxy ;;
        detect) _bin=z2k-detect ;;
    esac
    _count=$(find "$T/stage/usr/lib/z2k/bin" -path "*/linux-*/*" -name "$_bin" -type f | wc -l | tr -d ' ')
    assert_eq "all seven $_kind binaries staged" "7" "$_count"
done
printf "DISTRIB_ARCH='mips_24kc'\n" > "$T/openwrt_release"
_out=$(Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release" "$T/stage/usr/lib/z2k/bin/z2k-rt-proxy" argv)
assert_eq "RT wrapper resolves big-endian MIPS from OpenWrt target" "rt-mips
argv" "$_out"
printf "DISTRIB_ARCH='aarch64_cortex-a53'\n" > "$T/openwrt_release"
_out=$(Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release" "$T/stage/usr/lib/z2k/bin/z2k-detect" argv)
assert_eq "detector wrapper resolves ARM64 from OpenWrt target" "detect-arm64
argv" "$_out"
_t_done
