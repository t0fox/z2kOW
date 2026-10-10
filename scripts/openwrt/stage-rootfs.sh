#!/bin/sh
# Подготовка полной файловой системы продукта OpenWrt из исходных файлов.
# Пакет z2kOW APK здесь не собирается и не распаковывается.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
STAGE="${1:-}"
RUNTIME_ARCHIVE="${2:-}"
WARPD_DIR="${3:-}"
TG_DIR="${4:-}"
RT_DIR="${5:-}"
DETECT_DIR="${6:-}"
RELEASE_KEYS_DIR="${7:-$ROOT/scripts/openwrt/release-keys}"

die() { printf 'подготовка OpenWrt rootfs: %s\n' "$*" >&2; exit 1; }
copy_data() {
    src="$1"; dst="$2"; mode="${3:-0644}"
    [ -f "$src" ] || die "нет обязательного исходного файла: $src"
    mkdir -p "$(dirname -- "$STAGE/$dst")"
    cp -p "$src" "$STAGE/$dst"
    chmod "$mode" "$STAGE/$dst"
}

[ -n "$STAGE" ] && [ -n "$RUNTIME_ARCHIVE" ] && [ -n "$WARPD_DIR" ] \
    && [ -n "$TG_DIR" ] && [ -n "$RT_DIR" ] && [ -n "$DETECT_DIR" ] \
    || die "использование: $0 STAGING_ROOT ZAPRET2_RUNTIME_TARBALL Z2K_WARPD_DIR TG_DIR RT_DIR DETECT_DIR"
[ -f "$RUNTIME_ARCHIVE" ] || die "нет архива runtime zapret2"
[ -d "$WARPD_DIR" ] || die "нет каталога архитектурных сборок z2k-warpd"
[ -d "$TG_DIR" ] || die "нет каталога сборок клиента Telegram"
[ -d "$RT_DIR" ] || die "нет каталога сборок RT-прокси"
[ -d "$DETECT_DIR" ] || die "нет каталога сборок диагностического детектора"
case "$STAGE" in /|/etc|/usr|/usr/lib|/www) die "небезопасный каталог подготовки: $STAGE" ;; esac
mkdir -p "$STAGE"
[ -z "$(find "$STAGE" -mindepth 1 -print -quit 2>/dev/null)" ] \
    || die "каталог подготовки должен быть пустым: $STAGE"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/z2k-stage.XXXXXX")" || die "не удалось создать временный каталог"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Поместить общие файлы сразу в единый каталог подготовки.
# Архив-заготовка или маркер версии payload для установки не создаются.
sh "$ROOT/scripts/openwrt/stage-common-payload.sh" "$ROOT" "$STAGE" \
    || die "не удалось подготовить файлы OpenWrt"
python3 "$ROOT/scripts/openwrt/stamp_panel_assets.py" \
    --root "$STAGE/usr/lib/z2k/www" --manifest "$ROOT/UPDATES.json" \
    || die "не удалось обновить метки кеша WebPanel по контролируемому манифесту релиза"

# Жизненный цикл и адаптеры платформы OpenWrt входят в тот же релизный каталог.
mkdir -p "$STAGE/usr/lib/z2k/platform/openwrt" "$STAGE/usr/lib/z2k/share"
for src in "$ROOT"/platform/openwrt/*.sh; do
    [ -f "$src" ] || continue
    case "$(basename "$src")" in
        diag.sh|update.sh|tcp16-check.sh|tiktok-check.sh|tg-check.sh|rt-check.sh|warp-check.sh|fw-check.sh|list-refresh.sh) _mode=0755 ;;
        *) _mode=0644 ;;
    esac
    copy_data "$src" "usr/lib/z2k/platform/openwrt/$(basename "$src")" "$_mode"
done
copy_data "$ROOT/platform/openwrt/owned-paths.txt" usr/lib/z2k/platform/openwrt/owned-paths.txt
for src in "$ROOT"/platform/openwrt/custom.d/*; do
    [ -f "$src" ] || continue
    copy_data "$src" "usr/lib/z2k/platform/openwrt/custom.d/$(basename "$src")" 0755
done
for src in "$ROOT"/platform/openwrt/webpanel-brand/*; do
    [ -f "$src" ] || continue
    copy_data "$src" "usr/lib/z2k/www/assets/openwrt/$(basename "$src")" 0644
done

copy_data "$ROOT/platform/openwrt/files/etc/init.d/z2k" etc/init.d/z2k 0755
copy_data "$ROOT/platform/openwrt/files/etc/init.d/z2k-webpanel" etc/init.d/z2k-webpanel 0755
copy_data "$ROOT/platform/openwrt/files/etc/hotplug.d/iface/90-z2k" etc/hotplug.d/iface/90-z2k 0755
copy_data "$ROOT/platform/openwrt/files/etc/sysctl.d/99-z2k.conf" etc/sysctl.d/99-z2k.conf
copy_data "$ROOT/platform/openwrt/files/usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft" \
    usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft
copy_data "$ROOT/platform/openwrt/files/etc/z2k/config.default" usr/lib/z2k/share/config.default
copy_data "$ROOT/platform/openwrt/z2kow.sh" usr/bin/z2kow 0755
copy_data "$ROOT/scripts/openwrt/install_release.sh" usr/sbin/install_release 0755
copy_data "$ROOT/files/z2k-warp-list-filter.awk" usr/lib/z2k/z2k-warp-list-filter.awk
copy_data "$ROOT/files/z2k-diag.sh" usr/lib/z2k/z2k-diag.sh 0755
for _key in "$RELEASE_KEYS_DIR"/*.pub; do
    [ -f "$_key" ] || continue
    _key_id=${_key##*/}
    _key_id=${_key_id%.pub}
    printf '%s' "$_key_id" | grep -Eq '^[0-9a-f]{64}$' \
        || die "имя файла открытого ключа должно быть его SHA-256-отпечатком в нижнем регистре: $_key_id"
    copy_data "$_key" "usr/lib/z2k/platform/openwrt/release-keys/$_key_id.pub"
done
_warpd_count=0
for _warpd in "$WARPD_DIR"/linux-*/z2k-warpd; do
    [ -f "$_warpd" ] || continue
    _arch=${_warpd#*/linux-}
    _arch=${_arch%/z2k-warpd}
    copy_data "$_warpd" "usr/lib/z2k/platform/openwrt/bin/linux-$_arch/z2k-warpd" 0755
    _warpd_count=$((_warpd_count + 1))
done
[ "$_warpd_count" -eq 7 ] || die "ожидалось 7 сборок z2k-warpd для разных архитектур, найдено: $_warpd_count"
_tg_count=0
for _tg in "$TG_DIR"/linux-*/tg-mtproxy-client; do
    [ -f "$_tg" ] || continue
    _arch=${_tg#*/linux-}
    _arch=${_arch%/tg-mtproxy-client}
    copy_data "$_tg" "usr/lib/z2k/bin/linux-$_arch/tg-mtproxy-client" 0755
    _tg_count=$((_tg_count + 1))
done
[ "$_tg_count" -eq 7 ] || die "ожидалось 7 проверенных сборок клиента Telegram для разных архитектур, найдено: $_tg_count"

_rt_count=0
for _rt in "$RT_DIR"/linux-*/z2k-rt-proxy; do
    [ -f "$_rt" ] || continue
    _arch=${_rt#*/linux-}
    _arch=${_arch%/z2k-rt-proxy}
    copy_data "$_rt" "usr/lib/z2k/bin/linux-$_arch/z2k-rt-proxy" 0755
    _rt_count=$((_rt_count + 1))
done
[ "$_rt_count" -eq 7 ] || die "ожидалось 7 сборок RT-прокси для разных архитектур, найдено: $_rt_count"
_detect_count=0
for _detect in "$DETECT_DIR"/linux-*/z2k-detect; do
    [ -f "$_detect" ] || continue
    _arch=${_detect#*/linux-}
    _arch=${_arch%/z2k-detect}
    copy_data "$_detect" "usr/lib/z2k/bin/linux-$_arch/z2k-detect" 0755
    _detect_count=$((_detect_count + 1))
done
[ "$_detect_count" -eq 7 ] || die "ожидалось 7 сборок детектора для разных архитектур, найдено: $_detect_count"
copy_data "$ROOT/platform/openwrt/bin/z2k-rt-proxy" usr/lib/z2k/bin/z2k-rt-proxy 0755
copy_data "$ROOT/platform/openwrt/bin/z2k-detect" usr/lib/z2k/bin/z2k-detect 0755

# Распаковать закреплённый архив dataplane в единый каталог релиза.
mkdir -p "$TMP/runtime"
tar -xzf "$RUNTIME_ARCHIVE" -C "$TMP/runtime" --strip-components=1 \
    || die "не удалось распаковать закреплённый runtime zapret2"
runtime="$TMP/runtime"
for _arch in arm arm64 mips mipsel riscv64 x86 x86_64; do
    for _binary in nfqws2 ip2net mdig; do
        [ -x "$runtime/binaries/linux-$_arch/$_binary" ] \
            || die "в архиве runtime отсутствует исполняемый linux-$_arch/$_binary"
    done
done
for path in \
    init.d/openwrt/functions:opt/zapret2/init.d/openwrt/functions \
    common/base.sh:opt/zapret2/common/base.sh \
    common/fwtype.sh:opt/zapret2/common/fwtype.sh \
    common/linux_iphelper.sh:opt/zapret2/common/linux_iphelper.sh \
    common/ipt.sh:opt/zapret2/common/ipt.sh \
    common/nft.sh:opt/zapret2/common/nft.sh \
    common/linux_fw.sh:opt/zapret2/common/linux_fw.sh \
    common/linux_daemons.sh:opt/zapret2/common/linux_daemons.sh \
    common/list.sh:opt/zapret2/common/list.sh \
    common/custom.sh:opt/zapret2/common/custom.sh \
    ipset/create_ipset.sh:opt/zapret2/ipset/create_ipset.sh \
    ipset/def.sh:opt/zapret2/ipset/def.sh; do
    src="${path%%:*}"; dst="${path#*:}"
    case "$src" in binaries/*|ipset/create_ipset.sh) mode=0755 ;; *) mode=0644 ;; esac
    copy_data "$runtime/$src" "$dst" "$mode"
done
mkdir -p "$STAGE/opt/zapret2/binaries"
cp -a "$runtime/binaries/." "$STAGE/opt/zapret2/binaries/" \
    || die "не удалось подготовить полный multi-architecture runtime upstream"

# Сохранить плоскую раскладку upstream: bootstrap создаёт runtime-ссылки
# прямо на эти файлы. Каталог с именем бинарника не является его заменой.
for _arch_dir in "$STAGE"/opt/zapret2/binaries/linux-*; do
    [ -d "$_arch_dir" ] || continue
    for _binary in nfqws2 ip2net mdig; do
        [ -f "$_arch_dir/$_binary" ] && [ -x "$_arch_dir/$_binary" ] \
            || die "в runtime нет исполняемого файла архитектуры: $_arch_dir/$_binary"
    done
done

for lua in zapret-lib zapret-antidpi zapret-auto; do
    src="$runtime/lua/$lua.lua.gz"
    [ -s "$src" ] || die "в архиве runtime нет файла $src"
    mkdir -p "$STAGE/opt/zapret2/lua"
    gzip -dc "$src" > "$STAGE/opt/zapret2/lua/$lua.lua" || die "не удалось распаковать $lua"
    chmod 0644 "$STAGE/opt/zapret2/lua/$lua.lua"
done

# Архив должен содержать полный payload, но не полномочия обновления,
# состояние пакетов, пользовательскую конфигурацию или файлы LuCI/uhttpd.
if find "$STAGE" -type f \( -name '*.apk' -o -name 'packages.adb' \) -print -quit | grep -q .; then
    die "в подготовленном payload найден APK или файл репозитория пакетов"
fi
if [ -e "$STAGE/www/cgi-bin/luci" ] || [ -e "$STAGE/www/luci-static" ] \
    || [ -e "$STAGE/etc/config/uhttpd" ] || [ -e "$STAGE/etc/apk" ]; then
    die "в подготовленном payload найден запрещённый путь LuCI/uhttpd или пакетного репозитория"
fi
printf 'подготовлен корень релиза OpenWrt: %s\n' "$STAGE"
