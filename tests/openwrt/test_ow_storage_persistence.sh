#!/bin/sh
# Disk-backed release storage must be verified through the actual mount table.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-storage-persistence"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/platform/openwrt/release.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-storage.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM

mkdir -p "$T/work" "$T/upper" "$T/link-parent" "$T/foreign-owner"
MEM="$T/meminfo"
MOUNTS="$T/mountinfo"
export Z2K_OW_MEMINFO_FILE="$MEM" Z2K_OW_MOUNTINFO_FILE="$MOUNTS"

if ! command -v z2k_ow_storage_persistent >/dev/null 2>&1 \
    || ! command -v z2k_ow_path_components_safe >/dev/null 2>&1 \
    || ! command -v z2k_ow_installer_owned >/dev/null 2>&1; then
    _t_bad "release engine exports persistent storage, path safety, and owner guards"
    _t_done
    exit 1
fi

printf '36 25 0:32 / %s rw - ext4 /dev/test-overlay rw\n' "$T" > "$MOUNTS"
assert_eq "ext4 is a persistent backing filesystem" 0 "$(z2k_ow_storage_persistent "$T/work"; echo $?)"

printf '36 25 0:32 / %s rw - ubifs ubi0:rootfs_data rw\n' "$T" > "$MOUNTS"
assert_eq "ubifs is a persistent backing filesystem" 0 "$(z2k_ow_storage_persistent "$T/work"; echo $?)"

printf '36 25 0:32 / %s rw - tmpfs tmpfs rw\n' "$T" > "$MOUNTS"
if z2k_ow_storage_persistent "$T/work"; then
    _t_bad "tmpfs cannot host release archive, stage, or rollback"
else
    _t_ok
fi

cat > "$MOUNTS" <<EOF_MOUNTS
36 25 0:32 / $T rw - overlay overlay rw,lowerdir=/lower,upperdir=$T/upper,workdir=$T/work
37 36 0:33 / $T/upper rw - ext4 /dev/test-overlay rw
EOF_MOUNTS
assert_eq "overlay backed by ext4 is persistent" 0 "$(z2k_ow_storage_persistent "$T/work/file"; echo $?)"

cat > "$MOUNTS" <<EOF_MOUNTS
36 25 0:32 / $T rw - overlay overlay rw,lowerdir=/lower,upperdir=$T/upper,workdir=$T/work
37 36 0:33 / $T/upper rw - tmpfs tmpfs rw
EOF_MOUNTS
if z2k_ow_storage_persistent "$T/work"; then
    _t_bad "overlay whose upperdir is tmpfs is rejected"
else
    _t_ok
fi

ln -s "$T/work" "$T/link-parent/linked"
if z2k_ow_path_components_safe "$T/link-parent/linked/child"; then
    _t_bad "a symlink in the release work path is rejected"
else
    _t_ok
fi
if z2k_ow_path_components_safe "$T/work/../outside"; then
    _t_bad "parent traversal in a release work path is rejected"
else
    _t_ok
fi
if z2k_ow_installer_owned "$T/work"; then
    _t_ok
else
    _t_bad "current installer owner is accepted"
fi
mkdir -p "$T/no-stat-bin"
cat > "$T/no-stat-bin/stat" <<'EOF_NO_STAT'
#!/bin/sh
exit 127
EOF_NO_STAT
chmod +x "$T/no-stat-bin/stat"
_saved_path="$PATH"
PATH="$T/no-stat-bin:$PATH"
if z2k_ow_installer_owned "$T/work"; then
    _t_ok
else
    _t_bad "BusyBox without the stat applet can verify the installer owner"
fi
PATH="$_saved_path"
TOOLBIN="$T/busybox-tools"
mkdir -p "$TOOLBIN"
for _tool in awk df du grep head ls readlink sed sha256sum sync tar tr xargs; do
    _path=$(command -v "$_tool") || { _t_bad "test helper command $_tool is available"; continue; }
    ln -s "$_path" "$TOOLBIN/$_tool"
done
cat > "$TOOLBIN/apk" <<'EOF_APK'
#!/bin/sh
exit 0
EOF_APK
chmod +x "$TOOLBIN/apk"
cat > "$T/openwrt_release" <<'EOF_OPENWRT'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.5'
DISTRIB_ARCH='x86_64'
EOF_OPENWRT
printf 'MemTotal: 131072 kB\nMemAvailable: 23000 kB\n' > "$MEM"
_saved_path="$PATH"
_adapter_saved="${_adapter:-}"
_adapter="$REPO/platform/openwrt"
PATH="$TOOLBIN"
export PATH Z2K_OW_TESTING=0 Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release" Z2K_OW_MEMINFO_FILE="$MEM"
if z2k_ow_system_preflight; then
    PATH="$_saved_path"
    export PATH
    _adapter="$_adapter_saved"
    _t_ok
else
    PATH="$_saved_path"
    export PATH
    _adapter="$_adapter_saved"
    _t_bad "OpenWrt preflight supports the standard BusyBox set without stat"
fi
unset Z2K_OW_TESTING Z2K_OW_OPENWRT_RELEASE_FILE Z2K_OW_MEMINFO_FILE
if [ "$(id -u)" = 0 ] && chown 65534 "$T/foreign-owner" 2>/dev/null; then
    if z2k_ow_installer_owned "$T/foreign-owner"; then
        _t_bad "foreign-owned release workspace is rejected"
    else
        _t_ok
    fi
fi

mkdir -p "$T/work/stage/etc"
printf '%s\n' z2kow-overlay-stage-v1 > "$T/work/stage.owner"
printf 'owned\n' > "$T/work/stage/etc/owned"
ln -s owned "$T/work/stage/etc/owned-link"
assert_eq "owned safe symlink stage can be removed" 0 \
    "$(z2k_ow_remove_install_stage "$T/work/stage" "$T/work" >/dev/null 2>&1; echo $?)"

mkdir -p "$T/work/stage/etc"
printf '%s\n' z2kow-overlay-stage-v1 > "$T/work/stage.owner"
printf 'foreign\n' > "$T/work/stage/etc/foreign"
if [ "$(id -u)" = 0 ] && chown 65534 "$T/work/stage/etc/foreign" 2>/dev/null; then
    if z2k_ow_remove_install_stage "$T/work/stage" "$T/work"; then
        _t_bad "cleanup refuses to delete a foreign-owned file inside an installer stage"
    elif [ -f "$T/work/stage/etc/foreign" ]; then
        _t_ok
    else
        _t_bad "foreign-owned stage data remains available for recovery"
    fi
fi

# The signed archive+payload budget must fail on tmpfs before any service action.
printf 'MemTotal: 131072 kB\nMemAvailable: 23000 kB\n' > "$MEM"
printf '36 25 0:32 / %s rw - tmpfs tmpfs rw\n' "$T" > "$MOUNTS"
df() { printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 1048576 1 1048575 1%% %s\n' "$T"; }
if z2k_ow_overlay_download_preflight "$T/work" 1048576 1048576; then
    _t_bad "download preflight rejects tmpfs even when it has nominal free bytes"
else
    _t_ok
fi

# Final cleanup removes only the installer marker. If another file appears in
# the owned scratch directory, preserve it instead of recursively deleting it.
printf '36 25 0:32 / %s rw - ext4 /dev/test-overlay rw\n' "$T" > "$MOUNTS"
Z2K_OW_TESTING=1
_cleanup_work="$T/cleanup-work"
_cleanup_parent="$T/install-stage-parent"
_cleanup_tmp="$_cleanup_parent/z2kow-release"
z2k_ow_prepare_install_workspace "$_cleanup_work" \
    && z2k_ow_prepare_temp_workspace "$_cleanup_tmp" || {
        _t_bad "owned cleanup workspaces can be prepared"
        _t_done
        exit 1
    }
printf '%s\n' "leave-me" > "$_cleanup_tmp/foreign"
if z2k_ow_cleanup_install_workspace "$_cleanup_work" "$_cleanup_tmp" >/dev/null 2>&1; then
    _t_bad "cleanup refuses a temporary directory containing unknown files"
elif [ -f "$_cleanup_tmp/foreign" ] && [ "$(cat "$_cleanup_tmp/foreign")" = leave-me ]; then
    _t_ok
else
    _t_bad "cleanup leaves an unknown temporary file untouched"
fi
_clean_work="$T/clean-work"
_clean_parent="$T/clean-stage-parent"
_clean_tmp="$_clean_parent/z2kow-release"
z2k_ow_prepare_install_workspace "$_clean_work" \
    && z2k_ow_prepare_temp_workspace "$_clean_tmp" \
    && z2k_ow_cleanup_install_workspace "$_clean_work" "$_clean_tmp" \
    && [ ! -e "$_clean_work" ] && [ ! -e "$_clean_tmp" ] && [ -d "$_clean_parent" ] \
    && [ -z "$(ls -A "$_clean_parent")" ] \
    && _t_ok || _t_bad "owned scratch directory is removed while its configured parent is preserved"

_bootstrap_work="$T/bootstrap-work"
_bootstrap_tmp="$T/bootstrap-stage-parent/z2kow-release"
z2k_ow_prepare_install_workspace "$_bootstrap_work" \
    && z2k_ow_prepare_temp_workspace "$_bootstrap_tmp" \
    && printf '%s\n' 'verified archive' > "$_bootstrap_work/openwrt-rootfs-bootstrap.tar.gz" \
    && z2k_ow_cleanup_install_workspace "$_bootstrap_work" "$_bootstrap_tmp" \
    && [ ! -e "$_bootstrap_work" ] && [ ! -e "$_bootstrap_tmp" ] \
    && _t_ok || _t_bad "rollback cleanup removes the verified bootstrap archive"

_t_done
