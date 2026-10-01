#!/bin/sh
# Reusable LuCI state witness for OpenWrt lifecycle tests.

luci_fixture_seed() {
    _luci_root=$1
    mkdir -p "$_luci_root/www/cgi-bin" "$_luci_root/etc/config" || return 1
    cat > "$_luci_root/www/cgi-bin/luci" <<'LUCI'
#!/bin/sh
# Known LuCI fixture. z2kOW lifecycle operations must leave it untouched.
printf '%s\n' 'fixture LuCI endpoint'
LUCI
    chmod 0755 "$_luci_root/www/cgi-bin/luci" || return 1
    cat > "$_luci_root/etc/config/uhttpd" <<'UHTTPD'
config uhttpd 'main'
	option listen_http '0.0.0.0:80'
	option listen_https '0.0.0.0:443'
	option home '/www'
UHTTPD
}

luci_fixture_state() {
    _luci_root=$1
    [ -f "$_luci_root/www/cgi-bin/luci" ] || return 1
    [ -f "$_luci_root/etc/config/uhttpd" ] || return 1
    (
        cd "$_luci_root" || exit 1
        find www -mindepth 1 -print | LC_ALL=C sort | while IFS= read -r _luci_path; do
            if [ -L "$_luci_path" ]; then
                printf 'link %s %s\n' "$(stat -c '%a:%u:%g' "$_luci_path")" "$(readlink "$_luci_path")"
            elif [ -d "$_luci_path" ]; then
                printf 'dir %s %s\n' "$(stat -c '%a:%u:%g' "$_luci_path")" "$_luci_path"
            elif [ -f "$_luci_path" ]; then
                printf 'file %s %s\n' "$(stat -c '%a:%u:%g' "$_luci_path")" "$_luci_path"
                sha256sum "$_luci_path"
            else
                printf 'other %s\n' "$_luci_path"
            fi
        done || exit 1
        printf 'uhttpd %s\n' "$(stat -c '%a:%u:%g' etc/config/uhttpd)"
        sha256sum etc/config/uhttpd
    )
}

luci_fixture_assert_unchanged() {
    _luci_actual=$(luci_fixture_state "$1") || {
        _t_bad "$3: LuCI fixture file or uhttpd config disappeared"
        return 1
    }
    assert_eq "$3" "$2" "$_luci_actual"
}
