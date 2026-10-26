#!/bin/sh
# tests/test_shipped_files_downloaded.sh — всё, что лежит в files/fake и
# files/lua, установка обязана скачать из нашего репозитория.
#
# Правило Марка (25.10.2026): неиспользуемого не возим, недостающее тянется
# обязательно и только с нашего репозитория. Неиспользуемое и
# незарегистрированное ловит test_blob_identifiers.sh; этот набор закрывает
# вторую половину — файл есть в репозитории и зарегистрирован, а установщик о
# нём не знает, и на свежей установке движок не находит блоб или модуль.
# Обновление такие файлы доставляет через манифест (release_map: files/fake/*
# и files/lua/* → restart-service), а установка — только по списку в z2k.sh.
# POSIX sh.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
Z2K="$ROOT/z2k.sh"
MAP="$ROOT/lib/release_map.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }

missing=""
for f in "$ROOT"/files/fake/*.bin; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    grep -qx "$b" "$Z2K" || missing="$missing $b"
done
if [ -z "$missing" ]; then
    ok "каждый блоб из files/fake есть в списке скачивания установки"
else
    no "блобы есть в репозитории, но установка их не скачает:$missing"
fi

missing=""
for f in "$ROOT"/files/lua/*.lua; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    grep -q "$b" "$Z2K" || missing="$missing $b"
done
if [ -z "$missing" ]; then
    ok "каждый модуль из files/lua есть в списке скачивания установки"
else
    no "модули есть в репозитории, но установка их не скачает:$missing"
fi

# Обновление: оба каталога должны быть в карте доставки на роутер.
grep -q 'files/fake/\*)' "$MAP" && ok "обновление знает, куда класть блобы" \
    || no "в release_map нет пути для files/fake"
grep -q 'files/lua/\*)' "$MAP" && ok "обновление знает, куда класть модули" \
    || no "в release_map нет пути для files/lua"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
