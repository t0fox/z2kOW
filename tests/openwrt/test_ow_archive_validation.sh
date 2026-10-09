#!/bin/sh
# Проверка типа каждой записи rootfs и цели каждой символической ссылки.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-archive-validation"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/platform/openwrt/release.sh"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM

make_archive() {
    _root="$1" _archive="$2"
    tar -czf "$_archive" -C "$_root" \
        usr/lib/z2k/platform/openwrt usr/sbin/install_release usr/bin/z2kow
}

_root="$T/valid"
mkdir -p "$_root/usr/lib/z2k/platform/openwrt" "$_root/usr/sbin" "$_root/usr/bin"
printf 'release engine\n' > "$_root/usr/lib/z2k/platform/openwrt/release.sh"
ln -s release.sh "$_root/usr/lib/z2k/platform/openwrt/current.sh" || exit 1
printf 'install engine\n' > "$_root/usr/sbin/install_release"
printf 'cli\n' > "$_root/usr/bin/z2kow"
make_archive "$_root" "$T/valid.tar.gz"
if z2k_ow_archive_safe "$T/valid.tar.gz" "$T/valid.list"; then
    _t_ok
else
    _t_bad "безопасная относительная ссылка разрешена"
fi

for _target in /etc/passwd ../../../../../../etc/passwd 'release engine'; do
    _root="$T/invalid"
    rm -rf "$_root"
    mkdir -p "$_root/usr/lib/z2k/platform/openwrt" "$_root/usr/sbin" "$_root/usr/bin"
    printf 'release engine\n' > "$_root/usr/lib/z2k/platform/openwrt/release.sh"
    ln -s "$_target" "$_root/usr/lib/z2k/platform/openwrt/escape.sh" || exit 1
    printf 'install engine\n' > "$_root/usr/sbin/install_release"
    printf 'cli\n' > "$_root/usr/bin/z2kow"
    make_archive "$_root" "$T/invalid.tar.gz"
    if z2k_ow_archive_safe "$T/invalid.tar.gz" "$T/invalid.list"; then
        _t_bad "небезопасная цель ссылки отклонена: $_target"
    else
        _t_ok
    fi
done

_root="$T/special"
mkdir -p "$_root/usr/lib/z2k/platform/openwrt" "$_root/usr/sbin" "$_root/usr/bin"
printf 'release engine\n' > "$_root/usr/lib/z2k/platform/openwrt/release.sh"
mkfifo "$_root/usr/lib/z2k/platform/openwrt/unexpected.pipe"
printf 'install engine\n' > "$_root/usr/sbin/install_release"
printf 'cli\n' > "$_root/usr/bin/z2kow"
make_archive "$_root" "$T/special.tar.gz"
if z2k_ow_archive_safe "$T/special.tar.gz" "$T/special.list"; then
    _t_bad "специальный тип записи rootfs отклонён"
else
    _t_ok
fi

python3 - "$T/repeated-separator.tar.gz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz", format=tarfile.PAX_FORMAT) as archive:
    for name, payload in (
        ("usr/lib/z2k/platform/openwrt/release.sh", b"release engine\n"),
        ("usr/sbin/install_release", b"install engine\n"),
        ("usr/bin/z2kow", b"cli\n"),
    ):
        member = tarfile.TarInfo(name)
        member.size = len(payload)
        archive.addfile(member, io.BytesIO(payload))
    link = tarfile.TarInfo("usr//lib/z2k/platform/openwrt/escape.sh")
    link.type = tarfile.SYMTYPE
    link.linkname = "../../../../../../etc/passwd"
    archive.addfile(link)
PY
if z2k_ow_archive_safe "$T/repeated-separator.tar.gz" "$T/repeated-separator.list"; then
    _t_bad "повторные разделители не должны скрывать выход ссылки за rootfs"
else
    _t_ok
fi

_t_done
