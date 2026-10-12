#!/bin/sh
# Проверяет расчёт безопасного бюджета Telegram TCP-соединений.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tg-connection-budget"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/platform/openwrt/tg-policy.sh" || exit 1

assert_eq "Auto ограничен проверенной CPU-политикой, если ресурсов достаточно" \
    32 "$(z2k_ow_tg_connection_budget auto 32 1024 524288 318000 318000)"
assert_eq "меньший FD-бюджет ограничивает Manual" \
    14 "$(z2k_ow_tg_connection_budget manual 64 128 524288 318000 318000)"
assert_eq "Manual сохраняет заданный максимум при достаточном бюджете" \
    64 "$(z2k_ow_tg_connection_budget manual 64 1024 8388608 7340032 7340032)"
assert_eq "память ограничивает Auto с учётом baseline-резерва" \
    14 "$(z2k_ow_tg_connection_budget auto 32 1024 65536 30000 30000)"
assert_eq "исчерпанный memory budget запрещает запуск слотов" \
    0 "$(z2k_ow_tg_connection_budget auto 32 1024 65536 12000 30000)"
assert_eq "лимит FD ниже резерва не запускает прокси" \
    0 "$(z2k_ow_tg_connection_budget auto 32 32 524288 318000 318000)"
assert_eq "неизвестный режим безопасно сводится к Auto" \
    32 "$(z2k_ow_tg_connection_budget invalid 64 1024 524288 318000 318000)"
assert_eq "повреждённый ручной лимит безопасно сводится к Auto" \
    32 "$(z2k_ow_tg_connection_budget manual invalid 1024 524288 318000 318000)"
assert_eq "ручной лимит выше жёсткой границы безопасно сводится к Auto" \
    32 "$(z2k_ow_tg_connection_budget manual 129 1024 524288 318000 318000)"
assert_eq "нечисловые ресурсы запрещают вычислить лимит" \
    0 "$(z2k_ow_tg_connection_budget auto 32 unlimited 524288 318000 318000)"

_t_done
