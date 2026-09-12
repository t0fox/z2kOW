#!/bin/sh
# tests/openwrt/test_ow_ownership.sh - Step 4/6: у каждого ресурса ОДИН владелец.
# Статический анализ platform/ + package/: кто запускает nfqws2, кто строит nft,
# откуда берутся QNUM/marks/ports, нет ли второго firewall-фреймворка.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-ownership"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO/platform/openwrt $REPO/package/openwrt"
# shellcheck disable=SC2086
code() { for _d in $SRC; do find "$_d" -type f ! -name '.keep'; done | while IFS= read -r _f; do sed 's/#.*$//' "$_f"; done; }

# 1. демоны запускаются из procd-сервиса z2k (ОДИН сервис, с Stage 3 —
# ДВА instance: nfqws2 в init.d/z2k, tg-mtproxy-client в platform/openwrt/tg.sh,
# который init подключает напрямую; второго init-сервиса нет).
_n="$(grep -rl 'procd_set_param command' "$REPO/platform/openwrt" "$REPO/package/openwrt" 2>/dev/null | wc -l)"
assert_eq "два instance-определения (init + tg.sh)" "2" "$(printf '%s' "$_n" | tr -d ' ')"
grep -rl 'procd_set_param command' "$REPO/package/openwrt/files/etc/init.d/z2k" >/dev/null 2>&1 \
    && _t_ok || _t_bad "владелец nfqws2 — не init.d/z2k"
grep -rl 'procd_set_param command' "$REPO/platform/openwrt/tg.sh" >/dev/null 2>&1 \
    && _t_ok || _t_bad "владелец tg — не platform/openwrt/tg.sh"
_n="$(grep -c 'procd_set_param command' "$REPO/package/openwrt/files/etc/init.d/z2k" 2>/dev/null)"
assert_eq "nfqws2 command ровно один" "1" "$(printf '%s' "$_n" | tr -d ' ')"
_n="$(grep -c 'procd_set_param command' "$REPO/platform/openwrt/tg.sh" 2>/dev/null)"
assert_eq "tg command ровно один" "1" "$(printf '%s' "$_n" | tr -d ' ')"

# 2. своей nft-таблицы нет (не строим второй firewall-фреймворк)
code | grep -qE 'table inet z2k|add table|create table' \
    && _t_bad "адаптер создаёт свою nft-таблицу" || _t_ok

# 3. своих offload-правил нет (делегировано zapret2 через FLOWOFFLOAD конфига)
code | grep -qE 'FLOWOFFLOAD=|flowtable|-j FLOWOFFLOAD|nft.*offload' \
    && _t_bad "адаптер пишет offload-правила" || _t_ok

# 4. QNUM/marks/ports не назначаются кодом — только читаются из конфига
code | grep -qE '(^|[[:space:];])QNUM=' \
    && _t_bad "адаптер назначает QNUM" || _t_ok
code | grep -qE '(^|[[:space:];])DESYNC_MARK=' \
    && _t_bad "адаптер назначает DESYNC_MARK" || _t_ok
code | grep -qE 'NFQWS2_PORTS_(TCP|UDP)=' \
    && _t_bad "адаптер назначает порты" || _t_ok

# 5. firewall делегирован РЕАЛЬНЫМ функциям zapret2
for _fn in zapret_apply_firewall zapret_unapply_firewall zapret_reload_ifsets; do
    grep -q "$_fn" "$REPO/platform/openwrt/firewall.sh" \
        && _t_ok || _t_bad "нет делегирования $_fn"
done

# 6. daemon-половина stock zapret2-init не используется (её OPT_BASE без z2k lua)
code | grep -q 'standard_mode_daemons' \
    && _t_bad "адаптер дёргает daemon-половину zapret2-init" || _t_ok

# 7. сборка OPT_BASE — в одном месте, вызывается из одного места
_n="$(grep -rl 'z2k_ow_optbase' "$REPO/platform/openwrt" "$REPO/package/openwrt" | wc -l)"
assert_eq "optbase: 1 определение + 1 вызов" "2" "$(printf '%s' "$_n" | tr -d ' ')"

# 8. §10 lifecycle invariants: ровно один владелец у каждого ресурса.
#   nfqws2 process .... z2k procd adapter (/etc/init.d/z2k)
#   tg process ........ platform/openwrt/tg.sh (instance того же сервиса)
#   nft/firewall ...... zapret2 (делегирование) + TG chains/sets в ЕГО таблице
#                       (единственное исключение, см. пункт 8b)
#   interface sets .... zapret2 (reload_ifsets; hotplug только зовёт)
#   selective offload . zapret2 (FLOWOFFLOAD из конфига; своих правил нет)
# ровно один procd-СЕРВИС в слое (instance'ов с Stage 3 — два)
_n="$(ls "$REPO"/package/openwrt/files/etc/init.d/ 2>/dev/null | wc -l)"
assert_eq "один procd-сервис (нет второго init-скрипта)" "1" "$(printf '%s' "$_n" | tr -d ' ')"
_n="$(grep -rl 'procd_open_instance' "$REPO/platform/openwrt" "$REPO/package/openwrt" 2>/dev/null | wc -l)"
assert_eq "два instance (nfqws2 + tg)" "2" "$(printf '%s' "$_n" | tr -d ' ')"
# ifsets: единственный писатель — zapret2 (мы только вызываем reload)
code | grep -qE 'lanif|wanif|nft_fill_ifsets|add_element|create_set' \
    && _t_bad "адаптер пишет interface sets" || _t_ok
grep -q 'zapret_reload_ifsets' "$REPO/platform/openwrt/firewall.sh" \
    && _t_ok || _t_bad "нет делегирования ifsets в zapret2"
# firewall: builder — zapret2, ЕДИНСТВЕННОЕ исключение — TG glue
# (свои chains/sets в ЧУЖОЙ runtime-таблице; таблицу не создаёт, см. 8b).
# ifsets: единственный писатель — zapret2 (мы только вызываем reload)
code | grep -qE 'lanif|wanif|nft_fill_ifsets|add_element|create_set' \
    && _t_bad "адаптер пишет interface sets" || _t_ok
grep -q 'zapret_reload_ifsets' "$REPO/platform/openwrt/firewall.sh" \
    && _t_ok || _t_bad "нет делегирования ifsets в zapret2"
_nftbuilders="$(grep -rlE 'nft add|nft create' "$REPO/platform/openwrt" "$REPO/package/openwrt" 2>/dev/null || true)"
if [ -z "$_nftbuilders" ]; then
    _t_bad "нет TG builder (ожидался tg.sh)"
elif [ "$_nftbuilders" = "$REPO/platform/openwrt/tg.sh" ]; then
    _t_ok
else
    _t_bad "firewall строит не только tg.sh: $_nftbuilders"
fi
# 8b. TG-исключение обусловлено: таблицу создаём НЕ мы (только runtime),
# перед записями — проверка её наличия; второго фреймворка нет.
code | grep -qE 'add table|create table' \
    && _t_bad "адаптер создаёт nft-таблицу" || _t_ok
grep -q '_z2k_ow_tg_table_ok' "$REPO/platform/openwrt/tg.sh" \
    && _t_ok || _t_bad "tg.sh пишет без проверки таблицы"
code | grep -qE 'iptables -A|iptables -I|fw3|fw4' \
    && _t_bad "адаптер использует чужой firewall-фреймворк" || _t_ok
# offload уже покрыт пунктом 3; здесь — явное отсутствие второго владельца:
# ни одного упоминания flowtable в коде слоя
code | grep -qi 'flowtable' \
    && _t_bad "второй offload-владелец (flowtable)" || _t_ok

_t_done
