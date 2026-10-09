#!/bin/sh
# Начальная установка проверяет манифест и полный архив rootfs, затем запускает
# ту же транзакцию install_release(tag), что используется при обновлениях.
# apk применяется только для установки системных зависимостей OpenWrt.
set -eu

# Сопоставить путь с самым длинным mountpoint, а не с именем устройства df.
z2k_ow_storage_type() {
    local _storage_path _mountinfo="${Z2K_OW_MOUNTINFO_FILE:-/proc/self/mountinfo}"
    _storage_path="$(readlink -f "$1" 2>/dev/null)" || return 1
    [ -n "$_storage_path" ] && [ -r "$_mountinfo" ] || return 1
    Z2K_STORAGE_PATH="$_storage_path" awk '
        BEGIN { path=ENVIRON["Z2K_STORAGE_PATH"] }
        {
            point=$5
            gsub(/\\040/, " ", point)
            gsub(/\\011/, "\t", point)
            if (point == "/" || path == point || index(path, point "/") == 1) {
                if (length(point) > longest) {
                    for (i=6; i<=NF; i++) if ($i == "-") {
                        kind=$(i+1); longest=length(point); break
                    }
                }
            }
        }
        END { if (kind == "") exit 1; print kind }
    ' "$_mountinfo"
}

# Свободная ёмкость tmpfs не равна физической RAM: бюджет проверяется отдельно.
# На дисковом хранилище архив целиком не резервирует оперативную память.
z2k_ow_memory_preflight() {
    local _memory_path="$1" _memory_bytes="$2" _memory_reserve="$3" _memory_type _memory_available
    local _memory_info="${Z2K_OW_MEMINFO_FILE:-/proc/meminfo}"
    _memory_type="$(z2k_ow_storage_type "$_memory_path")" || {
        echo "z2k-openwrt: не удалось определить тип временной файловой системы: $_memory_path" >&2
        return 1
    }
    case "$_memory_type" in tmpfs|ramfs|rootfs) ;; *) return 0 ;; esac
    [ -r "$_memory_info" ] || return 1
    _memory_available=$(awk '
        /^MemAvailable:/ { available=$2; found=1 }
        /^MemFree:/ { free=$2; fallback=1 }
        /^Buffers:/ { buffers=$2 }
        /^Cached:/ { cached=$2 }
        /^Shmem:/ { shmem=$2 }
        END {
            if (!found && !fallback) exit 1
            if (!found) available=free+buffers+cached-shmem
            if (available < 0) available=0
            if (available ~ /^[0-9]+$/) printf "%.0f\n", available
            else exit 1
        }
    ' "$_memory_info") || return 1
    [ -n "$_memory_available" ] || return 1
    awk -v available="$_memory_available" -v bytes="$_memory_bytes" -v reserve="$_memory_reserve" '
        BEGIN {
            if (bytes !~ /^[0-9]+$/ || reserve !~ /^[0-9]+$/) exit 1
            if (available*1024 < bytes+reserve) {
                printf "z2k-openwrt: недостаточно RAM для временного хранилища (нужно %.0f байт с резервом; доступно %.0f КиБ)\n", bytes+reserve, available > "/dev/stderr"
                exit 1
            }
        }
    '
}

die() { printf 'установщик z2kOW: %s\n' "$*" >&2; exit 1; }
[ "$(id -u 2>/dev/null || echo 1)" = 0 ] || die "запустите установщик от root"
OPENWRT_RELEASE_FILE="${Z2K_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"
[ -r "$OPENWRT_RELEASE_FILE" ] || die "это не OpenWrt"
. "$OPENWRT_RELEASE_FILE"
[ "${DISTRIB_ID:-}" = OpenWrt ] || die "поддерживается только OpenWrt"
_openwrt_release=${DISTRIB_RELEASE:-}
case "$_openwrt_release" in
    SNAPSHOT) ;;
    *)
        awk -v version="$_openwrt_release" 'BEGIN {
            if (!match(version, /^[0-9]+\.[0-9]+/)) exit 1
            split(substr(version, RSTART, RLENGTH), part, /\./)
            exit !((part[1] > 24) || (part[1] == 24 && part[2] >= 10))
        }' || die "поддерживается OpenWrt 24.10 или новее с apk"
        ;;
esac
_meminfo=${Z2K_OW_MEMINFO_FILE:-/proc/meminfo}
[ -r "$_meminfo" ] || die "не удалось определить объём свободной оперативной памяти"
_mem_available_kb=$(awk '
    /^MemAvailable:/ { available=$2; found=1 }
    /^MemFree:/ { free=$2 }
    /^Buffers:/ { buffers=$2 }
    /^Cached:/ { cached=$2 }
    END {
        if (!found) available=free+buffers+cached
        if (available ~ /^[0-9]+$/) printf "%.0f\n", available
    }
' "$_meminfo")
case "$_mem_available_kb" in ''|*[!0-9]*) die "не удалось определить объём свободной оперативной памяти" ;; esac
if [ "$_mem_available_kb" -lt 8192 ]; then
    die "недостаточно оперативной памяти: требуется 8192 КиБ, доступно $_mem_available_kb КиБ"
fi
command -v apk >/dev/null 2>&1 || die "нужен OpenWrt с apk для системных зависимостей"

BASE="https://raw.githubusercontent.com/t0fox/z2kOW/main"
# Здесь закреплены отпечатки доверенных ключей выпуска. При ротации сохраняйте
# старые отпечатки: уже опубликованный релиз должен добавить следующий открытый
# ключ в keyring до того, как этим ключом подпишут новый релиз.
BOOTSTRAP_TRUSTED_KEY_IDS="916b1459a03961d66af48ddb2165afbed3c0d7445f75c8b7c95adbb5fc044bae"
_manifest_override_set=${Z2KOW_MANIFEST_URL+x}
_trust_override_set=${Z2KOW_TRUST_KEY+x}
if [ "$_manifest_override_set" != "$_trust_override_set" ]; then
    die "Z2KOW_MANIFEST_URL и Z2KOW_TRUST_KEY должны задаваться вместе"
fi
if [ "$_manifest_override_set" = x ]; then
    [ -n "$Z2KOW_MANIFEST_URL" ] && [ -n "$Z2KOW_TRUST_KEY" ] \
        || die "Z2KOW_MANIFEST_URL и Z2KOW_TRUST_KEY должны задаваться вместе"
    case "$Z2KOW_MANIFEST_URL" in
        http://*/UPDATES.json|https://*/UPDATES.json) ;;
        *) die "адрес приёмочного манифеста должен оканчиваться на /UPDATES.json" ;;
    esac
    [ -f "$Z2KOW_TRUST_KEY" ] && [ -r "$Z2KOW_TRUST_KEY" ] \
        || die "приёмочный открытый ключ недоступен для чтения"
    _acceptance_source=1
    MANIFEST_URL=$Z2KOW_MANIFEST_URL
else
    _acceptance_source=0
    MANIFEST_URL="$BASE/UPDATES.json"
fi
SIGNATURE_URL="$MANIFEST_URL.sig"

apk update || die "не удалось обновить индексы системных зависимостей"
apk add ca-bundle openssl-util jsonfilter || die "не удалось установить системные средства проверки подписи"
for _tool in awk df grep openssl readlink sha256sum tar tr xargs; do
    command -v "$_tool" >/dev/null 2>&1 || die "необходимая системная команда отсутствует: $_tool"
done
command -v jsonfilter >/dev/null 2>&1 || die "после установки системных зависимостей отсутствует jsonfilter"

if command -v wget >/dev/null 2>&1; then
    download() { wget -q -T 60 -O "$2" "$1"; }
elif command -v curl >/dev/null 2>&1; then
    download() { curl --fail --location --silent --show-error --connect-timeout 10 --max-time 600 -o "$2" "$1"; }
else
    die "нужен wget или curl"
fi

TMP="${TMPDIR:-/tmp}/z2kow-bootstrap.$$"
(umask 077 && mkdir "$TMP") || die "не удалось создать временный каталог"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

MANIFEST="$TMP/UPDATES.json"
SIGNATURE="$TMP/UPDATES.json.sig"
PUBKEY="$TMP/z2k-update-pub.pem"
ARTIFACT="$TMP/openwrt-rootfs.tar.gz"
ENGINE="$TMP/engine"

value() { jsonfilter -i "$MANIFEST" -e "@.$1" 2>/dev/null | head -n 1; }

download "$MANIFEST_URL" "$MANIFEST" || die "не удалось получить проверенный UPDATES.json"
_key_id=$(value signing.key_id)
printf '%s' "$_key_id" | grep -Eq '^[0-9a-f]{64}$' \
    || die "проверенный UPDATES.json содержит неверный идентификатор ключа подписи"

# Этот ключ закреплён в самом установщике. Если загружать его рядом с
# манифестом, подменённый манифест сможет подменить и собственный корень доверия.
if [ "$_acceptance_source" = 1 ]; then
    cp "$Z2KOW_TRUST_KEY" "$PUBKEY" || die "не удалось подготовить приёмочный открытый ключ"
else
    case " $BOOTSTRAP_TRUSTED_KEY_IDS " in
        *" $_key_id "*) ;;
        *) die "манифест ссылается на незакреплённый ключ выпуска" ;;
    esac
    download "$BASE/scripts/openwrt/release-keys/$_key_id.pub" "$PUBKEY" \
        || die "не удалось получить закреплённый открытый ключ выпуска"
fi
_actual_key_id=$(openssl pkey -pubin -in "$PUBKEY" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
[ "$_actual_key_id" = "$_key_id" ] || die "отпечаток ключа выпуска не совпадает с проверенным UPDATES.json"

download "$SIGNATURE_URL" "$SIGNATURE" || die "нет подписи проверенного UPDATES.json; релиз не опубликован"
openssl pkeyutl -verify -rawin -pubin -inkey "$PUBKEY" \
    -in "$MANIFEST" -sigfile "$SIGNATURE" >/dev/null 2>&1 \
    || die "подпись проверенного UPDATES.json неверна"

_schema=$(value schema)
_branch=$(value branch)
_platform=$(value platform)
_tag=$(value current)
_seq=$(value seq)
_upstream_repo=$(value upstream.repository)
_upstream_branch=$(value upstream.branch)
_upstream_tag=$(value upstream.tag)
_upstream_commit=$(value upstream.commit)
_filename=$(value artifact.filename)
_url=$(value artifact.url)
_sha=$(value artifact.sha256 | tr 'A-F' 'a-f')
_size=$(value artifact.size_bytes)
[ "$_schema" = 1 ] && [ "$_branch" = main ] && [ "$_platform" = openwrt ] \
    || die "проверенный UPDATES.json имеет неподдерживаемую схему"
printf '%s' "$_tag" | grep -Eq '^[pr]-[0-9]+(\.[0-9]+)+$' \
    || die "проверенный UPDATES.json содержит неверную версию релиза"
printf '%s' "$_seq" | grep -Eq '^[1-9][0-9]*$' \
    || die "проверенный UPDATES.json содержит неверный номер версии"
[ "$_upstream_repo" = necronicle/z2k ] \
    && [ "$_upstream_branch" = z2k-enhanced ] && [ "$_upstream_tag" = "$_tag" ] \
    || die "проверенный UPDATES.json содержит неверные исходные сведения upstream"
printf '%s' "$_upstream_commit" | grep -Eq '^[0-9a-f]{40}$' \
    || die "проверенный UPDATES.json содержит неверный коммит upstream"
if [ "$_acceptance_source" = 1 ]; then
    _expected_artifact_url="${Z2KOW_MANIFEST_URL%/UPDATES.json}/openwrt-rootfs.tar.gz"
    [ "$_filename" = openwrt-rootfs.tar.gz ] && [ "$_url" = "$_expected_artifact_url" ] \
        || die "проверенный UPDATES.json содержит неверный URL архива"
else
    [ "$_filename" = openwrt-rootfs.tar.gz ] \
        && printf '%s' "$_url" | grep -Eq '^https://github[.]com/t0fox/z2kOW/releases/download/(openwrt-[0-9a-f]{40}|[pr]-[0-9]+([.][0-9]+)+)/openwrt-rootfs[.]tar[.]gz$' \
        || die "проверенный UPDATES.json содержит неверный URL архива"
fi
printf '%s' "$_sha" | grep -Eq '^[0-9a-f]{64}$' \
    || die "проверенный UPDATES.json содержит неверный SHA-256"
printf '%s' "$_size" | grep -Eq '^[1-9][0-9]*$' \
    || die "проверенный UPDATES.json содержит неверный размер архива"

_tmp_available_kb=$(df -Pk "$TMP" 2>/dev/null | awk 'END { if (NR >= 2) print $4 }')
case "$_tmp_available_kb" in ''|*[!0-9]*) die "не удалось определить свободное место во временном хранилище" ;; esac
if ! awk -v available_kb="$_tmp_available_kb" -v artifact_bytes="$_size" \
    'BEGIN { exit (available_kb * 1024 >= artifact_bytes + 4194304) ? 0 : 1 }'; then
    die "недостаточно места во временном хранилище: требуется $_size байт архива плюс 4 МиБ, доступно $_tmp_available_kb КиБ"
fi

z2k_ow_memory_preflight "$TMP" "$_size" 4194304 \
    || die "архив не помещается в доступную оперативную память"

download "$_url" "$ARTIFACT" || die "не удалось скачать полный выпуск $_tag"
[ "$(wc -c < "$ARTIFACT" | tr -d ' \t\r\n')" = "$_size" ] \
    || die "размер rootfs не совпал с проверенным UPDATES.json"
[ "$(sha256sum "$ARTIFACT" | awk '{print $1}')" = "$_sha" ] \
    || die "SHA-256 rootfs не совпал с проверенным UPDATES.json"

# Извлечь все shell-исходники движка из того же подписанного архива.
# Состав выбирается по содержимому архива, чтобы список установщика не расходился
# с файлами, которые подключает install_release. Runtime-файлы и бинарники роутера
# во временную копию движка не попадают.
mkdir -p "$ENGINE"
_archive_members="$TMP/archive-members"
_engine_files="$TMP/engine-files"
_archive_details="$TMP/archive-details"
tar -tzf "$ARTIFACT" > "$_archive_members" \
    || die "не удалось прочитать список файлов подписанного rootfs"
tar -tvzf "$ARTIFACT" > "$_archive_details" \
    || die "не удалось прочитать типы файлов подписанного rootfs"
awk '
    function safe_link(path, target, path_parts, path_count, depth, target_parts, target_count, i) {
        if (target == "" || target ~ /^\// || target ~ /\\/ || target ~ /\/\// \
            || target ~ /[[:space:][:cntrl:]]/) return 0
        path_count = split(path, path_parts, "/")
        depth = path_count - 1
        target_count = split(target, target_parts, "/")
        for (i = 1; i <= target_count; i++) {
            if (target_parts[i] == "" || target_parts[i] == ".") continue
            if (target_parts[i] == "..") {
                if (depth == 0) return 0
                depth--
            } else {
                depth++
            }
        }
        return 1
    }
    {
        kind = substr($1, 1, 1)
        if (kind != "-" && kind != "d" && kind != "l") exit 1
        if (kind == "l") {
            if (NF < 3 || $(NF - 1) != "->") exit 1
            path = $(NF - 2)
            target = $NF
            if (!safe_link(path, target)) exit 1
        } else {
            path = $NF
        }
        if (path ~ /\/\//) exit 1
        sub(/\/$/, "", path)
        if (path == "" || path ~ /^\// || path ~ /[[:space:][:cntrl:]]/ \
            || path ~ /\\/ || path ~ /(^|\/)\.\.?($|\/)/) exit 1
        if (path == "www" || path ~ /^www\// || path == "etc/config/uhttpd" \
            || path == "etc/apk" || path ~ /^etc\/apk\// \
            || path ~ /(^|\/)[^\/]+\.apk$/) exit 1
        count++
    }
    END { if (count == 0) exit 1 }
' "$_archive_details" || die "архив содержит небезопасный тип записи, путь или цель ссылки"
awk '
    {
        path = $0
        safe = path !~ /(^|\/)\.\.?($|\/)/ && path !~ /[[:space:]]/ && index(path, "\\") == 0
        engine = path ~ /^usr\/lib\/z2k\/lib\/.+\.sh$/ ||
            path ~ /^usr\/lib\/z2k\/platform\/openwrt\/.+\.sh$/ ||
            path == "usr/lib/z2k/platform/openwrt/owned-paths.txt" ||
            path == "usr/sbin/install_release" || path == "usr/bin/z2kow"
        if (safe && engine) print path
    }
' "$_archive_members" > "$_engine_files" || die "не удалось определить файлы установочного движка"
for _required in \
    usr/lib/z2k/lib/utils.sh \
    usr/lib/z2k/lib/auto_update.sh \
    usr/lib/z2k/platform/openwrt/paths.sh \
    usr/lib/z2k/platform/openwrt/env.sh \
    usr/lib/z2k/platform/openwrt/manifest.sh \
    usr/lib/z2k/platform/openwrt/release_state.sh \
    usr/lib/z2k/platform/openwrt/release.sh \
    usr/lib/z2k/platform/openwrt/recover_boot.sh \
    usr/lib/z2k/platform/openwrt/bootstrap.sh \
    usr/lib/z2k/platform/openwrt/arch.sh \
    usr/lib/z2k/platform/openwrt/owned-paths.txt \
    usr/sbin/install_release usr/bin/z2kow; do
    grep -qx "$_required" "$_engine_files" \
        || die "подписанный rootfs не содержит обязательный файл движка установки: $_required"
done
# BusyBox tar не во всех сборках поддерживает -T. Передавать проверенные имена
# аргументами с нулевым разделителем и ограничивать размер каждой команды.
tr '\n' '\000' < "$_engine_files" \
    | xargs -0 -r -s 32768 tar -xzf "$ARTIFACT" -C "$ENGINE" \
    || die "не удалось извлечь install engine из подписанного rootfs"
[ -x "$ENGINE/usr/sbin/install_release" ] || die "основной install_release отсутствует в rootfs"

# Каталог payload — файловая система роутера. Из временной распаковки берутся
# только установочный код и исходники библиотек.
Z2K_ROOT=/usr/lib/z2k
Z2K_ADAPTER_DIR="$ENGINE/usr/lib/z2k/platform/openwrt"
Z2K_LIB="$ENGINE/usr/lib/z2k/lib"
Z2K_AU_PUBKEY="$PUBKEY"
Z2K_OW_BOOTSTRAP_MANIFEST="$MANIFEST"
Z2K_OW_BOOTSTRAP_SIGNATURE="$SIGNATURE"
Z2K_OW_BOOTSTRAP_ARTIFACT="$ARTIFACT"
Z2K_OW_BOOTSTRAP_PUBLIC_KEY="$PUBKEY"
export Z2K_ROOT Z2K_ADAPTER_DIR Z2K_LIB Z2K_AU_PUBKEY \
    Z2K_OW_BOOTSTRAP_PUBLIC_KEY \
    Z2K_OW_BOOTSTRAP_MANIFEST Z2K_OW_BOOTSTRAP_SIGNATURE Z2K_OW_BOOTSTRAP_ARTIFACT
"$ENGINE/usr/sbin/install_release" "$_tag"

cat <<'NOTICE'

ВАЖНО ДЛЯ WINDOWS
Если через z2kOW будут работать Windows-клиенты, включите TCP timestamps
в командной строке от имени администратора:

  netsh interface tcp set global timestamps=enabled

Вернуть как было:
  netsh interface tcp set global timestamps=disabled

Подробнее: README.md → Windows.
NOTICE
