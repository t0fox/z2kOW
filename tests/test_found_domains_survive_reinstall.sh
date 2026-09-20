#!/bin/sh
# p-85.2: retire background discovery without deleting user-owned lists.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

INST="$ROOT/lib/install.sh"
[ -f "$INST" ] || { no "installer exists" yes no; exit 1; }
if [ "$(grep -c '^ *_acc=autohostlist-domains$' "$INST")" = 2 ] &&
   ! grep -q 'discovered-domains.txt' "$INST"; then
    ok "installer keeps only autohostlist and no discovery state"
else
    no "installer discovery retirement" "no discovered state" "present"
fi

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
TREE="$TMP/opt/zapret2"; PROC="$TMP/proc"; mkdir -p "$TREE/lists" "$PROC/321" "$PROC/322"
printf '%s\000run\000' "$TMP/opt/sbin/z2k-detect" > "$PROC/321/cmdline"
printf '%s\000probe\000example.com\000' "$TMP/opt/sbin/z2k-detect" > "$PROC/322/cmdline"
printf 'old\n' > "$TREE/lists/discovered-domains.txt"
printf 'user\n' > "$TREE/lists/extra-domains.txt"
printf 'user\n' > "$TREE/lists/whitelist.txt"
mkdir -p "$TMP/opt/etc/init.d"
touch "$TMP/opt/etc/init.d/S98z2k-detect" "$TREE/z2k-detect-watchdog.sh"
kill() { echo "$1" >> "$TMP/killed"; rm -rf -- "${PROC:?}/$1"; }

# Only the process-control boundary is mocked; the migration is production code.
. "$ROOT/lib/config_official.sh"
ZAPRET2_DIR="$TREE" Z2K_DISCOVERY_PROC_ROOT="$PROC" z2k_retire_discovery
_rc=$?
if [ "$_rc" = 0 ] && [ ! -e "$TREE/lists/discovered-domains.txt" ] &&
   [ ! -e "$TMP/opt/etc/init.d/S98z2k-detect" ] &&
   [ ! -e "$TREE/z2k-detect-watchdog.sh" ]; then
    ok "migration removes old publication and launchers"
else
    no "migration" "deleted, rc=0" "rc=$_rc"
fi
if [ "$(cat "$TMP/killed" 2>/dev/null)" = 321 ] && [ -f "$PROC/322/cmdline" ]; then
    ok "migration kills only legacy run, not manual probe"
else
    no "process selection" "321 only" "$(cat "$TMP/killed" 2>/dev/null)"
fi
if [ "$(cat "$TREE/lists/extra-domains.txt")" = user ] &&
   [ "$(cat "$TREE/lists/whitelist.txt")" = user ]; then
    ok "user lists are preserved"
else
    no "user lists" preserved changed
fi

# A writer that cannot be stopped must veto publication deletion.
mkdir -p "$PROC/321"
printf '%s\000run\000' "$TMP/opt/sbin/z2k-detect" > "$PROC/321/cmdline"
printf 'still-live\n' > "$TREE/lists/discovered-domains.txt"
kill() { return 1; }
ZAPRET2_DIR="$TREE" Z2K_DISCOVERY_PROC_ROOT="$PROC" z2k_retire_discovery
if [ "$?" -ne 0 ] && [ -s "$TREE/lists/discovered-domains.txt" ]; then
    ok "live legacy writer blocks deletion"
else
    no "live writer" "nonzero and publication preserved" "missing"
fi

# Execute the real migration, including a running legacy writer and a manual probe.
. "$ROOT/lib/config_official.sh"
ZAPRET2_DIR="$TREE"
Z2K_DISCOVERY_PROC_ROOT="$TMP/proc"
mkdir -p "$TMP/opt/etc/init.d" "$Z2K_DISCOVERY_PROC_ROOT/321" "$Z2K_DISCOVERY_PROC_ROOT/322"
printf '%s\000run\000' "$TMP/opt/sbin/z2k-detect" > "$Z2K_DISCOVERY_PROC_ROOT/321/cmdline"
printf '%s\000probe\000www.google.com\000' "$TMP/opt/sbin/z2k-detect" > "$Z2K_DISCOVERY_PROC_ROOT/322/cmdline"
printf 'www.google.com\n' > "$TREE/lists/discovered-domains.txt"
printf 'www.google.com\n' > "$TREE/lists/extra-domains.txt"
printf 'google.com\n' > "$TREE/lists/whitelist.txt"
touch "$TMP/opt/etc/init.d/S98z2k-detect" "$TREE/z2k-detect-watchdog.sh"
# Only the process-control boundary is mocked; migration logic is production code.
kill() { echo "$1" >> "$TMP/killed"; rm -rf "${Z2K_DISCOVERY_PROC_ROOT:?}/${1:?}"; }
z2k_retire_discovery
_rc=$?
if [ "$_rc" = 0 ] && [ ! -e "$TREE/lists/discovered-domains.txt" ] &&
   [ ! -e "$TMP/opt/etc/init.d/S98z2k-detect" ] && [ ! -e "$TREE/z2k-detect-watchdog.sh" ]; then
    ok "миграция удаляет публикацию и оба пути автозапуска"
else
    no "миграция" "deleted, rc=0" "rc=$_rc"
fi
if [ "$(cat "$TMP/killed")" = 321 ] && [ -f "$Z2K_DISCOVERY_PROC_ROOT/322/cmdline" ]; then
    ok "остановлен только run, ручная проба не тронута"
else
    no "выбор процесса" "321 only" "$(cat "$TMP/killed")"
fi
if [ "$(cat "$TREE/lists/extra-domains.txt")" = www.google.com ] &&
   [ "$(cat "$TREE/lists/whitelist.txt")" = google.com ] &&
   [ -s "$TREE/lists/autohostlist-domains.txt" ]; then
    ok "ручные списки и отдельный автохостлист сохранены"
else
    no "чужие списки" "preserved" "changed"
fi
z2k_retire_discovery && ok "повторная миграция идемпотентна" || no "повтор" 0 "$?"

# A still-running writer must veto deleting its publication.
mkdir -p "$Z2K_DISCOVERY_PROC_ROOT/321"
printf '%s\000run\000' "$TMP/opt/sbin/z2k-detect" > "$Z2K_DISCOVERY_PROC_ROOT/321/cmdline"
printf 'www.google.com\n' > "$TREE/lists/discovered-domains.txt"
kill() { return 1; }
if z2k_retire_discovery; then
    no "отказ остановки виден вызывающему" "nonzero" 0
else
    ok "отказ остановки виден вызывающему"
fi
[ -s "$TREE/lists/discovered-domains.txt" ] && ok "при живом writer публикация не удаляется" || no "writer" "preserved" "deleted"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
