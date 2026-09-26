#!/bin/sh
# tests/test_stale_binaries_cleanup.sh — уборка недокачанных бинарников.
#
# Каждый бинарник скачивается во временный файл рядом с целью
# (`<цель>.new.<pid>`) и переезжает на место атомарным mv. Если установка
# оборвалась между скачиванием и mv — пропало питание, кончилось место,
# оборвался SSH — файл остаётся навсегда. Своих сирот процесс чистит сам, но
# только СВОИХ: от чужого прогона остаётся мусор с чужим pid, и его не убирал
# никто.
#
# Цена: tg-mtproxy-client и z2k-detect по ~5.2 МБ, z2k-rt-proxy ~3.7 МБ — до
# 14 МБ за один обрыв. Петля получается порочная: типичная причина обрыва —
# нехватка места, каждый обрыв оставляет хвост, следующая попытка падает
# вероятнее. Ровно это и произошло в issue #29: при нехватке пяти мегабайт у
# человека лежал z2k-rt-proxy.new.2988.
#
# Тест проверяет ДВА свойства, и второе не менее важно первого: чужие сироты
# убираются, а СВОЙ файл — нет. Снести свой .new значит убить установку,
# которая как раз идёт.
#
# POSIX sh.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INST="$ROOT/lib/install.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n      %s\n' "$1" "$2"; }

[ -f "$INST" ] || { no "lib/install.sh найден" "нет файла"; printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"; exit 1; }
. "$INST"
print_info() { :; }
print_error() { :; }

# Поведение целиком на настоящем временном каталоге: чужие загрузки убрать,
# свой .new.<pid> и рабочие файлы сохранить. Список берётся из production helper.
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sbin"
for f in tg-mtproxy-client.new.2988 z2k-rt-proxy.new.2988 z2k-detect.new.777 \
         z2k-warpd.new.2988 z2k-usque.new.1 tg-mtproxy-client \
         z2k-rt-proxy z2k-warpd; do
    echo payload > "$T/sbin/$f"
done
MYPID=4242
echo payload > "$T/sbin/tg-mtproxy-client.new.$MYPID"
echo payload > "$T/sbin/z2k-warpd.new.$MYPID"
_rc=0; z2k_cleanup_stale_binary_downloads "$T/sbin" "$MYPID" || _rc=$?
if [ "$_rc" = "0" ]; then
    ok "уборка завершилась успешно"
else
    no "уборка завершилась успешно" "helper вернул $_rc"
fi
for f in tg-mtproxy-client.new.2988 z2k-rt-proxy.new.2988 z2k-detect.new.777 z2k-warpd.new.2988; do
    [ ! -e "$T/sbin/$f" ] \
        && ok "чужая загрузка $f удалена" \
        || no "чужая загрузка $f удалена" "файл остался"
done
for f in tg-mtproxy-client.new.$MYPID z2k-warpd.new.$MYPID tg-mtproxy-client \
         z2k-rt-proxy z2k-warpd z2k-usque.new.1; do
    [ -f "$T/sbin/$f" ] \
        && ok "сохранён принадлежащий установке файл $f" \
        || no "сохранён принадлежащий установке файл $f" "файл удалён"
done

# Failure to free a stale file is part of the install result: the caller must
# stop before replacing the tree instead of reporting cleanup as successful.
mkdir -p "$T/bin"
cat > "$T/bin/rm" <<EOF
#!/bin/sh
case "\$*" in *z2k-detect.new.blocked*) exit 1 ;; esac
exec /bin/rm "\$@"
EOF
chmod +x "$T/bin/rm"
echo payload > "$T/sbin/z2k-detect.new.blocked"
_saved_path=$PATH
PATH="$T/bin:$PATH"; export PATH
_rc=0; z2k_cleanup_stale_binary_downloads "$T/sbin" "$MYPID" || _rc=$?
PATH=$_saved_path; export PATH
if [ "$_rc" != "0" ] && [ -f "$T/sbin/z2k-detect.new.blocked" ]; then
    ok "ошибка удаления сироты возвращается вызывающему установщику"
else
    no "ошибка удаления сироты возвращается вызывающему установщику" \
       "rc=$_rc, файл=$([ -f "$T/sbin/z2k-detect.new.blocked" ] && echo present || echo missing)"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
