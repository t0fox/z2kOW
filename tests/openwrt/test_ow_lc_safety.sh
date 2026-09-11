#!/bin/sh
# tests/openwrt/test_ow_lc_safety.sh - Level C: конкуренция и lock.
# S11a: два updater — второй skip'ается (mkdir-lock + живой pid);
# S11b: postinst (seed_ensure-skip) во время удерживаемого lock — идёт,
#       ничего не трогает (координация не нужна — доказательство здесь);
# stale lock мёртвого pid — снимается и работа идёт.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-lc-safety"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LC_REPO="$REPO"; export LC_REPO
. "$(dirname "$0")/lc_harness.sh"
lc_init || { echo "FAIL[ow-lc-safety]: init" >&2; exit 1; }
trap 'rm -rf "$LC_T"' EXIT INT TERM
lc_fresh_sysroot || { echo "FAIL[ow-lc-safety]: sysroot" >&2; exit 1; }

# --- S11a: второй экземпляр skip'ается ---
# holder — как au_run_apply (EXIT-trap освобождает; см. upstream entry).
( trap 'au_lock_release' EXIT; au_lock_acquire >/dev/null 2>&1 && sleep 5 ) &
_holder=$!
sleep 1
if au_lock_acquire >/dev/null 2>&1; then
    _t_bad "S11a: второй lock захвачен при живом первом"
    au_lock_release 2>/dev/null || true
else
    _t_ok
fi
wait "$_holder" 2>/dev/null
au_lock_release 2>/dev/null || true
# после holder — захватывается снова
au_lock_acquire >/dev/null 2>&1 && _t_ok || _t_bad "S11a: lock не освободился"
au_lock_release 2>/dev/null || true

# --- stale lock мёртвого pid снимается ---
mkdir -p "${Z2K_AU_LOCK_FILE}.d" 2>/dev/null
printf '99999999\n' > "${Z2K_AU_LOCK_FILE}.d/pid" 2>/dev/null
if kill -0 99999999 2>/dev/null; then
    echo "SKIP[ow-lc-safety]: pid 99999999 жив (невероятно, но проверено)"
else
    au_lock_acquire >/dev/null 2>&1 && _t_ok || _t_bad "S11a: stale lock не снят"
    au_lock_release 2>/dev/null || true
fi

# --- S11b: postinst во время удерживаемого lock — no-op, идёт ---
lc_begin; lc_snap s11b-before
( trap 'au_lock_release' EXIT; au_lock_acquire >/dev/null 2>&1 && sleep 4 ) &
_holder=$!
sleep 1
_sum_before="$(cksum "$Z2K_ROOT/lib/utils.sh")"
lc_postinst
assert_eq "S11b postinst rc под lock" "0" "$?"
assert_eq "S11b payload не тронут" "$_sum_before" "$(cksum "$Z2K_ROOT/lib/utils.sh")"
if [ -f "${Z2K_AU_LOCK_FILE}.d/pid" ]; then
    _t_ok
else
    _t_bad "S11b postinst снял чужой lock"
fi
wait "$_holder" 2>/dev/null
au_lock_release 2>/dev/null || true
lc_snap s11b-after
lc_mutlog s11b-before s11b-after "S11 postinst-under-lock"
lc_invariant "S11" || _t_bad "S11 invariant"

_t_done
