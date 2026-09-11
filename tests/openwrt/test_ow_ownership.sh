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

# 1. демон запускает ровно один файл (procd-сервис)
_n="$(grep -rl 'procd_set_param command' "$REPO/platform/openwrt" "$REPO/package/openwrt" 2>/dev/null | wc -l)"
assert_eq "один владелец процесса nfqws2" "1" "$(printf '%s' "$_n" | tr -d ' ')"
grep -rl 'procd_set_param command' "$REPO/package/openwrt/files/etc/init.d/z2k" >/dev/null 2>&1 \
    && _t_ok || _t_bad "владелец демона — не init.d/z2k"

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

_t_done
