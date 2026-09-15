#!/bin/sh
# tests/test_cli_link.sh — команда `z2k` из любого каталога (issue #57).
#
# Ссылку /opt/bin/z2k ставила только установка, и только если z2k.sh в этот раз
# скачался. Без неё оставались все, кто ставил z2k до её появления и дальше
# обновлялся без переустановки, и те, у кого на финальном шаге не прошёл запрос
# к GitHub. Контракт:
#   * ссылка ставится, если z2k.sh лежит на диске, — независимо от того,
#     скачался ли он в этот раз;
#   * битая или чужая ССЫЛКА заменяется, обычный файл с тем же именем — нет;
#   * то же делает каждое удачное обновление, по обоим путям.
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

SB=$(mktemp -d "${TMPDIR:-/tmp}/clilink.XXXXXX") || exit 1
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/zd"
: > "$SB/zd/z2k.sh"
Z2K_CLI_LINK="$SB/bin/z2k"; export Z2K_CLI_LINK

# Обе копии логики — из исходников, как есть.
awk '/^z2k_ensure_cli_link\(\) \{/,/^\}/' "$HERE/lib/utils.sh" > "$SB/fn.sh"
awk '/^au_ensure_cli_link\(\) \{/,/^\}/' "$HERE/lib/auto_update.sh" >> "$SB/fn.sh"
[ -s "$SB/fn.sh" ] && grep -q 'au_ensure_cli_link' "$SB/fn.sh" \
    || { no "функции вырезаны из исходников" "обе" "$(wc -l < "$SB/fn.sh")"; exit 1; }

run_utils() { sh -c ". '$SB/fn.sh'; z2k_ensure_cli_link '$SB/zd/z2k.sh'"; }
run_au()    { sh -c "au_log() { :; }; ZAPRET2_DIR='$SB/zd'; . '$SB/fn.sh'; au_ensure_cli_link"; }

for impl in utils au; do
    rm -rf "${SB:?}/bin"
    "run_$impl"; rc=$?
    check "$impl: нет каталога и ссылки — создаёт оба" "$SB/zd/z2k.sh" "$(readlink "$SB/bin/z2k" 2>/dev/null)"
    [ "$impl" = utils ] && check "$impl: код 0 при успехе" "0" "$rc"
    ln -sfn "$SB/nowhere/z2k.sh" "$SB/bin/z2k"
    "run_$impl"
    check "$impl: битая ссылка заменена" "$SB/zd/z2k.sh" "$(readlink "$SB/bin/z2k")"
    "run_$impl"
    check "$impl: повтор ничего не меняет" "$SB/zd/z2k.sh" "$(readlink "$SB/bin/z2k")"
    rm -f "$SB/bin/z2k"; printf 'чужое\n' > "$SB/bin/z2k"
    "run_$impl"
    check "$impl: чужой обычный файл не тронут" "чужое" "$(cat "$SB/bin/z2k")"
    rm -f "$SB/bin/z2k"; mv "$SB/zd/z2k.sh" "$SB/zd/z2k.sh.off"
    "run_$impl"
    check "$impl: нет z2k.sh — ссылка не ставится" "no" "$([ -e "$SB/bin/z2k" ] || [ -L "$SB/bin/z2k" ] && echo yes || echo no)"
    mv "$SB/zd/z2k.sh.off" "$SB/zd/z2k.sh"
done

# Установка: ссылка — ПОСЛЕ ветки скачивания, а не внутри её успеха.
inst="$HERE/lib/install.sh"
fetch_ln=$(grep -n 'if z2k_fetch "$local_z2k_url" "$local_z2k_script"; then' "$inst" | head -1 | cut -d: -f1)
link_ln=$(grep -n 'z2k_ensure_cli_link "$local_z2k_script"' "$inst" | head -1 | cut -d: -f1)
if [ -n "$fetch_ln" ] && [ -n "$link_ln" ]; then
    fi_ln=$(awk -v s="$fetch_ln" 'NR>s && /^    fi$/ {print NR; exit}' "$inst")
    [ -n "$fi_ln" ] && [ "$link_ln" -gt "$fi_ln" ] \
        && ok "установка ставит ссылку и тогда, когда z2k.sh не скачался" \
        || no "ссылка вне ветки успешного скачивания" "после строки $fi_ln" "$link_ln"
else
    no "в установке есть и скачивание, и ссылка" "обе строки" "fetch=$fetch_ln link=$link_ln"
fi
check "старый ln в финале установки убран" "0" "$(grep -c 'ln -sf "$local_z2k_script" /opt/bin/z2k' "$inst")"

# Обновление: оба пути успеха.
au="$HERE/lib/auto_update.sh"
check "обновление ставит ссылку на обоих путях успеха" "2" \
    "$(grep -v '^au_ensure_cli_link()' "$au" | grep -c '^[[:space:]]*au_ensure_cli_link$')"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
