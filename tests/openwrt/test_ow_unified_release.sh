#!/bin/sh
# Один полный архив, одна запись состояния и общий путь install_release(tag).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-unified-release"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/platform/openwrt/paths.sh"
. "$REPO/lib/auto_update.sh"
. "$REPO/platform/openwrt/manifest.sh"
. "$REPO/platform/openwrt/release_state.sh"
. "$REPO/platform/openwrt/release.sh"
Z2K_TEST_CORE_READY=1
z2k_ow_core_ready() { [ "$Z2K_TEST_CORE_READY" = 1 ]; }
Z2K_TEST_PYTHON="${Z2K_TEST_PYTHON:-python3}"
Z2K_ADAPTER_DIR="$REPO/platform/openwrt"
export Z2K_ADAPTER_DIR

jsonfilter() {
    python3 - "$@" <<'PY'
import json, sys
args = sys.argv[1:]
filename = expr = None
kind = False
while args:
    arg = args.pop(0)
    if arg == "-i": filename = args.pop(0)
    elif arg == "-e": expr = args.pop(0)
    elif arg == "-t": kind = True; expr = args.pop(0)
    else: raise SystemExit(2)
value = json.load(open(filename, encoding="utf-8"))
for key in expr.removeprefix("@.").split("."):
    value = value[key]
if kind:
    print("object" if isinstance(value, dict) else "array" if isinstance(value, list) else "string" if isinstance(value, str) else "number" if isinstance(value, (int, float)) else "null")
elif value is not None:
    print(value)
PY
}

_CURRENT_TAG="$(jsonfilter -i "$REPO/UPDATES.json" -e '@.current')"
_CURRENT_SEQ="$(jsonfilter -i "$REPO/UPDATES.json" -e '@.seq')"
[ -n "$_CURRENT_TAG" ] && [ -n "$_CURRENT_SEQ" ] || { echo 'FAIL[ow-unified-release]: controlled release manifest is unreadable' >&2; exit 1; }

sha256sum() {
    [ "$#" -eq 0 ] && { command sha256sum; return; }
    "$Z2K_TEST_PYTHON" -c 'import hashlib,sys; p=sys.argv[1]; print(hashlib.sha256(open(p,"rb").read()).hexdigest(), p)' "$1"
}

T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
mkdir -p "$T/download-failure-bin"
cat > "$T/download-failure-bin/wget" <<'EOF_WGET_FAIL'
#!/bin/sh
exit 37
EOF_WGET_FAIL
chmod 0755 "$T/download-failure-bin/wget"
_download_error="$(PATH="$T/download-failure-bin:$PATH" \
    z2k_ow_download 'https://github.com/t0fox/z2kOW/releases/download/p-86.13/openwrt-rootfs-arm64.tar.gz' \
    "$T/openwrt-rootfs-arm64.tar.gz.part" 2>&1)"
_download_rc=$?
if [ "$_download_rc" -eq 37 ] \
    && printf '%s\n' "$_download_error" | grep -qF 'не удалось скачать архив выпуска' \
    && printf '%s\n' "$_download_error" | grep -qF 'код ошибки 37' \
    && printf '%s\n' "$_download_error" | grep -qF 'openwrt-rootfs-arm64.tar.gz.part'; then
    _t_ok
else
    _t_bad "ошибка загрузки сообщает причину, код возврата и временный путь: rc=$_download_rc output=$_download_error"
fi
printf "DISTRIB_ARCH='aarch64_cortex-a53'\n" > "$T/openwrt_release"
export Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release"
make_artifact() {
    _stage="$1"
    mkdir -p "$_stage/usr/lib/z2k/platform/openwrt" \
        "$_stage/usr/lib/z2k/bin/linux-arm64" "$_stage/usr/lib/z2k/bin/linux-x86_64" \
        "$_stage/usr/lib/z2k/platform/openwrt/bin/linux-arm64" \
        "$_stage/usr/lib/z2k/platform/openwrt/bin/linux-x86_64" \
        "$_stage/opt/zapret2/binaries/linux-arm64" "$_stage/opt/zapret2/binaries/linux-x86_64" \
        "$_stage/usr/bin" "$_stage/usr/sbin" \
        "$_stage/opt/zapret2/etc/z2k" \
        "$_stage/etc/init.d" "$_stage/etc/hotplug.d/iface" \
        "$_stage/etc/sysctl.d" "$_stage/usr/share/nftables.d/chain-pre/forward"
    printf 'release payload\n' > "$_stage/usr/lib/z2k/platform/openwrt/release.sh"
    cp "$REPO/platform/openwrt/arch.sh" "$_stage/usr/lib/z2k/platform/openwrt/arch.sh"
    printf 'arm64 tg\n' > "$_stage/usr/lib/z2k/bin/linux-arm64/tg-mtproxy-client"
    printf 'x86 tg\n' > "$_stage/usr/lib/z2k/bin/linux-x86_64/tg-mtproxy-client"
    printf 'arm64 rt\n' > "$_stage/usr/lib/z2k/bin/linux-arm64/z2k-rt-proxy"
    printf 'x86 rt\n' > "$_stage/usr/lib/z2k/bin/linux-x86_64/z2k-rt-proxy"
    printf 'arm64 detect\n' > "$_stage/usr/lib/z2k/bin/linux-arm64/z2k-detect"
    printf 'x86 detect\n' > "$_stage/usr/lib/z2k/bin/linux-x86_64/z2k-detect"
    printf 'arm64 warp\n' > "$_stage/usr/lib/z2k/platform/openwrt/bin/linux-arm64/z2k-warpd"
    printf 'x86 warp\n' > "$_stage/usr/lib/z2k/platform/openwrt/bin/linux-x86_64/z2k-warpd"
    chmod 0755 \
        "$_stage/usr/lib/z2k/bin/linux-arm64/tg-mtproxy-client" \
        "$_stage/usr/lib/z2k/bin/linux-x86_64/tg-mtproxy-client" \
        "$_stage/usr/lib/z2k/bin/linux-arm64/z2k-rt-proxy" \
        "$_stage/usr/lib/z2k/bin/linux-x86_64/z2k-rt-proxy" \
        "$_stage/usr/lib/z2k/bin/linux-arm64/z2k-detect" \
        "$_stage/usr/lib/z2k/bin/linux-x86_64/z2k-detect" \
        "$_stage/usr/lib/z2k/platform/openwrt/bin/linux-arm64/z2k-warpd" \
        "$_stage/usr/lib/z2k/platform/openwrt/bin/linux-x86_64/z2k-warpd"
    printf 'arm64 dataplane\n' > "$_stage/opt/zapret2/binaries/linux-arm64/nfqws2"
    printf 'x86 dataplane\n' > "$_stage/opt/zapret2/binaries/linux-x86_64/nfqws2"
    printf 'arm64 ip2net\n' > "$_stage/opt/zapret2/binaries/linux-arm64/ip2net"
    printf 'arm64 mdig\n' > "$_stage/opt/zapret2/binaries/linux-arm64/mdig"
    printf 'x86 ip2net\n' > "$_stage/opt/zapret2/binaries/linux-x86_64/ip2net"
    printf 'x86 mdig\n' > "$_stage/opt/zapret2/binaries/linux-x86_64/mdig"
    chmod 0755 \
        "$_stage/opt/zapret2/binaries/linux-arm64/nfqws2" \
        "$_stage/opt/zapret2/binaries/linux-arm64/ip2net" \
        "$_stage/opt/zapret2/binaries/linux-arm64/mdig" \
        "$_stage/opt/zapret2/binaries/linux-x86_64/nfqws2" \
        "$_stage/opt/zapret2/binaries/linux-x86_64/ip2net" \
        "$_stage/opt/zapret2/binaries/linux-x86_64/mdig"
    printf '#!/bin/sh\nexit 0\n' > "$_stage/usr/lib/z2k/platform/openwrt/bootstrap.sh"
    printf 'release tag %s\n' "$_CURRENT_TAG" > "$_stage/usr/lib/z2k/version.txt"
    printf 'update public key\n' > "$_stage/opt/zapret2/etc/z2k-update-pub.pem"
    printf '#!/bin/sh\nexit 0\n' > "$_stage/usr/bin/z2kow"
    printf '#!/bin/sh\nexit 0\n' > "$_stage/usr/sbin/install_release"
    printf '#!/bin/sh\nexit 0\n' > "$_stage/etc/init.d/z2k"
    printf '#!/bin/sh\nexit 0\n' > "$_stage/etc/init.d/z2k-webpanel"
    printf '# product hotplug\n' > "$_stage/etc/hotplug.d/iface/90-z2k"
    printf 'net.ipv4.ip_forward=1\n' > "$_stage/etc/sysctl.d/99-z2k.conf"
    printf 'table inet z2k-test {}\n' > "$_stage/usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft"
    chmod 0755 "$_stage/usr/bin/z2kow" "$_stage/usr/sbin/install_release" \
        "$_stage/etc/init.d/z2k" "$_stage/etc/init.d/z2k-webpanel"
}

prepare_manifest() {
    _artifact="$1"; _out="$2"; _url="${3:-https://github.com/t0fox/z2kOW/releases/download/openwrt-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/openwrt-rootfs.tar.gz}"; _sha=""; _size=""
    _sha="$(sha256sum "$_artifact" | awk '{print $1}')"
    _size="$(wc -c < "$_artifact" | tr -d ' \t\r\n')"
    "$Z2K_TEST_PYTHON" -c 'import json,sys; p,a,o,sha,size,url=sys.argv[1:]; d=json.load(open(p,encoding="utf-8")); d["artifact"]={"filename":"openwrt-rootfs.tar.gz","url":url,"sha256":sha,"size_bytes":int(size)}; d["signing"]={"key_id":"0000000000000000000000000000000000000000000000000000000000000000"}; history=d.pop("history"); f=open(o,"w",encoding="utf-8"); f.write(json.dumps(d,ensure_ascii=False,indent=2)[:-1]+",\n  "+chr(34)+"history"+chr(34)+": [\n"); f.write(",\n".join("    "+json.dumps(entry,ensure_ascii=False,separators=(",",":")) for entry in history)); f.write("\n  ]\n}\n"); f.close()' \
        "$REPO/UPDATES.json" "$_artifact" "$_out" "$_sha" "$_size" "$_url"
}

prepare_arch_manifest() {
    _artifact="$1" _out="$2" _arch="$3" _url="$4" _legacy_url="${5:-}"
    "$Z2K_TEST_PYTHON" - "$REPO/UPDATES.json" "$_artifact" "$_out" "$_arch" "$_url" "$_legacy_url" <<'PY'
import hashlib, json, pathlib, sys, tarfile
source, archive_path, output, arch, url, legacy_url = sys.argv[1:]
d = json.loads(pathlib.Path(source).read_text(encoding="utf-8"))
archive = pathlib.Path(archive_path).read_bytes()
digest = hashlib.sha256(archive).hexdigest()
size = len(archive)
prefixes = (
    ("usr/lib/z2k/bin/", "linux-"),
    ("usr/lib/z2k/platform/openwrt/bin/", "linux-"),
    ("opt/zapret2/binaries/", "linux-"),
)
unpacked = 0
with tarfile.open(archive_path, "r:gz") as tf:
    for member in tf:
        if not member.isfile():
            continue
        foreign = False
        for prefix, marker in prefixes:
            if member.name.startswith(prefix):
                name = member.name[len(prefix):].split("/", 1)[0]
                if name.startswith(marker) and name != marker + arch:
                    foreign = True
                break
        if not foreign:
            unpacked += member.size
filename = f"openwrt-rootfs-{arch}.tar.gz"
d.pop("artifact", None)
d["artifacts"] = {arch: {"filename": filename, "url": url, "sha256": digest,
                         "size_bytes": size, "unpacked_size_bytes": unpacked}}
if legacy_url:
    d["artifact"] = {"filename": "openwrt-rootfs.tar.gz", "url": legacy_url,
                     "sha256": digest, "size_bytes": size}
d["signing"] = {"key_id": "0000000000000000000000000000000000000000000000000000000000000000"}
pathlib.Path(output).write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

_state_is_release() {
    grep -qx "tag=$1" "$3" 2>/dev/null && grep -qx "seq=$2" "$3" 2>/dev/null
}

SYS="$T/sys"
STAGE="$T/release-root"
_unsafe_owned_paths=""
mkdir -p "$SYS/etc/z2k/state" "$SYS/etc/z2k" "$SYS/usr/lib/z2k/share" "$SYS/etc/apk/repositories.d" "$SYS/etc/apk/keys"
mkdir -p "$SYS/opt/zapret2"
printf '{"install_id":"legacy-install","priv":"legacy-key"}\n' > "$SYS/opt/zapret2/.z2k-relay-id"
printf 'p-86.2\n' > "$SYS/etc/z2k/state/installed-release"
printf 'keep user config\n' > "$SYS/etc/z2k/config"
printf 'old apk-owned file\n' > "$SYS/usr/lib/z2k/legacy.txt"
printf '#!/bin/sh\nexit 0\n' > "$SYS/usr/lib/z2k/z2k-stats-upload.sh"
printf 'stats-upload=2026-10-05\n' > "$SYS/opt/zapret2/.z2k-scheduler-state"
printf 'https://github.com/t0fox/z2kOW/releases/latest/download/packages.adb\n' > "$SYS/etc/apk/repositories.d/z2kow.list"
printf 'https://feed.z2k.example.com/openwrt\n' > "$SYS/etc/apk/repositories.d/z2k.list"
printf 'https://downloads.openwrt.org/releases/24.10/packages/aarch64_cortex-a53/base\n' > "$SYS/etc/apk/repositories.d/custom.list"
printf 'https://feed.z2k.example.com/openwrt\nhttps://downloads.openwrt.org/releases/24.10/packages/aarch64_cortex-a53/packages\n' > "$SYS/etc/apk/repositories"
printf 'legacy z2kOW feed key\n' > "$SYS/usr/lib/z2k/share/z2k-feed.pem"
cp "$SYS/usr/lib/z2k/share/z2k-feed.pem" "$SYS/etc/apk/keys/z2k-feed.pem"
printf '%s\n' z2k-adapter z2k-webpanel z2k-zapret2-runtime z2k-warp-runtime > "$T/legacy-packages"
make_artifact "$STAGE"
mkdir -p "$T/dist"
    tar -czf "$T/dist/openwrt-rootfs.tar.gz" -C "$STAGE" usr etc opt
_release_real_tar="$(command -v tar)"
mkdir -p "$T/extract-failure-bin" "$T/extract-failure-work" \
    "$T/extract-failure-stage" "$T/extract-failure-tmp"
"$_release_real_tar" -tzf "$T/dist/openwrt-rootfs.tar.gz" > "$T/extract-failure-list"
cat > "$T/extract-failure-bin/tar" <<'EOF_TAR_FAIL'
#!/bin/sh
case " $* " in
    *' -xzf '*) echo 'ошибка тестовой распаковки' >&2; exit 41 ;;
esac
exec "$Z2K_TEST_REAL_TAR" "$@"
EOF_TAR_FAIL
chmod 0755 "$T/extract-failure-bin/tar"
_extract_error="$(
    (
        PATH="$T/extract-failure-bin:$PATH"
        Z2K_TEST_REAL_TAR="$_release_real_tar"
        export PATH Z2K_TEST_REAL_TAR
        _adapter="$REPO/platform/openwrt"
        z2k_ow_overlay_preflight() { return 0; }
        z2k_ow_memory_preflight() { return 0; }
        z2k_ow_extract_target_payload "$T/dist/openwrt-rootfs.tar.gz" \
            "$T/extract-failure-stage" "$T/extract-failure-list" \
            "$T/extract-failure-work" "$T/extract-failure-tmp"
    ) 2>&1
)"
_extract_rc=$?
if [ "$_extract_rc" -ne 0 ] \
    && printf '%s\n' "$_extract_error" | grep -qF 'не удалось распаковать проверенный архив' \
    && printf '%s\n' "$_extract_error" | grep -qF "$T/extract-failure-stage" \
    && printf '%s\n' "$_extract_error" | grep -qF 'код ошибки'; then
    _t_ok
else
    _t_bad "сбой распаковки сообщает путь временного каталога и код ошибки: rc=$_extract_rc output=$_extract_error"
fi
prepare_manifest "$T/dist/openwrt-rootfs.tar.gz" "$T/UPDATES.json"
z2k_ow_manifest_release_ok "$T/UPDATES.json" \
    && _t_ok || _t_bad "technical immutable release URL is valid for the controlled p-86.13 manifest"
cp "$T/UPDATES.json" "$T/untrusted-URL.json"
"$Z2K_TEST_PYTHON" - "$T/untrusted-URL.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
d = json.loads(path.read_text(encoding="utf-8"))
d["artifact"]["url"] = "https://attacker.example/releases/download/openwrt-" + "a" * 40 + "/openwrt-rootfs.tar.gz"
path.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
if z2k_ow_manifest_release_ok "$T/untrusted-URL.json"; then
    _t_bad "manifest artifact URL cannot escape the controlled GitHub repository"
else
    _t_ok
fi
_decision="$(z2k_ow_release_decision "$T/UPDATES.json" "$SYS/etc/z2k/state/installed-release")"
assert_eq "p-86.2 through upstream reinstall release enters controlled full install" \
    "update $_CURRENT_TAG" "$_decision"

apk() {
    printf '%s\n' "$*" >> "$T/apk.log"
    case "$1" in
        info)
            case "$2" in
                -e) grep -qx "$3" "$T/legacy-packages" ;;
                --contents)
                    grep -qx "$3" "$T/legacy-packages" || return 1
                    if [ -n "$_unsafe_owned_paths" ]; then
                        printf '%s\n' "$_unsafe_owned_paths"
                    else
                        printf '%s\n' usr/lib/z2k/legacy.txt
                    fi
                    ;;
                *) return 2 ;;
            esac
            ;;
        add)
            printf '%s\n' "$*" >> "$T/apk.add.log"
            printf '%s\n' 'system dependency install' >> "$T/apk.log"
            ;;
        del)
            shift; [ "$1" = --no-scripts ] || return 9; shift
            for _pkg in "$@"; do
                sed -i "\\|^$_pkg\$|d" "$T/legacy-packages"
                # Имитировать удаление файлов пакетом apk. До apk del транзакция
                # должна перенести их рядом с исходными путями.
                rm -f "$SYS/usr/lib/z2k/legacy.txt" "$SYS/usr/bin/z2kow" \
                    "$SYS/usr/sbin/install_release" "$SYS/etc/init.d/z2k" \
                    "$SYS/etc/init.d/z2k-webpanel" "$SYS/etc/hotplug.d/iface/90-z2k" \
                    "$SYS/etc/sysctl.d/99-z2k.conf" \
                    "$SYS/usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft"
            done
            ;;
        *) return 2 ;;
    esac
}

export Z2K_OW_TESTING=1 Z2K_OW_SYSROOT="$SYS"
export Z2K_ROOT="$SYS/usr/lib/z2k" Z2K_ADAPTER_DIR="$REPO/platform/openwrt"
export Z2K_OW_INSTALL_TMP="$T/install-tmp"
export Z2K_OW_MANIFEST_PATH="$T/UPDATES.json" Z2K_OW_ARTIFACT_PATH="$T/dist/openwrt-rootfs.tar.gz"
export Z2K_OW_INSTALLED_RELEASE_FILE=/etc/z2k/state/installed-release
export Z2K_OW_INSTALL_WORK=/usr/lib/.z2k-install
mkdir -p "$Z2K_OW_INSTALL_TMP"
printf 'не удалять пользовательские временные данные\n' > "$Z2K_OW_INSTALL_TMP/user-data.txt"

_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
_state_ok=0; _old_ok=0; _version_ok=0; _config_ok=0
_state_is_release "$_CURRENT_TAG" "$_CURRENT_SEQ" "$SYS/etc/z2k/state/installed-release" && _state_ok=1
_identity_ok=0
grep -q 'legacy-install' "$SYS/etc/z2k/state/relay-id.json" && _identity_ok=1
[ ! -e "$SYS/usr/lib/z2k/legacy.txt" ] && _old_ok=1
_telemetry_ok=0
[ ! -e "$SYS/usr/lib/z2k/z2k-stats-upload.sh" ] \
    && [ ! -e "$SYS/opt/zapret2/.z2k-scheduler-state" ] && _telemetry_ok=1
grep -q "release tag $_CURRENT_TAG" "$SYS/usr/lib/z2k/version.txt" && _version_ok=1
grep -q 'keep user config' "$SYS/etc/z2k/config" && _config_ok=1
if [ "$_rc" -eq 0 ] && [ "$_state_ok" = 1 ] && [ "$_identity_ok" = 1 ] && [ "$_old_ok" = 1 ] && [ "$_telemetry_ok" = 1 ] \
    && [ "$_version_ok" = 1 ] && [ "$_config_ok" = 1 ]; then
    _t_ok
else
    _t_bad "legacy full migration to $_CURRENT_TAG retires old strategy telemetry without losing release state: rc=$_rc checks=$_state_ok/$_identity_ok/$_old_ok/$_telemetry_ok/$_version_ok/$_config_ok state=$(cat "$SYS/etc/z2k/state/installed-release" 2>/dev/null) old=$(test -e "$SYS/usr/lib/z2k/legacy.txt" && echo present || echo absent) uploader=$(test -e "$SYS/usr/lib/z2k/z2k-stats-upload.sh" && echo present || echo absent) version=$(cat "$SYS/usr/lib/z2k/version.txt" 2>/dev/null) config=$(cat "$SYS/etc/z2k/config" 2>/dev/null) output=$_out"
fi
if printf '%s\n' "$_out" | grep -qF 'Проверяю совместный запас оперативной памяти и временного хранилища' \
    && printf '%s\n' "$_out" | grep -qF 'Заранее проверяю место для архива, распаковки и отката' \
    && printf '%s\n' "$_out" | grep -qF 'Повторно проверяю место после установки системных зависимостей'; then
    _t_ok
else
    _t_bad "журнал установки показывает отдельные этапы проверки памяти и места на разделе"
fi
if grep -q 'не удалять пользовательские временные данные' "$Z2K_OW_INSTALL_TMP/user-data.txt"; then
    _t_ok
else
    _t_bad "установка затронула пользовательские данные рядом с временным каталогом"
fi
if grep -Eq '^add --no-scripts lighttpd([[:space:]]|$)' "$T/apk.add.log"; then
    _t_ok
else
    _t_bad "lighttpd system dependency install must not enable its default LuCI-port daemon"
fi
if [ -f "$SYS/usr/lib/z2k/bin/linux-arm64/tg-mtproxy-client" ] \
    && [ ! -e "$SYS/usr/lib/z2k/bin/linux-x86_64/tg-mtproxy-client" ] \
    && [ -f "$SYS/usr/lib/z2k/platform/openwrt/bin/linux-arm64/z2k-warpd" ] \
    && [ ! -e "$SYS/usr/lib/z2k/platform/openwrt/bin/linux-x86_64/z2k-warpd" ] \
    && [ -f "$SYS/opt/zapret2/binaries/linux-arm64/nfqws2" ] \
    && [ ! -e "$SYS/opt/zapret2/binaries/linux-x86_64/nfqws2" ]; then
    _t_ok
else
    _t_bad "installer did not prune other architecture variants from target staging"
fi

# Если маркер отсутствует или пуст, безопасно синхронизировать текущий тег
# и не считать всю историю релизов новой установкой.
: > "$SYS/etc/z2k/state/installed-release"
_decision="$(z2k_ow_release_decision "$T/UPDATES.json" "$SYS/etc/z2k/state/installed-release")"
assert_eq "empty installed tag resyncs without reinstall loop" "resync $_CURRENT_TAG" "$_decision"
z2k_ow_release_state_write "$SYS/etc/z2k/state/installed-release" "$T/UPDATES.json"
if [ ! -e "$SYS/etc/apk/repositories.d/z2kow.list" ] \
    && [ ! -e "$SYS/etc/apk/repositories.d/z2k.list" ] \
    && grep -q 'downloads.openwrt.org/releases/24.10/packages/aarch64_cortex-a53/base' "$SYS/etc/apk/repositories.d/custom.list" \
    && ! grep -q 'feed.z2k.example.com/openwrt' "$SYS/etc/apk/repositories" \
    && grep -q 'downloads.openwrt.org/releases/24.10/packages/aarch64_cortex-a53/packages' "$SYS/etc/apk/repositories" \
    && [ ! -e "$SYS/etc/apk/keys/z2k-feed.pem" ] \
    && [ ! -s "$T/legacy-packages" ]; then
    _t_ok
else
    _t_bad "legacy APK/feed ownership remains after migration"
fi

_install_lock="$SYS/usr/lib/.z2k-install.lock"
mkdir -p "$_install_lock"
printf '99999999\n' > "$_install_lock/pid"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] && printf '%s' "$_out" | grep -q "none $_CURRENT_TAG" \
    && [ ! -e "$_install_lock" ]; then
    _t_ok
else
    _t_bad "stale installer lock was not recovered: rc=$_rc output=$_out"
fi
mkdir -p "$_install_lock"
printf '%s\n' "$$" > "$_install_lock/pid"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_out" | grep -q 'уже выполняется другой install_release' \
    && _state_is_release "$_CURRENT_TAG" "$_CURRENT_SEQ" "$SYS/etc/z2k/state/installed-release"; then
    _t_ok
else
    _t_bad "concurrent installer was not rejected safely: rc=$_rc output=$_out"
fi
rm -rf "$_install_lock"

# Неверное описание старого пакета, которому принадлежат LuCI/uhttpd,
# отклоняется до apk del и изменения любых защищённых путей.
mkdir -p "$SYS/www/cgi-bin" "$SYS/etc/config"
printf 'keep LuCI entrypoint\n' > "$SYS/www/cgi-bin/luci"
printf 'keep OpenWrt web server config\n' > "$SYS/etc/config/uhttpd"
printf '%s\n' z2k-adapter > "$T/legacy-packages"
_unsafe_owned_paths='www/cgi-bin/luci
etc/config/uhttpd'
: > "$T/apk.log"
_out="$(z2k_ow_legacy_migrate "$SYS/usr/lib/z2k" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_out" | grep -q 'защищённым путём LuCI/uhttpd' \
    && ! grep -qE '^(add|del) ' "$T/apk.log" \
    && grep -q 'keep LuCI entrypoint' "$SYS/www/cgi-bin/luci" \
    && grep -q 'keep OpenWrt web server config' "$SYS/etc/config/uhttpd"; then
    _t_ok
else
    _t_bad "legacy migration touched or accepted protected LuCI/uhttpd ownership"
fi
_unsafe_owned_paths=""
: > "$T/legacy-packages"

_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
assert_eq "second install is none" "none $_CURRENT_TAG" "$(printf '%s\n' "$_out" | tail -n 1)"
assert_eq "second install is a no-op" "0" "$_rc"
_decision="$(z2k_ow_release_decision "$T/UPDATES.json" "$SYS/etc/z2k/state/installed-release")"
assert_eq "check after p-86.2 -> $_CURRENT_TAG install is none" "none $_CURRENT_TAG" "$_decision"
assert_eq "installed state has one tag and upstream seq" "2" "$(wc -l < "$SYS/etc/z2k/state/installed-release" | tr -d ' \t\r\n')"

# Совпадающие метаданные не должны скрывать отказ dataplane readiness.
_out="$(Z2K_TEST_CORE_READY=0 z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] && printf '%s\n' "$_out" | grep -q "^Установлен выпуск $_CURRENT_TAG$"; then
    _t_ok
else
    _t_bad "no-op скрыл неготовый dataplane вместо восстановления: rc=$_rc output=$_out"
fi

# Канонический tag сам по себе не подтверждает целостность повреждённого payload.
# Перед no-op проверяется набор исполняемых файлов выбранной архитектуры.
rm -f "$SYS/usr/lib/z2k/bin/linux-arm64/tg-mtproxy-client"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] && printf '%s\n' "$_out" | grep -q "^Установлен выпуск $_CURRENT_TAG$" \
    && [ -x "$SYS/usr/lib/z2k/bin/linux-arm64/tg-mtproxy-client" ]; then
    _t_ok
else
    _t_bad "matching tag masked a missing target binary instead of repairing it: rc=$_rc mode=$(ls -ld "$SYS/usr/lib/z2k/bin/linux-arm64/tg-mtproxy-client" 2>/dev/null) archive=$(tar -tvzf "$T/dist/openwrt-rootfs.tar.gz" 2>/dev/null | grep 'linux-arm64/tg-mtproxy-client') output=$_out"
fi

# Намеренная переустановка той же версии заменяет проверенные файлы на месте,
# используя сверенный архив как резерв. Это восстанавливает повреждённый файл
# без второй полной копии и сохраняет состояние, настройки и пользовательские списки.
_state_before="$(cat "$SYS/etc/z2k/state/installed-release")"
mkdir -p "$SYS/etc/z2k/user-lists"
mkdir -p "$SYS/etc/config" "$SYS/etc/z2k/state"
printf 'keep user config\n' > "$SYS/etc/z2k/config"
printf 'keep user domains\n' > "$SYS/etc/z2k/user-lists/extra-domains.txt"
printf 'enabled=1\nprovider=xbox\n' > "$SYS/etc/z2k/state/doh.state"
printf 'z2kow_xbox\n' > "$SYS/etc/z2k/state/.doh-uci-owned"
printf 'https-dns-proxy\n' > "$SYS/etc/z2k/state/.doh-package-owned"
printf "config main 'config'\n\nconfig https-dns-proxy 'z2kow_xbox'\n\toption resolver_url 'https://xbox-dns.ru/dns-query'\n" \
    > "$SYS/etc/config/https-dns-proxy"
printf 'damaged release file\n' > "$SYS/usr/lib/z2k/version.txt"
_out="$( (
    z2k_ow_extract_target_payload() {
        echo "повторная установка не должна создавать полную временную распаковку" >&2
        return 91
    }
    z2k_ow_prepare_install_stage() {
        echo "повторная установка не должна создавать временный каталог распаковки" >&2
        return 92
    }
    z2k_ow_install_release --reinstall "$_CURRENT_TAG"
) 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] \
    && [ "$(printf '%s\n' "$_out" | tail -n 1)" = "Установлен выпуск $_CURRENT_TAG" ] \
    && grep -q "release tag $_CURRENT_TAG" "$SYS/usr/lib/z2k/version.txt" \
    && [ "$(cat "$SYS/etc/z2k/state/installed-release")" = "$_state_before" ] \
    && grep -q 'keep user config' "$SYS/etc/z2k/config" \
    && grep -q 'keep user domains' "$SYS/etc/z2k/user-lists/extra-domains.txt" \
    && grep -q '^enabled=1$' "$SYS/etc/z2k/state/doh.state" \
    && grep -q '^z2kow_xbox$' "$SYS/etc/z2k/state/.doh-uci-owned" \
    && grep -q '^https-dns-proxy$' "$SYS/etc/z2k/state/.doh-package-owned" \
    && grep -q "https://xbox-dns.ru/dns-query" "$SYS/etc/config/https-dns-proxy" \
    && [ ! -e "$SYS/usr/lib/.z2k-install" ] \
    && [ ! -e "$Z2K_OW_INSTALL_TMP/z2kow-release" ] \
    && ! find "$SYS" \( -name '*.z2k-backup.*' -o -name '*.z2k-new.*' \) | grep -q .; then
    _t_ok
else
    _t_bad "same-version reinstall did not reconverge while preserving state/settings/lists: rc=$_rc state=$(cat "$SYS/etc/z2k/state/installed-release" 2>/dev/null) version=$(cat "$SYS/usr/lib/z2k/version.txt" 2>/dev/null) output=$_out"
fi

# При малом постоянном хранилище отказ должен произойти до остановки службы
# и оставить прежние файлы и состояние нетронутыми.
cp "$SYS/usr/lib/z2k/version.txt" "$T/direct-reinstall-before-low-space.txt"
printf 'сохранить при нехватке места\n' > "$SYS/usr/lib/z2k/version.txt"
_apk_calls_before="$(wc -l < "$T/apk.log")"
_out="$( (
    z2k_ow_memory_preflight() { return 0; }
    df() { printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim-root 100000 99999 1 99%% /overlay\n'; }
    z2k_ow_service_call() {
        [ "${2:-}" != stop ] || : > "$T/direct-low-space-service-stopped"
        return 0
    }
    z2k_ow_install_release --reinstall "$_CURRENT_TAG"
) 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && printf '%s\n' "$_out" | grep -q 'недостаточно места' \
    && grep -q 'сохранить при нехватке места' "$SYS/usr/lib/z2k/version.txt" \
    && [ "$(cat "$SYS/etc/z2k/state/installed-release")" = "$_state_before" ] \
    && [ "$(wc -l < "$T/apk.log")" -eq "$_apk_calls_before" ] \
    && [ ! -e "$T/direct-low-space-service-stopped" ] \
    && [ ! -e "$SYS/usr/lib/.z2k-install" ] \
    && [ ! -e "$Z2K_OW_INSTALL_TMP/z2kow-release" ]; then
    _t_ok
else
    _t_bad "нехватка места не остановила переустановку до изменения файлов и служб: rc=$_rc output=$_out"
fi
cp "$T/direct-reinstall-before-low-space.txt" "$SYS/usr/lib/z2k/version.txt"

# Если распаковка после освобождения прежних путей прерывается, откат заново
# извлекает тот же сверенный архив и удаляет временные данные после проверки.
_real_tar="$(command -v tar)"
mkdir -p "$T/direct-reinstall-fail-bin"
cat > "$T/direct-reinstall-fail-bin/tar" <<'EOF_DIRECT_TAR_FAIL'
#!/bin/sh
if [ -n "${Z2K_TEST_DIRECT_ROOT:-}" ] && [ -n "${Z2K_TEST_DIRECT_FAIL_MARKER:-}" ] \
    && [ ! -e "$Z2K_TEST_DIRECT_FAIL_MARKER" ] \
    && printf '%s\n' "$*" | grep -Fq -- "-xzf " \
    && printf '%s\n' "$*" | grep -Fq -- "-C $Z2K_TEST_DIRECT_ROOT"; then
    : > "$Z2K_TEST_DIRECT_FAIL_MARKER"
    echo 'искусственный обрыв распаковки' >&2
    exit 47
fi
exec "$Z2K_TEST_REAL_TAR" "$@"
EOF_DIRECT_TAR_FAIL
chmod 0755 "$T/direct-reinstall-fail-bin/tar"
printf 'повреждено перед проверкой отката\n' > "$SYS/usr/lib/z2k/version.txt"
_out="$( (
    PATH="$T/direct-reinstall-fail-bin:$PATH"
    Z2K_TEST_REAL_TAR="$_real_tar"
    Z2K_TEST_DIRECT_ROOT="${SYS%/}/"
    Z2K_TEST_DIRECT_FAIL_MARKER="$T/direct-reinstall-fail-once"
    export PATH Z2K_TEST_REAL_TAR Z2K_TEST_DIRECT_ROOT Z2K_TEST_DIRECT_FAIL_MARKER
    z2k_ow_install_release --reinstall "$_CURRENT_TAG"
) 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && [ "$(cat "$SYS/etc/z2k/state/installed-release")" = "$_state_before" ] \
    && grep -q "release tag $_CURRENT_TAG" "$SYS/usr/lib/z2k/version.txt" \
    && printf '%s\n' "$_out" | grep -q 'Z2KOW_ROLLBACK=complete' \
    && [ ! -e "$SYS/usr/lib/.z2k-install" ] \
    && [ ! -e "$Z2K_OW_INSTALL_TMP/z2kow-release" ]; then
    _t_ok
else
    _t_bad "повторная установка не восстановила тот же проверенный архив после обрыва: rc=$_rc state=$(cat "$SYS/etc/z2k/state/installed-release" 2>/dev/null) version=$(cat "$SYS/usr/lib/z2k/version.txt" 2>/dev/null) output=$_out"
fi

# После отключения питания установленная часть может отсутствовать целиком.
# Раннее восстановление должно собрать её из оставленного проверенного архива.
DIRECT_RECOVERY_SYS="$T/direct-recovery-sys"
DIRECT_RECOVERY_WORK="$DIRECT_RECOVERY_SYS/usr/lib/.z2k-install"
DIRECT_RECOVERY_TMP="$T/direct-recovery-tmp/z2kow-release"
DIRECT_RECOVERY_SHA="$(cat "$SYS/etc/z2k/state/installed-artifact-sha256")"
mkdir -p "$DIRECT_RECOVERY_SYS/etc/z2k/state" "$DIRECT_RECOVERY_SYS/etc/z2k" \
    "$DIRECT_RECOVERY_WORK" "$DIRECT_RECOVERY_TMP"
printf '%s\n' 'z2kow-release-stage-v1' > "$DIRECT_RECOVERY_TMP/.z2kow-owner"
printf 'tag=%s\nseq=%s\n' "$_CURRENT_TAG" "$_CURRENT_SEQ" \
    > "$DIRECT_RECOVERY_SYS/etc/z2k/state/installed-release"
printf '%s\n' "$DIRECT_RECOVERY_SHA" \
    > "$DIRECT_RECOVERY_SYS/etc/z2k/state/installed-artifact-sha256"
cp "$DIRECT_RECOVERY_SYS/etc/z2k/state/installed-release" \
    "$DIRECT_RECOVERY_WORK/installed-release.old"
cp "$DIRECT_RECOVERY_SYS/etc/z2k/state/installed-artifact-sha256" \
    "$DIRECT_RECOVERY_WORK/installed-artifact.old"
cp "$T/dist/openwrt-rootfs.tar.gz" "$DIRECT_RECOVERY_WORK/openwrt-rootfs.tar.gz"
printf '%s\n' "$DIRECT_RECOVERY_SHA" > "$DIRECT_RECOVERY_WORK/transaction-artifact"
wc -c < "$DIRECT_RECOVERY_WORK/openwrt-rootfs.tar.gz" \
    | tr -d ' \t\r\n' > "$DIRECT_RECOVERY_WORK/transaction-artifact-size"
printf '%s\n' arm64 > "$DIRECT_RECOVERY_WORK/transaction-arch"
printf 'tag=%s\nseq=%s\n' "$_CURRENT_TAG" "$_CURRENT_SEQ" \
    > "$DIRECT_RECOVERY_WORK/transaction-target"
printf '%s\n' 9417 > "$DIRECT_RECOVERY_WORK/transaction-id"
printf '%s\n' same-archive-v1 > "$DIRECT_RECOVERY_WORK/reinstall-from-archive"
printf '%s\n' 'V|2' > "$DIRECT_RECOVERY_WORK/transaction.log"
cp "$REPO/platform/openwrt/owned-paths.txt" "$DIRECT_RECOVERY_WORK/owned-paths"
: > "$DIRECT_RECOVERY_WORK/state-was-present"
: > "$DIRECT_RECOVERY_WORK/artifact-was-present"
: > "$DIRECT_RECOVERY_WORK/transaction-active"
: > "$DIRECT_RECOVERY_WORK/startup-links-prepared"
: > "$DIRECT_RECOVERY_WORK/startup-paths"
printf 'ENABLED=0\n' > "$DIRECT_RECOVERY_SYS/etc/z2k/config"
_out="$( (
    export Z2K_OW_SYSROOT="$DIRECT_RECOVERY_SYS"
    export Z2K_ROOT="$DIRECT_RECOVERY_SYS/usr/lib/z2k"
    export Z2K_ADAPTER_DIR="$REPO/platform/openwrt"
    export Z2K_OW_INSTALL_TMP="${DIRECT_RECOVERY_TMP%/z2kow-release}"
    _tmp_work="$DIRECT_RECOVERY_TMP"
    z2k_ow_recover_transaction "$DIRECT_RECOVERY_WORK" \
        "$DIRECT_RECOVERY_SYS/etc/z2k/state/installed-release" \
        "$DIRECT_RECOVERY_SYS/etc/init.d/z2k" "$_CURRENT_TAG" "$_CURRENT_SEQ" \
        "$DIRECT_RECOVERY_SYS/etc/init.d/z2k-webpanel"
) 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] \
    && grep -q "release tag $_CURRENT_TAG" "$DIRECT_RECOVERY_SYS/usr/lib/z2k/version.txt" \
    && [ "$(cat "$DIRECT_RECOVERY_SYS/etc/z2k/state/installed-artifact-sha256")" = "$DIRECT_RECOVERY_SHA" ] \
    && [ ! -e "$DIRECT_RECOVERY_WORK" ] \
    && [ ! -e "$DIRECT_RECOVERY_TMP" ] \
    && printf '%s\n' "$_out" | grep -q 'восстановлена прерванная транзакция установки'; then
    _t_ok
else
    _t_bad "восстановление после отключения питания не собрало файлы из проверенного архива: rc=$_rc version=$(cat "$DIRECT_RECOVERY_SYS/usr/lib/z2k/version.txt" 2>/dev/null) output=$_out"
fi

# Принудительная переустановка пропускает только проверку равенства версии.
# Хэш и размер архива по-прежнему проверяются до замены файлов релиза.
cp "$T/UPDATES.json" "$T/reinstall-bad-hash.json"
"$Z2K_TEST_PYTHON" -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); d["artifact"]["sha256"]="0"*64; json.dump(d,open(sys.argv[2],"w",encoding="utf-8"),ensure_ascii=False)' \
    "$T/UPDATES.json" "$T/reinstall-bad-hash.json"
export Z2K_OW_MANIFEST_PATH="$T/reinstall-bad-hash.json"
printf 'preserve before hash failure\n' > "$SYS/usr/lib/z2k/version.txt"
_out="$(z2k_ow_install_release --reinstall "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && grep -q 'preserve before hash failure' "$SYS/usr/lib/z2k/version.txt" \
    && [ "$(cat "$SYS/etc/z2k/state/installed-release")" = "$_state_before" ]; then
    _t_ok
else
    _t_bad "same-version reinstall bypassed artifact SHA-256 verification: rc=$_rc output=$_out"
fi
export Z2K_OW_MANIFEST_PATH="$T/UPDATES.json"

cp "$T/UPDATES.json" "$T/reinstall-bad-size.json"
"$Z2K_TEST_PYTHON" -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p,encoding="utf-8")); d["artifact"]["size_bytes"] += 1; json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)' \
    "$T/reinstall-bad-size.json"
export Z2K_OW_MANIFEST_PATH="$T/reinstall-bad-size.json"
printf 'preserve before size failure\n' > "$SYS/usr/lib/z2k/version.txt"
_out="$(z2k_ow_install_release --reinstall "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && grep -q 'preserve before size failure' "$SYS/usr/lib/z2k/version.txt" \
    && [ "$(cat "$SYS/etc/z2k/state/installed-release")" = "$_state_before" ]; then
    _t_ok
else
    _t_bad "same-version reinstall bypassed artifact size verification: rc=$_rc output=$_out"
fi
export Z2K_OW_MANIFEST_PATH="$T/UPDATES.json"

# Если утверждённый релиз изменился после показа сообщения, но до ручного
# действия, install_release должен отклонить старую цель до замены файлов.
# Это защищает от гонки версий.
cp "$T/UPDATES.json" "$T/reinstall-newer.json"
_CURRENT_TAG_PREFIX=${_CURRENT_TAG%.*}
_CURRENT_TAG_PATCH=${_CURRENT_TAG##*.}
case "$_CURRENT_TAG_PATCH" in
    ''|*[!0-9]*) _t_bad "cannot derive a newer race-fixture tag from $_CURRENT_TAG"; exit 1 ;;
esac
_RACE_TAG="$_CURRENT_TAG_PREFIX.$((_CURRENT_TAG_PATCH + 1))"
_RACE_SEQ=$((_CURRENT_SEQ + 1))
"$Z2K_TEST_PYTHON" - "$T/reinstall-newer.json" "$_RACE_TAG" "$_RACE_SEQ" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
d = json.loads(path.read_text(encoding="utf-8"))
d["current"] = sys.argv[2]
d["seq"] = int(sys.argv[3])
d["upstream"]["tag"] = sys.argv[2]
path.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
export Z2K_OW_MANIFEST_PATH="$T/reinstall-newer.json"
printf 'preserve on manifest race\n' > "$SYS/usr/lib/z2k/version.txt"
_out="$(z2k_ow_install_release --reinstall "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -eq 3 ] \
    && printf '%s\n' "$_out" | grep -q "^Z2KOW_REINSTALL_UPDATE_AVAILABLE:$_RACE_TAG$" \
    && grep -q 'preserve on manifest race' "$SYS/usr/lib/z2k/version.txt" \
    && [ "$(cat "$SYS/etc/z2k/state/installed-release")" = "$_state_before" ]; then
    _t_ok
else
    _t_bad "manifest race installed or obscured the newer release: rc=$_rc output=$_out"
fi
export Z2K_OW_MANIFEST_PATH="$T/UPDATES.json"

# При переустановке production-подпись проверяется до решения о no-op; размер
# и хэш архива нельзя переносить за ветку принудительного режима. Эти проверки
# порядка защищают production-границу доверия; выше проверяется сама транзакция.
"$Z2K_TEST_PYTHON" - "$REPO/platform/openwrt/release.sh" <<'PY'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text(encoding="utf-8")
body = source.split("_z2k_ow_install_release_locked() {", 1)[1].split("\n}", 1)[0]
verify = body.index("z2k_ow_manifest_prepare_production")
reinstall_guard = body.index('if [ "$_reinstall" = 1 ]; then')
same_version = body.index('echo "none $_tag"')
size_check = body.index('_actual_size="$(wc -c < "$_archive"')
hash_check = body.index('[ "$_actual" = "$_sha" ]')
assert verify < reinstall_guard < same_version < size_check < hash_check
assert '[ "$_reinstall" != 1 ]' in body
PY
_rc=$?
[ "$_rc" -eq 0 ] && _t_ok || _t_bad "reinstall force is limited to the same-version early return and preserves trust checks"

# Новый процесс shell имитирует состояние после перезагрузки.
_out="$(Z2K_ADAPTER_DIR="$REPO/platform/openwrt" z2k_ow_release_decision "$T/UPDATES.json" "$SYS/etc/z2k/state/installed-release")"
assert_eq "reboot simulation retains one installed-release state" "none $_CURRENT_TAG" "$_out"

# Новая установка использует тот же обработчик и создаёт одну запись состояния.
rm -rf "$SYS"
mkdir -p "$SYS/usr/lib" "$SYS/usr/bin" "$SYS/usr/sbin" "$SYS/etc/z2k/state"
: > "$SYS/etc/z2k/state/installed-release"
export Z2K_OW_SYSROOT="$SYS"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
_state_ok=0; _version_ok=0
_state_is_release "$_CURRENT_TAG" "$_CURRENT_SEQ" "$SYS/etc/z2k/state/installed-release" && _state_ok=1
[ -f "$SYS/usr/lib/z2k/version.txt" ] && _version_ok=1
if [ "$_rc" -eq 0 ] && [ "$_state_ok" = 1 ] && [ "$_version_ok" = 1 ]; then
    _t_ok
else
    _t_bad "fresh full install: rc=$_rc state_ok=$_state_ok version_ok=$_version_ok state=$(cat "$SYS/etc/z2k/state/installed-release" 2>/dev/null) version=$(cat "$SYS/usr/lib/z2k/version.txt" 2>/dev/null) output=$_out"
fi
if [ ! -e "$SYS/etc/z2k/state/installed-tag" ] && [ ! -e "$SYS/etc/z2k/state/product-tag" ]; then
    _t_ok
else
    _t_bad "more than one installed release state remains"
fi

# Начальный установщик с явно заданным манифестом сохраняет локальный URL
# загрузки и использует тот же основной движок install_release.
BOOTSTRAP_SYS="$T/bootstrap-sys"
BOOTSTRAP_TMP="$T/bootstrap-tmp"
BOOTSTRAP_ENGINE="$T/bootstrap-engine/usr/lib/z2k"
BOOTSTRAP_SERVICE_ENV="$T/bootstrap-service-env"
BOOTSTRAP_SERVICE_STOP="$T/bootstrap-service-stop"
BOOTSTRAP_URL=http://127.0.0.1:17777/UPDATES.json
mkdir -p "$BOOTSTRAP_SYS/usr/lib" "$BOOTSTRAP_SYS/usr/bin" "$BOOTSTRAP_SYS/usr/sbin" \
    "$BOOTSTRAP_SYS/etc/z2k/state" "$BOOTSTRAP_TMP"
printf 'tag=p-86.12\nseq=135\n' > "$BOOTSTRAP_SYS/etc/z2k/state/installed-release"
mkdir -p "$BOOTSTRAP_SYS/usr/lib/z2k" "$BOOTSTRAP_SYS/etc/init.d"
printf 'previous payload\n' > "$BOOTSTRAP_SYS/usr/lib/z2k/version.txt"
cat > "$BOOTSTRAP_SYS/etc/init.d/z2k" <<EOF
#!/bin/sh
case "\$1" in
    stop) echo stopped >> "$BOOTSTRAP_SERVICE_STOP" ;;
    restart|start|status) exit 0 ;;
esac
EOF
chmod 755 "$BOOTSTRAP_SYS/etc/init.d/z2k"
mkdir -p "$BOOTSTRAP_ENGINE/platform"
cp -R "$REPO/platform/openwrt" "$BOOTSTRAP_ENGINE/platform/openwrt"
cp -R "$REPO/lib" "$BOOTSTRAP_ENGINE/lib"
make_artifact "$T/bootstrap-payload"
cat > "$T/bootstrap-payload/etc/init.d/z2k" <<EOF
#!/bin/sh
case "\$1" in
    restart|start|status|running)
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "\${Z2K_LIB:-}" "\${Z2K_ADAPTER_DIR:-}" "\${Z2K_AU_PUBKEY:-}" \
            "\${Z2K_OW_BOOTSTRAP_MANIFEST:-}" "\${Z2K_OW_BOOTSTRAP_SIGNATURE:-}" \
            "\${Z2K_OW_BOOTSTRAP_ARTIFACT:-}" "\${Z2K_OW_BOOTSTRAP_PUBLIC_KEY:-}" \
            "\${Z2KOW_MANIFEST_URL:-}" "\${Z2KOW_TRUST_KEY:-}" \
            "\${TMPDIR:-}" "\${Z2K_OW_INSTALL_TMP:-}" "\${Z2K_OW_SYSROOT:-}" \
            >> "$BOOTSTRAP_SERVICE_ENV"
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
cat > "$T/bootstrap-payload/etc/init.d/z2k-webpanel" <<EOF
#!/bin/sh
case "\$1" in restart|start|running) exit 0 ;; *) exit 0 ;; esac
EOF
chmod 755 "$T/bootstrap-payload/etc/init.d/z2k" "$T/bootstrap-payload/etc/init.d/z2k-webpanel"
dd if=/dev/zero of="$T/bootstrap-payload/usr/lib/z2k/test-large.bin" bs=1M count=4 2>/dev/null || exit 1
tar -czf "$T/dist/openwrt-rootfs-arm64.tar.gz" -C "$T/bootstrap-payload" usr etc opt
BOOTSTRAP_ARCH_URL="http://127.0.0.1:17777/openwrt-rootfs-arm64.tar.gz"
BOOTSTRAP_LEGACY_URL="http://127.0.0.1:17777/openwrt-rootfs.tar.gz"
prepare_arch_manifest "$T/dist/openwrt-rootfs-arm64.tar.gz" "$T/bootstrap-UPDATES.json" \
    arm64 "$BOOTSTRAP_ARCH_URL"
openssl genpkey -algorithm Ed25519 -out "$T/bootstrap.key" >/dev/null 2>&1 || exit 1
openssl pkey -in "$T/bootstrap.key" -pubout -out "$T/bootstrap.pub" >/dev/null 2>&1 || exit 1
_bootstrap_key_id="$(openssl pkey -pubin -in "$T/bootstrap.pub" -outform DER 2>/dev/null | command sha256sum | awk '{print $1}')"
"$Z2K_TEST_PYTHON" -c 'import json,sys; p,k=sys.argv[1:]; d=json.load(open(p,encoding="utf-8")); d["signing"]={"key_id":k}; json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2); open(p,"a",encoding="utf-8").write("\n")' \
    "$T/bootstrap-UPDATES.json" "$_bootstrap_key_id"
openssl pkeyutl -sign -rawin -inkey "$T/bootstrap.key" -in "$T/bootstrap-UPDATES.json" \
    -out "$T/bootstrap-UPDATES.json.sig" >/dev/null 2>&1 || exit 1
Z2K_OW_BOOTSTRAP_PUBLIC_KEY="$T/bootstrap.pub" \
    z2k_ow_manifest_verify_signature "$T/bootstrap-UPDATES.json" "$T/bootstrap-UPDATES.json.sig" \
    && _t_ok || _t_bad "local bootstrap manifest verifies with its explicit test trust key"
if z2k_ow_manifest_release_ok "$T/bootstrap-UPDATES.json"; then
    _t_bad "local artifact URL is rejected without the explicit bootstrap origin"
else
    _t_ok
fi
z2k_ow_manifest_release_ok "$T/bootstrap-UPDATES.json" \
    "$BOOTSTRAP_ARCH_URL" \
    && _t_ok || _t_bad "local architecture URL is accepted only when it matches the explicit bootstrap origin"
z2k_ow_manifest_select_artifact "$T/bootstrap-UPDATES.json" arm64 "$BOOTSTRAP_ARCH_URL" \
    && assert_eq "per-architecture record selected from per-arch-only manifest" \
        "$BOOTSTRAP_ARCH_URL" "$Z2K_OW_ARTIFACT_URL"
prepare_arch_manifest "$T/dist/openwrt-rootfs-arm64.tar.gz" "$T/bootstrap-transition-UPDATES.json" \
    arm64 "$BOOTSTRAP_ARCH_URL" "$BOOTSTRAP_LEGACY_URL"
"$Z2K_TEST_PYTHON" -c 'import json,sys; p,k=sys.argv[1:]; d=json.load(open(p,encoding="utf-8")); d["signing"]={"key_id":k}; json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2); open(p,"a",encoding="utf-8").write("\n")' \
    "$T/bootstrap-transition-UPDATES.json" "$_bootstrap_key_id"
openssl pkeyutl -sign -rawin -inkey "$T/bootstrap.key" -in "$T/bootstrap-transition-UPDATES.json" \
    -out "$T/bootstrap-transition-UPDATES.json.sig" >/dev/null 2>&1 || exit 1
z2k_ow_manifest_select_artifact "$T/bootstrap-transition-UPDATES.json" arm64 "$BOOTSTRAP_ARCH_URL" \
    && assert_eq "transition map chooses per-arch entry even with valid legacy fallback" \
        "$BOOTSTRAP_ARCH_URL" "$Z2K_OW_ARTIFACT_URL"
_BOOTSTRAP_TAG="$(jsonfilter -i "$T/bootstrap-transition-UPDATES.json" -e '@.current')"
_BOOTSTRAP_SEQ="$(jsonfilter -i "$T/bootstrap-transition-UPDATES.json" -e '@.seq')"
export Z2K_OW_SYSROOT="$BOOTSTRAP_SYS" \
    Z2K_OW_INSTALL_TMP="$BOOTSTRAP_TMP" \
    Z2K_ROOT=/usr/lib/z2k \
    Z2K_ADAPTER_DIR="$BOOTSTRAP_ENGINE/platform/openwrt" \
    Z2K_LIB="$BOOTSTRAP_ENGINE/lib" \
    Z2K_AU_PUBKEY="$BOOTSTRAP_TMP/z2k-update-pub.pem" \
    Z2K_OW_BOOTSTRAP_MANIFEST="$T/bootstrap-transition-UPDATES.json" \
    Z2K_OW_BOOTSTRAP_SIGNATURE="$T/bootstrap-transition-UPDATES.json.sig" \
    Z2K_OW_BOOTSTRAP_ARTIFACT="$T/dist/openwrt-rootfs-arm64.tar.gz" \
    Z2K_OW_BOOTSTRAP_PUBLIC_KEY="$T/bootstrap.pub" \
    Z2KOW_MANIFEST_URL="$BOOTSTRAP_URL" \
    Z2KOW_TRUST_KEY="$T/bootstrap.pub" \
    TMPDIR="$BOOTSTRAP_TMP" \
    Z2K_TEST_BOOTSTRAP_SERVICE_ENV="$BOOTSTRAP_SERVICE_ENV" \
    Z2K_OW_TEST_HEALTHCHECK=1
OVERLAY_LOW=0
TMP_LOW=1
STAGE_LOW=0
OPT_SEPARATE=0
df() {
    _probe="$2"
    printf '%s\n' "$_probe" >> "$T/df.calls"
    case "$_probe" in
        "$BOOTSTRAP_TMP"/*)
            if [ "$TMP_LOW" = 1 ]; then
                printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 400000 399999 1 99%% /tmp\n'
            else
                printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 400000 100000 300000 25%% /tmp\n'
            fi
            ;;
        "$BOOTSTRAP_SYS/usr/lib/.z2k-install")
            if [ "$STAGE_LOW" = 1 ]; then
                printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim-root 100000 99999 1 99%% /overlay\n'
            else
                printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim-root 400000 100000 300000 25%% /overlay\n'
            fi
            ;;
        "$BOOTSTRAP_SYS/usr/lib/.z2k-install/stage")
            if [ "$STAGE_LOW" = 1 ]; then
                printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim-root 100000 99999 1 99%% /overlay\n'
            else
                printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim-root 400000 100000 300000 25%% /overlay\n'
            fi
            ;;
        "$BOOTSTRAP_SYS/opt")
            if [ "$OPT_SEPARATE" = 1 ]; then
                printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim-opt 400000 100000 300000 25%% /opt\n'
            elif [ "$OVERLAY_LOW" = 1 ]; then
                printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 100000 99999 1 99%% /overlay\n'
            else
                printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 400000 100000 300000 25%% /overlay\n'
            fi
            ;;
        "$BOOTSTRAP_SYS/usr/lib"|"$BOOTSTRAP_SYS/opt"|"$BOOTSTRAP_SYS")
            if [ "$OVERLAY_LOW" = 1 ]; then
                printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 100000 99999 1 99%% /overlay\n'
            else
                printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 400000 100000 300000 25%% /overlay\n'
            fi
            ;;
        *) command df "$@" ;;
    esac
}
printf 'MemTotal: 131072 kB\nMemAvailable: 4096 kB\n' > "$T/128m-low-meminfo"
_out="$(Z2K_OW_MEMINFO_FILE="$T/128m-low-meminfo" \
    z2k_ow_install_release "$_BOOTSTRAP_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && _state_is_release p-86.12 135 "$BOOTSTRAP_SYS/etc/z2k/state/installed-release" \
    && grep -q 'previous payload' "$BOOTSTRAP_SYS/usr/lib/z2k/version.txt" \
    && [ ! -e "$BOOTSTRAP_SERVICE_STOP" ] \
    && printf '%s\n' "$_out" | grep -q 'недостаточно свободной оперативной памяти'; then
    _t_ok
else
    _t_bad "128 MiB low-MemAvailable preflight did not refuse before mutation or service stop: rc=$_rc output=$_out"
fi
rm -f "$T/128m-low-meminfo"
_out="$(z2k_ow_install_release "$_BOOTSTRAP_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && _state_is_release p-86.12 135 "$BOOTSTRAP_SYS/etc/z2k/state/installed-release" \
    && grep -q 'previous payload' "$BOOTSTRAP_SYS/usr/lib/z2k/version.txt" \
    && [ ! -e "$BOOTSTRAP_SERVICE_STOP" ] \
    && printf '%s\n' "$_out" | grep -q 'недостаточно места'; then
    _t_ok
else
    _t_bad "проверка tmpfs не остановила замену до изменения файлов и служб: rc=$_rc output=$_out df=$(tr '\n' ';' < "$T/df.calls")"
fi
TMP_LOW=0
OVERLAY_LOW=1
_out="$(z2k_ow_install_release "$_BOOTSTRAP_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && _state_is_release p-86.12 135 "$BOOTSTRAP_SYS/etc/z2k/state/installed-release" \
    && grep -q 'previous payload' "$BOOTSTRAP_SYS/usr/lib/z2k/version.txt" \
    && [ ! -e "$BOOTSTRAP_SERVICE_STOP" ] \
    && printf '%s\n' "$_out" | grep -q 'недостаточно места в /overlay'; then
    _t_ok
else
    _t_bad "проверка overlay не остановила замену до изменения файлов и служб: rc=$_rc output=$_out df=$(tr '\n' ';' < "$T/df.calls")"
fi
STAGE_LOW=1
OPT_SEPARATE=1
_out="$(z2k_ow_install_release "$_BOOTSTRAP_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && _state_is_release p-86.12 135 "$BOOTSTRAP_SYS/etc/z2k/state/installed-release" \
    && grep -q 'previous payload' "$BOOTSTRAP_SYS/usr/lib/z2k/version.txt" \
    && [ ! -e "$BOOTSTRAP_SERVICE_STOP" ] \
    && printf '%s\n' "$_out" | grep -q 'недостаточно места на разделе временной распаковки'; then
    _t_ok
else
    _t_bad "low staging filesystem was not rejected before extraction/service stop when /opt is separate: rc=$_rc output=$_out"
fi
STAGE_LOW=0
OPT_SEPARATE=0
rm -rf "$BOOTSTRAP_SYS"
mkdir -p "$BOOTSTRAP_SYS/usr/lib/z2k" "$BOOTSTRAP_SYS/usr/bin" "$BOOTSTRAP_SYS/usr/sbin" \
    "$BOOTSTRAP_SYS/etc/z2k/state" "$BOOTSTRAP_SYS/etc/init.d"
: > "$BOOTSTRAP_SYS/etc/z2k/state/installed-release"
OVERLAY_LOW=0
_out="$(z2k_ow_install_release "$_BOOTSTRAP_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] \
    && _state_is_release "$_BOOTSTRAP_TAG" "$_BOOTSTRAP_SEQ" "$BOOTSTRAP_SYS/etc/z2k/state/installed-release" \
    && grep -q "release tag $_BOOTSTRAP_TAG" "$BOOTSTRAP_SYS/usr/lib/z2k/version.txt"; then
    _t_ok
else
    _t_bad "signed local bootstrap did not converge through install_release: rc=$_rc output=$_out"
fi
printf 'damaged selected release\n' > "$BOOTSTRAP_SYS/usr/lib/z2k/version.txt"
_out="$(z2k_ow_install_release --reinstall "$_BOOTSTRAP_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] \
    && printf '%s\n' "$_out" | grep -q "^Установлен выпуск $_BOOTSTRAP_TAG$" \
    && grep -q "release tag $_BOOTSTRAP_TAG" "$BOOTSTRAP_SYS/usr/lib/z2k/version.txt"; then
    _t_ok
else
    _t_bad "per-architecture reinstall did not converge through install_release: rc=$_rc output=$_out"
fi
for _root in \
    "$BOOTSTRAP_SYS/usr/lib/z2k/bin" \
    "$BOOTSTRAP_SYS/usr/lib/z2k/platform/openwrt/bin" \
    "$BOOTSTRAP_SYS/opt/zapret2/binaries"; do
    if find "$_root" -mindepth 1 -maxdepth 1 -type d ! -name linux-arm64 | grep -q .; then
        _t_bad "per-architecture install left foreign binaries under $_root"
    else
        _t_ok
    fi
done
grep -Fq "$BOOTSTRAP_SYS/usr/lib/.z2k-install/stage/" "$T/df.calls" && _t_ok \
    || _t_bad "проверка свободного места для распаковки не проверила overlay staging: $(tr '\n' ';' < "$T/df.calls")"
if [ -s "$BOOTSTRAP_SERVICE_ENV" ] \
    && awk -F'|' 'NF != 12 { bad=1 } { for (i=1; i<=NF; i++) if ($i != "") bad=1 } END { if (NR == 0 || bad) exit 1 }' "$BOOTSTRAP_SERVICE_ENV"; then
    _t_ok
else
    _t_bad "restarted services inherited bootstrap paths, sysroot or trust overrides: $(cat "$BOOTSTRAP_SERVICE_ENV" 2>/dev/null)"
fi
unset -f df
unset Z2K_OW_INSTALL_TMP Z2K_OW_BOOTSTRAP_MANIFEST Z2K_OW_BOOTSTRAP_SIGNATURE \
    Z2K_OW_BOOTSTRAP_ARTIFACT Z2K_OW_BOOTSTRAP_PUBLIC_KEY Z2KOW_MANIFEST_URL \
    Z2KOW_TRUST_KEY Z2K_TEST_BOOTSTRAP_SERVICE_ENV Z2K_OW_TEST_HEALTHCHECK \
    Z2K_ADAPTER_DIR Z2K_LIB Z2K_AU_PUBKEY
export Z2K_ADAPTER_DIR="$REPO/platform/openwrt" Z2K_ROOT="$SYS/usr/lib/z2k"
export Z2K_OW_SYSROOT="$SYS"

# После вызова фиксации установщик проверяет запись состояния. Так обнаружится
# помощник, который завершился успешно, но не сохранил tag + seq.
READBACK_SYS="$T/readback-sys"
mkdir -p "$READBACK_SYS/usr/lib" "$READBACK_SYS/usr/bin" "$READBACK_SYS/usr/sbin" \
    "$READBACK_SYS/etc/z2k/state"
export Z2K_OW_SYSROOT="$READBACK_SYS"
_out="$( (
    z2k_ow_release_state_write() { return 0; }
    z2k_ow_install_release "$_CURRENT_TAG"
) 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && [ ! -e "$READBACK_SYS/etc/z2k/state/installed-release" ] \
    && [ ! -e "$READBACK_SYS/usr/lib/z2k/version.txt" ]; then
    _t_ok
else
    _t_bad "installer accepted a successful state writer that persisted no canonical release record: rc=$_rc output=$_out"
fi
export Z2K_OW_SYSROOT="$SYS"

# Подменённый хэш архива должен привести к отказу до очистки старой установки
# или изменения файлов.
rm -rf "$SYS"
mkdir -p "$SYS/etc/z2k/state" "$SYS/usr/lib/z2k"
printf 'p-86.2\n' > "$SYS/etc/z2k/state/installed-release"
printf 'old tree\n' > "$SYS/usr/lib/z2k/version.txt"
cp "$T/UPDATES.json" "$T/bad-UPDATES.json"
"$Z2K_TEST_PYTHON" -c 'import json,sys; p,o=sys.argv[1:]; d=json.load(open(p,encoding="utf-8")); d["artifact"]["sha256"]="0"*64; json.dump(d,open(o,"w",encoding="utf-8"),ensure_ascii=False,indent=2)' \
    "$T/UPDATES.json" "$T/bad-UPDATES.json"
export Z2K_OW_MANIFEST_PATH="$T/bad-UPDATES.json"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] && grep -qx 'p-86.2' "$SYS/etc/z2k/state/installed-release" \
    && grep -q 'old tree' "$SYS/usr/lib/z2k/version.txt"; then
_t_ok
else
    _t_bad "hash failure was not fail-closed: rc=$_rc output=$_out"
fi

# Неполный релиз отклоняется на предварительной проверке до миграции старых
# APK-пакетов и любых изменений постоянных файлов.
rm -rf "$SYS"
mkdir -p "$SYS/etc/z2k/state" "$SYS/etc/z2k" "$SYS/usr/lib/z2k/share" \
    "$SYS/usr/bin" "$SYS/usr/sbin" "$SYS/etc/init.d" \
    "$SYS/etc/hotplug.d/iface" "$SYS/etc/sysctl.d" \
    "$SYS/usr/share/nftables.d/chain-pre/forward" \
    "$SYS/etc/apk/repositories.d" "$SYS/etc/apk/keys"
printf 'p-86.2\n' > "$SYS/etc/z2k/state/installed-release"
printf 'preserve config\n' > "$SYS/etc/z2k/config"
printf 'old core tree\n' > "$SYS/usr/lib/z2k/legacy.txt"
printf 'old core init\n' > "$SYS/etc/init.d/z2k"
printf 'old panel init\n' > "$SYS/etc/init.d/z2k-webpanel"
printf 'https://github.com/t0fox/z2kOW/releases/latest/download/packages.adb\n' > "$SYS/etc/apk/repositories.d/z2kow.list"
printf 'https://feed.z2k.example.com/openwrt\n' > "$SYS/etc/apk/repositories.d/z2k.list"
printf 'z2kow feed key\n' > "$SYS/usr/lib/z2k/share/z2k-feed.pem"
printf 'z2kow feed key\n' > "$SYS/etc/apk/keys/z2k-feed.pem"
printf '%s\n' z2k-adapter z2k-webpanel > "$T/legacy-packages"
make_artifact "$T/incomplete"
rm -f "$T/incomplete/etc/hotplug.d/iface/90-z2k"
tar -czf "$T/dist/incomplete-rootfs.tar.gz" -C "$T/incomplete" usr etc opt
prepare_manifest "$T/dist/incomplete-rootfs.tar.gz" "$T/incomplete-UPDATES.json"
export Z2K_OW_MANIFEST_PATH="$T/incomplete-UPDATES.json"
export Z2K_OW_ARTIFACT_PATH="$T/dist/incomplete-rootfs.tar.gz"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] && grep -qx 'p-86.2' "$SYS/etc/z2k/state/installed-release" \
    && grep -q 'old core tree' "$SYS/usr/lib/z2k/legacy.txt" \
    && grep -q 'old core init' "$SYS/etc/init.d/z2k" \
    && grep -q 'preserve config' "$SYS/etc/z2k/config" \
    && [ -s "$T/legacy-packages" ] \
    && [ -e "$SYS/etc/apk/repositories.d/z2kow.list" ] \
    && printf '%s\n' "$_out" | grep -q 'архив релиза не содержит принадлежащий ему путь'; then
    _t_ok
else
    _t_bad "incomplete release was not rejected before legacy migration: rc=$_rc output=$_out"
fi

# После отказа предварительной проверки полноценная повторная попытка завершается.
make_artifact "$T/retry"
tar -czf "$T/dist/retry-rootfs.tar.gz" -C "$T/retry" usr etc opt
prepare_manifest "$T/dist/retry-rootfs.tar.gz" "$T/retry-UPDATES.json"
export Z2K_OW_MANIFEST_PATH="$T/retry-UPDATES.json"
export Z2K_OW_ARTIFACT_PATH="$T/dist/retry-rootfs.tar.gz"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] && _state_is_release "$_CURRENT_TAG" "$_CURRENT_SEQ" "$SYS/etc/z2k/state/installed-release" \
    && grep -q "release tag $_CURRENT_TAG" "$SYS/usr/lib/z2k/version.txt"; then
    _t_ok
else
    _t_bad "retry after partial legacy retirement failed: rc=$_rc output=$_out"
fi

# Если проверка состояния после замены не пройдена, файлы и прежняя запись
# релиза восстанавливаются вместе. Новая версия фиксируется только после успеха.
HEALTH_SYS="$T/health-sys"
HEALTH_STAGE="$T/health-stage"
HEALTH_FAIL="$T/healthcheck-fails"
HEALTH_SERVICE_FAIL="$T/service-start-fails"
mkdir -p "$HEALTH_SYS/etc/z2k/state" "$HEALTH_SYS/usr/lib/z2k" \
    "$HEALTH_SYS/etc/init.d" "$HEALTH_SYS/usr/lib/.z2k-install"
printf 'tag=p-86.2\nseq=127\n' > "$HEALTH_SYS/etc/z2k/state/installed-release"
printf 'previous payload\n' > "$HEALTH_SYS/usr/lib/z2k/version.txt"
make_artifact "$HEALTH_STAGE"
cat > "$HEALTH_STAGE/etc/init.d/z2k" <<EOF
#!/bin/sh
case "\$1" in
    enable) exit 0 ;;
    restart|start)
        if grep -q '^ENABLED=0$' "$HEALTH_SYS/etc/z2k/config" 2>/dev/null; then
            echo "\$1" >> "$HEALTH_SYS/disabled-service-actions"
            exit 23
        fi
        if [ -e "$HEALTH_SERVICE_FAIL" ]; then
            echo "mock-z2k-\$1-diagnostic" >&2
            exit 23
        fi
        ;;
    status|running)
        if grep -q '^ENABLED=0$' "$HEALTH_SYS/etc/z2k/config" 2>/dev/null; then
            echo "\$1" >> "$HEALTH_SYS/disabled-service-actions"
            exit 1
        fi
        if grep -q 'release tag ' "$HEALTH_SYS/usr/lib/z2k/version.txt" 2>/dev/null; then
            [ ! -e "$HEALTH_FAIL" ]
        else
            exit 0
        fi
        ;;
    *) exit 0 ;;
esac
EOF
cat > "$HEALTH_STAGE/etc/init.d/z2k-webpanel" <<EOF
#!/bin/sh
case "\$1" in
    restart|start) exit 0 ;;
    running)
        if grep -q 'release tag ' "$HEALTH_SYS/usr/lib/z2k/version.txt" 2>/dev/null; then
            [ ! -e "$HEALTH_FAIL" ]
        else
            exit 0
        fi
        ;;
    *) exit 0 ;;
esac
EOF
chmod 755 "$HEALTH_STAGE/etc/init.d/z2k" "$HEALTH_STAGE/etc/init.d/z2k-webpanel"
mkdir -p "$T/dist"
tar -czf "$T/dist/health-rootfs.tar.gz" -C "$HEALTH_STAGE" usr etc opt
prepare_manifest "$T/dist/health-rootfs.tar.gz" "$T/health-UPDATES.json"
export Z2K_OW_SYSROOT="$HEALTH_SYS" Z2K_OW_MANIFEST_PATH="$T/health-UPDATES.json"
export Z2K_OW_ARTIFACT_PATH="$T/dist/health-rootfs.tar.gz" Z2K_OW_TEST_HEALTHCHECK=1
touch "$HEALTH_SERVICE_FAIL"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && _state_is_release p-86.2 127 "$HEALTH_SYS/etc/z2k/state/installed-release" \
    && grep -q 'previous payload' "$HEALTH_SYS/usr/lib/z2k/version.txt" \
    && printf '%s\n' "$_out" | grep -q 'mock-z2k-restart-diagnostic' \
    && printf '%s\n' "$_out" | grep -q 'mock-z2k-start-diagnostic'; then
    _t_ok
else
    _t_bad "service start failure lost diagnostics or rollback: rc=$_rc state=$(cat "$HEALTH_SYS/etc/z2k/state/installed-release" 2>/dev/null) output=$_out"
fi
rm -f "$HEALTH_SERVICE_FAIL"
touch "$HEALTH_FAIL"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && _state_is_release p-86.2 127 "$HEALTH_SYS/etc/z2k/state/installed-release" \
    && grep -q 'previous payload' "$HEALTH_SYS/usr/lib/z2k/version.txt" \
    && printf '%s\n' "$_out" | grep -q 'Z2KOW_ROLLBACK=complete'; then
    _t_ok
else
    _t_bad "failed health check committed release state or left target files: rc=$_rc state=$(cat "$HEALTH_SYS/etc/z2k/state/installed-release" 2>/dev/null) output=$_out"
fi
_out="$( (
    z2k_ow_restore_paths() { return 1; }
    z2k_ow_install_release "$_CURRENT_TAG"
) 2>&1)"; _rc=$?
_transaction_id="$(cat "$HEALTH_SYS/usr/lib/.z2k-install/transaction-id" 2>/dev/null)"
if [ "$_rc" -ne 0 ] \
    && _state_is_release p-86.2 127 "$HEALTH_SYS/etc/z2k/state/installed-release" \
    && [ -f "$HEALTH_SYS/usr/lib/.z2k-install/transaction-active" ] \
    && [ -s "$HEALTH_SYS/usr/lib/.z2k-install/transaction.log" ] \
    && [ -n "$_transaction_id" ] \
    && [ -e "$HEALTH_SYS/usr/lib/z2k.z2k-backup.$_transaction_id" ] \
    && printf '%s\n' "$_out" | grep -q 'откат не завершён; данные для восстановления сохранены' \
    && ! printf '%s\n' "$_out" | grep -q 'Z2KOW_ROLLBACK=complete'; then
    _t_ok
else
    _t_bad "failed file rollback deleted recovery metadata or claimed success: rc=$_rc output=$_out"
fi
rm -f "$HEALTH_FAIL"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] \
    && _state_is_release "$_CURRENT_TAG" "$_CURRENT_SEQ" "$HEALTH_SYS/etc/z2k/state/installed-release" \
    && grep -q "release tag $_CURRENT_TAG" "$HEALTH_SYS/usr/lib/z2k/version.txt"; then
    _t_ok
else
    _t_bad "healthy install did not commit target state: rc=$_rc state=$(cat "$HEALTH_SYS/etc/z2k/state/installed-release" 2>/dev/null) output=$_out"
fi

# С ENABLED=0 установка обновляет файлы, но не включает и не запускает dataplane.
printf 'ENABLED=0\n' > "$HEALTH_SYS/etc/z2k/config"
rm -f "$HEALTH_SYS/disabled-service-actions"
_out="$(z2k_ow_install_release --reinstall "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] \
    && _state_is_release "$_CURRENT_TAG" "$_CURRENT_SEQ" "$HEALTH_SYS/etc/z2k/state/installed-release" \
    && [ ! -e "$HEALTH_SYS/disabled-service-actions" ]; then
    _t_ok
else
    _t_bad "установка не сохранила отключённое состояние dataplane: rc=$_rc actions=$(cat "$HEALTH_SYS/disabled-service-actions" 2>/dev/null) output=$_out"
fi

# Прерванная запись нового seq того же тега не должна считаться завершённой.
RECOVERY_SYS="$T/recovery-sys"
RECOVERY_WORK="$RECOVERY_SYS/usr/lib/.z2k-install"
RECOVERY_TMP="$T/recovery-tmp/z2kow-release"
mkdir -p "$RECOVERY_SYS/etc/z2k/state" "$RECOVERY_SYS/usr/lib/z2k" "$RECOVERY_WORK"
printf 'tag=p-86.2\nseq=127\n' > "$RECOVERY_SYS/etc/z2k/state/installed-release"
cp "$RECOVERY_SYS/etc/z2k/state/installed-release" "$RECOVERY_WORK/installed-release.old"
: > "$RECOVERY_WORK/state-was-present"
: > "$RECOVERY_WORK/state-write-started"
: > "$RECOVERY_WORK/transaction-active"
printf '4101\n' > "$RECOVERY_WORK/transaction-id"
printf '%s\n' /usr/lib/z2k > "$RECOVERY_WORK/owned-paths"
printf 'V|2\nB|/usr/lib/z2k\nO|/usr/lib/z2k\nI|/usr/lib/z2k\n' > "$RECOVERY_WORK/transaction.log"
printf 'tag=p-86.2\nseq=128\n' > "$RECOVERY_WORK/transaction-target"
mkdir -p "$RECOVERY_SYS/usr/lib/z2k.z2k-backup.4101"
printf 'предыдущий payload\n' > "$RECOVERY_SYS/usr/lib/z2k.z2k-backup.4101/version.txt"
printf 'новый payload\n' > "$RECOVERY_SYS/usr/lib/z2k/version.txt"
Z2K_OW_SYSROOT="$RECOVERY_SYS" _tmp_work="$RECOVERY_TMP" \
    z2k_ow_recover_transaction "$RECOVERY_WORK" \
        "$RECOVERY_SYS/etc/z2k/state/installed-release" "" p-86.2 128 ""; _rc=$?
if [ "$_rc" -eq 0 ] \
    && _state_is_release p-86.2 127 "$RECOVERY_SYS/etc/z2k/state/installed-release" \
    && grep -q 'предыдущий payload' "$RECOVERY_SYS/usr/lib/z2k/version.txt" \
    && [ ! -e "$RECOVERY_WORK" ]; then
    _t_ok
else
    _t_bad "восстановление ошибочно приняло старый seq за завершённый релиз: rc=$_rc state=$(cat "$RECOVERY_SYS/etc/z2k/state/installed-release" 2>/dev/null) payload=$(cat "$RECOVERY_SYS/usr/lib/z2k/version.txt" 2>/dev/null)"
fi

# После отката той же версии совпадение tag + seq не доказывает, что переустановка завершилась.
SAME_RECOVERY_SYS="$T/same-recovery-sys"
SAME_RECOVERY_WORK="$SAME_RECOVERY_SYS/usr/lib/.z2k-install"
SAME_RECOVERY_MARKER="$SAME_RECOVERY_SYS/recovery-restarted"
mkdir -p "$SAME_RECOVERY_SYS/etc/z2k/state" "$SAME_RECOVERY_SYS/usr/lib/z2k" \
    "$SAME_RECOVERY_SYS/etc/init.d" "$SAME_RECOVERY_WORK"
printf 'tag=p-86.2\nseq=128\n' > "$SAME_RECOVERY_SYS/etc/z2k/state/installed-release"
cp "$SAME_RECOVERY_SYS/etc/z2k/state/installed-release" "$SAME_RECOVERY_WORK/installed-release.old"
: > "$SAME_RECOVERY_WORK/state-was-present"
: > "$SAME_RECOVERY_WORK/state-write-started"
: > "$SAME_RECOVERY_WORK/transaction-active"
printf '4104\n' > "$SAME_RECOVERY_WORK/transaction-id"
printf '%s\n' /usr/lib/z2k > "$SAME_RECOVERY_WORK/owned-paths"
printf 'V|2\nB|/usr/lib/z2k\nO|/usr/lib/z2k\nI|/usr/lib/z2k\nR|/usr/lib/z2k\n' \
    > "$SAME_RECOVERY_WORK/transaction.log"
printf 'tag=p-86.2\nseq=128\n' > "$SAME_RECOVERY_WORK/transaction-target"
printf 'старые файлы после отката\n' > "$SAME_RECOVERY_SYS/usr/lib/z2k/version.txt"
cat > "$SAME_RECOVERY_SYS/etc/init.d/z2k" <<EOF
#!/bin/sh
case "\$1" in
    restart|start) : > "$SAME_RECOVERY_MARKER" ;;
    status|stop|enable) exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod 755 "$SAME_RECOVERY_SYS/etc/init.d/z2k"
Z2K_OW_SYSROOT="$SAME_RECOVERY_SYS" _tmp_work="$RECOVERY_TMP" \
    z2k_ow_recover_transaction "$SAME_RECOVERY_WORK" \
        "$SAME_RECOVERY_SYS/etc/z2k/state/installed-release" \
        "$SAME_RECOVERY_SYS/etc/init.d/z2k" p-86.3 129 ""; _rc=$?
if [ "$_rc" -eq 0 ] \
    && [ -e "$SAME_RECOVERY_MARKER" ] \
    && grep -q 'старые файлы после отката' "$SAME_RECOVERY_SYS/usr/lib/z2k/version.txt" \
    && [ ! -e "$SAME_RECOVERY_WORK" ]; then
    _t_ok
else
    _t_bad "откат той же версии был принят за commit: rc=$_rc restarted=$([ -e "$SAME_RECOVERY_MARKER" ] && echo yes || echo no) output=$(cat "$SAME_RECOVERY_SYS/usr/lib/z2k/version.txt" 2>/dev/null)"
fi

# Частичная очистка после commit должна завершаться по сохранённой цели транзакции,
# даже если манифест уже указывает на следующий релиз.
mkdir -p "$RECOVERY_SYS/etc/z2k/state" "$RECOVERY_SYS/usr/lib/z2k" "$RECOVERY_SYS/opt/zapret2" "$RECOVERY_WORK"
printf 'tag=p-86.2\nseq=128\n' > "$RECOVERY_SYS/etc/z2k/state/installed-release"
printf 'tag=p-86.1\nseq=126\n' > "$RECOVERY_WORK/installed-release.old"
: > "$RECOVERY_WORK/state-was-present"
: > "$RECOVERY_WORK/state-write-started"
: > "$RECOVERY_WORK/transaction-active"
printf '4102\n' > "$RECOVERY_WORK/transaction-id"
printf '%s\n' /usr/lib/z2k /opt/zapret2 > "$RECOVERY_WORK/owned-paths"
printf 'V|2\nB|/usr/lib/z2k\nO|/usr/lib/z2k\nI|/usr/lib/z2k\nB|/opt/zapret2\nO|/opt/zapret2\nI|/opt/zapret2\n' \
    > "$RECOVERY_WORK/transaction.log"
printf 'tag=p-86.2\nseq=128\n' > "$RECOVERY_WORK/transaction-target"
mkdir -p "$RECOVERY_SYS/opt/zapret2.z2k-backup.4102"
printf 'новый z2k payload\n' > "$RECOVERY_SYS/usr/lib/z2k/version.txt"
printf 'новый zapret payload\n' > "$RECOVERY_SYS/opt/zapret2/version.txt"
printf 'старый zapret payload\n' > "$RECOVERY_SYS/opt/zapret2.z2k-backup.4102/version.txt"
Z2K_OW_SYSROOT="$RECOVERY_SYS" _tmp_work="$RECOVERY_TMP" \
    z2k_ow_recover_transaction "$RECOVERY_WORK" \
        "$RECOVERY_SYS/etc/z2k/state/installed-release" "" p-86.3 129 ""; _rc=$?
if [ "$_rc" -eq 0 ] \
    && _state_is_release p-86.2 128 "$RECOVERY_SYS/etc/z2k/state/installed-release" \
    && grep -q 'новый z2k payload' "$RECOVERY_SYS/usr/lib/z2k/version.txt" \
    && grep -q 'новый zapret payload' "$RECOVERY_SYS/opt/zapret2/version.txt" \
    && [ ! -e "$RECOVERY_SYS/opt/zapret2.z2k-backup.4102" ] \
    && [ ! -e "$RECOVERY_WORK" ]; then
    _t_ok
else
    _t_bad "частичная очистка откатила уже зафиксированный релиз: rc=$_rc state=$(cat "$RECOVERY_SYS/etc/z2k/state/installed-release" 2>/dev/null) z2k=$(cat "$RECOVERY_SYS/usr/lib/z2k/version.txt" 2>/dev/null) zapret=$(cat "$RECOVERY_SYS/opt/zapret2/version.txt" 2>/dev/null)"
fi

# Старый журнал без цели не должен частично откатывать дерево при пропавшей копии.
LEGACY_RECOVERY_SYS="$T/legacy-recovery-sys"
LEGACY_RECOVERY_WORK="$LEGACY_RECOVERY_SYS/usr/lib/.z2k-install"
mkdir -p "$LEGACY_RECOVERY_SYS/etc/z2k/state" "$LEGACY_RECOVERY_SYS/usr/lib/z2k" \
    "$LEGACY_RECOVERY_SYS/opt/zapret2" "$LEGACY_RECOVERY_SYS/opt/zapret2.z2k-backup.4103" \
    "$LEGACY_RECOVERY_WORK"
printf 'tag=p-86.2\nseq=127\n' > "$LEGACY_RECOVERY_SYS/etc/z2k/state/installed-release"
printf 'tag=p-86.1\nseq=126\n' > "$LEGACY_RECOVERY_WORK/installed-release.old"
: > "$LEGACY_RECOVERY_WORK/state-was-present"
: > "$LEGACY_RECOVERY_WORK/state-write-started"
: > "$LEGACY_RECOVERY_WORK/transaction-active"
printf '4103\n' > "$LEGACY_RECOVERY_WORK/transaction-id"
printf '%s\n' /usr/lib/z2k /opt/zapret2 > "$LEGACY_RECOVERY_WORK/owned-paths"
printf 'V|2\nB|/usr/lib/z2k\nO|/usr/lib/z2k\nI|/usr/lib/z2k\nB|/opt/zapret2\nO|/opt/zapret2\nI|/opt/zapret2\n' \
    > "$LEGACY_RECOVERY_WORK/transaction.log"
printf 'новый z2k payload\n' > "$LEGACY_RECOVERY_SYS/usr/lib/z2k/version.txt"
printf 'новый zapret payload\n' > "$LEGACY_RECOVERY_SYS/opt/zapret2/version.txt"
printf 'старый zapret payload\n' > "$LEGACY_RECOVERY_SYS/opt/zapret2.z2k-backup.4103/version.txt"
Z2K_OW_SYSROOT="$LEGACY_RECOVERY_SYS" _tmp_work="$RECOVERY_TMP" \
    z2k_ow_recover_transaction "$LEGACY_RECOVERY_WORK" \
        "$LEGACY_RECOVERY_SYS/etc/z2k/state/installed-release" "" p-86.3 129 ""; _rc=$?
if [ "$_rc" -ne 0 ] \
    && grep -q 'новый z2k payload' "$LEGACY_RECOVERY_SYS/usr/lib/z2k/version.txt" \
    && grep -q 'новый zapret payload' "$LEGACY_RECOVERY_SYS/opt/zapret2/version.txt" \
    && [ -e "$LEGACY_RECOVERY_SYS/opt/zapret2.z2k-backup.4103" ] \
    && [ -e "$LEGACY_RECOVERY_WORK/transaction-active" ]; then
    _t_ok
else
    _t_bad "откат изменил часть дерева при отсутствующей резервной копии: rc=$_rc z2k=$(cat "$LEGACY_RECOVERY_SYS/usr/lib/z2k/version.txt" 2>/dev/null) zapret=$(cat "$LEGACY_RECOVERY_SYS/opt/zapret2/version.txt" 2>/dev/null)"
fi
# После очистки временной распаковки не оставлять пустой стандартный каталог.
CANONICAL_SYSROOT="$T/canonical-sysroot"
CANONICAL_TMP="$CANONICAL_SYSROOT/tmp/z2kow-install-stage"
CANONICAL_TMP_WORK="$CANONICAL_TMP/z2kow-release"
CANONICAL_CLEANUP_WORK="$CANONICAL_SYSROOT/usr/lib/.z2k-install"
mkdir -p "$CANONICAL_TMP_WORK" "$CANONICAL_CLEANUP_WORK"
printf '%s\n' z2kow-release-stage-v1 > "$CANONICAL_TMP_WORK/.z2kow-owner"
if Z2K_OW_SYSROOT="$CANONICAL_SYSROOT" \
    z2k_ow_cleanup_install_workspace "$CANONICAL_CLEANUP_WORK" "$CANONICAL_TMP_WORK" \
    && [ ! -e "$CANONICAL_TMP" ]; then
    _t_ok
else
    _t_bad "очистка оставила пустой стандартный каталог временных файлов: $CANONICAL_TMP"
fi
unset Z2K_OW_SYSROOT Z2K_OW_MANIFEST_PATH Z2K_OW_ARTIFACT_PATH Z2K_OW_TEST_HEALTHCHECK

_t_done
