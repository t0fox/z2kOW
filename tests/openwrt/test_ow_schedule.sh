#!/bin/sh
# tests/openwrt/test_ow_schedule.sh - §10-12: cron-интеграция без багажа.
# install/remove идемпотентны и трогают только свою строку; в schedule.sh и
# update.sh нет Keenetic-начинки; jitter — в launcher (z2k_host_jitter).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-schedule"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-sched.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

Z2K_ROOT=/r; export Z2K_ROOT
Z2K_CRON_TAB="$T/crontab"; export Z2K_CRON_TAB
. "$REPO/platform/openwrt/schedule.sh" || { echo "FAIL[ow-schedule]: schedule" >&2; exit 1; }

printf '0 3 * * * /bin/true # чужое\n' > "$Z2K_CRON_TAB"
z2k_ow_cron_install >/dev/null 2>&1 || { echo "FAIL[ow-schedule]: install" >&2; exit 1; }
assert_eq "одна наша строка" "1" "$(grep -c 'z2k-updater' "$Z2K_CRON_TAB")"
assert_contains "зовёт launcher apply" "$Z2K_CRON_TAB" "/r/platform/openwrt/update.sh apply"
assert_contains "чужое цело" "$Z2K_CRON_TAB" "/bin/true"
z2k_ow_cron_install >/dev/null 2>&1
assert_eq "идемпотентность" "1" "$(grep -c 'z2k-updater' "$Z2K_CRON_TAB")"
z2k_ow_cron_remove >/dev/null 2>&1
assert_eq "наша убрана" "0" "$(grep -c 'z2k-updater' "$Z2K_CRON_TAB" || true)"
assert_contains "чужая осталась" "$Z2K_CRON_TAB" "/bin/true"
rm -f "$Z2K_CRON_TAB"
z2k_ow_cron_remove >/dev/null 2>&1 && _t_ok || _t_bad "remove без файла падает"

# z2k-only crontab: remove чистит в пустой (но целый) файл, rc 0 (баг B)
printf '%s\n' "17 2 * * * /r/platform/openwrt/update.sh apply # z2k-updater" > "$Z2K_CRON_TAB"
z2k_ow_cron_remove >/dev/null 2>&1 || _t_bad "remove z2k-only падает"
assert_eq "z2k-only убран" "0" "$(grep -c 'z2k-updater' "$Z2K_CRON_TAB" || true)"
assert_eq "файл цел (пуст)" "0" "$(wc -l < "$Z2K_CRON_TAB" | tr -d ' ')"

# дубли схлопываются в одну актуальную строку (баг B, часть 2)
printf '17 2 * * * /old/path apply # z2k-updater\n17 2 * * * /r/platform/openwrt/update.sh apply # z2k-updater\n' > "$Z2K_CRON_TAB"
z2k_ow_cron_install >/dev/null 2>&1
assert_eq "дублей нет" "1" "$(grep -c 'z2k-updater' "$Z2K_CRON_TAB")"
assert_contains "актуальная строка" "$Z2K_CRON_TAB" "/r/platform/openwrt/update.sh apply # z2k-updater"

# NOTE: отсутствие Keenetic-багажа (S99/PPE/watchdog/tcp16/warp/ndm//opt)
# в schedule.sh и update.sh сторожит test_ow_forbidden.sh (единое место) —
# здесь только поведение cron.

# jitter: детерминирован на хосте и в окне
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/utils.sh" >/dev/null 2>&1 || exit 1
_j1="$(z2k_host_jitter 3600)"; _j2="$(z2k_host_jitter 3600)"
assert_eq "jitter детерминирован" "$_j1" "$_j2"
case "$_j1" in
    ''|*[!0-9]*) _t_bad "jitter не число: $_j1" ;;
    *) [ "$_j1" -lt 3600 ] && _t_ok || _t_bad "jitter вне окна: $_j1" ;;
esac

# Makefile wire: postinst ставит cron, prerm — через uninstall-функцию
assert_contains "postinst cron" "$REPO/package/openwrt/Makefile" "z2k_ow_cron_install"
assert_contains "prerm uninstall" "$REPO/package/openwrt/Makefile" "z2k_ow_uninstall"

_t_done
