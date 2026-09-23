#!/bin/sh
# tests/openwrt/test_ow_ownership.sh - Step 4/6: у каждого ресурса ОДИН владелец.
# Статический анализ platform/ + package/: кто запускает nfqws2, кто строит nft,
# откуда берутся QNUM/marks/ports, нет ли второго firewall-фреймворка.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-ownership"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO/platform/openwrt $REPO/package/openwrt"
# shellcheck disable=SC2086
# diag.sh is a read-only observer and is intentionally allowed to mention the
# stock runtime's flowtable vocabulary; all writers remain in this scan.
code() { for _d in $SRC; do find "$_d" -type f ! -name '.keep' ! -path '*/platform/openwrt/diag.sh'; done | while IFS= read -r _f; do sed 's/#.*$//' "$_f"; done; }

# 1. демоны запускаются из procd-сервисов (ЯДРО — один сервис z2k, с Stage 3 —
# ДВА instance: nfqws2 в init.d/z2k, tg-mtproxy-client в platform/openwrt/tg.sh;
# Stage 4 добавляет ТРЕТИЙ: z2k-rt-proxy в platform/openwrt/rt.sh, который init
# подключает напрямую; Stage 5 добавляет ЧЕТВЁРТЫЙ: z2k-warpd в
# platform/openwrt/warp.sh (instance того же сервиса); Stage 6 добавляет
# ВТОРОЙ сервис: панель z2k-webpanel (свой instance, независимый lifecycle);
# z2k-detect is a manual diagnostic tool only; it has no package-owned daemon.
_n="$(grep -rl 'procd_set_param command' "$REPO/platform/openwrt" "$REPO/package/openwrt" 2>/dev/null | wc -l)"
assert_eq "шесть command-определений (init + customd + tg.sh + rt.sh + warp.sh + init панели)" "6" "$(printf '%s' "$_n" | tr -d ' ')"
grep -rl 'procd_set_param command' "$REPO/package/openwrt/files/etc/init.d/z2k" >/dev/null 2>&1 \
    && _t_ok || _t_bad "владелец nfqws2 — не init.d/z2k"
grep -rl 'procd_set_param command' "$REPO/platform/openwrt/tg.sh" >/dev/null 2>&1 \
    && _t_ok || _t_bad "владелец tg — не platform/openwrt/tg.sh"
grep -rl 'procd_set_param command' "$REPO/platform/openwrt/rt.sh" >/dev/null 2>&1 \
    && _t_ok || _t_bad "владелец rt — не platform/openwrt/rt.sh"
grep -rl 'procd_set_param command' "$REPO/platform/openwrt/warp.sh" >/dev/null 2>&1 \
    && _t_ok || _t_bad "владелец warp — не platform/openwrt/warp.sh"
grep -rl 'procd_set_param command' "$REPO/package/openwrt/files/etc/init.d/z2k-webpanel" >/dev/null 2>&1 \
    && _t_ok || _t_bad "владелец панели — не init.d/z2k-webpanel"
_n="$(grep -c 'procd_set_param command' "$REPO/package/openwrt/files/etc/init.d/z2k" 2>/dev/null)"
assert_eq "nfqws2 command ровно один" "1" "$(printf '%s' "$_n" | tr -d ' ')"
_n="$(grep -c 'procd_set_param command' "$REPO/platform/openwrt/tg.sh" 2>/dev/null)"
assert_eq "tg command ровно один" "1" "$(printf '%s' "$_n" | tr -d ' ')"
_n="$(grep -c 'procd_set_param command' "$REPO/platform/openwrt/rt.sh" 2>/dev/null)"
assert_eq "rt command ровно один" "1" "$(printf '%s' "$_n" | tr -d ' ')"
_n="$(grep -c 'procd_set_param command' "$REPO/platform/openwrt/warp.sh" 2>/dev/null)"
assert_eq "warp command ровно один" "1" "$(printf '%s' "$_n" | tr -d ' ')"
_n="$(grep -c 'procd_set_param command' "$REPO/package/openwrt/files/etc/init.d/z2k-webpanel" 2>/dev/null)"
assert_eq "panel command ровно один" "1" "$(printf '%s' "$_n" | tr -d ' ')"

# 2. своей nft-таблицы нет (не строим второй firewall-фреймворк)
code | grep -qE 'table inet z2k|add table|create table' \
    && _t_bad "адаптер создаёт свою nft-таблицу" || _t_ok

# 3. своих offload-правил нет (делегировано zapret2 через FLOWOFFLOAD конфига).
# FLOWOFFLOAD= и `nft list ... flowtable` в адаптере могут только сохранять
# режим или наблюдать штатный runtime. Запрещаем именно команды записи.
code | grep -qiE 'nft[[:space:]]+(add|insert|replace|delete|flush|create)[[:space:]].*(flowtable|offload)|(^|[;&|[:space:]])-j[[:space:]]+FLOWOFFLOAD' \
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
assert_eq "optbase: 1 определение + 2 вызова (core + customd)" "3" "$(printf '%s' "$_n" | tr -d ' ')"

# 8. §10 lifecycle invariants: ровно один владелец у каждого ресурса.
#   nfqws2 process .... z2k procd adapter (/etc/init.d/z2k)
#   tg process ........ platform/openwrt/tg.sh (instance того же сервиса)
#   rt process ........ platform/openwrt/rt.sh (instance того же сервиса)
#   warp process ...... platform/openwrt/warp.sh (instance того же сервиса)
#   nft/firewall ...... zapret2 (делегирование) + TG/RT/WARP chains/sets в ЕГО таблице
#                       (единственное исключение, см. пункт 8b)
#   interface sets .... zapret2 (reload_ifsets; hotplug только зовёт)
#   selective offload . zapret2 (FLOWOFFLOAD из конфига; своих правил нет)
# ровно два procd-СЕРВИСА в слое: z2k (ядро) + z2k-webpanel (панель,
# Stage 6, независимый lifecycle); z2k-detect остаётся on-demand CLI.
_n="$(ls "$REPO"/package/openwrt/files/etc/init.d/ 2>/dev/null | wc -l)"
assert_eq "два procd-сервиса (ядро + панель)" "2" "$(printf '%s' "$_n" | tr -d ' ')"
_n="$(grep -rl 'procd_open_instance' "$REPO/platform/openwrt" "$REPO/package/openwrt" 2>/dev/null | wc -l)"
assert_eq "шесть instance (4 ядра + customd + 1 панели)" "6" "$(printf '%s' "$_n" | tr -d ' ')"
# ifsets: единственный писатель — zapret2 (мы только вызываем reload).
# fw_verify ЧИТАЕТ wanif (nft list set — существование/заселённость), но не
# пишет: исключаем read-only list-линии из скана (запись — add/create/flush).
code | grep -vE 'nft list set' | grep -qE 'lanif|wanif|nft_fill_ifsets|add_element|create_set' \
    && _t_bad "адаптер пишет interface sets" || _t_ok
grep -q 'zapret_reload_ifsets' "$REPO/platform/openwrt/firewall.sh" \
    && _t_ok || _t_bad "нет делегирования ifsets в zapret2"
# firewall: builder — zapret2; narrow adapter hooks are custom.d return guards
# plus TG/RT/WARP glue (chains/sets in zapret2's table, never a new table).
# ifsets: единственный писатель — zapret2 (мы только вызываем reload;
# read-only list-исключение — см. выше).
code | grep -vE 'nft list set' | grep -qE 'lanif|wanif|nft_fill_ifsets|add_element|create_set' \
    && _t_bad "адаптер пишет interface sets" || _t_ok
grep -q 'zapret_reload_ifsets' "$REPO/platform/openwrt/firewall.sh" \
    && _t_ok || _t_bad "нет делегирования ifsets в zapret2"
_nftbuilders="$(grep -rlE 'nft add|nft create' "$REPO/platform/openwrt" "$REPO/package/openwrt" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
_expected="$REPO/platform/openwrt/customd.sh $REPO/platform/openwrt/rt.sh $REPO/platform/openwrt/tg.sh $REPO/platform/openwrt/warp.sh "
if [ -z "$_nftbuilders" ]; then
    _t_bad "нет TG/RT/WARP builder'ов (ожидались tg.sh rt.sh warp.sh)"
elif [ "$_nftbuilders" = "$_expected" ]; then
    _t_ok
else
    _t_bad "firewall строят не только tg.sh+rt.sh+warp.sh: $_nftbuilders"
fi
# 8b. TG/RT/WARP-исключение обусловлено: таблицу создаём НЕ мы (только runtime),
# перед записями — проверка её наличия; второго фреймворка нет.
code | grep -qE 'add table|create table' \
    && _t_bad "адаптер создаёт nft-таблицу" || _t_ok
grep -q '_z2k_ow_tg_table_ok' "$REPO/platform/openwrt/tg.sh" \
    && _t_ok || _t_bad "tg.sh пишет без проверки таблицы"
grep -q '_z2k_ow_rt_table_ok' "$REPO/platform/openwrt/rt.sh" \
    && _t_ok || _t_bad "rt.sh пишет без проверки таблицы"
grep -q '_z2k_ow_warp_table_ok' "$REPO/platform/openwrt/warp.sh" \
    && _t_ok || _t_bad "warp.sh пишет без проверки таблицы"
# Штатный /etc/init.d/firewall reload для fw4 допускается; запрещены команды
# второго firewall-фреймворка и прямой запуск fw4/iptables-правил.
code | grep -qE '(^|[;&|][[:space:]]*)(iptables[[:space:]]+(-A|-I)|(/usr/)?(sbin/)?fw3|(/usr/)?(sbin/)?fw4)([[:space:]]|$)' \
    && _t_bad "адаптер использует чужой firewall-фреймворк" || _t_ok
# offload уже покрыт пунктом 3; здесь — явное отсутствие второго владельца:
# writer-код слоя не содержит команд записи flowtable/offload.
code | grep -qiE 'nft[[:space:]]+(add|insert|replace|delete|flush|create)[[:space:]].*(flowtable|offload)|(^|[;&|[:space:]])-j[[:space:]]+FLOWOFFLOAD' \
    && _t_bad "второй offload-владелец (flowtable)" || _t_ok

_t_done
