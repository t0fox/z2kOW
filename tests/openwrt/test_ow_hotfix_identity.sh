#!/bin/sh
# Проверяет применение нового содержимого с прежними tag+seq и откат отпечатка.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-hotfix-identity"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/platform/openwrt/manifest.sh"
. "$REPO/platform/openwrt/release_state.sh"
. "$REPO/platform/openwrt/release.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-hotfix-identity.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
SYS="$T/sys"; STAGE="$T/rootfs"; ARCHIVE="$T/rootfs.tar.gz"; MANIFEST="$T/UPDATES.json"
TAG="$(awk -F'"' '/"current"[[:space:]]*:/ {print $4; exit}' "$REPO/UPDATES.json")"
mkdir -p "$STAGE/usr/lib/z2k/platform/openwrt/bin/linux-arm64" \
    "$STAGE/usr/lib/z2k/bin/linux-arm64" "$STAGE/opt/zapret2/binaries/linux-arm64" \
    "$STAGE/usr/bin" "$STAGE/usr/sbin" "$STAGE/etc/init.d" \
    "$STAGE/etc/hotplug.d/iface" "$STAGE/etc/sysctl.d" \
    "$STAGE/usr/share/nftables.d/chain-pre/forward"

make_archive() {
    _payload="$1"
    cp -a "$REPO/platform/openwrt/." "$STAGE/usr/lib/z2k/platform/openwrt/" || return 1
    printf 'release tag %s\n%s\n' "$TAG" "$_payload" > "$STAGE/usr/lib/z2k/version.txt"
    for _p in "$STAGE/usr/lib/z2k/bin/linux-arm64/tg-mtproxy-client" \
        "$STAGE/usr/lib/z2k/bin/linux-arm64/z2k-rt-proxy" "$STAGE/usr/lib/z2k/bin/linux-arm64/z2k-detect" \
        "$STAGE/usr/lib/z2k/platform/openwrt/bin/linux-arm64/z2k-warpd" \
        "$STAGE/opt/zapret2/binaries/linux-arm64/nfqws2" "$STAGE/opt/zapret2/binaries/linux-arm64/ip2net" \
        "$STAGE/opt/zapret2/binaries/linux-arm64/mdig" "$STAGE/usr/bin/z2kow" \
        "$STAGE/usr/sbin/install_release" "$STAGE/etc/init.d/z2k" "$STAGE/etc/init.d/z2k-webpanel"; do
        printf '#!/bin/sh\nexit 0\n' > "$_p"; chmod 755 "$_p"
    done
    printf 'hotplug\n' > "$STAGE/etc/hotplug.d/iface/90-z2k"
    printf 'sysctl\n' > "$STAGE/etc/sysctl.d/99-z2k.conf"
    printf 'nft\n' > "$STAGE/usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft"
    tar -czf "$ARCHIVE" -C "$STAGE" usr etc opt || return 1
    _sha="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
    _size="$(wc -c < "$ARCHIVE" | tr -d ' \t\r\n')"
    python3 - "$REPO/UPDATES.json" "$MANIFEST" "$_sha" "$_size" <<'PY'
import json, sys
src, dst, sha, size = sys.argv[1:]
d = json.load(open(src, encoding="utf-8"))
d["artifact"] = {"filename":"openwrt-rootfs.tar.gz", "url":"https://github.com/t0fox/z2kOW/releases/download/openwrt-"+"a"*40+"/openwrt-rootfs.tar.gz", "sha256":sha, "size_bytes":int(size)}
d["signing"] = {"key_id":"0"*64}
open(dst,"w",encoding="utf-8").write(json.dumps(d))
PY
}

printf "DISTRIB_ARCH='aarch64_cortex-a53'\n" > "$T/openwrt_release"
export Z2K_OW_TESTING=1 Z2K_OW_TEST_HEALTHCHECK=1 Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release"
export Z2K_OW_SYSROOT="$SYS" Z2K_ROOT="$SYS/usr/lib/z2k" Z2K_ADAPTER_DIR="$REPO/platform/openwrt"
export Z2K_OW_INSTALLED_RELEASE_FILE=/etc/z2k/state/installed-release Z2K_OW_INSTALL_WORK=/usr/lib/.z2k-install
export Z2K_OW_INSTALL_TMP="$T/tmp" Z2K_OW_MANIFEST_PATH="$MANIFEST" Z2K_OW_ARTIFACT_PATH="$ARCHIVE"
mkdir -p "$T/tmp"
jsonfilter() {
    _f= _e=; while [ "$#" -gt 0 ]; do case "$1" in -i) _f="$2"; shift 2;; -e) _e="${2#@.}"; shift 2;; *) return 2;; esac; done
    python3 - "$_f" "$_e" <<'PY'
import json,sys
v=json.load(open(sys.argv[1],encoding="utf-8"))
for k in sys.argv[2].split("."): v=v[k]
if v is not None: print(v)
PY
}
apk() { case "$1" in info) return 1;; add|del) return 0;; *) return 2;; esac; }
SERVICE_HELPER="$T/service-helper"
cat > "$SERVICE_HELPER" <<'SH'
#!/bin/sh
op=${2:-}
case "$op" in
    enable)
        [ "${SERVICE_FAIL_ENABLE:-0}" != 1 ] || exit 77
        mkdir -p "$SERVICE_SYSROOT/etc/rc.d" || exit 1
        ln -sf ../init.d/z2k "$SERVICE_SYSROOT/etc/rc.d/S22z2k"
        ln -sf ../init.d/z2k-webpanel "$SERVICE_SYSROOT/etc/rc.d/S95z2k-webpanel"
        exit 0
        ;;
    status)
        if [ -n "${SERVICE_HEALTH_FAIL:-}" ] && [ -e "$SERVICE_HEALTH_FAIL" ] \
            && grep -q 'payload C' "$SERVICE_SYSROOT/usr/lib/z2k/version.txt"; then exit 1; fi
        exit 0
        ;;
    stop|restart|start|running) exit 0 ;;
esac
exit 0
SH
chmod 755 "$SERVICE_HELPER"; export Z2K_OW_TEST_SERVICE_HELPER="$SERVICE_HELPER"
export SERVICE_SYSROOT="$SYS" SERVICE_FAIL_ENABLE=0 SERVICE_HEALTH_FAIL="" SERVICE_FAIL_FILE="" OLD_COUNT_FILE="$T/count" SERVICE_STOP_MARKER="$T/stopped"
export TEST_RELEASE_TAG="$TAG"

rm -rf "$SYS"; mkdir -p "$SYS/etc/z2k/state" "$SYS/etc/init.d" "$SYS/usr/lib/z2k" "$SYS/usr/bin" "$SYS/usr/sbin" "$SYS/opt"
make_archive 'payload A' || exit 1
z2k_ow_install_release "$TAG" >/dev/null 2>&1; _rc=$?
if [ "$_rc" -eq 0 ] && grep -q 'payload A' "$SYS/usr/lib/z2k/version.txt"; then _t_ok; else _t_bad "первичная установка A завершилась rc=$_rc"; fi

make_archive 'payload B' || exit 1
z2k_ow_install_release "$TAG" >"$T/second.log" 2>&1; _rc=$?
if [ "$_rc" -eq 0 ] && grep -q 'payload B' "$SYS/usr/lib/z2k/version.txt"; then _t_ok; else _t_bad "хотфикс B с прежним tag+seq должен примениться: rc=$_rc вывод=$(cat "$T/second.log")"; fi
assert_startup_links() {
    _label="$1"
    if [ "$(readlink "$SYS/etc/rc.d/S22z2k" 2>/dev/null)" = ../init.d/z2k ] \
        && [ "$(readlink "$SYS/etc/rc.d/S95z2k-webpanel" 2>/dev/null)" = ../init.d/z2k-webpanel ]; then
        _t_ok
    else
        _t_bad "$_label: ссылки автозапуска z2k и WebPanel не сохранены"
    fi
}
assert_startup_links "после применения B"
z2k_ow_install_release "$TAG" >"$T/third.log" 2>&1; _rc=$?
if [ "$_rc" -eq 0 ] && grep -q 'payload B' "$SYS/usr/lib/z2k/version.txt"; then _t_ok; else _t_bad "повтор B должен быть безопасным no-op: rc=$_rc"; fi
assert_startup_links "после no-op B"

# Отсутствующий или повреждённый отпечаток не подтверждает идентичность.
rm -f "$SYS/etc/z2k/state/installed-artifact-sha256"
z2k_ow_install_release "$TAG" >/dev/null 2>&1; _rc=$?
if [ "$_rc" -eq 0 ] && grep -q 'payload B' "$SYS/usr/lib/z2k/version.txt"; then _t_ok; else _t_bad "отсутствующий отпечаток должен приводить к переустановке: rc=$_rc"; fi
printf 'not-a-digest\n' > "$SYS/etc/z2k/state/installed-artifact-sha256"
z2k_ow_install_release "$TAG" >/dev/null 2>&1; _rc=$?
if [ "$_rc" -eq 0 ] && grep -q 'payload B' "$SYS/usr/lib/z2k/version.txt"; then _t_ok; else _t_bad "повреждённый отпечаток должен приводить к переустановке: rc=$_rc"; fi

# Отказ проверки хотфикса с прежним тегом должен вернуть содержимое, отпечаток и ссылки запуска.
export SERVICE_HEALTH_FAIL=""
make_archive 'payload C' || exit 1
_old_receipt="$(cat "$SYS/etc/z2k/state/installed-artifact-sha256" 2>/dev/null || true)"
touch "$T/fail-health"
export SERVICE_HEALTH_FAIL="$T/fail-health"
z2k_ow_install_release "$TAG" >"$T/rollback.log" 2>&1; _rc=$?
if [ "$_rc" -ne 0 ] && grep -q 'payload B' "$SYS/usr/lib/z2k/version.txt" \
    && [ "$(cat "$SYS/etc/z2k/state/installed-artifact-sha256" 2>/dev/null)" = "$_old_receipt" ] \
    && grep -q 'Z2KOW_ROLLBACK=complete' "$T/rollback.log"; then
    _t_ok
else
    _t_bad "отказ проверки должен восстановить содержимое и отпечаток с полным откатом: rc=$_rc отпечаток=$(cat "$SYS/etc/z2k/state/installed-artifact-sha256" 2>/dev/null) вывод=$(cat "$T/rollback.log")"
fi
assert_startup_links "после отката хотфикса C"

# Ошибка `enable` не должна быть проигнорирована: откатить B и сохранить ссылки.
rm -f "$T/fail-health"; export SERVICE_HEALTH_FAIL="" SERVICE_FAIL_ENABLE=1
make_archive 'payload D' || exit 1
_old_receipt="$(cat "$SYS/etc/z2k/state/installed-artifact-sha256" 2>/dev/null)"
z2k_ow_install_release "$TAG" >"$T/enable-fail.log" 2>&1; _rc=$?
if [ "$_rc" -ne 0 ] && grep -q 'payload B' "$SYS/usr/lib/z2k/version.txt" \
    && [ "$(cat "$SYS/etc/z2k/state/installed-artifact-sha256" 2>/dev/null)" = "$_old_receipt" ] \
    && grep -q 'Z2KOW_ROLLBACK=complete' "$T/enable-fail.log"; then
    _t_ok
else
    _t_bad "ошибка enable должна откатить содержимое и отпечаток: rc=$_rc вывод=$(cat "$T/enable-fail.log")"
fi
assert_startup_links "после отката при ошибке enable"
_t_done
