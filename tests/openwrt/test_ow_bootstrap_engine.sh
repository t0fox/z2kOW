#!/bin/sh
# Начальный установщик извлекает все исходники, нужные настоящему движку релизов.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-bootstrap-engine"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-bootstrap-engine.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
BIN="$T/bin"; BOOT_TMP="$T/bootstrap-tmp"; STAGE_TMP="$T/staging"
PAYLOAD="$T/payload"; SYS="$T/sys"
mkdir -p "$BIN" "$BOOT_TMP" "$PAYLOAD" "$SYS/usr/lib" "$STAGE_TMP"

# Начальный установщик и извлечённый движок используют awk роутера.
_busybox="${Z2K_TEST_BUSYBOX:-$(command -v busybox 2>/dev/null || true)}"
if [ -n "$_busybox" ]; then
    for _applet in awk tar xargs tr; do
        ln -s "$_busybox" "$BIN/$_applet" || exit 1
    done
fi

command -v openssl >/dev/null 2>&1 || { _t_bad "openssl unavailable"; _t_done; exit $?; }
openssl genpkey -algorithm ED25519 -out "$T/test.key" >/dev/null 2>&1 || exit 1
openssl pkey -in "$T/test.key" -pubout -out "$T/test.pub" >/dev/null 2>&1 || exit 1
TEST_KEY_ID="$(openssl pkey -pubin -in "$T/test.pub" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"

# Собрать небольшой rootfs с рабочим движком установки и обязательными файлами.
# arch.sh находится в подписанном архиве; проверяется, что install.sh извлекает
# его вместе с остальными файлами движка.
mkdir -p "$PAYLOAD/usr/lib/z2k/platform/openwrt" "$PAYLOAD/usr/lib/z2k/lib" \
    "$PAYLOAD/usr/lib/z2k/bin/linux-x86_64" \
    "$PAYLOAD/usr/lib/z2k/platform/openwrt/bin/linux-x86_64" \
    "$PAYLOAD/usr/sbin" "$PAYLOAD/usr/bin" "$PAYLOAD/opt/zapret2/binaries/linux-x86_64" \
    "$PAYLOAD/opt/zapret2/binaries/linux-x86_64" \
    "$PAYLOAD/opt/zapret2/binaries/linux-x86_64" \
    "$PAYLOAD/etc/init.d" "$PAYLOAD/etc/hotplug.d/iface" "$PAYLOAD/etc/sysctl.d" \
    "$PAYLOAD/usr/share/nftables.d/chain-pre/forward"
for name in paths.sh env.sh manifest.sh release_state.sh release.sh recover_boot.sh bootstrap.sh arch.sh; do
    cp "$REPO/platform/openwrt/$name" "$PAYLOAD/usr/lib/z2k/platform/openwrt/$name" || exit 1
done
cp "$REPO/platform/openwrt/owned-paths.txt" "$PAYLOAD/usr/lib/z2k/platform/openwrt/owned-paths.txt" || exit 1
cp "$REPO/lib/utils.sh" "$REPO/lib/auto_update.sh" "$PAYLOAD/usr/lib/z2k/lib/" || exit 1
cp "$REPO/scripts/openwrt/install_release.sh" "$PAYLOAD/usr/sbin/install_release" || exit 1
chmod 755 "$PAYLOAD/usr/sbin/install_release"
printf '#!/bin/sh\nexit 0\n' > "$PAYLOAD/usr/bin/z2kow"
chmod 755 "$PAYLOAD/usr/bin/z2kow"
mkdir -p "$PAYLOAD/usr/lib/z2k/lists" "$PAYLOAD/usr/lib/z2k/share"
printf 'example.test\n' > "$PAYLOAD/usr/lib/z2k/lists/rkn.txt"
printf 'ENABLED=0\n' > "$PAYLOAD/usr/lib/z2k/share/config.default"
for _pool in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
    mkdir -p "$PAYLOAD/usr/lib/z2k/extra_strats/$_pool"
    printf 'тестовая стратегия\n' > "$PAYLOAD/usr/lib/z2k/extra_strats/$_pool/Strategy.txt"
done
for name in tg-mtproxy-client z2k-rt-proxy z2k-detect; do
    printf '#!/bin/sh\nexit 0\n' > "$PAYLOAD/usr/lib/z2k/bin/linux-x86_64/$name"
    chmod 755 "$PAYLOAD/usr/lib/z2k/bin/linux-x86_64/$name"
done
printf '#!/bin/sh\nexit 0\n' > "$PAYLOAD/usr/lib/z2k/platform/openwrt/bin/linux-x86_64/z2k-warpd"
chmod 755 "$PAYLOAD/usr/lib/z2k/platform/openwrt/bin/linux-x86_64/z2k-warpd"
for pair in nfq2/nfqws2 ip2net/ip2net mdig/mdig; do
    name="${pair#*/}"
    printf '#!/bin/sh\nexit 0\n' > "$PAYLOAD/opt/zapret2/binaries/linux-x86_64/$name"
    chmod 755 "$PAYLOAD/opt/zapret2/binaries/linux-x86_64/$name"
done
for name in z2k z2k-webpanel; do
    printf '#!/bin/sh\nexit 0\n' > "$PAYLOAD/etc/init.d/$name"
    chmod 755 "$PAYLOAD/etc/init.d/$name"
done
printf '#!/bin/sh\nexit 0\n' > "$PAYLOAD/etc/hotplug.d/iface/90-z2k"
printf 'net.ipv4.ip_forward=1\n' > "$PAYLOAD/etc/sysctl.d/99-z2k.conf"
printf 'table inet z2k {}\n' > "$PAYLOAD/usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft"
tar -czf "$T/openwrt-rootfs.tar.gz" -C "$PAYLOAD" usr etc opt || exit 1
ARTIFACT_ARCH="$T/openwrt-rootfs-x86_64.tar.gz"
cp "$T/openwrt-rootfs.tar.gz" "$ARTIFACT_ARCH"

ARTIFACT_SHA="$(sha256sum "$ARTIFACT_ARCH" | awk '{print $1}')"
ARTIFACT_SIZE="$(wc -c < "$ARTIFACT_ARCH" | tr -d ' \t\r\n')"
UNPACKED_SIZE="$(tar -tvzf "$ARTIFACT_ARCH" | awk '$1 ~ /^-/ && $3 ~ /^[0-9]+$/ { total += $3 } END { printf "%.0f\n", total }')"
cat > "$T/UPDATES.json" <<EOF
{"schema":1,"branch":"main","platform":"openwrt","seq":136,"current":"p-86.13","upstream":{"repository":"necronicle/z2k","branch":"z2k-enhanced","tag":"p-86.13","commit":"7f630a9d459052b9c9c9eded06298f1b8f7f0a22"},"signing":{"key_id":"$TEST_KEY_ID"},"artifacts":{"x86_64":{"filename":"openwrt-rootfs-x86_64.tar.gz","url":"http://127.0.0.1:17778/openwrt-rootfs-x86_64.tar.gz","sha256":"$ARTIFACT_SHA","size_bytes":$ARTIFACT_SIZE,"unpacked_size_bytes":$UNPACKED_SIZE}}}
EOF
openssl pkeyutl -sign -rawin -inkey "$T/test.key" -in "$T/UPDATES.json" -out "$T/UPDATES.json.sig" || exit 1

cat > "$BIN/id" <<'ID'
#!/bin/sh
[ "${1:-}" = -u ] && { echo 0; exit 0; }
exit 2
ID
cat > "$BIN/apk" <<'APK'
#!/bin/sh
case "${1:-}" in
    update|add) exit 0 ;;
    info) exit 1 ;;
    *) echo "unexpected apk command: $*" >&2; exit 2 ;;
esac
APK
cat > "$BIN/wget" <<'WGET'
#!/bin/sh
dest= url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -q) shift ;;
        -T) shift 2 ;;
        -O) dest="$2"; shift 2 ;;
        *) url="$1"; shift ;;
    esac
done
case "$url" in
    http://127.0.0.1:17778/UPDATES.json) cp "$Z2K_TEST_MANIFEST" "$dest" ;;
    http://127.0.0.1:17778/UPDATES.json.sig) cp "$Z2K_TEST_SIGNATURE" "$dest" ;;
    http://127.0.0.1:17778/openwrt-rootfs-x86_64.tar.gz)
        [ -z "${Z2K_TEST_ARTIFACT_FETCHES:-}" ] || printf '%s\n' "$url" >> "$Z2K_TEST_ARTIFACT_FETCHES"
        if [ "${Z2K_TEST_WGET_MODE:-}" = truncated ]; then
            dd if="$Z2K_TEST_ARTIFACT" of="$dest" bs=32 count=1 2>/dev/null
            exit 0
        fi
        cp "$Z2K_TEST_ARTIFACT" "$dest" ;;
    http://127.0.0.1:17778/openwrt-rootfs.tar.gz)
        [ -z "${Z2K_TEST_ARTIFACT_FETCHES:-}" ] || printf '%s\n' "$url" >> "$Z2K_TEST_ARTIFACT_FETCHES"
        cp "$Z2K_TEST_ARTIFACT" "$dest" ;;
    *) echo "unexpected URL: $url" >&2; exit 2 ;;
esac
WGET
cat > "$BIN/jsonfilter" <<'JSONFILTER'
#!/bin/sh
exec python3 - "$@" <<'PY'
import json, sys
args = sys.argv[1:]
filename = expression = None
kind = False
while args:
    arg = args.pop(0)
    if arg == "-i": filename = args.pop(0)
    elif arg == "-e": expression = args.pop(0).removeprefix("@.")
    elif arg == "-t": kind = True; expression = args.pop(0).removeprefix("@.")
    else: raise SystemExit(2)
value = json.load(open(filename, encoding="utf-8"))
for key in expression.split("."):
    value = value[key]
if kind:
    print("object" if isinstance(value, dict) else "array" if isinstance(value, list) else "string" if isinstance(value, str) else "number" if isinstance(value, (int, float)) else "null")
elif value is not None: print(value)
PY
JSONFILTER
cat > "$BIN/df" <<'DF'
#!/bin/sh
case "${2:-}" in
    "${TMPDIR:-/tmp}"/*|"${Z2K_OW_INSTALL_TMP:-/tmp}"/*)
        _free="${Z2K_TEST_DF_KB:-500000}"
        printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 600000 100000 %s 17%% /tmp\n' "$_free"
        ;;
    *) printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 4000000 100000 3900000 3%% /overlay\n' ;;
esac
DF
chmod 755 "$BIN/id" "$BIN/apk" "$BIN/wget" "$BIN/jsonfilter" "$BIN/df"
_REAL_TAR="$(command -v tar)"
if [ -n "$_busybox" ]; then _REAL_TAR="$_busybox tar"; fi
cat > "$BIN/tar" <<'TAR'
#!/bin/sh
[ -z "${Z2K_TEST_TAR_CALLS:-}" ] || printf '%s\n' "$*" >> "$Z2K_TEST_TAR_CALLS"
exec ${Z2K_TEST_REAL_TAR} "$@"
TAR
chmod 755 "$BIN/tar"

cat > "$SYS/openwrt_release" <<'RELEASE'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.5'
DISTRIB_ARCH='x86_64'
RELEASE
: > "$T/artifact-fetches"
: > "$T/tar-calls"
export PATH="$BIN:/usr/bin:/bin" TMPDIR="$BOOT_TMP" \
    Z2K_TEST_MANIFEST="$T/UPDATES.json" Z2K_TEST_SIGNATURE="$T/UPDATES.json.sig" \
    Z2K_TEST_ARTIFACT="$ARTIFACT_ARCH" Z2K_TEST_REAL_TAR="$_REAL_TAR" \
    Z2K_TEST_ARTIFACT_FETCHES="$T/artifact-fetches" Z2K_TEST_TAR_CALLS="$T/tar-calls" \
    Z2K_OPENWRT_RELEASE_FILE="$SYS/openwrt_release" \
    Z2K_OW_OPENWRT_RELEASE_FILE="$SYS/openwrt_release" \
    Z2KOW_MANIFEST_URL=http://127.0.0.1:17778/UPDATES.json Z2KOW_TRUST_KEY="$T/test.pub" \
    Z2K_OW_SYSROOT="$SYS" Z2K_OW_INSTALL_TMP="$STAGE_TMP" Z2K_OW_TESTING=1

if sh "$REPO/scripts/openwrt/install.sh" > "$T/out" 2>&1; then
    _t_ok
else
    _t_bad "real fresh bootstrap engine failed: $(cat "$T/out")"
fi
cp "$T/UPDATES.json" "$T/good-UPDATES.json"
cp "$T/UPDATES.json.sig" "$T/good-UPDATES.json.sig"
assert_contains "real install_release committed the controlled tag and sequence" \
    "$SYS/etc/z2k/state/installed-release" "tag=p-86.13"
assert_contains "real install_release committed the controlled sequence" \
    "$SYS/etc/z2k/state/installed-release" "seq=136"
assert_file "target architecture binary was installed" "$SYS/usr/lib/z2k/bin/linux-x86_64/tg-mtproxy-client"
assert_file "real fresh install printed its completion notice" "$T/out"
assert_contains "bootstrap log names the selected architecture and release" "$T/out" \
    'установщик z2kOW: выбираю архив для архитектуры x86_64, выпуск p-86.13'
assert_contains "bootstrap log records the verified archive digest" "$T/out" \
    'установщик z2kOW: размер и SHA-256 архива подтверждены'
assert_contains "bootstrap log records the handoff to the shared installer" "$T/out" \
    'установщик z2kOW: передаю проверенный выпуск общей процедуре install_release'
assert_eq "bootstrap downloads only its selected architecture" \
    http://127.0.0.1:17778/openwrt-rootfs-x86_64.tar.gz "$(cat "$T/artifact-fetches")"
for _root in \
    "$SYS/usr/lib/z2k/bin" \
    "$SYS/usr/lib/z2k/platform/openwrt/bin" \
    "$SYS/opt/zapret2/binaries"; do
    if find "$_root" -mindepth 1 -maxdepth 1 -type d ! -name linux-x86_64 | grep -q .; then
        _t_bad "installed tree contains a foreign architecture under $_root"
    else
        _t_ok
    fi
done

_fetch_count() { wc -l < "$T/artifact-fetches" | tr -d ' \t\r\n'; }
_tar_count() { wc -l < "$T/tar-calls" | tr -d ' \t\r\n'; }

# A valid transition manifest prefers the selected architecture over its
# full-rootfs compatibility field.
python3 - "$T/UPDATES.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
record = data['artifacts']['x86_64']
data['artifact'] = {
    'filename': 'openwrt-rootfs.tar.gz',
    'url': 'http://127.0.0.1:17778/openwrt-rootfs.tar.gz',
    'sha256': record['sha256'], 'size_bytes': record['size_bytes'],
}
path.write_text(json.dumps(data))
PY
openssl pkeyutl -sign -rawin -inkey "$T/test.key" -in "$T/UPDATES.json" -out "$T/UPDATES.json.sig" || exit 1
if sh "$REPO/scripts/openwrt/install.sh" > "$T/transition-bootstrap.out" 2>&1; then
    _t_ok
else
    _t_bad "transition per-arch bootstrap failed: $(cat "$T/transition-bootstrap.out")"
fi
assert_eq "transition bootstrap requests only the selected architecture" \
    http://127.0.0.1:17778/openwrt-rootfs-x86_64.tar.gz "$(tail -n 1 "$T/artifact-fetches")"
_fetches_before=$(_fetch_count)

# A present but incomplete per-architecture map is authoritative; it may not
# silently fall back to the valid legacy artifact field.
python3 - "$T/UPDATES.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
record = data['artifacts']['x86_64']
data['artifact'] = {
    'filename': 'openwrt-rootfs.tar.gz',
    'url': 'http://127.0.0.1:17778/openwrt-rootfs.tar.gz',
    'sha256': record['sha256'], 'size_bytes': record['size_bytes'],
}
data['artifacts'] = {'arm': {
    'filename': 'openwrt-rootfs-arm.tar.gz',
    'url': 'http://127.0.0.1:17778/openwrt-rootfs-arm.tar.gz',
    'sha256': record['sha256'], 'size_bytes': record['size_bytes'],
    'unpacked_size_bytes': record['unpacked_size_bytes'],
}}
path.write_text(json.dumps(data))
PY
openssl pkeyutl -sign -rawin -inkey "$T/test.key" -in "$T/UPDATES.json" -out "$T/UPDATES.json.sig" || exit 1
if sh "$REPO/scripts/openwrt/install.sh" > "$T/no-arch-fallback.out" 2>&1; then
    _t_bad "bootstrap fell back to legacy artifact when artifacts map omitted x86_64"
else
    _t_ok
fi
assert_eq "missing architecture selection does not fetch legacy archive" "$_fetches_before" "$(_fetch_count)"

# The transition legacy-only schema still selects its one full rootfs archive.
python3 - "$T/UPDATES.json" "$ARTIFACT_ARCH" <<'PY'
import hashlib, json, pathlib, sys
path, archive_path = map(pathlib.Path, sys.argv[1:])
data = json.loads(path.read_text())
archive = archive_path.read_bytes()
data.pop('artifacts', None)
data['artifact'] = {
    'filename': 'openwrt-rootfs.tar.gz',
    'url': 'http://127.0.0.1:17778/openwrt-rootfs.tar.gz',
    'sha256': hashlib.sha256(archive).hexdigest(), 'size_bytes': len(archive),
}
path.write_text(json.dumps(data))
PY
openssl pkeyutl -sign -rawin -inkey "$T/test.key" -in "$T/UPDATES.json" -out "$T/UPDATES.json.sig" || exit 1
if sh "$REPO/scripts/openwrt/install.sh" > "$T/legacy-bootstrap.out" 2>&1; then
    _t_ok
else
    _t_bad "legacy-only bootstrap failed: $(cat "$T/legacy-bootstrap.out")"
fi
assert_eq "legacy-only bootstrap requests the full fallback archive" \
    http://127.0.0.1:17778/openwrt-rootfs.tar.gz "$(tail -n 1 "$T/artifact-fetches")"

# Archive failures are rejected before tar sees any untrusted bytes.
cp "$T/good-UPDATES.json" "$T/UPDATES.json"
cp "$T/good-UPDATES.json.sig" "$T/UPDATES.json.sig"
_tar_before=$(_tar_count)
if Z2K_TEST_WGET_MODE=truncated sh "$REPO/scripts/openwrt/install.sh" > "$T/interrupted.out" 2>&1; then
    _t_bad "bootstrap accepted an interrupted artifact download"
else
    _t_ok
fi
assert_contains "обрыв загрузки обнаруживается по размеру до распаковки" "$T/interrupted.out" 'размер архива файлов роутера не совпал'
assert_eq "interrupted download never invokes tar" "$_tar_before" "$(_tar_count)"

python3 - "$T/UPDATES.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data['artifacts']['x86_64']['sha256'] = '0' * 64
path.write_text(json.dumps(data))
PY
openssl pkeyutl -sign -rawin -inkey "$T/test.key" -in "$T/UPDATES.json" -out "$T/UPDATES.json.sig" || exit 1
if sh "$REPO/scripts/openwrt/install.sh" > "$T/wrong-sha.out" 2>&1; then
    _t_bad "bootstrap accepted an archive with the wrong SHA-256"
else
    _t_ok
fi
assert_contains "неверный SHA-256 обнаруживается до распаковки" "$T/wrong-sha.out" 'SHA-256 архива файлов роутера не совпал'
assert_eq "wrong SHA-256 never invokes tar" "$_tar_before" "$(_tar_count)"
cp "$T/good-UPDATES.json" "$T/UPDATES.json"
cp "$T/good-UPDATES.json.sig" "$T/UPDATES.json.sig"

# Exact tmpfs and live MemAvailable guards reject before requesting the archive.
_fetches_before=$(_fetch_count)
if Z2K_TEST_DF_KB=1 sh "$REPO/scripts/openwrt/install.sh" > "$T/low-tmpfs.out" 2>&1; then
    _t_bad "bootstrap ignored the constrained workspace tmpfs"
else
    _t_ok
fi
assert_contains "tmpfs budget failure is reported before download" "$T/low-tmpfs.out" 'недостаточно места'
assert_eq "tmpfs refusal happens before artifact fetch" "$_fetches_before" "$(_fetch_count)"

# На устройстве с 64 МиБ архива и распаковки нет в оперативной памяти, но
# установщик всё равно заранее проверяет собственную память и запас.
cp "$T/UPDATES.json" "$T/good-UPDATES.json"
cp "$T/UPDATES.json.sig" "$T/good-UPDATES.json.sig"
python3 - "$T/UPDATES.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text())
manifest['artifacts']['x86_64']['size_bytes'] = 16777216
manifest['artifacts']['x86_64']['unpacked_size_bytes'] = 67108864
path.write_text(json.dumps(manifest))
PY
openssl pkeyutl -sign -rawin -inkey "$T/test.key" -in "$T/UPDATES.json" -out "$T/UPDATES.json.sig" || exit 1
printf 'MemTotal: 65536 kB\nMemAvailable: 9000 kB\n' > "$T/low-meminfo"
printf '1 0 0:1 / / rw - tmpfs tmpfs rw\n' > "$T/memory-mountinfo"
_fetches_before=$(_fetch_count)
if Z2K_OW_MEMINFO_FILE="$T/low-meminfo" Z2K_OW_MOUNTINFO_FILE="$T/memory-mountinfo" \
    Z2K_TEST_ARTIFACT_FETCHES="$T/artifact-fetches" \
    sh "$REPO/scripts/openwrt/install.sh" > "$T/low-memory.out" 2>&1; then
    _t_bad "начальная установка отказывает на профиле 64 МиБ при нехватке оперативной памяти"
else
    _t_ok
fi
assert_contains "диагностика начального установщика сообщает о нехватке оперативной памяти" "$T/low-memory.out" 'недостаточно свободной оперативной памяти'
assert_eq "профиль 64 МиБ отказывает до загрузки архива" "$_fetches_before" "$(_fetch_count)"
cp "$T/good-UPDATES.json" "$T/UPDATES.json"
cp "$T/good-UPDATES.json.sig" "$T/UPDATES.json.sig"

# Устройство с 128 МиБ и 26 МиБ свободной памяти может загрузить архив x86_64:
# архив и распакованные файлы остаются на диске. Маленький тестовый файл затем
# отклоняется по подписанному размеру; до этой проверки подтверждается выбор пути.
python3 - "$T/UPDATES.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text())
manifest['artifacts']['x86_64']['size_bytes'] = 14132028
manifest['artifacts']['x86_64']['unpacked_size_bytes'] = 33710110
path.write_text(json.dumps(manifest))
PY
openssl pkeyutl -sign -rawin -inkey "$T/test.key" -in "$T/UPDATES.json" -out "$T/UPDATES.json.sig" || exit 1
printf 'MemTotal: 131072 kB\nMemAvailable: 26544 kB\n' > "$T/low-meminfo"
_fetches_before=$(_fetch_count)
if Z2K_OW_MEMINFO_FILE="$T/low-meminfo" Z2K_OW_MOUNTINFO_FILE="$T/memory-mountinfo" \
    Z2K_TEST_ARTIFACT_FETCHES="$T/artifact-fetches" \
    sh "$REPO/scripts/openwrt/install.sh" > "$T/128-disk-stage.out" 2>&1; then
    _t_bad "128 MiB disk-staged bootstrap accepted a fixture with false archive size"
else
    _t_ok
fi
assert_contains "проверка для 128 МиБ доходит до проверки подписанного размера" \
    "$T/128-disk-stage.out" 'размер архива файлов роутера не совпал'
assert_eq "профиль 128 МиБ загружает архив после проверки доступной памяти" \
    "$((_fetches_before + 1))" "$(_fetch_count)"
cp "$T/good-UPDATES.json" "$T/UPDATES.json"
cp "$T/good-UPDATES.json.sig" "$T/UPDATES.json.sig"

# Подписанный неполный архив нужно отклонить до запуска движка и изменения
# уже установленного дерева.
cp -a "$PAYLOAD" "$T/payload-without-arch" || exit 1
rm -f "$T/payload-without-arch/usr/lib/z2k/platform/openwrt/arch.sh"
tar -czf "$T/openwrt-rootfs-without-arch.tar.gz" -C "$T/payload-without-arch" usr etc opt || exit 1
python3 - "$T/UPDATES.json" "$T/openwrt-rootfs-without-arch.tar.gz" <<'PY'
import hashlib, json, pathlib, sys
manifest_path, archive_path = map(pathlib.Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
archive = archive_path.read_bytes()
manifest["artifacts"]["x86_64"]["sha256"] = hashlib.sha256(archive).hexdigest()
manifest["artifacts"]["x86_64"]["size_bytes"] = len(archive)
manifest["artifacts"]["x86_64"]["unpacked_size_bytes"] = sum(member.size for member in __import__("tarfile").open(archive_path, "r:gz") if member.isfile())
manifest_path.write_text(json.dumps(manifest, separators=(",", ":")), encoding="utf-8")
PY
openssl pkeyutl -sign -rawin -inkey "$T/test.key" -in "$T/UPDATES.json" -out "$T/UPDATES.json.sig" || exit 1
Z2K_TEST_ARTIFACT="$T/openwrt-rootfs-without-arch.tar.gz" \
    sh "$REPO/scripts/openwrt/install.sh" > "$T/missing-arch.out" 2>&1 \
    && _t_bad "signed rootfs without the required architecture module was accepted"
assert_contains "missing required module is diagnosed before applying files" \
    "$T/missing-arch.out" "обязательный файл установочного кода: usr/lib/z2k/platform/openwrt/arch.sh"
assert_eq "incomplete signed rootfs leaves installed release state unchanged" \
    "tag=p-86.13
seq=136" "$(cat "$SYS/etc/z2k/state/installed-release" 2>/dev/null)"

_t_done
