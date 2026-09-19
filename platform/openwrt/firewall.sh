#!/bin/sh
# platform/openwrt/firewall.sh - граница владения firewall/nft.
#
# ТАБЛИЦА ВЛАДЕНИЯ (единственная, см. contract):
#   процесс nfqws2 ............ z2k procd-сервис (init.d/z2k). Причина: OPT_BASE
#     stock zapret2-init жёстко зашит в скрипте без z2k lua-init/--blob/
#     --bind-fix — через конфиг не инжектится, делегировать нечего.
#   nft-таблица zapret2 ...... zapret2 runtime (zapret_apply_firewall/remove).
#   lan/wan ifsets ........... zapret2 runtime (reload_ifsets по hotplug).
#   QNUM/marks/ports ......... ОБЩИЕ: лежат в /etc/z2k/config, демон и firewall
#     читают один файл (тест сверяет равенство).
#   flow offload ............. zapret2 runtime (FLOWOFFLOAD из того же конфига;
#     своих offload-правил адаптер НЕ создаёт — см. тест ownership).
#   custom.d ................. РАЗДЕЛЬНО: zapret2/custom.d — runtime'а (пуст
#     upstream); z2k/custom.d — наш раннер ниже (будущие TG/RT/WARP-хуки).
#
# Делегирование — вызовом РЕАЛЬНЫХ функций zapret2 (functions сорсится лениво
# здесь; на тестах без runtime — только раннер custom.d, он автономен).

_Z2K_OW_FW_SOURCED=""

z2k_ow_fw_source() {
    [ -n "$_Z2K_OW_FW_SOURCED" ] && return 0
    local _f="$Z2K_ZAPRET2_RUNTIME/init.d/openwrt/functions"
    [ -f "$_f" ] || { echo "z2k-openwrt: нет zapret2 runtime: $_f" >&2; return 1; }
    # shellcheck disable=SC1090
    . "$_f" || return 1
    _Z2K_OW_FW_SOURCED=1
}

# Применить/снять firewall zapret2 (читает $ZAPRET_CONFIG=/etc/z2k/config).
z2k_ow_fw_apply() { z2k_ow_fw_source || return 1; zapret_apply_firewall; }
z2k_ow_fw_remove() { z2k_ow_fw_source || return 1; zapret_unapply_firewall; }
z2k_ow_fw_reload_ifsets() { z2k_ow_fw_source || return 1; zapret_reload_ifsets; }

# fw4 global flow offload and zapret2 selective offload cannot own the same
# dataplane simultaneously: fw4 may shortcut a flow before NFQUEUE sees it.
# Keep the user values (including an option that was absent) in persistent
# state, disable both global switches while this service owns NFQUEUE, and
# restore the exact UCI shape after zapret2 has removed its own rules.
_z2k_ow_fw4_uci_get() {
    command -v uci >/dev/null 2>&1 || return 127
    uci -q get "firewall.@defaults[0].$1" 2>/dev/null
}

_z2k_ow_fw4_has_global_offload() {
    local _key _value
    for _key in flow_offloading flow_offloading_hw; do
        _value="$(_z2k_ow_fw4_uci_get "$_key")" || continue
        [ "$_value" = "1" ] && return 0
    done
    return 1
}

_z2k_ow_fw4_snapshot() {
    local _state _tmp _key _value _present
    _state="${Z2K_FW4_OFFLOAD_STATE:-${Z2K_STATE:-/etc/z2k/state}/fw4-offload.state}"
    _tmp="${_state}.tmp.$$"
    [ -f "$_state" ] && return 0
    mkdir -p "$(dirname "$_state")" 2>/dev/null || return 1
    : > "$_tmp" || return 1
    for _key in flow_offloading flow_offloading_hw; do
        _present=0; _value=""
        if _value="$(_z2k_ow_fw4_uci_get "$_key")"; then
            _present=1
        fi
        printf '%s\t%s\t%s\n' "$_key" "$_present" "$_value" >> "$_tmp" || {
            rm -f "$_tmp"; return 1;
        }
    done
    mv -f "$_tmp" "$_state" 2>/dev/null || {
        rm -f "$_tmp"; return 1;
    }
}

_z2k_ow_fw4_reload() {
    local _reload="${Z2K_FW4_RELOAD:-/etc/init.d/firewall}"
    [ -x "$_reload" ] || {
        echo "z2k-openwrt: fw4 reload helper missing: $_reload" >&2
        return 1
    }
    "$_reload" reload >/dev/null 2>&1
}

z2k_ow_offload_prepare() {
    [ "${INIT_APPLY_FW:-1}" = "1" ] || return 0
    command -v uci >/dev/null 2>&1 || return 0
    _z2k_ow_fw4_has_global_offload || return 0
    _z2k_ow_fw4_snapshot || return 1
    uci -q set firewall.@defaults[0].flow_offloading=0 || return 1
    uci -q set firewall.@defaults[0].flow_offloading_hw=0 || return 1
    uci -q commit firewall || return 1
    _z2k_ow_fw4_reload
}

z2k_ow_offload_restore() {
    local _state _key _present _value _changed=0
    _state="${Z2K_FW4_OFFLOAD_STATE:-${Z2K_STATE:-/etc/z2k/state}/fw4-offload.state}"
    [ -f "$_state" ] || return 0
    command -v uci >/dev/null 2>&1 || return 1
    while IFS="$(printf '\t')" read -r _key _present _value; do
        [ -n "$_key" ] || continue
        if [ "$_present" = "1" ]; then
            uci -q set "firewall.@defaults[0].$_key=$_value" || return 1
        else
            uci -q delete "firewall.@defaults[0].$_key" || return 1
        fi
        _changed=1
    done < "$_state"
    [ "$_changed" = "1" ] || return 1
    uci -q commit firewall || return 1
    _z2k_ow_fw4_reload || return 1
    rm -f "$_state"
}

# z2k_ow_fw_check — periodic convergence (cron, p-84.20 parity): сверяет
# КАЖДЫЙ required invariant через fw_verify (не count), при дрейфе — ОДНА
# попытка re-apply + повторная сверка. Упорный провал = снять ready
# (degraded виден), демона НЕ дёргаем (трафик уже fail-open мимо очереди;
# рестарт-шторм каждые 5 минут хуже). No-ready = немедленный возврат
# (воскрешать нечего и нельзя). INIT_APPLY_FW=0 = чужой fw, скип.
z2k_ow_fw_check() {
    [ "${INIT_APPLY_FW:-1}" = "1" ] || return 0
    local _ready="${Z2K_CORE_READY:-${Z2K_RUN:-/tmp/z2k/runtime}/core-ready}"
    # A clean stop wins over a race with cron while procd is still tearing
    # down the instance.  Crash recovery has no stopping fence and can pass
    # through the same consumer predicate after procd respawns the process.
    if [ -f "${Z2K_RUN:-/tmp/z2k/runtime}/stopping" ]; then
        rm -f "$_ready" 2>/dev/null
        return 0
    fi
    "${INIT_SCRIPT:-/etc/init.d/z2k}" running >/dev/null 2>&1 || {
        rm -f "$_ready" 2>/dev/null
        return 0
    }
    if command -v z2k_ow_nfqws_consumer_ready >/dev/null 2>&1; then
        z2k_ow_nfqws_consumer_ready || {
            rm -f "$_ready" 2>/dev/null
            return 0
        }
    fi
    # Do not race service_started while the initial procd transaction is
    # waiting for its post-commit consumer check.
    [ ! -f "${Z2K_RUN:-/tmp/z2k/runtime}/starting" ] || return 0
    z2k_ow_offload_prepare >/dev/null 2>&1 || {
        rm -f "$_ready" 2>/dev/null
        return 0
    }
    z2k_ow_fw_verify >/dev/null 2>&1 && {
        : > "$_ready" 2>/dev/null
        return 0
    }
    z2k_ow_fw_apply >/dev/null 2>&1 || return 0
    z2k_ow_fw_verify >/dev/null 2>&1 && {
        : > "$_ready" 2>/dev/null
        return 0
    }
    rm -f "$_ready" 2>/dev/null
    echo "z2k-openwrt: fw_check: инварианты не сошлись после re-apply — ready снят (degraded)" >&2
    return 0
}

# z2k_ow_fw_verify — доказать КОНЕЧНОЕ СТАТИЧЕСКОЕ состояние dataplane
# (live-урок p-84.17: apply вернул 0, queue-правила встали, но hook jumps не
# встали — ipsets не создались, трафик шёл мимо очереди при живом nfqws2).
# СТРОГО статика: sets/jumps/rules. Consumer/process-доказательства здесь
# ЗАПРЕЩЕНЫ: verify зовётся из start_service ДО commit в procd, процессов
# там ещё нет (live-урок: consumer-check здесь ронял каждый старт).
# Ожидаемая структура выводится из runtime+конфига, а не из захардкоженного
# дампа: таблица ${ZAPRET_NFT_TABLE:-zapret2}, сеты ${ZIPSET_EXCLUDE*}
# (= nozapret/nozapret6 в def.sh), заселённый wanif, hook→chain jumps,
# NFQUEUE qnum == $QNUM из конфига.
z2k_ow_fw_verify() {
    local _tab="${Z2K_ZAPRET_NFT_TABLE:-${ZAPRET_NFT_TABLE:-zapret2}}"
    local _q="${QNUM:-200}" _c
    command -v nft >/dev/null 2>&1 || {
        echo "z2k-openwrt: fw_verify: нет nft" >&2; return 1; }
    for _s in nozapret nozapret6; do
        nft list set inet "$_tab" "$_s" >/dev/null 2>&1 || {
            echo "z2k-openwrt: fw_verify: нет сета $_s (ipsets не созданы?)" >&2
            return 1; }
    done
    # wanif заселён (пустой = jump'ы с фильтром никуда не ведут; IPv4-аплинк
    # обязан быть — без него роутеру нечего обходить). wanif6 может быть
    # легитимно пуст (нет IPv6-аплинка — фильтр тогда не ставится, jump
    # работает без него), требуется только существование.
    # NB: имена сетов — только в nft-вызовах выше; echo/комментарии их не
    # содержат (ownership-guard: единственный писатель ifsets — zapret2).
    nft list set inet "$_tab" wanif 2>/dev/null | grep -q '"' || {
        echo "z2k-openwrt: fw_verify: пуст uplink-сет (аплинк не резолвится?)" >&2
        return 1; }
    nft list set inet "$_tab" wanif6 >/dev/null 2>&1 || {
        echo "z2k-openwrt: fw_verify: нет v6 uplink-сета" >&2
        return 1; }
    for _pair in "postnat_hook postnat" "prenat_hook prenat"; do
        set -- $_pair
        nft list chain inet "$_tab" "$1" 2>/dev/null | grep -q "jump $2" || {
            echo "z2k-openwrt: fw_verify: нет jump $2 в $1 (dataplane недостижим)" >&2
            return 1; }
        nft list chain inet "$_tab" "$2" 2>/dev/null | grep -q "to $_q" || {
            echo "z2k-openwrt: fw_verify: нет NFQUEUE qnum $_q в $2" >&2
            return 1; }
    done
    return 0
}

# z2k_ow_runtime_preflight — fail loudly ДО procd (start gate).
# Ложный success прошлого live: POST /service/start -> job exit=0, процесс
# exit=127 (нет бинарника), UI потом показывал stopped. Проверяем здесь:
# демон +x, functions, fork-lua (plain или .gz, как в optbase.sh).
# Сообщение — точный путь (runtime_missing: ...); rc!=0 роняет start_service
# до создания instance, а webpanel job — в exit!=0.
z2k_ow_runtime_preflight() {
    local _n _rt="${Z2K_ZAPRET2_RUNTIME:-/opt/zapret2}"
    local _nfqws2="${Z2K_NFQWS2:-$_rt/nfq2/nfqws2}"
    [ -x "$_nfqws2" ] || {
        echo "z2k-openwrt: runtime_missing: $_nfqws2 (поставьте z2k-zapret2-runtime)" >&2
        return 1
    }
    [ -f "$_rt/init.d/openwrt/functions" ] || {
        echo "z2k-openwrt: runtime_missing: $_rt/init.d/openwrt/functions" >&2
        return 1
    }
    for _n in zapret-lib.lua zapret-antidpi.lua zapret-auto.lua; do
        if [ ! -f "$_rt/lua/$_n" ] && [ ! -f "$_rt/lua/$_n.gz" ]; then
            echo "z2k-openwrt: runtime_missing: $_rt/lua/$_n" >&2
            return 1
        fi
    done
    # Required z2k-owned binaries (инвариант fresh-install completeness):
    # tg-mtproxy-client, z2k-rt-proxy, z2k-detect ставит ensure-binaries
    # (postinst best-effort / updater); WARP — optional (кнопка), здесь
    # не проверяется. Отсутствующий required — громкий отказ, а не
    # молчаливый skip: silent-degraded core хуже нестартанувшего.
    for _n in tg-mtproxy-client z2k-rt-proxy z2k-detect; do
        if [ ! -x "${Z2K_BIN:-/usr/lib/z2k/bin}/$_n" ]; then
            echo "z2k-openwrt: missing required binary: ${Z2K_BIN:-/usr/lib/z2k/bin}/$_n (fresh install incomplete: нет сети для ensure?)" >&2
            return 1
        fi
    done
    # Executable-биты runtime (live-урок p-84.17: create_ipset.sh уехал 0644 —
    # Permission denied убил ipsets и весь dataplane при живом nfqws2).
    for _n in nfq2/nfqws2 ip2net/ip2net mdig/mdig ipset/create_ipset.sh; do
        if [ ! -x "$_rt/$_n" ]; then
            echo "z2k-openwrt: runtime_not_executable: $_rt/$_n" >&2
            return 1
        fi
    done
    # RT capability --so-mark (p-84.17 contract): бинарь без флага + адаптер
    # с флагом = тихий mismatch (мост без метки, движок гоняется за туннелем).
    # The immutable binary is scanned once per content hash.  Subsequent
    # restarts compute the cheap cryptographic hash and consult the proof,
    # while a changed binary necessarily re-enters the loud capability gate.
    if [ -x "${Z2K_BIN:-/usr/lib/z2k/bin}/z2k-rt-proxy" ]; then
        local _rtbin="${Z2K_BIN:-/usr/lib/z2k/bin}/z2k-rt-proxy" \
              _rtproof="${Z2K_RUNTIME_CAPABILITY_CACHE:-${Z2K_STATE:-${Z2K_ETC:-/etc/z2k}/state}/runtime-capabilities}" \
              _rthash=""
        if command -v sha256sum >/dev/null 2>&1; then
            _rthash=$(sha256sum "$_rtbin" 2>/dev/null | awk '{print $1}')
        else
            echo "z2k-openwrt: runtime_not_capable: sha256sum отсутствует, proof z2k-rt-proxy невозможен" >&2
            return 1
        fi
        if [ -z "$_rthash" ] || ! grep -qxF "$_rthash|so-mark=1" "$_rtproof" 2>/dev/null; then
            if ! grep -q 'so-mark' "$_rtbin" >/dev/null 2>&1; then
                echo "z2k-openwrt: runtime_not_capable: z2k-rt-proxy без --so-mark (старый бинарь?)" >&2
                return 1
            fi
            mkdir -p "$(dirname "$_rtproof")" 2>/dev/null || return 1
            printf '%s|so-mark=1\n' "$_rthash" > "${_rtproof}.tmp.$$" 2>/dev/null || return 1
            mv -f "${_rtproof}.tmp.$$" "$_rtproof" 2>/dev/null || {
                rm -f "${_rtproof}.tmp.$$" 2>/dev/null; return 1;
            }
        fi
    fi
    return 0
}

# --- z2k custom.d: точка расширения для будущих RT/WARP-демонов ---
# Контракт повторяет zapret2 custom_runner, отдельный неймспейс:
# каждый $Z2K_CUSTOM_DIR/*.sh может определить z2k_custom_daemons(),
# которая вызывается с $1=1 (start) / 0 (stop). DISABLE_CUSTOM=1 (дефолт
# upstream) раннер гасит целиком.
#
# TG (Stage 3) через этот раннер НЕ идёт осознанно: DISABLE_CUSTOM не должен
# гасить first-class feature — tg.sh вызывается из init.d/z2k напрямую.
Z2K_CUSTOM_DIR="${Z2K_CUSTOM_DIR:-$Z2K_ADAPTER_DIR/custom.d}"

z2k_ow_custom_daemons() {
    [ "${DISABLE_CUSTOM:-1}" = "1" ] && return 0
    [ -d "$Z2K_CUSTOM_DIR" ] || return 0
    local _script
    for _script in "$Z2K_CUSTOM_DIR"/*.sh; do
        [ -f "$_script" ] || continue
        unset -f z2k_custom_daemons
        # shellcheck disable=SC1090
        . "$_script"
        if command -v z2k_custom_daemons >/dev/null 2>&1; then
            z2k_custom_daemons "$1" || return 1
        fi
    done
    return 0
}
