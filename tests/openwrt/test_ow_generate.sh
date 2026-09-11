#!/bin/sh
# tests/openwrt/test_ow_generate.sh - Step 8: /etc/z2k/config -> РЕАЛЬНЫЙ NFQWS2_OPT.
# Прогоняет НЕТРОНУТЫЙ upstream create_official_config на фикстуре и доказывает:
# конфиг содержит настоящие z2k-стратегии, пути указывают в фикстуру (не /opt),
# пользовательские флаги переживают регенерацию через мост ${ZAPRET2_DIR}/config.
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/fixture.sh"
_t_plan "ow-generate"
ow_fixture_init || { echo "FAIL[ow-generate]: fixture" >&2; exit 1; }
trap ow_fixture_done EXIT INT TERM

AD="$REPO/platform/openwrt"
. "$AD/paths.sh"
. "$AD/env.sh"
# shellcheck disable=SC1090,SC1091
. "$Z2K_LIB/utils.sh" || { echo "FAIL[ow-generate]: utils.sh" >&2; exit 1; }
. "$Z2K_LIB/strategies.sh" || { echo "FAIL[ow-generate]: strategies.sh" >&2; exit 1; }
. "$Z2K_LIB/config_official.sh" || { echo "FAIL[ow-generate]: config_official.sh" >&2; exit 1; }
. "$AD/materialize.sh"
. "$AD/bootstrap.sh"
. "$AD/generate.sh"

z2k_ow_materialize "$Z2K_MANIFESTS_DIR" >/dev/null 2>&1 \
    || { echo "FAIL[ow-generate]: materialize" >&2; exit 1; }
z2k_ow_bootstrap >/dev/null 2>&1 \
    || { echo "FAIL[ow-generate]: bootstrap" >&2; exit 1; }
z2k_ow_generate >"$T/gen1.log" 2>&1 \
    || { echo "FAIL[ow-generate]: generate:"; tail -20 "$T/gen1.log" >&2; exit 1; }
_t_ok  # генерация отработала штатным кодом

CFG="$Z2K_CONFIG"
assert_file "конфиг создан" "$CFG"

# --- настоящие z2k-стратегии, а не stock zapret2 ---
NFQWS="$(sed -n '/^NFQWS2_OPT="/,/^"$/p' "$CFG")"
[ -n "$NFQWS" ] && _t_ok || _t_bad "NFQWS2_OPT пуст"
echo "$NFQWS" | grep -q -- '--filter-tcp=443' && _t_ok || _t_bad "нет tcp/443-профиля"
echo "$NFQWS" | grep -q 'circular' && _t_ok || _t_bad "нет ротатора circular"
echo "$NFQWS" | grep -q 'lua-desync' && _t_ok || _t_bad "нет lua-desync стратегий"
echo "$NFQWS" | grep -q -- '--filter-udp=443' && _t_ok || _t_bad "нет quic-профиля"
echo "$NFQWS" | grep -q 'fake' && _t_ok || _t_bad "нет fake-десинка"

# --- пути ведут в фикстуру, а не в /opt ---
echo "$NFQWS" | grep -oE -- '--(hostlist|hostlist-exclude|hostlist-auto|ipset)=[^ ]+' \
    | grep -v "^[^=]*=$T/" >"$T/badpaths" || true
[ -s "$T/badpaths" ] && _t_bad "пути мимо фикстуры: $(head -3 "$T/badpaths")" || _t_ok
echo "$NFQWS" | grep -qF -- "--hostlist-exclude=$T/root/lists/whitelist.txt" \
    && _t_ok || _t_bad "whitelist не из фикстуры"
echo "$NFQWS" | grep -qF -- "$T/root/extra_strats/TCP/RKN/List.txt" \
    && _t_ok || _t_bad "RKN-пул не из фикстуры"

# --- z2k-специфика конфига ---
assert_contains "QNUM=200" "$CFG" "QNUM=200"
assert_contains "desync mark" "$CFG" "DESYNC_MARK=0x40000000"
assert_contains "WA-порт 5222" "$CFG" "5222"
assert_contains "MODE_FILTER=hostlist" "$CFG" "MODE_FILTER=hostlist"
assert_contains "INIT_APPLY_FW=1" "$CFG" "INIT_APPLY_FW=1"
assert_contains "master-гейт ENABLED" "$CFG" "ENABLED=1"

# --- мост ${ZAPRET2_DIR}/config работает: флаг из /etc читается генератором ---
# Z2K_NFQWS2_TEMPLATES читается generate_* через ${ZAPRET2_DIR}/config (симлинк).
grep -q -- '--template=' "$CFG" && _t_ok || _t_bad "дефолт: нет --template (ожидался templates=1)"
sed -i 's/^ENABLED=1$/ENABLED=1\nZ2K_NFQWS2_TEMPLATES=0/' "$CFG"
z2k_ow_generate >"$T/gen2.log" 2>&1 \
    || { echo "FAIL[ow-generate]: regenerate:"; tail -5 "$T/gen2.log" >&2; exit 1; }
grep -q -- '--template=' "$CFG" \
    && _t_bad "TEMPLATES=0 из конфига проигнорирован (мост симлинка мёртв)" || _t_ok
assert_contains "флаг пережил регенерацию" "$CFG" "Z2K_NFQWS2_TEMPLATES=0"

# --- симлинк-мост цел после двух генераций ---
[ -L "$Z2K_ROOT/config" ] && _t_ok || _t_bad "$Z2K_ROOT/config больше не симлинк"
assert_eq "симлинк ведёт в /etc" "$Z2K_CONFIG" "$(readlink "$Z2K_ROOT/config")"

_t_done
