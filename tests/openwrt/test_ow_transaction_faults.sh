#!/bin/sh
# Ошибки транзакции проверяются на реальном release engine в изолированном sysroot.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-transaction-faults"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/platform/openwrt/manifest.sh"
. "$REPO/platform/openwrt/release_state.sh"
. "$REPO/platform/openwrt/release.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-transaction-faults.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
SYS="$T/sys"
STAGE="$T/rootfs"
ARCHIVE="$T/rootfs.tar.gz"
MANIFEST="$T/UPDATES.json"
mkdir -p "$STAGE/usr/lib/z2k/platform/openwrt/bin/linux-arm64" \
    "$STAGE/usr/lib/z2k/bin/linux-arm64" \
    "$STAGE/opt/zapret2/binaries/linux-arm64" \
    "$STAGE/usr/bin" "$STAGE/usr/sbin" "$STAGE/etc/init.d" \
    "$STAGE/etc/hotplug.d/iface" "$STAGE/etc/sysctl.d" \
    "$STAGE/usr/share/nftables.d/chain-pre/forward"

_tag="$(awk -F'"' '/"current"[[:space:]]*:/ {print $4; exit}' "$REPO/UPDATES.json")"
_seq="$(awk '/"seq"[[:space:]]*:/ {gsub(/[, ]/, "", $2); print $2; exit}' "$REPO/UPDATES.json")"
printf 'release tag %s\n' "$_tag" > "$STAGE/usr/lib/z2k/version.txt"
printf '#!/bin/sh\nexit 0\n' > "$STAGE/usr/lib/z2k/platform/openwrt/release.sh"
for _name in tg-mtproxy-client z2k-rt-proxy z2k-detect; do
    printf '#!/bin/sh\nexit 0\n' > "$STAGE/usr/lib/z2k/bin/linux-arm64/$_name"
    chmod 755 "$STAGE/usr/lib/z2k/bin/linux-arm64/$_name"
done
printf '#!/bin/sh\nexit 0\n' > "$STAGE/usr/lib/z2k/platform/openwrt/bin/linux-arm64/z2k-warpd"
chmod 755 "$STAGE/usr/lib/z2k/platform/openwrt/bin/linux-arm64/z2k-warpd"
for _name in nfqws2 ip2net mdig; do
    printf '#!/bin/sh\nexit 0\n' > "$STAGE/opt/zapret2/binaries/linux-arm64/$_name"
    chmod 755 "$STAGE/opt/zapret2/binaries/linux-arm64/$_name"
done
printf '#!/bin/sh\nexit 0\n' > "$STAGE/usr/bin/z2kow"
printf '#!/bin/sh\nexit 0\n' > "$STAGE/usr/sbin/install_release"
chmod 755 "$STAGE/usr/bin/z2kow" "$STAGE/usr/sbin/install_release"
for _svc in z2k z2k-webpanel; do
    printf '#!/bin/sh\nexit 0\n' > "$STAGE/etc/init.d/$_svc"
    chmod 755 "$STAGE/etc/init.d/$_svc"
done
printf 'hotplug\n' > "$STAGE/etc/hotplug.d/iface/90-z2k"
printf 'sysctl\n' > "$STAGE/etc/sysctl.d/99-z2k.conf"
printf 'nft\n' > "$STAGE/usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft"
tar -czf "$ARCHIVE" -C "$STAGE" usr etc opt || exit 1

_sha="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
_size="$(wc -c < "$ARCHIVE" | tr -d ' \t\r\n')"
python3 - "$REPO/UPDATES.json" "$MANIFEST" "$_sha" "$_size" "$_tag" <<'PY'
import json, sys
src, dst, sha, size, tag = sys.argv[1:]
d = json.load(open(src, encoding="utf-8"))
d["current"] = tag
d["upstream"]["tag"] = tag
d.pop("artifact", None)
d["artifacts"] = {
    arch: {
        "filename": f"openwrt-rootfs-{arch}.tar.gz",
        "url": "https://github.com/t0fox/z2kOW/releases/download/openwrt-" + "a" * 40 + f"/openwrt-rootfs-{arch}.tar.gz",
        "sha256": sha if arch == "arm64" else "e" * 64,
        "size_bytes": int(size),
        "unpacked_size_bytes": 4096,
    }
    for arch in ("arm64", "arm", "x86_64", "x86", "mips", "mipsel", "riscv64")
}
d["signing"] = {"key_id": "0" * 64}
open(dst, "w", encoding="utf-8").write(json.dumps(d))
PY

printf "DISTRIB_ARCH='aarch64_cortex-a53'\n" > "$T/openwrt_release"
export Z2K_OW_TESTING=1 Z2K_OW_TEST_HEALTHCHECK=1
export Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release"
export Z2K_OW_SYSROOT="$SYS" Z2K_ROOT="$SYS/usr/lib/z2k"
export Z2K_ADAPTER_DIR="$REPO/platform/openwrt"
export Z2K_OW_INSTALLED_RELEASE_FILE=/etc/z2k/state/installed-release
export Z2K_OW_INSTALL_WORK=/usr/lib/.z2k-install
export Z2K_OW_INSTALL_TMP="$T/tmp"
export Z2K_OW_MANIFEST_PATH="$MANIFEST" Z2K_OW_ARTIFACT_PATH="$ARCHIVE"
mkdir -p "$T/tmp"

jsonfilter() {
    _file= _expr= _type=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -i) _file="$2"; shift 2 ;;
            -t) _type=1; _expr="${2#@.}"; shift 2 ;;
            -e) _expr="${2#@.}"; shift 2 ;;
            *) return 2 ;;
        esac
    done
    python3 - "$_file" "$_expr" "$_type" <<'PY'
import json, sys
v = json.load(open(sys.argv[1], encoding="utf-8"))
for key in sys.argv[2].split("."):
    v = v[key]
if sys.argv[3] == "1":
    print({dict: "object", list: "array", str: "string", int: "number", float: "number", bool: "boolean", type(None): "null"}.get(type(v), "null"))
elif v is not None:
    print(v)
PY
}

apk() {
    case "$1" in
        info) return 1 ;;
        add)
            if [ "${APK_FAIL:-0}" = 1 ]; then
                : > "$T/apk-add-failed"
                return 28
            fi
            return 0
            ;;
        del) return 0 ;;
        *) return 2 ;;
    esac
}

_FAULT=""
_FAULT_USED=0
mv() {
    _mv_dest=
    for _mv_arg do _mv_dest="$_mv_arg"; done
    if [ "$_FAULT" = backup ] && [ "$_FAULT_USED" = 0 ]; then
        case "$2" in *.z2k-backup.*) _FAULT_USED=1; : > "$T/injection-fired"; return 73 ;; esac
    fi
    if [ "$_FAULT" = apply-copy ] && [ "$_FAULT_USED" = 0 ] \
        && [ "$1" = "$SYS/usr/lib/.z2k-install/stage/usr/lib/z2k" ] \
        && [ "$2" = "$SYS/usr/lib/z2k" ]; then
        return 74
    fi
    if [ "$_FAULT" = apply-final ] && [ "$_FAULT_USED" = 0 ] \
        && [ "$2" = "$SYS/usr/bin/z2kow" ]; then
        _FAULT_USED=1; : > "$T/injection-fired"; return 75
    fi
    if [ "$_FAULT" = receipt ] && [ "$_FAULT_USED" = 0 ] \
        && [ "$_mv_dest" = "$SYS/etc/z2k/state/installed-artifact-sha256" ]; then
        _FAULT_USED=1; : > "$T/injection-fired"; return 77
    fi
    command mv "$@"
}

cp() {
    if [ "$_FAULT" = apply-copy ] && [ "$_FAULT_USED" = 0 ] \
        && [ "${1:-}" = -a ] \
        && [ "$2" = "$SYS/usr/lib/.z2k-install/stage/usr/lib/z2k" ]; then
        case "$3" in "$SYS/usr/lib/z2k.z2k-new."*)
            _FAULT_USED=1; : > "$T/injection-fired"
            mkdir -p "$3/platform/openwrt"
            printf 'частичная копия\n' > "$3/partial-copy"
            return 76
            ;;
        esac
    fi
    command cp "$@"
}

_OLD_COUNT="$T/old-service-count"
_SERVICE_HELPER="$T/service-helper"
cat > "$_SERVICE_HELPER" <<'SH'
#!/bin/sh
svc=${1##*/}
shift
op=${1:-}
case "$op" in
    stop) [ -z "$SERVICE_STOP_MARKER" ] || : > "$SERVICE_STOP_MARKER"; exit 0 ;;
    enable) exit 0 ;;
    restart|start)
        if [ -n "$SERVICE_FAIL_FILE" ] && [ -e "$SERVICE_FAIL_FILE" ] \
            && grep -q 'old payload' "$Z2K_OW_SYSROOT/usr/lib/z2k/version.txt"; then
            _count=$(cat "$OLD_COUNT_FILE" 2>/dev/null || echo 0)
            if [ "$_count" -lt 2 ]; then
                echo $((_count + 1)) > "$OLD_COUNT_FILE"
                exit 81
            fi
        fi
        exit 0
        ;;
    status|running)
        if [ "$svc" = z2k ] && grep -q "release tag $TEST_RELEASE_TAG" "$Z2K_OW_SYSROOT/usr/lib/z2k/version.txt" \
            && [ -n "$SERVICE_HEALTH_FAIL" ] && [ -e "$SERVICE_HEALTH_FAIL" ]; then exit 1; fi
        exit 0
        ;;
esac
exit 0
SH
chmod 755 "$_SERVICE_HELPER"
export Z2K_OW_TEST_SERVICE_HELPER="$_SERVICE_HELPER"
export TEST_RELEASE_TAG="$_tag" SERVICE_HEALTH_FAIL="" SERVICE_FAIL_FILE="$T/fail-old-service" OLD_COUNT_FILE="$_OLD_COUNT"
export SERVICE_STOP_MARKER="$T/service-stopped"

prepare_sysroot() {
    rm -rf "$SYS"
    rm -f "$T/injection-fired" "$T/fail-new-health" "$SERVICE_FAIL_FILE" \
        "$T/service-stopped" "$T/apk-add-failed"
    mkdir -p "$SYS/etc/z2k/state" "$SYS/etc/init.d" "$SYS/usr/lib/z2k" \
        "$SYS/etc/z2k/user-lists" "$SYS/www/cgi-bin" \
        "$SYS/usr/bin" "$SYS/usr/sbin" "$SYS/etc/apk/repositories.d" "$SYS/etc/apk/keys"
    printf 'tag=p-1.2\nseq=1\n' > "$SYS/etc/z2k/state/installed-release"
    printf '%s\n' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' > "$SYS/etc/z2k/state/installed-artifact-sha256"
    printf 'ENABLED=1\nUSER_VALUE=preserve\n' > "$SYS/etc/z2k/config"
    chmod 640 "$SYS/etc/z2k/config"
    printf 'user-list preserve\n' > "$SYS/etc/z2k/user-lists/custom.txt"
    chmod 640 "$SYS/etc/z2k/user-lists/custom.txt"
    printf 'luci sentinel\n' > "$SYS/www/cgi-bin/luci"
    chmod 644 "$SYS/www/cgi-bin/luci"
    _old_config_stat=$(stat -c '%u:%g:%a' "$SYS/etc/z2k/config")
    _old_user_list_stat=$(stat -c '%u:%g:%a' "$SYS/etc/z2k/user-lists/custom.txt")
    _old_luci_stat=$(stat -c '%u:%g:%a' "$SYS/www/cgi-bin/luci")
    printf 'old payload\n' > "$SYS/usr/lib/z2k/version.txt"
    for _svc in z2k z2k-webpanel; do
        printf '#!/bin/sh\nexit 0\n' > "$SYS/etc/init.d/$_svc"
        chmod 755 "$SYS/etc/init.d/$_svc"
    done
    rm -f "$_OLD_COUNT"
    echo 0 > "$_OLD_COUNT"
}

assert_operator_files_preserved() {
    _description="$1"
    if [ "$(cat "$SYS/etc/z2k/config" 2>/dev/null)" = "ENABLED=1
USER_VALUE=preserve" ] \
        && [ "$(cat "$SYS/etc/z2k/user-lists/custom.txt" 2>/dev/null)" = "user-list preserve" ] \
        && [ "$(cat "$SYS/www/cgi-bin/luci" 2>/dev/null)" = "luci sentinel" ] \
        && [ "$(stat -c '%u:%g:%a' "$SYS/etc/z2k/config" 2>/dev/null)" = "$_old_config_stat" ] \
        && [ "$(stat -c '%u:%g:%a' "$SYS/etc/z2k/user-lists/custom.txt" 2>/dev/null)" = "$_old_user_list_stat" ] \
        && [ "$(stat -c '%u:%g:%a' "$SYS/www/cgi-bin/luci" 2>/dev/null)" = "$_old_luci_stat" ]; then
        _t_ok
    else
        _t_bad "$_description: конфигурация, ownership/permissions или защищённый LuCI path изменились"
    fi
}

assert_rolled_back() {
    _description="$1"
    if [ "$_rc" -ne 0 ] \
        && grep -qx 'tag=p-1.2' "$SYS/etc/z2k/state/installed-release" \
        && grep -qx 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$SYS/etc/z2k/state/installed-artifact-sha256" \
        && grep -q 'old payload' "$SYS/usr/lib/z2k/version.txt" \
        && [ ! -e "$SYS/usr/lib/.z2k-install/transaction-active" ]; then
        _t_ok
    else
        _t_bad "$_description: rc=$_rc state=$(cat "$SYS/etc/z2k/state/installed-release" 2>/dev/null) payload=$(cat "$SYS/usr/lib/z2k/version.txt" 2>/dev/null)"
    fi
    assert_operator_files_preserved "$_description"
}

prepare_sysroot
_FAULT=backup _FAULT_USED=0
_out="$(z2k_ow_install_release "$_tag" 2>&1)"; _rc=$?
assert_rolled_back "ошибка mv backup после записи журнала возвращает старые файлы"
[ -e "$T/injection-fired" ] && _t_ok || _t_bad "не сработал injection отказа backup mv"

prepare_sysroot
_FAULT=receipt _FAULT_USED=0
_out="$(z2k_ow_install_release "$_tag" 2>&1)"; _rc=$?
assert_rolled_back "ошибка фиксации digest receipt откатывает новый payload и сохраняет прежний receipt"
[ -e "$T/injection-fired" ] && _t_ok || _t_bad "не сработал injection отказа записи digest receipt"

prepare_sysroot
_FAULT=apply-copy _FAULT_USED=0
_out="$(z2k_ow_install_release "$_tag" 2>&1)"; _rc=$?
assert_rolled_back "частичная копия staging откатывается"
[ -e "$T/injection-fired" ] && _t_ok || _t_bad "не сработал injection частичной копии staging"
[ ! -e "$SYS/usr/lib/z2k.z2k-new.$$" ] && _t_ok \
    || _t_bad "после отката частичной копии остался sidecar"

prepare_sysroot
_FAULT=apply-final _FAULT_USED=0
_out="$(z2k_ow_install_release "$_tag" 2>&1)"; _rc=$?
assert_rolled_back "ошибка final rename откатывает все применённые пути"
[ -e "$T/injection-fired" ] && _t_ok || _t_bad "не сработал injection final rename"
[ ! -e "$SYS/usr/bin/z2kow.z2k-new.$$" ] && _t_ok \
    || _t_bad "после отката final rename остался sidecar"

prepare_sysroot
_FAULT="" _FAULT_USED=0
APK_FAIL=1 _out="$(z2k_ow_install_release "$_tag" 2>&1)"; _rc=$?
_leftover_backup=0
for _left in "$SYS/usr/lib/z2k.z2k-backup."* "$SYS/opt/zapret2.z2k-backup."*; do
    { [ -e "$_left" ] || [ -L "$_left" ]; } && _leftover_backup=1
done
if [ "$_rc" -ne 0 ] \
    && [ -e "$T/apk-add-failed" ] \
    && [ ! -e "$SERVICE_STOP_MARKER" ] \
    && grep -qx 'tag=p-1.2' "$SYS/etc/z2k/state/installed-release" \
    && grep -q 'old payload' "$SYS/usr/lib/z2k/version.txt" \
    && [ ! -e "$SYS/usr/lib/.z2k-install/transaction-active" ] \
    && [ "$_leftover_backup" = 0 ]; then
    _t_ok
else
    _t_bad "ошибка apk add должна завершаться до stop/journal/backup: rc=$_rc stop=$([ -e "$SERVICE_STOP_MARKER" ] && echo yes || echo no) active=$([ -e "$SYS/usr/lib/.z2k-install/transaction-active" ] && echo yes || echo no) backup=$_leftover_backup output=$_out"
fi
APK_FAIL=0

prepare_sysroot
_FAULT="" _FAULT_USED=0
_out="$( (
    z2k_ow_release_state_write() { return 1; }
    z2k_ow_install_release "$_tag"
) 2>&1)"; _rc=$?
assert_rolled_back "ошибка записи installed-release возвращает старую версию"

prepare_sysroot
_FAULT="" _FAULT_USED=0
touch "$T/fail-new-health" "$SERVICE_FAIL_FILE"
SERVICE_HEALTH_FAIL="$T/fail-new-health" \
    _out="$(z2k_ow_install_release "$_tag" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && grep -qx 'tag=p-1.2' "$SYS/etc/z2k/state/installed-release" \
    && grep -q 'old payload' "$SYS/usr/lib/z2k/version.txt" \
    && [ -f "$SYS/usr/lib/.z2k-install/transaction-active" ] \
    && [ -s "$SYS/usr/lib/.z2k-install/transaction.log" ]; then
    _t_ok
else
    _t_bad "отказ старой службы при rollback не оставил recovery journal: rc=$_rc output=$_out"
fi
rm -f "$T/fail-new-health" "$SERVICE_FAIL_FILE"
_out="$(z2k_ow_install_release "$_tag" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] \
    && grep -qx "tag=$_tag" "$SYS/etc/z2k/state/installed-release" \
    && grep -qx "$_sha" "$SYS/etc/z2k/state/installed-artifact-sha256" \
    && grep -q "release tag $_tag" "$SYS/usr/lib/z2k/version.txt" \
    && [ ! -e "$SYS/usr/lib/.z2k-install/transaction-active" ]; then
    _t_ok
else
    _t_bad "повтор после неудачного rollback не восстановил транзакцию: rc=$_rc output=$_out"
fi
assert_operator_files_preserved "успешное обновление"

# Reinstall through the same release engine at the same tag and sequence must
# converge a stale receipt without touching user configuration or ownership.
prepare_sysroot
printf 'tag=%s\nseq=%s\n' "$_tag" "$_seq" > "$SYS/etc/z2k/state/installed-release"
_out="$(z2k_ow_install_release --reinstall "$_tag" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] \
    && grep -qx "$_sha" "$SYS/etc/z2k/state/installed-artifact-sha256" \
    && grep -q "release tag $_tag" "$SYS/usr/lib/z2k/version.txt" \
    && [ ! -e "$SYS/usr/lib/.z2k-install/transaction-active" ]; then
    _t_ok
else
    _t_bad "повторная установка текущего tag/seq обновляет digest receipt через общую транзакцию: rc=$_rc output=$_out"
fi
assert_operator_files_preserved "переустановка через release engine"

_t_done
