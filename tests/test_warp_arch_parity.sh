#!/bin/sh
# tests/test_warp_arch_parity.sh — проверяет арки, объявленные для WARP.
#
# Повод: 06.09.2026, жалоба «не могу поставить WARP». Движок собирался под пять
# арок, клиент туннеля — под девять. На остальных установка отвечала
# `unsupported architecture` — строкой, из которой человек не может понять, что
# дело не в его роутере, а в том, что сборки под него нет вовсе. Разница была
# случайной: движок на Go и кросс-компилируется всюду, где и всё остальное.
#
# Здесь сторожатся ОБА конца: и наличие файла сборки, и то, что опознание арки
# в него попадает. Одного без другого мало — сборка, до которой не доходит
# опознание, так же бесполезна, как её отсутствие.
# POSIX sh (busybox ash).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

WD="$ROOT/z2k-warpd/builds"
[ -d "$WD" ] || { echo "нет каталога сборок WARP"; exit 1; }

# Суффиксы файлов могут отличаться от GOARCH (386→x86, mips64le→mips64el),
# поэтому берём целевые имена из общей матрицы сборки.
_ref=$(awk -F '\t' '$1 == "z2k-warpd" { print $6 }' "$ROOT/build-matrix.tsv" | sort -u)
[ -n "$_ref" ] || { echo "в build-matrix.tsv нет арок WARP"; exit 1; }

_miss=""
for a in $_ref; do
    [ -f "$WD/z2k-warpd-linux-$a" ] || _miss="$_miss $a"
done
if [ -z "$_miss" ]; then
    ok "каждая арка WARP из build-matrix.tsv имеет бинарник"
else
    bad "в build-matrix.tsv нет отгружаемых сборок WARP под:$_miss"
fi

# Опознание арки обязано попадать в существующий файл. Берём НАСТОЯЩУЮ функцию
# из files/z2k-warp.sh, подставляя железо через uname (opkg.conf в песочнице
# нет, функция сама уходит на uname -m).
_fn=$(awk '/^warp_arch\(\)/{f=1} f{print} f && /^\}/{exit}' "$ROOT/files/z2k-warp.sh")
if [ -z "$_fn" ]; then
    bad "не нашёл warp_arch в files/z2k-warp.sh — проверка ослепла"
else
    _bad=""
    for hw in aarch64 armv7l mipsel mips mips64el i686 x86_64 ppc64 riscv64; do
        _got=$(printf '%s\nuname() { echo "%s"; }\nwarp_arch\n' "$_fn" "$hw" | sh 2>/dev/null)
        if [ -z "$_got" ]; then
            _bad="$_bad $hw(не опознана)"
        elif [ ! -f "$WD/z2k-warpd-linux-$_got" ]; then
            _bad="$_bad $hw(->$_got, файла нет)"
        fi
    done
    if [ -z "$_bad" ]; then
        ok "опознание арки для каждой железки попадает в существующую сборку"
    else
        bad "опознание не даёт рабочей сборки для:$_bad"
    fi
fi

echo
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" -eq 0 ]
