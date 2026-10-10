#!/bin/sh
# Начальная установка проверяет манифест и выбранный архив файлов роутера, затем
# запускает ту же транзакцию install_release(tag), что используется при обновлениях.
# apk применяется только для установки системных зависимостей OpenWrt.
set -eu

# Найти самую длинную точку монтирования пути, а не судить по имени устройства df.
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

# Сжатый архив хранится на постоянном разделе. Во временной памяти остаются
# только манифест, списки файлов и установочный код с ограниченным размером.
# Место для архива, распаковки и отката проверяется до загрузки.
z2k_ow_memory_preflight() {
    local _memory_path="$1" _archive_bytes="$2" _stage_bytes="$3" _engine_index_bytes="$4"
    local _memory_reserve="$5" _tmpfs_extra_bytes="${6:-0}" _memory_type _memory_available _free_kb
    local _memory_info="${Z2K_OW_MEMINFO_FILE:-/proc/meminfo}"
    _memory_type="$(z2k_ow_storage_type "$_memory_path")" || {
        echo "z2k-openwrt: не удалось определить тип временной файловой системы: $_memory_path" >&2
        return 1
    }
    for _budget_value in "$_archive_bytes" "$_stage_bytes" "$_engine_index_bytes" \
        "$_memory_reserve" "$_tmpfs_extra_bytes"; do
        case "$_budget_value" in ''|*[!0-9]*) echo "z2k-openwrt: неверная оценка временного бюджета" >&2; return 1 ;; esac
        [ "${#_budget_value}" -le 10 ] && [ "$_budget_value" -le 2147483647 ] 2>/dev/null \
            || { echo "z2k-openwrt: оценка временного бюджета выходит за допустимый диапазон" >&2; return 1; }
    done
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
    awk -v kind="$_memory_type" -v available="$_memory_available" \
        -v archive="$_archive_bytes" -v stage="$_stage_bytes" \
        -v engine="$_engine_index_bytes" -v reserve="$_memory_reserve" \
        -v tmpfs_extra="$_tmpfs_extra_bytes" '
        BEGIN {
            if (available !~ /^[0-9]+$/ || archive !~ /^[0-9]+$/ || stage !~ /^[0-9]+$/ \
                || engine !~ /^[0-9]+$/ || reserve !~ /^[0-9]+$/ || tmpfs_extra !~ /^[0-9]+$/) exit 1
            ram_archive = (kind == "tmpfs" || kind == "ramfs" || kind == "rootfs") ? archive : 0
            ram_needed = ram_archive + stage + engine + reserve
            if (available*1024 < ram_needed) {
                printf "z2k-openwrt: недостаточно свободной оперативной памяти для установщика и резерва (нужно %.0f байт; доступно %.0f КиБ)\n", ram_needed, available > "/dev/stderr"
                exit 1
            }
        }
    ' || return 1
    _free_kb=$(df -Pk "$_memory_path" 2>/dev/null | awk 'END { if (NR >= 2) print $4 }') || return 1
    case "$_free_kb" in ''|*[!0-9]*)
        echo "z2k-openwrt: не удалось определить свободное место во временном хранилище" >&2
        return 1 ;;
    esac
    awk -v free_kb="$_free_kb" -v archive="$_archive_bytes" \
        -v stage="$_stage_bytes" -v extra="$_tmpfs_extra_bytes" -v reserve="$_memory_reserve" '
        BEGIN {
            needed = archive + stage + extra + reserve
            if (free_kb !~ /^[0-9]+$/ || free_kb*1024 < needed) {
                printf "z2k-openwrt: недостаточно места во временном хранилище (нужно %.0f байт; доступно %.0f КиБ)\n", needed, free_kb > "/dev/stderr"
                exit 1
            }
        }'
}

# До загрузки проверить место на разделе, где одновременно будут лежать
# сжатый архив, файлы установщика и распакованная версия программы.
z2k_ow_disk_preflight() {
    local _disk_path="$1" _archive_bytes="$2" _payload_bytes="$3"
    local _engine_bytes="$4" _reserve_bytes="$5" _df _available_kb _mountpoint
    for _disk_bytes in "$_archive_bytes" "$_payload_bytes" "$_engine_bytes" "$_reserve_bytes"; do
        case "$_disk_bytes" in ''|*[!0-9]*) return 1 ;; esac
    done
    _df="$(df -Pk "$_disk_path" 2>/dev/null | awk 'END { if (NR >= 2) print $4 "|" $NF}')"
    _available_kb=${_df%%|*}
    _mountpoint=${_df#*|}
    case "$_available_kb" in ''|*[!0-9]*)
        echo "z2k-openwrt: не удалось определить свободное место для установки" >&2
        return 1
        ;;
    esac
    if ! awk -v available="$_available_kb" -v archive="$_archive_bytes" \
        -v payload="$_payload_bytes" -v engine="$_engine_bytes" -v reserve="$_reserve_bytes" \
        'BEGIN { exit (available * 1024 >= archive + payload + engine + reserve) ? 0 : 1 }'; then
        echo "z2k-openwrt: недостаточно места на разделе $_mountpoint (архив $_archive_bytes байт, распакованные файлы $_payload_bytes байт, установщик и списки до $_engine_bytes байт, запас для отката $_reserve_bytes байт; свободно $_available_kb КиБ)" >&2
        return 1
    fi
}

z2k_ow_positive_bytes() {
    local _value="$1"
    case "$_value" in ''|0|0*|*[!0-9]*) return 1 ;; esac
    [ "${#_value}" -le 10 ] && [ "$_value" -le 2147483647 ] 2>/dev/null
}

# Повторять правила arch.sh до проверки подписанного архива, поскольку общий
# установочный движок станет доступен только после извлечения его исходников.
z2k_ow_bootstrap_arch() {
    local _source="${DISTRIB_ARCH:-$(uname -m 2>/dev/null)}" _lower
    _lower="$(printf '%s' "$_source" | tr 'A-Z' 'a-z')"
    case "$_lower" in
        *aarch64*|*arm64*|*cortex-a53*|*cortex-a72*|*cortex-a76*) printf '%s\n' arm64 ;;
        *armv7*|*cortex-a7*|*cortex-a9*|*cortex-a15*) printf '%s\n' arm ;;
        *x86_64*|*amd64*) printf '%s\n' x86_64 ;;
        *i386*|*i686*|*x86*|*pentium*) printf '%s\n' x86 ;;
        *mips64el*|*mips64le*) return 1 ;;
        *mips_24kc*|*mips_74kc*|*mips_1004kc*) printf '%s\n' mips ;;
        *mipsel*|*mipsle*|*24kc*|*74kc*|*1004kc*) printf '%s\n' mipsel ;;
        *mips*) printf '%s\n' mips ;;
        *riscv64*) printf '%s\n' riscv64 ;;
        *) return 1 ;;
    esac
}

die() { printf 'установщик z2kOW: %s\n' "$*" >&2; exit 1; }
progress() { printf 'установщик z2kOW: %s\n' "$*" >&2; }
progress "проверяю совместимость OpenWrt и доступную память"
[ "$(id -u 2>/dev/null || echo 1)" = 0 ] || die "запустите установщик от имени суперпользователя"
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
    /^Shmem:/ { shmem=$2 }
    END {
        if (!found) available=free+buffers+cached-shmem
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
# ключ в список доверенных ключей до того, как им подпишут новый релиз.
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

progress "обновляю список системных программ"
apk update || die "не удалось обновить индексы системных зависимостей"
progress "устанавливаю средства проверки подписи и состава архива"
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

# Служебные файлы и временная копия установочного кода остаются во временном
# каталоге. Сжатый архив будет записан в существующий каталог транзакции ниже.
TMP="${Z2K_OW_BOOTSTRAP_TMP:-${TMPDIR:-/tmp}}/z2kow-bootstrap.$$"
(umask 077 && mkdir "$TMP") || die "не удалось создать временный каталог"
_install_work="${Z2K_OW_INSTALL_WORK:-}"
if [ -z "$_install_work" ]; then
    if [ -n "${Z2K_OW_SYSROOT:-}" ]; then
        _install_work="${Z2K_OW_SYSROOT%/}/usr/lib/.z2k-install"
    else
        _install_work=/usr/lib/.z2k-install
    fi
fi
case "$_install_work" in /*) ;; *) rm -rf "$TMP"; die "каталог транзакции должен иметь абсолютный путь" ;; esac
ARTIFACT="$_install_work/openwrt-rootfs-bootstrap.tar.gz"
ARTIFACT_OWNED=0
cleanup() {
    rm -rf "$TMP"
    if [ "$ARTIFACT_OWNED" = 1 ]; then rm -f "$ARTIFACT"; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

MANIFEST="$TMP/UPDATES.json"
SIGNATURE="$TMP/UPDATES.json.sig"
PUBKEY="$TMP/z2k-update-pub.pem"
ENGINE="$TMP/engine"

value() { jsonfilter -i "$MANIFEST" -e "@.$1" 2>/dev/null | head -n 1; }
value_type() { jsonfilter -i "$MANIFEST" -t "@.$1" 2>/dev/null | head -n 1; }

progress "получаю манифест выпусков"
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
progress "проверяю подпись манифеста выпусков"
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
_arch=$(z2k_ow_bootstrap_arch) || die "архитектура роутера не поддерживается"
progress "выбираю архив для архитектуры $_arch, выпуск $_tag"
_artifacts_type=$(value_type artifacts)
case "$_artifacts_type" in
    '')
        _artifact_prefix=artifact
        _expected_filename=openwrt-rootfs.tar.gz
        _unpacked=
        ;;
    object)
        _artifact_prefix="artifacts.$_arch"
        _expected_filename="openwrt-rootfs-$_arch.tar.gz"
        _unpacked=$(value "$_artifact_prefix.unpacked_size_bytes")
        z2k_ow_positive_bytes "$_unpacked" \
            || die "проверенный UPDATES.json содержит неверный распакованный размер для $_arch"
        ;;
    *) die "проверенный UPDATES.json содержит неверную карту архитектурных архивов" ;;
esac
_filename=$(value "$_artifact_prefix.filename")
_url=$(value "$_artifact_prefix.url")
_sha=$(value "$_artifact_prefix.sha256" | tr 'A-F' 'a-f')
_size=$(value "$_artifact_prefix.size_bytes")
_expected_filename_escaped=$(printf '%s' "$_expected_filename" | sed 's/[.]/\\./g')
if [ "$_acceptance_source" = 1 ]; then
    _expected_artifact_url="${Z2KOW_MANIFEST_URL%/UPDATES.json}/$_expected_filename"
    [ "$_filename" = "$_expected_filename" ] && [ "$_url" = "$_expected_artifact_url" ] \
        || die "проверенный UPDATES.json содержит неверный URL архива"
else
    [ "$_filename" = "$_expected_filename" ] \
        && printf '%s' "$_url" | grep -Eq "^https://github[.]com/t0fox/z2kOW/releases/download/(openwrt-[0-9a-f]{40}|[pr]-[0-9]+([.][0-9]+)+)/$_expected_filename_escaped\$" \
        || die "проверенный UPDATES.json содержит неверный URL архива"
fi
printf '%s' "$_sha" | grep -Eq '^[0-9a-f]{64}$' \
    || die "проверенный UPDATES.json содержит неверный SHA-256"
z2k_ow_positive_bytes "$_size" \
    || die "проверенный UPDATES.json содержит неверный размер архива"
_engine_index_budget=2097152
_safety_reserve=8388608
z2k_ow_memory_preflight "$TMP" 0 0 \
    "$_engine_index_budget" "$_safety_reserve" "$_engine_index_budget" \
    || die "архив и установочный код не помещаются в доступную оперативную память и временное хранилище"
if [ -L "$_install_work" ]; then
    die "каталог транзакции является символической ссылкой: $_install_work"
fi
mkdir -p "$_install_work" || die "не удалось подготовить каталог транзакции"
[ -d "$_install_work" ] && [ ! -L "$_install_work" ] \
    || die "каталог транзакции является ссылкой или не является каталогом"
if [ -e "$ARTIFACT" ] || [ -L "$ARTIFACT" ]; then
    [ -f "$ARTIFACT" ] && [ ! -L "$ARTIFACT" ] \
        || die "временный путь архива повреждён или подменён: $ARTIFACT"
    rm -f "$ARTIFACT" || die "не удалось удалить архив предыдущей попытки"
fi
_old_stage="$_install_work/stage"
_old_stage_owner="${_old_stage}.owner"
if [ -e "$_old_stage" ] || [ -L "$_old_stage" ] \
    || [ -e "$_old_stage_owner" ] || [ -L "$_old_stage_owner" ]; then
    [ -d "$_old_stage" ] && [ ! -L "$_old_stage" ] \
        && [ -f "$_old_stage_owner" ] && [ ! -L "$_old_stage_owner" ] \
        && [ "$(cat "$_old_stage_owner" 2>/dev/null)" = "z2kow-overlay-stage-v1" ] \
        || die "найдена временная распаковка без правильной метки владельца; оставлена без изменений: $_old_stage"
    rm -rf "$_old_stage" "$_old_stage_owner" \
        || die "не удалось очистить распаковку, оставшуюся после прерванной установки"
fi
z2k_ow_disk_preflight "$_install_work" "$_size" "${_unpacked:-0}" \
    "$_engine_index_budget" "$_safety_reserve" \
    || die "на разделе недостаточно места для безопасной загрузки и установки"

ARTIFACT_OWNED=1
progress "скачиваю архив выбранной архитектуры"
download "$_url" "$ARTIFACT" || die "не удалось скачать архив релиза $_tag"
[ "$(wc -c < "$ARTIFACT" | tr -d ' \t\r\n')" = "$_size" ] \
    || die "размер архива файлов роутера не совпал с проверенным UPDATES.json"
[ "$(sha256sum "$ARTIFACT" | awk '{print $1}')" = "$_sha" ] \
    || die "SHA-256 архива файлов роутера не совпал с проверенным UPDATES.json"
progress "размер и SHA-256 архива подтверждены"

# Извлечь исходные файлы установочного движка из того же подписанного архива.
# Состав определяется по архиву, чтобы совпадать с файлами, которые подключает
# install_release. Исполняемые файлы и рабочие данные программы не попадают
# в отдельную копию установочного кода.
mkdir -p "$ENGINE"
progress "проверяю состав архива и готовлю установочный код"
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
_measured_payload_bytes=$(awk -v arch="$_arch" '
    $1 ~ /^-/ && $3 ~ /^[0-9]+$/ {
        path=$NF; sub(/\/$/, "", path); split(path, part, "/")
        if (part[1] == "usr" && part[2] == "lib" && part[3] == "z2k" && part[4] == "bin" && part[5] ~ /^linux-/ && part[5] != ("linux-" arch)) next
        if (part[1] == "usr" && part[2] == "lib" && part[3] == "z2k" && part[4] == "platform" && part[5] == "openwrt" && part[6] == "bin" && part[7] ~ /^linux-/ && part[7] != ("linux-" arch)) next
        if (part[1] == "opt" && part[2] == "zapret2" && part[3] == "binaries" && part[4] ~ /^linux-/ && part[4] != ("linux-" arch)) next
        total += $3
    }
    END { printf "%.0f\n", total }
' "$_archive_details") || die "не удалось измерить размер выбранных файлов релиза"
case "$_measured_payload_bytes" in ''|*[!0-9]*) die "не удалось измерить размер выбранных файлов релиза" ;; esac
if [ -n "$_unpacked" ]; then
    [ "$_measured_payload_bytes" -le "$_unpacked" ] \
        || die "размер выбранных файлов превышает подписанную оценку"
fi
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
        || die "подписанный архив не содержит обязательный файл установочного кода: $_required"
done
_budget_used=$(awk -v members="$_archive_members" -v details="$_archive_details" \
    -v engine_files="$_engine_files" -v detail_path="$_archive_details" '
    BEGIN {
        while ((getline path < engine_files) > 0) engine[path]=1
        close(engine_files)
        while ((getline line < members) > 0) members_bytes += length(line)+1
        close(members)
        while ((getline line < details) > 0) details_bytes += length(line)+1
        close(details)
    }
    $1 ~ /^-/ && $3 ~ /^[0-9]+$/ {
        path=$NF
        if (path in engine) engine_bytes += $3
    }
    END { printf "%.0f\n", members_bytes+details_bytes+engine_bytes }
' "$_archive_details") || die "не удалось оценить объём установочного кода и списков файлов архива"
case "$_budget_used" in ''|*[!0-9]*) die "не удалось оценить объём установочного кода и списков файлов архива" ;; esac
if [ "$_budget_used" -gt "$_engine_index_budget" ]; then
    die "установочный код и списки файлов превышают отведённый предел памяти"
fi
_engine_index_remaining=$((_engine_index_budget - _budget_used))
z2k_ow_memory_preflight "$TMP" 0 0 \
    "$_engine_index_remaining" "$_safety_reserve" "$_engine_index_remaining" \
    || die "после проверки архива осталось недостаточно оперативной памяти или места во временном хранилище"
# BusyBox tar не во всех сборках поддерживает -T. Передавать проверенные имена
# аргументами с нулевым разделителем и ограничивать размер каждой команды.
tr '\n' '\000' < "$_engine_files" \
    | xargs -0 -r -s 32768 tar -xzf "$ARTIFACT" -C "$ENGINE" \
    || die "не удалось извлечь установочный код из подписанного архива"
[ -x "$ENGINE/usr/sbin/install_release" ] || die "в архиве отсутствует основной install_release"
z2k_ow_memory_preflight "$TMP" 0 0 0 "$_safety_reserve" 0 \
    || die "после подготовки установочного кода недостаточно оперативной памяти или временного места для распаковки"

# Каталог программы находится на файловой системе роутера. Из временной распаковки берутся
# только установочный код и исходники библиотек.
Z2K_ROOT=/usr/lib/z2k
Z2K_ADAPTER_DIR="$ENGINE/usr/lib/z2k/platform/openwrt"
Z2K_LIB="$ENGINE/usr/lib/z2k/lib"
Z2K_AU_PUBKEY="$PUBKEY"
Z2K_OW_BOOTSTRAP_MANIFEST="$MANIFEST"
Z2K_OW_BOOTSTRAP_SIGNATURE="$SIGNATURE"
Z2K_OW_BOOTSTRAP_ARTIFACT="$ARTIFACT"
Z2K_OW_BOOTSTRAP_PUBLIC_KEY="$PUBKEY"
Z2K_OW_INSTALL_TMP="${Z2K_OW_INSTALL_TMP:-$TMP}"
Z2K_OW_INSTALL_WORK="$_install_work"
export Z2K_ROOT Z2K_ADAPTER_DIR Z2K_LIB Z2K_AU_PUBKEY \
    Z2K_OW_BOOTSTRAP_PUBLIC_KEY Z2K_OW_INSTALL_TMP \
    Z2K_OW_INSTALL_WORK Z2K_OW_BOOTSTRAP_MANIFEST Z2K_OW_BOOTSTRAP_SIGNATURE Z2K_OW_BOOTSTRAP_ARTIFACT
progress "передаю проверенный выпуск общей процедуре install_release"
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
