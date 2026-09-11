#!/bin/sh
# tests/openwrt/test_ow_ownership_map.sh - §4: package/updater без конфликтов.
# ownership.map — authoritative граница. Конфликт (цель и там, и там) =
# PACKAGE_UPDATER_OWNERSHIP_CONFLICT.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-ownership-map"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MAP="$REPO/package/openwrt/ownership.map"
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/release_map.sh" || { echo "FAIL[ow-ownership-map]: release_map" >&2; exit 1; }

# карта корректна: "<абс-путь> <package|updater|user>", без дублей
# (user-класс допускает glob-суффикс /* на поддерево целиком).
_bad="$(sed 's/#.*$//' "$MAP" | grep -v '^[[:space:]]*$' | grep -vE '^/[^[:space:]]+ (package|updater|user)$' || true)"
[ -z "$_bad" ] && _t_ok || _t_bad "битые строки карты: $_bad"
_dups="$(sed 's/#.*$//' "$MAP" | grep -v '^[[:space:]]*$' | awk '{print $1}' | sort | uniq -d)"
[ -z "$_dups" ] && _t_ok || _t_bad "дубли в карте: $_dups"

# user-класс покрывает всё состояние из §5 acceptance
for _u in "/etc/z2k/config" "/etc/z2k/state/*" "/etc/z2k/user-lists/*"; do
    grep -qxF "$_u user" "$MAP" 2>/dev/null && _t_ok || _t_bad "user-класс без $_u"
done
# marker — тоже user (persistent bootstrap-state, не package-shipped)
grep -qxF "/etc/z2k/.payload-initialized user" "$MAP" 2>/dev/null \
    && _t_ok || _t_bad "marker не user-owned"

# каждый package-owned путь имеет источник в репо (ставится Makefile/seed)
_miss=""
while IFS= read -r _line; do
    set -- $_line
    [ "${2:-}" = "package" ] || continue
    case "$1" in
        /etc/init.d/z2k) _src="package/openwrt/files/etc/init.d/z2k" ;;
        /etc/hotplug.d/iface/90-z2k) _src="package/openwrt/files/etc/hotplug.d/iface/90-z2k" ;;
        /usr/lib/z2k/platform/openwrt/*) _src="platform/openwrt/$(basename "$1")" ;;
        /usr/lib/z2k/share/config.default) _src="package/openwrt/files/etc/z2k/config.default" ;;
        /usr/lib/z2k/share/seed.tar.gz) _src="package/openwrt/make-seed.sh" ;;
        *) _src="" ;;
    esac
    { [ -n "$_src" ] && [ -f "$REPO/$_src" ]; } || _miss="$_miss $1"
done <<EOF
$(sed 's/#.*$//' "$MAP" | grep -v '^[[:space:]]*$')
EOF
[ -z "$_miss" ] && _t_ok || _t_bad "package-owned без источника:$_miss"

# КОНФЛИКТ: openwrt-назначения updater ∩ package-owned = пусто.
# Обход — вся таблица (seed — её подмножество, отдельно не нужен).
_pkgtmp="$(mktemp)" || exit 1
_filelist="$(mktemp)" || exit 1
trap 'rm -f "$_pkgtmp" "$_filelist" "$_pkgtmp.conflicts"' EXIT INT TERM
sed 's/#.*$//' "$MAP" | grep -v '^[[:space:]]*$' | awk '$2=="package" {print $1}' | LC_ALL=C sort -u >"$_pkgtmp"
( cd "$REPO" && git ls-files --cached --others --exclude-standard ) >"$_filelist" 2>/dev/null
_conf=""
while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    Z2K_PLATFORM=openwrt z2k_install_paths "$_f" 2>/dev/null | while IFS= read -r _d; do
        [ -n "$_d" ] || continue
        if grep -qxF "$_d" "$_pkgtmp"; then
            printf 'CONFLICT %s\n' "$_f->$_d" >>"$_pkgtmp.conflicts"
        fi
    done
done <"$_filelist"
if [ -f "$_pkgtmp.conflicts" ]; then
    _conf="$_conf $(cat "$_pkgtmp.conflicts")"
    rm -f "$_pkgtmp.conflicts"
fi
if [ -z "$_conf" ]; then
    _t_ok
else
    _t_bad "PACKAGE_UPDATER_OWNERSHIP_CONFLICT:$_conf"
fi

_t_done
