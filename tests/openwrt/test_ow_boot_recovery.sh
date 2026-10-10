#!/bin/sh
# Новый shell через загрузочную ссылку восстанавливает прерванную транзакцию.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-boot-recovery"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/platform/openwrt/release.sh"
. "$REPO/platform/openwrt/manifest.sh"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
SYS="$T/sys"
WORK="$SYS/usr/lib/.z2k-install"
TEMP="$T/tmp/z2kow-release"
LOCK="$SYS/usr/lib/.z2k-install.lock"
HOOK="$SYS/etc/rc.d/S21z2kow-install-recovery"
export Z2K_OW_SYSROOT="$SYS" Z2K_OW_TESTING=1
export Z2K_ETC=/etc/z2k Z2K_CONFIG=/etc/z2k/config
export Z2K_OW_BOOT_ID_FILE="$T/boot-id"
printf 'текущая-загрузка\n' > "$Z2K_OW_BOOT_ID_FILE"
_adapter="$REPO/platform/openwrt"
SERVICE_ENV_LOG="$T/service-env.log"
SERVICE_HELPER="$T/service-helper"
cat > "$SERVICE_HELPER" <<EOF
#!/bin/sh
printf '%s|%s|%s|%s\\n' "\$1" "\$2" "\${Z2K_ADAPTER_DIR:-}" "\${Z2K_LIB:-}" >> "$SERVICE_ENV_LOG"
exit 0
EOF
chmod 755 "$SERVICE_HELPER"
export Z2K_OW_TEST_SERVICE_HELPER="$SERVICE_HELPER"
printf "DISTRIB_ARCH='aarch64_cortex-a53'\n" > "$T/openwrt_release"
export Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release" Z2K_ADAPTER_DIR="$REPO/platform/openwrt"
MANIFEST="$T/UPDATES.json"
jsonfilter() {
    _jf_file= _jf_expr= _jf_type=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -i) _jf_file="$2"; shift 2 ;;
            -e) _jf_expr="${2#@.}"; shift 2 ;;
            -t) _jf_type=1; _jf_expr="${2#@.}"; shift 2 ;;
            *) return 2 ;;
        esac
    done
    python3 - "$_jf_file" "$_jf_expr" "$_jf_type" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for key in sys.argv[2].split("."):
    value = value[key]
if sys.argv[3] == "1":
    print({dict: "object", list: "array", str: "string", int: "number", float: "number", bool: "boolean", type(None): "null"}.get(type(value), "null"))
elif value is not None:
    print(value)
PY
}
python3 - "$REPO/UPDATES.json" "$MANIFEST" <<'PY'
import hashlib, json, sys
source, target = sys.argv[1:]
manifest = json.load(open(source, encoding="utf-8"))
manifest.pop("artifact", None)
manifest["artifacts"] = {}
for arch in ("arm64", "arm", "x86_64", "x86", "mips", "mipsel", "riscv64"):
    manifest["artifacts"][arch] = {
        "filename": f"openwrt-rootfs-{arch}.tar.gz",
        "url": "https://github.com/t0fox/z2kOW/releases/download/openwrt-" + "a" * 40 + f"/openwrt-rootfs-{arch}.tar.gz",
        "sha256": hashlib.sha256(f"archive:{arch}".encode()).hexdigest(),
        "size_bytes": 1024,
        "unpacked_size_bytes": 8192,
    }
with open(target, "w", encoding="utf-8") as output:
    json.dump(manifest, output)
PY
TARGET_SHA="$(z2k_ow_manifest_artifact_sha256 "$MANIFEST" arm64)" || exit 1
OLD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
if ! command -v z2k_ow_prepare_boot_recovery >/dev/null 2>&1; then
    _t_bad "установщик подготавливает сохраняемый загрузочный вызов recovery"
    _t_done
    exit 1
fi

prepare_interruption() {
    mkdir -p "$WORK" "$SYS/etc/z2k/state" "$SYS/etc/init.d" "$SYS/etc/rc.d" \
        "$SYS/usr/lib/z2k" "$SYS/opt/zapret2/binaries/linux-arm64" "$TEMP"
    rm -f "$SYS/etc/rc.d/S22z2k" "$SYS/etc/rc.d/S95z2k-webpanel"
    printf 'z2kow-release-stage-v1\n' > "$TEMP/.z2kow-owner"
    printf 'ENABLED=0\n' > "$SYS/etc/z2k/config"
    for service in z2k z2k-webpanel; do
        printf '#!/bin/sh\nexit 0\n' > "$SYS/etc/init.d/$service"
        chmod 755 "$SYS/etc/init.d/$service"
    done
    ln -s ../init.d/z2k "$SYS/etc/rc.d/S22z2k"
    ln -s ../init.d/z2k-webpanel "$SYS/etc/rc.d/S95z2k-webpanel"
    printf 'сломанная новая версия\n' > "$SYS/usr/lib/z2k/version.txt"
    mkdir -p "$SYS/usr/lib/z2k.z2k-backup.991"
    printf 'прежняя версия\n' > "$SYS/usr/lib/z2k.z2k-backup.991/version.txt"
    printf 'broken new zapret tree\n' > "$SYS/opt/zapret2/binaries/linux-arm64/nfqws2"
    mkdir -p "$SYS/opt/zapret2.z2k-backup.991/binaries/linux-arm64"
    printf 'previous zapret tree\n' > "$SYS/opt/zapret2.z2k-backup.991/binaries/linux-arm64/nfqws2"
    printf '/usr/lib/z2k\n/opt/zapret2\n' > "$WORK/owned-paths"
    printf 'V|2\nB|/usr/lib/z2k\nO|/usr/lib/z2k\nI|/usr/lib/z2k\nB|/opt/zapret2\nO|/opt/zapret2\nI|/opt/zapret2\n' > "$WORK/transaction.log"
    printf '991\n' > "$WORK/transaction-id"
    printf 'tag=p-86.12\nseq=135\n' > "$WORK/installed-release.old"
    cp "$WORK/installed-release.old" "$SYS/etc/z2k/state/installed-release"
    printf '%s\n' "$OLD_SHA" > "$WORK/installed-artifact.old"
    cp "$WORK/installed-artifact.old" "$SYS/etc/z2k/state/installed-artifact-sha256"
    : > "$WORK/artifact-was-present"
    : > "$WORK/state-was-present"
    printf 'tag=p-86.13\nseq=136\n' > "$WORK/transaction-target"
    printf '%s\n' "$TARGET_SHA" > "$WORK/transaction-artifact"
    z2k_ow_prepare_boot_recovery "$WORK" "$TEMP" "$_adapter" || return 1
    : > "$WORK/transaction-active"
    z2k_ow_suspend_startup "$WORK" || return 1
    mkdir -p "$LOCK"
    # PID существует, но принадлежит другой загрузке: он не блокирует recovery.
    printf '%s\n' "$$" > "$LOCK/pid"
    printf 'предыдущая-загрузка\n' > "$LOCK/boot-id"
}

prepare_interruption || exit 1
if sh "$HOOK" boot > "$T/boot.out" 2>&1; then
    _t_ok
else
    _t_bad "загрузочный entrypoint завершил recovery: $(cat "$T/boot.out")"
fi
assert_eq "прежний payload восстановлен при загрузке" "прежняя версия" "$(cat "$SYS/usr/lib/z2k/version.txt")"
assert_eq "прежнее состояние версии восстановлено" "tag=p-86.12
seq=135" "$(cat "$SYS/etc/z2k/state/installed-release")"
assert_eq "boot recovery возвращает прежний Zapret2 root" "previous zapret tree" "$(cat "$SYS/opt/zapret2/binaries/linux-arm64/nfqws2")"
assert_eq "boot recovery возвращает digest receipt старого релиза" "$OLD_SHA" "$(cat "$SYS/etc/z2k/state/installed-artifact-sha256")"
if [ "$(readlink "$SYS/etc/rc.d/S22z2k" 2>/dev/null)" = ../init.d/z2k ] \
    && [ "$(readlink "$SYS/etc/rc.d/S95z2k-webpanel" 2>/dev/null)" = ../init.d/z2k-webpanel ]; then
    _t_ok
else
    _t_bad "успешный recovery восстанавливает исходные ссылки запуска служб"
fi
if awk -F'|' -v service="$SYS/etc/init.d/z2k-webpanel" \
    -v adapter="$SYS/usr/lib/z2k/platform/openwrt" \
    '$1 == service && $3 == adapter && $3 !~ /recovery-engine/ { found=1 } END { exit !found }' \
    "$SERVICE_ENV_LOG"; then
    _t_ok
else
    _t_bad "перезапущенная панель наследует стабильный установленный адаптер, не snapshot engine"
fi
if [ ! -e "$WORK" ] && [ ! -L "$HOOK" ] && [ ! -e "$LOCK" ]; then
    _t_ok
else
    _t_bad "подтверждённый recovery удаляет загрузочную ссылку, журнал и блокировку"
fi

prepare_interruption || exit 1
rm -rf "$SYS/usr/lib/z2k.z2k-backup.991"
if sh "$HOOK" boot > "$T/boot-failed.out" 2>&1; then
    _t_bad "boot recovery отклоняет потерянную резервную копию"
else
    _t_ok
fi
if [ -f "$WORK/transaction-active" ] && [ -L "$HOOK" ] && [ ! -e "$LOCK" ] \
    && [ ! -e "$SYS/etc/rc.d/S22z2k" ] && [ ! -L "$SYS/etc/rc.d/S22z2k" ] \
    && [ ! -e "$SYS/etc/rc.d/S95z2k-webpanel" ] && [ ! -L "$SYS/etc/rc.d/S95z2k-webpanel" ]; then
    _t_ok
else
    _t_bad "неудачный boot recovery сохраняет журнал и recovery hook без ссылок старых служб"
fi

# Проверить обе реальные init-точки до загрузки адаптеров и runtime.
export Z2K_OW_INSTALL_WORK="$WORK" Z2K_OW_INSTALL_LOCK="$LOCK"
export Z2K_OW_BOOT_ID_FILE="$T/boot-id"
export Z2K_ROOT="$SYS/usr/lib/z2k"
. "$REPO/platform/openwrt/files/etc/init.d/z2k"
core_loaded="$T/core-adapter-loaded"
z2k_load_adapter() { : > "$core_loaded"; }
setup_guard_case() {
    _case_boot="$1" _case_pid="$2"
    rm -rf "$LOCK"
    if [ -n "$_case_pid" ]; then
        mkdir -p "$LOCK"
        printf '%s\n' "$_case_pid" > "$LOCK/pid"
        printf '%s\n' "$_case_boot" > "$LOCK/boot-id"
    fi
    printf 'текущая-загрузка\n' > "$Z2K_OW_BOOT_ID_FILE"
    : > "$WORK/transaction-active"
}

core_guard_case() {
    _case_name="$1" _case_boot="$2" _case_pid="$3" _expect="$4"
    setup_guard_case "$_case_boot" "$_case_pid"
    rm -f "$core_loaded"
    if [ "$_expect" = allowed ]; then
        if z2k_install_recovery_ready; then _t_ok; else _t_bad "$_case_name: текущий установщик должен пройти guard"; fi
    else
        if z2k_install_recovery_ready; then _t_bad "$_case_name: guard разрешил заблокированный старт"; else _t_ok; fi
        if start_service >/dev/null 2>&1; then :; fi
        if [ ! -e "$core_loaded" ]; then _t_ok; else _t_bad "$_case_name: core загрузил runtime до recovery guard"; fi
    fi
}

core_guard_case "нет lock" absent '' blocked
core_guard_case "мертвый PID той же загрузки" текущая-загрузка 99999999 blocked
core_guard_case "старый boot-id с живым PID" предыдущая-загрузка "$$" blocked
core_guard_case "текущая загрузка с живым PID" текущая-загрузка "$$" allowed

. "$REPO/platform/openwrt/files/etc/init.d/z2k-webpanel"
mkdir -p "$Z2K_ROOT/platform/openwrt"
cat > "$Z2K_ROOT/platform/openwrt/webpanel.sh" <<EOF
: > "$T/panel-adapter-loaded"
wp_panel_render() { return 1; }
EOF
panel_guard_case() {
    _case_name="$1" _case_boot="$2" _case_pid="$3" _expect="$4"
    setup_guard_case "$_case_boot" "$_case_pid"
    rm -f "$T/panel-adapter-loaded"
    if [ "$_expect" = allowed ]; then
        if z2k_install_recovery_ready; then _t_ok; else _t_bad "$_case_name: текущий установщик должен пройти panel guard"; fi
    else
        if z2k_install_recovery_ready; then _t_bad "$_case_name: panel guard разрешил заблокированный старт"; else _t_ok; fi
        if start_service >/dev/null 2>&1; then :; fi
        if [ ! -e "$T/panel-adapter-loaded" ]; then _t_ok; else _t_bad "$_case_name: panel загрузила адаптер до recovery guard"; fi
    fi
}
panel_guard_case "нет lock" absent '' blocked
panel_guard_case "мертвый PID той же загрузки" текущая-загрузка 99999999 blocked
panel_guard_case "старый boot-id с живым PID" предыдущая-загрузка "$$" blocked
panel_guard_case "текущая загрузка с живым PID" текущая-загрузка "$$" allowed
# Смоделировать commit, прерванный только на этапе очистки.
prepare_commit_cleanup() {
    rm -rf "$WORK" "$LOCK" "$HOOK" "$SYS/usr/lib/z2k.z2k-backup.991" "$SYS/opt/zapret2.z2k-backup.991"
    unset Z2K_OW_INSTALL_WORK Z2K_OW_INSTALL_LOCK
    prepare_interruption || return 1
    printf 'новая подтверждённая версия\n' > "$SYS/usr/lib/z2k/version.txt"
    printf 'new zapret release\n' > "$SYS/opt/zapret2/binaries/linux-arm64/nfqws2"
    cp "$WORK/transaction-target" "$SYS/etc/z2k/state/installed-release"
    cp "$WORK/transaction-artifact" "$SYS/etc/z2k/state/installed-artifact-sha256"
    : > "$WORK/state-write-started"
    # Настоящий enable создаёт ссылку панели до записи состояния версии.
    ln -s ../init.d/z2k-webpanel "$SYS/etc/rc.d/S95z2k-webpanel"
}
prepare_commit_cleanup || exit 1
if sh "$HOOK" boot > "$T/commit-cleanup.out" 2>&1 \
    && grep -q 'новая подтверждённая версия' "$SYS/usr/lib/z2k/version.txt" \
    && grep -Fxq 'new zapret release' "$SYS/opt/zapret2/binaries/linux-arm64/nfqws2" \
    && grep -Fxq "$TARGET_SHA" "$SYS/etc/z2k/state/installed-artifact-sha256" \
    && [ -L "$SYS/etc/rc.d/S22z2k" ] && [ -L "$SYS/etc/rc.d/S95z2k-webpanel" ] \
    && [ ! -e "$WORK" ] && [ ! -L "$HOOK" ]; then
    _t_ok
else
    _t_bad "commit recovery сохраняет новую версию и настройки автозапуска: $(cat "$T/commit-cleanup.out")"
fi

# Совпадение tag + seq без целевого SHA-256 не подтверждает commit хотфикса.
prepare_commit_cleanup || exit 1
cp "$WORK/installed-release.old" "$WORK/transaction-target"
cp "$WORK/installed-release.old" "$SYS/etc/z2k/state/installed-release"
printf '%s\n' "$OLD_SHA" > "$WORK/installed-artifact.old"
cp "$WORK/installed-artifact.old" "$SYS/etc/z2k/state/installed-artifact-sha256"
: > "$WORK/artifact-was-present"
if sh "$HOOK" boot > "$T/hotfix-recovery.out" 2>&1 \
    && grep -q 'прежняя версия' "$SYS/usr/lib/z2k/version.txt" \
    && grep -Fxq "$OLD_SHA" "$SYS/etc/z2k/state/installed-artifact-sha256" \
    && grep -Fxq 'previous zapret tree' "$SYS/opt/zapret2/binaries/linux-arm64/nfqws2"; then
    _t_ok
else
    _t_bad "прерванный commit одноимённого хотфикса откатывает прежний SHA-256: $(cat "$T/hotfix-recovery.out")"
fi

# Ошибка rm после подтверждённого commit не должна оставить active без boot hook.
prepare_commit_cleanup || exit 1
mkdir -p "$T/cleanup-bin"
cat > "$T/cleanup-bin/rm" <<'SH'
#!/bin/sh
if [ "${1:-}" = -rf ] && [ "${2:-}" = "$Z2K_TEST_CLEANUP_WORK" ]; then
    echo 'контролируемый отказ удаления workspace' >&2
    exit 1
fi
exec /bin/rm "$@"
SH
chmod 755 "$T/cleanup-bin/rm"
if PATH="$T/cleanup-bin:$PATH" Z2K_TEST_CLEANUP_WORK="$WORK" sh "$HOOK" boot > "$T/cleanup-failed.out" 2>&1; then
    _t_bad "отказ удаления workspace должен быть сообщён"
else
    _t_ok
fi
if [ ! -e "$WORK/transaction-active" ] && [ -L "$SYS/etc/rc.d/S22z2k" ] && [ -L "$SYS/etc/rc.d/S95z2k-webpanel" ]; then
    _t_ok
else
    _t_bad "ошибка cleanup не блокирует уже подтверждённый релиз активным журналом без recovery hook"
fi
_t_done
