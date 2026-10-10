#!/bin/sh
# Проверяет совокупный RAM/tmpfs-пик через функции установщика.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-memory-budget"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/platform/openwrt/release.sh"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM

if ! command -v z2k_ow_storage_type >/dev/null 2>&1 \
    || ! command -v z2k_ow_memory_preflight >/dev/null 2>&1; then
    _t_bad "движок релиза экспортирует storage_type и memory_preflight"
    _t_done
    exit 1
fi

OV="$T/overlay"
mkdir -p "$OV"
MEM="$T/meminfo"
MOUNTS="$T/mountinfo"
DF="$T/df.out"
DF_PATH="$T/df.path"
printf '1 0 0:1 / / rw - tmpfs tmpfs rw\n' > "$MOUNTS"
export Z2K_OW_MEMINFO_FILE="$MEM" Z2K_OW_MOUNTINFO_FILE="$MOUNTS"
df() {
    [ "${1:-}" = -Pk ] && { [ "${2:-}" = "$OV/archive.tar.gz" ] || [ "${2:-}" = "$OV" ]; } \
        || { _t_bad "preflight must query free bytes for the selected temporary or disk workspace"; return 1; }
    printf '%s\n' "$2" >> "$DF_PATH"
    cat "$DF"
}

assert_eq "type of tmpfs workspace" tmpfs "$(z2k_ow_storage_type "$OV/archive.tar.gz")"

# 128 MiB guest: the archive itself fits, but archive + target payload +
# engine/index bound + reserve exceeds the current MemAvailable.
printf 'MemTotal: 131072 kB\nMemAvailable: 65536 kB\n' > "$MEM"
printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 131072 65536 65536 50%% /tmp\n' > "$DF"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 12582912 41943040 12582912 8388608 12582912; then
    _t_bad "128 MiB RAM rejects a combined peak even when the 12 MiB archive alone fits"
else
    _t_ok
fi

# The expanded target is staged on overlay after digest validation, so it must
# be checked there rather than charged to tmpfs/RAM. This mirrors the measured
# 128 MiB guest: 26.5 MiB currently available, 13.5 MiB archive, 2 MiB
# bootstrap/index allowance and 8 MiB headroom.
printf 'MemTotal: 131072 kB\nMemAvailable: 26544 kB\n' > "$MEM"
printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 131072 65536 65536 50%% /tmp\n' > "$DF"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 14132028 0 2097152 8388608 2097152; then
    _t_ok
else
    _t_bad "128 MiB RAM accepts selected archive plus measured engine/index and reserve when stage is disk-backed"
fi
printf 'MemTotal: 131072 kB\nMemAvailable: 23000 kB\n' > "$MEM"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 14132028 0 2097152 8388608 2097152; then
    _t_bad "128 MiB RAM still rejects when current MemAvailable is below archive + engine/index + reserve"
else
    _t_ok
fi

# На устройстве с 64 МиБ ОЗУ архив и распакованные файлы остаются на диске;
# в памяти и временном хранилище нужны только установщик, списки файлов и резерв.
printf 'MemTotal: 65536 kB\nMemAvailable: 14336 kB\n' > "$MEM"
printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 65536 45056 20480 69%% /tmp\n' > "$DF"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 0 0 2097152 8388608 2097152; then
    _t_ok
else
    _t_bad "профиль 64 МиБ допускает архив на диске, если хватает памяти установщику и резерва временного хранилища"
fi
printf 'MemTotal: 65536 kB\nMemAvailable: 9000 kB\n' > "$MEM"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 0 0 2097152 8388608 2097152; then
    _t_bad "профиль 64 МиБ отказывает, если текущей свободной памяти меньше установщика и резерва"
else
    _t_ok
fi

# Same archive and payload fit in a 256 MiB guest with 160 MiB currently free.
printf 'MemTotal: 262144 kB\nMemAvailable: 163840 kB\n' > "$MEM"
printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 262144 102400 159744 40%% /tmp\n' > "$DF"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 12582912 41943040 12582912 8388608 12582912; then
    _t_ok
else
    _t_bad "256 MiB profile accepts a fitting aggregate peak"
fi

# A large RAM budget does not allow an aggregate tmpfs peak above exact free bytes.
printf 'MemTotal: 262144 kB\nMemAvailable: 163840 kB\n' > "$MEM"
printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 131072 65536 65536 50%% /tmp\n' > "$DF"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 12582912 41943040 12582912 8388608 12582912; then
    _t_bad "tmpfs rejects the aggregate archive + stage + engine/index + reserve peak"
else
    _t_ok
fi

# A second check after archive and indexes are allocated reserves only the
# remaining stage and safety margin; the live archive is not double-counted.
printf 'MemTotal: 131072 kB\nMemAvailable: 53248 kB\n' > "$MEM"
printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 131072 80000 51072 61%% /tmp\n' > "$DF"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 0 41943040 0 8388608 0; then
    _t_ok
else
    _t_bad "post-download check counts only remaining stage and reserve"
fi

# Constrained free bytes in the exact tmpfs fail even when live RAM is ample.
printf 'MemTotal: 262144 kB\nMemAvailable: 163840 kB\n' > "$MEM"
printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 131072 120000 11000 92%% /tmp\n' > "$DF"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 0 41943040 0 8388608 0; then
    _t_bad "tmpfs free space includes the remaining target stage and reserve"
else
    _t_ok
fi

# Legacy manifests have no unpacked-size estimate. Check archive + engine/index
# + reserve before downloading; the measured target payload is reserved later.
printf 'MemTotal: 131072 kB\nMemAvailable: 30000 kB\n' > "$MEM"
printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 131072 32768 98304 25%% /tmp\n' > "$DF"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 12582912 0 12582912 8388608 12582912; then
    _t_bad "legacy archive rejects when archive + engine/index + reserve exceeds current RAM"
else
    _t_ok
fi

# A disk-backed workspace does not count the whole compressed archive as RAM,
# but it still checks live stage/engine demand and the disk's available bytes.
printf '1 0 0:1 / / rw - ext4 /dev/root rw\n' > "$MOUNTS"
assert_eq "type of disk workspace" ext4 "$(z2k_ow_storage_type "$OV/archive.tar.gz")"
printf 'MemTotal: 131072 kB\nMemAvailable: 65536 kB\n' > "$MEM"
printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 400000 100000 300000 25%% /overlay\n' > "$DF"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 16777216 41943040 12582912 8388608 0; then
    _t_ok
else
    _t_bad "disk-backed archive is excluded from RAM while stage and reserve still fit"
fi
printf 'MemTotal: 131072 kB\nMemAvailable: 16384 kB\n' > "$MEM"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 16777216 41943040 12582912 8388608 0; then
    _t_bad "disk-backed workspace still rejects an insufficient live stage budget"
else
    _t_ok
fi

# До загрузки установщик резервирует место на диске под архив, распакованные
# файлы и запас для отката.
printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 131072 50000 80000 39%% /overlay\n' > "$DF"
if z2k_ow_overlay_download_preflight "$OV" 14132028 33712446; then
    _t_ok
else
    _t_bad "проверка перед загрузкой принимает раздел с достаточным местом для архива, файлов и отката"
fi
printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 131072 122880 8192 94%% /overlay\n' > "$DF"
if z2k_ow_overlay_download_preflight "$OV" 14132028 33712446; then
    _t_bad "проверка перед загрузкой отказывает при нехватке места до записи архива"
else
    _t_ok
fi

printf 'MemAvailable: damaged\n' > "$MEM"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 1024 1024 1024 1024 0; then
    _t_bad "damaged meminfo must fail closed"
else
    _t_ok
fi
printf 'not mountinfo\n' > "$MOUNTS"
printf 'MemAvailable: 8192 kB\n' > "$MEM"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 1024 1024 1024 1024 0; then
    _t_bad "unknown mountinfo must fail closed"
else
    _t_ok
fi

BUSYBOX="${Z2K_TEST_BUSYBOX:-$(command -v busybox 2>/dev/null || true)}"
if [ -n "$BUSYBOX" ]; then
    mkdir -p "$T/busybox-bin"
    cat > "$T/busybox-bin/awk" <<EOF
#!/bin/sh
exec "$BUSYBOX" awk "\$@"
EOF
    chmod 755 "$T/busybox-bin/awk"
    PATH="$T/busybox-bin:$PATH"
    export PATH
    printf '1 0 0:1 / / rw - tmpfs tmpfs rw\n' > "$MOUNTS"
    printf 'MemTotal: 131072 kB\nMemAvailable: 65536 kB\n' > "$MEM"
    printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 131072 65536 65536 50%% /tmp\n' > "$DF"
    if z2k_ow_memory_preflight "$OV/archive.tar.gz" 12582912 41943040 12582912 8388608 12582912; then
        _t_bad "BusyBox awk/sh must reject a combined 128 MiB peak"
    else
        _t_ok
    fi
fi

_t_done
