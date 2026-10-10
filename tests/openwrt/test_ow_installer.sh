#!/bin/sh
# Новая установка OpenWrt проверяет один подписанный манифест и запускает install_release(tag).
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/luci_fixture.sh"
_t_plan "ow-installer"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="$REPO/scripts/openwrt/install.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-installer.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
BIN="$T/bin"; TMPDIR="$T/tmp"; SYS="$T/sys"
mkdir -p "$BIN" "$TMPDIR" "$SYS/etc/init.d" "$SYS/etc/z2k/state" "$SYS/www/luci-static"

command -v openssl >/dev/null 2>&1 || { _t_bad "openssl unavailable"; _t_done; exit $?; }
openssl genpkey -algorithm ED25519 -out "$T/test.key" >/dev/null 2>&1 || exit 1
openssl pkey -in "$T/test.key" -pubout -out "$T/test.pub" >/dev/null 2>&1 || exit 1
TEST_KEY_ID="$(openssl pkey -pubin -in "$T/test.pub" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"

mkdir -p "$T/payload/usr/sbin" "$T/payload/usr/bin" "$T/payload/usr/lib/z2k/lib" \
    "$T/payload/usr/lib/z2k/platform/openwrt"
cat > "$T/payload/usr/sbin/install_release" <<'ENGINE'
#!/bin/sh
[ "$#" = 1 ] || exit 2
printf '%s\n' "$1" > "$Z2K_TEST_INSTALL_CALL"
[ -r "$Z2K_ADAPTER_DIR/arch.sh" ] || exit 4
[ -s "$Z2K_OW_BOOTSTRAP_MANIFEST" ] && [ -s "$Z2K_OW_BOOTSTRAP_SIGNATURE" ] \
    && [ -s "$Z2K_OW_BOOTSTRAP_ARTIFACT" ] \
    && [ -s "$Z2K_OW_BOOTSTRAP_PUBLIC_KEY" ] || exit 3
printf 'tag=%s\nseq=%s\n' "$1" 136 > "$Z2K_TEST_SYSROOT/etc/z2k/state/installed-release"
ENGINE
chmod 755 "$T/payload/usr/sbin/install_release"
printf '#!/bin/sh\nexit 0\n' > "$T/payload/usr/bin/z2kow"
chmod 755 "$T/payload/usr/bin/z2kow"
for f in utils.sh auto_update.sh; do printf '#!/bin/sh\n' > "$T/payload/usr/lib/z2k/lib/$f"; done
for f in paths.sh env.sh manifest.sh release_state.sh release.sh recover_boot.sh bootstrap.sh; do
    printf '#!/bin/sh\n' > "$T/payload/usr/lib/z2k/platform/openwrt/$f"
done
cp "$REPO/platform/openwrt/arch.sh" "$T/payload/usr/lib/z2k/platform/openwrt/arch.sh" || exit 1
printf '/usr/lib/z2k\n' > "$T/payload/usr/lib/z2k/platform/openwrt/owned-paths.txt"
tar -czf "$T/openwrt-rootfs.tar.gz" -C "$T/payload" \
    usr/sbin/install_release usr/bin/z2kow usr/lib/z2k/lib/utils.sh usr/lib/z2k/lib/auto_update.sh \
    usr/lib/z2k/platform/openwrt/paths.sh usr/lib/z2k/platform/openwrt/env.sh \
    usr/lib/z2k/platform/openwrt/manifest.sh usr/lib/z2k/platform/openwrt/release_state.sh \
    usr/lib/z2k/platform/openwrt/release.sh usr/lib/z2k/platform/openwrt/recover_boot.sh \
    usr/lib/z2k/platform/openwrt/bootstrap.sh usr/lib/z2k/platform/openwrt/arch.sh \
    usr/lib/z2k/platform/openwrt/owned-paths.txt
ARTIFACT_SHA="$(sha256sum "$T/openwrt-rootfs.tar.gz" | awk '{print $1}')"
ARTIFACT_SIZE="$(wc -c < "$T/openwrt-rootfs.tar.gz" | tr -d ' \t\r\n')"
cat > "$T/UPDATES.json" <<EOF
{"schema":1,"branch":"main","platform":"openwrt","seq":136,"current":"p-86.13","upstream":{"repository":"necronicle/z2k","branch":"z2k-enhanced","tag":"p-86.13","commit":"7f630a9d459052b9c9c9eded06298f1b8f7f0a22"},"signing":{"key_id":"$TEST_KEY_ID"},"history":[{"v":"p-86.13","type":"patch","ts":"2026-10-02T06:39:48Z","ref":"p-86.13","desc":"fixture","changed_files":["files/z2k-warp.sh"]}],"artifact":{"filename":"openwrt-rootfs.tar.gz","url":"http://127.0.0.1:17777/openwrt-rootfs.tar.gz","sha256":"$ARTIFACT_SHA","size_bytes":$ARTIFACT_SIZE}}
EOF
openssl pkeyutl -sign -rawin -inkey "$T/test.key" -in "$T/UPDATES.json" -out "$T/UPDATES.json.sig" || exit 1

cat > "$BIN/id" <<'ID'
#!/bin/sh
[ "$1" = -u ] && { echo 0; exit 0; }
exit 2
ID
cat > "$BIN/apk" <<'APK'
#!/bin/sh
printf '%s\n' "$*" >> "$Z2K_TEST_APK_LOG"
case "$1" in
    update) exit 0 ;;
    add)
        for arg in "$@"; do
            case "$arg" in z2k-*|packages.adb) echo "forbidden product package: $arg" >&2; exit 17 ;; esac
        done
        exit 0 ;;
    *) echo "unexpected apk command: $*" >&2; exit 18 ;;
esac
APK
cat > "$BIN/df" <<'DF'
#!/bin/sh
if [ "${Z2K_TEST_LOW_BOOTSTRAP_TMP:-0}" = 1 ]; then
    printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 100000 99999 1 99%% /tmp\n'
else
    exec /usr/bin/df "$@"
fi
DF
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
printf '%s\n' "$url" >> "$Z2K_TEST_WGET_LOG"
case "$url" in
    http://127.0.0.1:17777/UPDATES.json) cp "$Z2K_TEST_MANIFEST" "$dest" ;;
    http://127.0.0.1:17777/UPDATES.json.sig)
        if [ "${Z2K_TEST_BAD_SIGNATURE:-0}" = 1 ]; then printf 'bad-signature' > "$dest"; else cp "$Z2K_TEST_SIGNATURE" "$dest"; fi ;;
    http://127.0.0.1:17777/openwrt-rootfs.tar.gz)
        if [ "${Z2K_TEST_BAD_ARTIFACT:-0}" = 1 ]; then
            cp "$Z2K_TEST_ARTIFACT" "$dest"
            printf '\001' | dd of="$dest" bs=1 seek=0 conv=notrunc 2>/dev/null
        else cp "$Z2K_TEST_ARTIFACT" "$dest"; fi ;;
    *) echo "unexpected URL: $url" >&2; exit 19 ;;
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
chmod 755 "$BIN/id" "$BIN/apk" "$BIN/df" "$BIN/wget" "$BIN/jsonfilter"

cat > "$SYS/etc/openwrt_release" <<'RELEASE'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.5'
RELEASE
cat > "$T/healthy-memory" <<'MEMINFO'
MemTotal: 262144 kB
MemFree: 196608 kB
MemAvailable: 196608 kB
MEMINFO
printf 'LuCI assets\n' > "$SYS/www/luci-static/index"
luci_fixture_seed "$SYS" || exit 1
_luci_before="$(luci_fixture_state "$SYS")" || exit 1
export PATH="$BIN:/usr/bin:/bin" TMPDIR Z2K_TEST_MANIFEST="$T/UPDATES.json" \
    Z2K_OPENWRT_RELEASE_FILE="$SYS/etc/openwrt_release" \
    Z2KOW_MANIFEST_URL=http://127.0.0.1:17777/UPDATES.json Z2KOW_TRUST_KEY="$T/test.pub" \
    Z2K_TEST_SIGNATURE="$T/UPDATES.json.sig" Z2K_TEST_ARTIFACT="$T/openwrt-rootfs.tar.gz" \
    Z2K_TEST_INSTALL_CALL="$T/install-call" Z2K_TEST_APK_LOG="$T/apk.log" \
    Z2K_TEST_WGET_LOG="$T/wget.log" \
    Z2K_TEST_SYSROOT="$SYS" Z2K_OW_SYSROOT="$SYS" \
    Z2K_OW_MEMINFO_FILE="$T/healthy-memory"

if sh "$INSTALLER" > "$T/out" 2>&1; then _t_ok; else _t_bad "fresh bootstrap failed: $(cat "$T/out")"; fi
assert_eq "bootstrap enters the unified installer once with controlled tag" p-86.13 "$(cat "$T/install-call" 2>/dev/null)"
assert_eq "fresh bootstrap writes the single installed release state" "tag=p-86.13
seq=136" "$(cat "$SYS/etc/z2k/state/installed-release" 2>/dev/null)"
assert_contains "successful fresh bootstrap prints Windows TCP timestamps notice" "$T/out" "ВАЖНО ДЛЯ WINDOWS"
assert_contains "fresh bootstrap shows the required Windows command" "$T/out" "netsh interface tcp set global timestamps=enabled"
assert_not_contains "shared install/update transaction does not print the fresh-install Windows notice" "$REPO/platform/openwrt/release.sh" 'timestamps=enabled|ВАЖНО ДЛЯ WINDOWS'
assert_eq "bootstrap installs only required OpenWrt system dependencies" \
    "update
add ca-bundle openssl-util jsonfilter" "$(cat "$T/apk.log" 2>/dev/null)"
assert_not_contains "bootstrap contains no z2kOW APK or feed installation" "$INSTALLER" 'z2k-(adapter|webpanel|zapret2-runtime|warp-runtime)|packages\.adb|repositories\.d|apk (add|del).*z2k'
assert_contains "production manifest default remains pinned" "$INSTALLER" 'BASE="https://raw.githubusercontent.com/t0fox/z2kOW/main"'
luci_fixture_assert_unchanged "$SYS" "$_luci_before" "fresh bootstrap preserves LuCI and uhttpd"

# Несовместимая прошивка и нехватка памяти должны завершать проверку до apk,
# сетевых запросов и изменений постоянного состояния OpenWrt.
sed "s/DISTRIB_RELEASE='25.12.5'/DISTRIB_RELEASE='23.05.5'/" \
    "$SYS/etc/openwrt_release" > "$T/old-openwrt-release"
cp "$T/old-openwrt-release" "$SYS/etc/openwrt_release"
rm -f "$T/apk.log" "$T/wget.log" "$T/install-call"
if sh "$INSTALLER" > "$T/old-openwrt.out" 2>&1; then
    _t_bad "unsupported OpenWrt release was accepted"
else
    assert_contains "old firmware reports the minimum supported version" "$T/old-openwrt.out" "OpenWrt 24.10 или новее"
fi
[ ! -e "$T/apk.log" ] && _t_ok || _t_bad "unsupported release ran apk"
[ ! -e "$T/wget.log" ] && _t_ok || _t_bad "unsupported release downloaded installer metadata"
cat > "$SYS/etc/openwrt_release" <<'RELEASE'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.5'
RELEASE
cat > "$T/low-memory" <<'MEMINFO'
MemTotal: 65536 kB
MemFree: 512 kB
MemAvailable: 2048 kB
MEMINFO
rm -f "$T/apk.log" "$T/wget.log" "$T/install-call"
if Z2K_OW_MEMINFO_FILE="$T/low-memory" sh "$INSTALLER" > "$T/low-memory.out" 2>&1; then
    _t_bad "low-memory OpenWrt system was accepted"
else
assert_contains "low available memory is diagnosed before dependency install" "$T/low-memory.out" "недостаточно оперативной памяти"
fi
[ ! -e "$T/apk.log" ] && _t_ok || _t_bad "low-memory check ran apk"
[ ! -e "$T/wget.log" ] && _t_ok || _t_bad "low-memory check downloaded installer metadata"

# Подписанную манифестацию можно получить заранее, но нехватку места нужно
# обнаружить до начала загрузки архива.
rm -f "$T/apk.log" "$T/wget.log" "$T/install-call"
if Z2K_TEST_LOW_BOOTSTRAP_TMP=1 sh "$INSTALLER" > "$T/low-tmp.out" 2>&1; then
    _t_bad "bootstrap accepted insufficient temporary storage"
else
    assert_contains "bootstrap tmp preflight reports the archive requirement" "$T/low-tmp.out" "недостаточно места во временном хранилище"
fi
grep -Fq 'http://127.0.0.1:17777/UPDATES.json' "$T/wget.log" && _t_ok \
    || _t_bad "tmp preflight did not verify the controlled manifest"
grep -Fq 'http://127.0.0.1:17777/openwrt-rootfs.tar.gz' "$T/wget.log" \
    && _t_bad "tmp preflight downloaded the full rootfs before rejecting space" || _t_ok
[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ] && _t_ok \
    || _t_bad "failed bootstrap left temporary files behind"
[ ! -e "$T/install-call" ] && _t_ok || _t_bad "resource preflight reached install_release"

# Источник приёмочного манифеста и доверенный ключ задаются вместе. Неполная
# настройка должна остановить установку до зависимостей и сетевых запросов.
rm -f "$T/apk.log" "$T/install-call"
if Z2KOW_TRUST_KEY= sh "$INSTALLER" > "$T/partial-override.out" 2>&1; then
    _t_bad "partial acceptance override was accepted"
else
assert_contains "partial acceptance override reports paired settings" "$T/partial-override.out" "должны задаваться вместе"
fi
[ ! -e "$T/apk.log" ] && _t_ok || _t_bad "partial acceptance override ran apk before rejection"
[ ! -e "$T/install-call" ] && _t_ok || _t_bad "partial acceptance override reached install_release"

# Неверная подпись и несовпадающий хэш должны остановить установку до запуска
# install_release.
rm -f "$T/install-call" "$SYS/etc/z2k/state/installed-release"
Z2K_TEST_BAD_SIGNATURE=1 sh "$INSTALLER" > "$T/bad-signature.out" 2>&1 && _t_bad "bad signature was accepted"
[ -f "$T/install-call" ] && _t_bad "bad signature reached install_release" || _t_ok
assert_contains "bad signature is rejected by Ed25519 verification" "$T/bad-signature.out" "подпись проверенного UPDATES.json неверна"
Z2K_TEST_BAD_SIGNATURE=0 Z2K_TEST_BAD_ARTIFACT=1 sh "$INSTALLER" > "$T/bad-artifact.out" 2>&1 && _t_bad "bad artifact was accepted"
[ -f "$T/install-call" ] && _t_bad "bad artifact reached install_release" || _t_ok
assert_contains "изменённый архив того же размера отклоняется по SHA-256" "$T/bad-artifact.out" "SHA-256 архива файлов роутера не совпал"

# Даже корректно подписанный архив не должен извлекать движок через опасную ссылку.
cp -a "$T/payload" "$T/unsafe-payload"
rm -f "$T/unsafe-payload/usr/lib/z2k/platform/openwrt/arch.sh"
ln -s /etc/passwd "$T/unsafe-payload/usr/lib/z2k/platform/openwrt/arch.sh" || exit 1
tar -czf "$T/unsafe-rootfs.tar.gz" -C "$T/unsafe-payload" usr || exit 1
_unsafe_sha="$(sha256sum "$T/unsafe-rootfs.tar.gz" | awk '{print $1}')"
_unsafe_size="$(wc -c < "$T/unsafe-rootfs.tar.gz" | tr -d ' \t\r\n')"
python3 - "$T/UPDATES.json" "$_unsafe_sha" "$_unsafe_size" <<'PY'
import json, sys
path, sha256, size = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    manifest = json.load(stream)
manifest["artifact"]["sha256"] = sha256
manifest["artifact"]["size_bytes"] = int(size)
with open(path, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream, separators=(",", ":"))
PY
openssl pkeyutl -sign -rawin -inkey "$T/test.key" \
    -in "$T/UPDATES.json" -out "$T/UPDATES.json.sig" || exit 1
rm -f "$T/install-call"
if Z2K_TEST_ARTIFACT="$T/unsafe-rootfs.tar.gz" sh "$INSTALLER" > "$T/unsafe-link.out" 2>&1; then
    _t_bad "архив с абсолютной ссылкой был принят"
else
    assert_contains "bootstrap отклоняет абсолютную цель символической ссылки" \
        "$T/unsafe-link.out" "архив содержит небезопасный тип записи"
fi
[ ! -e "$T/install-call" ] && _t_ok || _t_bad "небезопасный архив достиг install_release"

# Повторный разделитель не должен менять глубину пути при проверке ссылки.
python3 - "$T/openwrt-rootfs.tar.gz" "$T/repeated-separator-rootfs.tar.gz" <<'PY'
import sys, tarfile
source_path, output_path = sys.argv[1:]
with tarfile.open(source_path, "r:gz") as source, tarfile.open(
    output_path, "w:gz", format=tarfile.PAX_FORMAT
) as output:
    for member in source.getmembers():
        payload = source.extractfile(member) if member.isfile() else None
        output.addfile(member, payload)
    link = tarfile.TarInfo("usr//lib/z2k/platform/openwrt/escape.sh")
    link.type = tarfile.SYMTYPE
    link.linkname = "../../../../../../etc/passwd"
    output.addfile(link)
PY
_repeated_sha="$(sha256sum "$T/repeated-separator-rootfs.tar.gz" | awk '{print $1}')"
_repeated_size="$(wc -c < "$T/repeated-separator-rootfs.tar.gz" | tr -d ' \t\r\n')"
python3 - "$T/UPDATES.json" "$_repeated_sha" "$_repeated_size" <<'PY'
import json, sys
path, sha256, size = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    manifest = json.load(stream)
manifest["artifact"]["sha256"] = sha256
manifest["artifact"]["size_bytes"] = int(size)
with open(path, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream, separators=(",", ":"))
PY
openssl pkeyutl -sign -rawin -inkey "$T/test.key" \
    -in "$T/UPDATES.json" -out "$T/UPDATES.json.sig" || exit 1
rm -f "$T/install-call"
if Z2K_TEST_ARTIFACT="$T/repeated-separator-rootfs.tar.gz" \
    sh "$INSTALLER" > "$T/repeated-separator.out" 2>&1; then
    _t_bad "архив со ссылкой и повторным разделителем был принят"
else
    assert_contains "bootstrap отклоняет выход ссылки за rootfs при повторном разделителе" \
        "$T/repeated-separator.out" "архив содержит небезопасный тип записи"
fi
[ ! -e "$T/install-call" ] && _t_ok || _t_bad "архив с повторным разделителем достиг install_release"

_t_done
