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

# --- FLOWOFFLOAD сохраняется по цепочке env -> generate -> config ---
# Первая генерация получает выбор из окружения; следующая уже без override
# обязана сохранить тот же выбор из боевого конфига.
Z2K_FORCE_CONFIG_REGEN=1 FLOWOFFLOAD=software z2k_ow_generate >"$T/gen-offload.log" 2>&1 \
    || { echo "FAIL[ow-generate]: offload generate:"; tail -5 "$T/gen-offload.log" >&2; exit 1; }
assert_contains "FLOWOFFLOAD выбран из env" "$CFG" "FLOWOFFLOAD=software"
unset FLOWOFFLOAD
Z2K_FORCE_CONFIG_REGEN=1 z2k_ow_generate >"$T/gen-offload-regenerate.log" 2>&1 \
    || { echo "FAIL[ow-generate]: offload regenerate:"; tail -5 "$T/gen-offload-regenerate.log" >&2; exit 1; }
assert_contains "FLOWOFFLOAD пережил регенерацию" "$CFG" "FLOWOFFLOAD=software"

# OpenWrt ships BusyBox tr.  The character-class form `tr -d "[:space:]"`
# is not portable there and turns `software` into `oftwr`; the persisted mode
# must remain readable by both the generator and the panel after another
# service lifecycle.
assert_eq "FLOWOFFLOAD mode reader is BusyBox-safe" "software" \
    "$(z2k_ow_flowoffload_mode)"

# --- user-owned strategy/list sources are the sources the generator consumes ---
# A strategy written by the panel must change the generated NFQWS2_OPT, not
# merely exist under /etc/z2k/user-lists.
mkdir -p "$Z2K_EXTRA_STRATS_DIR/unused" "$Z2K_USER_LISTS/custom-strategies"
cp "$Z2K_EXTRA_STRATS_DIR/TCP/RKN/Strategy.txt" "$T/rkn-strategy.txt"
printf '%s\n' '--dpi-desync-ttl=11' >> "$T/rkn-strategy.txt"
cp "$T/rkn-strategy.txt" "$Z2K_USER_LISTS/custom-strategies/rkn_tcp.txt"
Z2K_FORCE_CONFIG_REGEN=1 z2k_ow_generate >"$T/gen-user-strategy.log" 2>&1 \
    || { echo "FAIL[ow-generate]: user strategy:"; tail -10 "$T/gen-user-strategy.log" >&2; exit 1; }
assert_contains "user strategy reaches generated config" "$CFG" "--dpi-desync-ttl=11"

# Extra domains are user-owned and must be the hostlist consumed by the
# generated config; shipped baseline is not a substitute for the user's file.
printf '%s\n' 'user-only.example' > "$Z2K_EXTRA_DOMAINS_RUNTIME"
Z2K_FORCE_CONFIG_REGEN=1 z2k_ow_generate >"$T/gen-user-domains.log" 2>&1 \
    || { echo "FAIL[ow-generate]: user domains:"; tail -10 "$T/gen-user-domains.log" >&2; exit 1; }
assert_contains "user domains path reaches generated config" "$CFG" "--hostlist=$Z2K_EXTRA_DOMAINS_RUNTIME"
assert_contains "user domain is persisted" "$Z2K_EXTRA_DOMAINS_RUNTIME" "user-only.example"

# AutoHostList writes to persistent adapter state, never into the read-only
# payload tree. The same path must be present in the generated daemon args.
sed -i 's/^Z2K_AUTOHOSTLIST=.*/Z2K_AUTOHOSTLIST=1/' "$CFG"
Z2K_FORCE_CONFIG_REGEN=1 z2k_ow_generate >"$T/gen-autohostlist.log" 2>&1 \
    || { echo "FAIL[ow-generate]: autohostlist:"; tail -10 "$T/gen-autohostlist.log" >&2; exit 1; }
assert_contains "autohostlist uses persistent state" "$CFG" "--hostlist=$Z2K_AUTOHOSTLIST_FILE"
[ -f "$Z2K_AUTOHOSTLIST_FILE" ] && _t_ok || _t_bad "autohostlist state file не создан"

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
