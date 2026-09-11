#!/bin/sh
# tests/openwrt/helper.sh - мини-ассерты для openwrt-тестов (POSIX sh).
# Использование: . helper.sh; _t_plan "имя"; assert_* ...; _t_done

_T_PASS=0
_T_FAIL=0
_T_NAME=""

_t_plan() { _T_NAME="$1"; _T_PASS=0; _T_FAIL=0; }

_t_ok() { _T_PASS=$((_T_PASS + 1)); }
_t_bad() { _T_FAIL=$((_T_FAIL + 1)); echo "FAIL[$_T_NAME]: $1" >&2; }

assert_eq() {
    # $1 desc, $2 expected, $3 actual
    if [ "$2" = "$3" ]; then _t_ok; else _t_bad "$1: expected [$2], got [$3]"; fi
}

assert_contains() {
    # $1 desc, $2 haystack-file, $3 fixed string
    if grep -qF -- "$3" "$2" 2>/dev/null; then _t_ok; else _t_bad "$1: [$2] не содержит [$3]"; fi
}

assert_not_contains() {
    # $1 desc, $2 haystack-file, $3 ERE pattern
    if grep -qE -- "$3" "$2" 2>/dev/null; then _t_bad "$1: [$2] содержит запрещённое [$3]"; else _t_ok; fi
}

assert_file() {
    # $1 desc, $2 path (non-empty regular file or symlink-to-file)
    if [ -s "$2" ]; then _t_ok; else _t_bad "$1: нет/пуст [$2]"; fi
}

_t_done() {
    echo "SUITE[$_T_NAME]: pass=$_T_PASS fail=$_T_FAIL"
    return "$_T_FAIL"
}
