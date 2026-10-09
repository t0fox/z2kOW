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
    ln -s "$_busybox" "$BIN/awk" || exit 1
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
    "$PAYLOAD/usr/sbin" "$PAYLOAD/usr/bin" "$PAYLOAD/opt/zapret2/binaries/linux-x86_64/nfq2" \
    "$PAYLOAD/opt/zapret2/binaries/linux-x86_64/ip2net" \
    "$PAYLOAD/opt/zapret2/binaries/linux-x86_64/mdig" \
    "$PAYLOAD/etc/init.d" "$PAYLOAD/etc/hotplug.d/iface" "$PAYLOAD/etc/sysctl.d" \
    "$PAYLOAD/usr/share/nftables.d/chain-pre/forward"
for name in paths.sh env.sh manifest.sh release_state.sh release.sh bootstrap.sh arch.sh; do
    cp "$REPO/platform/openwrt/$name" "$PAYLOAD/usr/lib/z2k/platform/openwrt/$name" || exit 1
done
cp "$REPO/platform/openwrt/owned-paths.txt" "$PAYLOAD/usr/lib/z2k/platform/openwrt/owned-paths.txt" || exit 1
cp "$REPO/lib/utils.sh" "$REPO/lib/auto_update.sh" "$PAYLOAD/usr/lib/z2k/lib/" || exit 1
cp "$REPO/scripts/openwrt/install_release.sh" "$PAYLOAD/usr/sbin/install_release" || exit 1
chmod 755 "$PAYLOAD/usr/sbin/install_release"
printf '#!/bin/sh\nexit 0\n' > "$PAYLOAD/usr/bin/z2kow"
chmod 755 "$PAYLOAD/usr/bin/z2kow"
for name in tg-mtproxy-client z2k-rt-proxy z2k-detect; do
    printf '#!/bin/sh\nexit 0\n' > "$PAYLOAD/usr/lib/z2k/bin/linux-x86_64/$name"
    chmod 755 "$PAYLOAD/usr/lib/z2k/bin/linux-x86_64/$name"
done
printf '#!/bin/sh\nexit 0\n' > "$PAYLOAD/usr/lib/z2k/platform/openwrt/bin/linux-x86_64/z2k-warpd"
chmod 755 "$PAYLOAD/usr/lib/z2k/platform/openwrt/bin/linux-x86_64/z2k-warpd"
for pair in nfq2/nfqws2 ip2net/ip2net mdig/mdig; do
    name="${pair#*/}"
    printf '#!/bin/sh\nexit 0\n' > "$PAYLOAD/opt/zapret2/binaries/linux-x86_64/$pair"
    chmod 755 "$PAYLOAD/opt/zapret2/binaries/linux-x86_64/$pair"
done
for name in z2k z2k-webpanel; do
    printf '#!/bin/sh\nexit 0\n' > "$PAYLOAD/etc/init.d/$name"
    chmod 755 "$PAYLOAD/etc/init.d/$name"
done
printf '#!/bin/sh\nexit 0\n' > "$PAYLOAD/etc/hotplug.d/iface/90-z2k"
printf 'net.ipv4.ip_forward=1\n' > "$PAYLOAD/etc/sysctl.d/99-z2k.conf"
printf 'table inet z2k {}\n' > "$PAYLOAD/usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft"
tar -czf "$T/openwrt-rootfs.tar.gz" -C "$PAYLOAD" usr etc opt || exit 1

ARTIFACT_SHA="$(sha256sum "$T/openwrt-rootfs.tar.gz" | awk '{print $1}')"
ARTIFACT_SIZE="$(wc -c < "$T/openwrt-rootfs.tar.gz" | tr -d ' \t\r\n')"
cat > "$T/UPDATES.json" <<EOF
{"schema":1,"branch":"main","platform":"openwrt","seq":136,"current":"p-86.13","upstream":{"repository":"necronicle/z2k","branch":"z2k-enhanced","tag":"p-86.13","commit":"7f630a9d459052b9c9c9eded06298f1b8f7f0a22"},"signing":{"key_id":"$TEST_KEY_ID"},"artifact":{"filename":"openwrt-rootfs.tar.gz","url":"http://127.0.0.1:17778/openwrt-rootfs.tar.gz","sha256":"$ARTIFACT_SHA","size_bytes":$ARTIFACT_SIZE}}
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
    http://127.0.0.1:17778/openwrt-rootfs.tar.gz) cp "$Z2K_TEST_ARTIFACT" "$dest" ;;
    *) echo "unexpected URL: $url" >&2; exit 2 ;;
esac
WGET
cat > "$BIN/jsonfilter" <<'JSONFILTER'
#!/bin/sh
exec python3 - "$@" <<'PY'
import json, sys
args = sys.argv[1:]
filename = expression = None
while args:
    arg = args.pop(0)
    if arg == "-i": filename = args.pop(0)
    elif arg == "-e": expression = args.pop(0).removeprefix("@.")
    else: raise SystemExit(2)
value = json.load(open(filename, encoding="utf-8"))
for key in expression.split("."):
    value = value[key]
if value is not None: print(value)
PY
JSONFILTER
chmod 755 "$BIN/id" "$BIN/apk" "$BIN/wget" "$BIN/jsonfilter"

cat > "$SYS/openwrt_release" <<'RELEASE'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.5'
DISTRIB_ARCH='x86_64'
RELEASE
export PATH="$BIN:/usr/bin:/bin" TMPDIR="$BOOT_TMP" \
    Z2K_TEST_MANIFEST="$T/UPDATES.json" Z2K_TEST_SIGNATURE="$T/UPDATES.json.sig" \
    Z2K_TEST_ARTIFACT="$T/openwrt-rootfs.tar.gz" \
    Z2K_OPENWRT_RELEASE_FILE="$SYS/openwrt_release" \
    Z2K_OW_OPENWRT_RELEASE_FILE="$SYS/openwrt_release" \
    Z2KOW_MANIFEST_URL=http://127.0.0.1:17778/UPDATES.json Z2KOW_TRUST_KEY="$T/test.pub" \
    Z2K_OW_SYSROOT="$SYS" Z2K_OW_INSTALL_TMP="$STAGE_TMP" Z2K_OW_TESTING=1

if sh "$REPO/scripts/openwrt/install.sh" > "$T/out" 2>&1; then
    _t_ok
else
    _t_bad "real fresh bootstrap engine failed: $(cat "$T/out")"
fi
assert_contains "real install_release committed the controlled tag and sequence" \
    "$SYS/etc/z2k/state/installed-release" "tag=p-86.13"
assert_contains "real install_release committed the controlled sequence" \
    "$SYS/etc/z2k/state/installed-release" "seq=136"
assert_file "target architecture binary was installed" "$SYS/usr/lib/z2k/bin/linux-x86_64/tg-mtproxy-client"
assert_file "real fresh install printed its completion notice" "$T/out"

if python3 "$REPO/tests/openwrt/accept_release_candidate.py" \
    "$T/UPDATES.json" "$T/openwrt-rootfs.tar.gz" > "$T/candidate-acceptance.out" 2>&1; then
    _t_ok
else
    _t_bad "приёмка полного rootfs-кандидата завершилась ошибкой: $(cat "$T/candidate-acceptance.out")"
fi
assert_file "квитанция приёмки привязана к исходному кандидату" "$T/candidate-acceptance.json"

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
manifest["artifact"]["sha256"] = hashlib.sha256(archive).hexdigest()
manifest["artifact"]["size_bytes"] = len(archive)
manifest_path.write_text(json.dumps(manifest, separators=(",", ":")), encoding="utf-8")
PY
openssl pkeyutl -sign -rawin -inkey "$T/test.key" -in "$T/UPDATES.json" -out "$T/UPDATES.json.sig" || exit 1
Z2K_TEST_ARTIFACT="$T/openwrt-rootfs-without-arch.tar.gz" \
    sh "$REPO/scripts/openwrt/install.sh" > "$T/missing-arch.out" 2>&1 \
    && _t_bad "signed rootfs without the required architecture module was accepted"
assert_contains "missing required module is diagnosed before applying files" \
    "$T/missing-arch.out" "обязательный файл движка установки: usr/lib/z2k/platform/openwrt/arch.sh"
assert_eq "incomplete signed rootfs leaves installed release state unchanged" \
    "tag=p-86.13
seq=136" "$(cat "$SYS/etc/z2k/state/installed-release" 2>/dev/null)"

_t_done
