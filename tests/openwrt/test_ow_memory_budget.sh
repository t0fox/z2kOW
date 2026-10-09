#!/bin/sh
# Проверяет память с учётом хранилища на настоящих функциях установщика.
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
printf 'MemTotal: 16384 kB\nMemAvailable: 8192 kB\n' > "$MEM"
export Z2K_OW_MEMINFO_FILE="$MEM" Z2K_OW_MOUNTINFO_FILE="$MOUNTS"

cat > "$MOUNTS" <<'EOF'
1 0 0:1 / / rw - tmpfs tmpfs rw
EOF
assert_eq "тип корневого tmpfs определяется" tmpfs "$(z2k_ow_storage_type "$OV/archive.tar.gz")"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 2097152 4194304; then
    _t_ok
else
    _t_bad "2 МиБ архива и резерв 4 МиБ помещаются в 8 МиБ tmpfs RAM"
fi
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 5242880 4194304; then
    _t_bad "5 МиБ архива и резерв 4 МиБ должны превышать 8 МиБ tmpfs RAM"
else
    _t_ok
fi
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 16777216 4194304; then
    _t_bad "архив 16 МиБ и резерв 4 МиБ должны превышать доступную RAM"
else
    _t_ok
fi

cat > "$MOUNTS" <<'EOF'
1 0 0:1 / / rw - ext4 /dev/root rw
EOF
assert_eq "тип корневой дисковой ФС определяется" ext4 "$(z2k_ow_storage_type "$OV/archive.tar.gz")"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 16777216 4194304; then
    _t_ok
else
    _t_bad "дисковый rootfs не резервирует физическую RAM под весь архив"
fi

printf '1 0 0:1 / / rw - tmpfs tmpfs rw\n2 1 0:2 / %s rw - ext4 /dev/sda rw\n' "$OV" > "$MOUNTS"
assert_eq "для пути выбирается самый длинный путь точки монтирования" ext4 "$(z2k_ow_storage_type "$OV/archive.tar.gz")"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 16777216 4194304; then
    _t_ok
else
    _t_bad "дочерняя дисковая точка монтирования не наследует RAM-бюджет корневого tmpfs"
fi

printf 'MemAvailable: повреждено\n' > "$MEM"
cat > "$MOUNTS" <<'EOF'
1 0 0:1 / / rw - tmpfs tmpfs rw
EOF
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 1024 1024; then
    _t_bad "повреждённый meminfo должен закрываться отказом"
else
    _t_ok
fi

printf 'не mountinfo\n' > "$MOUNTS"
printf 'MemAvailable: 8192 kB\n' > "$MEM"
if z2k_ow_memory_preflight "$OV/archive.tar.gz" 1024 1024; then
    _t_bad "неизвестный mountinfo должен закрываться отказом"
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
    printf 'MemAvailable: 8192 kB\n' > "$MEM"
    cat > "$MOUNTS" <<'EOF'
1 0 0:1 / / rw - tmpfs tmpfs rw
EOF
    if z2k_ow_memory_preflight "$OV/archive.tar.gz" 2097152 4194304; then
        _t_ok
    else
        _t_bad "BusyBox awk поддерживает проверку памяти tmpfs"
    fi
fi

_t_done
