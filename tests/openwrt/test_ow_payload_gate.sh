#!/bin/sh
# Непригодный файл службы или бинарник блокируется до остановки старой версии.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-payload-gate"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/platform/openwrt/release.sh"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
export Z2K_OW_SYSROOT="$T/sys"
mkdir -p "$Z2K_OW_SYSROOT"
export Z2K_ADAPTER_DIR="$REPO/platform/openwrt"
_adapter="$Z2K_ADAPTER_DIR"
printf "DISTRIB_ARCH='x86_64'\n" > "$T/openwrt_release"
export Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release"

make_payload() {
    python3 - "$1" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
files = [
    'usr/lib/z2k/platform/openwrt/release.sh', 'usr/sbin/install_release',
    'usr/bin/z2kow', 'etc/init.d/z2k', 'etc/init.d/z2k-webpanel',
    'etc/hotplug.d/iface/90-z2k', 'etc/sysctl.d/99-z2k.conf',
    'usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft',
    *('usr/lib/z2k/bin/linux-x86_64/' + name for name in ('tg-mtproxy-client', 'z2k-rt-proxy', 'z2k-detect')),
    'usr/lib/z2k/platform/openwrt/bin/linux-x86_64/z2k-warpd',
    *('opt/zapret2/binaries/linux-x86_64/' + name for name in ('nfqws2', 'ip2net', 'mdig')),
]
for name in files:
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('#!/bin/sh\nexit 0\n')
    path.chmod(0o755)
PY
}

check_extract() {
    mkdir -p "$2" "$3"
    z2k_ow_archive_safe "$1" "$3/list" || return 1
    z2k_ow_extract_target_payload "$1" "$2" "$3/list" "$3"
}

make_payload "$T/valid" || exit 1
tar -czf "$T/valid.tar.gz" -C "$T/valid" usr etc opt || exit 1
if check_extract "$T/valid.tar.gz" "$T/valid-stage" "$T/valid-work"; then
    _t_ok
else
    _t_bad "полный payload с исполняемыми службами разрешён"
fi

for _path in etc/init.d/z2k etc/init.d/z2k-webpanel usr/bin/z2kow; do
    _case="$T/$(printf '%s' "$_path" | tr / _)"
    cp -a "$T/valid" "$_case" || exit 1
    chmod 0644 "$_case/$_path"
    tar -czf "$_case.tar.gz" -C "$_case" usr etc opt || exit 1
    if (check_extract "$_case.tar.gz" "$_case-stage" "$_case-work") >"$_case.out" 2>&1; then
        _t_bad "неисполняемый обязательный файл отклонён: $_path"
    else
        _t_ok
    fi
done

# При rename уже распакованного каталога на той же ФС вторую копию не резервируют.
dd if=/dev/zero of="$T/valid/usr/lib/z2k/large.bin" bs=1048576 count=8 2>/dev/null || exit 1
cp "$T/valid/usr/lib/z2k/large.bin" "$T/valid-stage/usr/lib/z2k/large.bin" || exit 1
tar -czf "$T/large.tar.gz" -C "$T/valid" usr etc opt || exit 1
z2k_ow_archive_safe "$T/large.tar.gz" "$T/large.list" || exit 1
df() {
    printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 20000 15000 5000 75%% /overlay\n'
}
if z2k_ow_overlay_preflight "$T/large.tar.gz" x86_64 "$REPO/platform/openwrt/owned-paths.txt" \
    "$T/large.list" "$T/valid-work" "$T/valid-stage" > "$T/space.out" 2>&1; then
    _t_ok
else
    _t_bad "повторный preflight учитывает уже занятую staging-каталогом память без двойного резервирования: $(cat "$T/space.out")"
fi
_t_done
