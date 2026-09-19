#!/bin/sh
# platform/openwrt/generate.sh - генерация /etc/z2k/config штатным генератором.
#
# Вызывает НЕТРОНУТЫЙ upstream create_official_config (lib/config_official.sh)
# с явным путём канонического конфига. Все чтения стратегий/листов идут через
# ZAPRET2_DIR=$Z2K_ROOT (env.sh), supplementary-чтения ${ZAPRET2_DIR}/config —
# через симлинк bootstrap.sh. Результат — zapret2-совместимый конфиг:
# NFQWS2_OPT с реальными z2k-стратегиями + QNUM/marks/ports/offload для
# firewall-половины (firewall.sh скармливает этот же файл zapret2-функциям).
#
# Требует подключённых lib/utils.sh + lib/strategies.sh + lib/config_official.sh.

# The generated config is a published artifact.  Rebuilding it on every
# service start is both expensive on flash-backed routers and creates needless
# backup churn in callers that update only the daemon lifecycle.  Keep the
# decision here, beside the upstream generator, so every start path shares one
# dirty check.
Z2K_CONFIG_GENERATION_MARKER="${Z2K_CONFIG_GENERATION_MARKER:-${Z2K_STATE:-/etc/z2k/state}/config.generation}"
Z2K_CONFIG_BACKUP_KEEP="${Z2K_CONFIG_BACKUP_KEEP:-3}"

z2k_ow_hash_text() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v cksum >/dev/null 2>&1; then
        cksum | awk '{print $1 ":" $2}'
    else
        return 1
    fi
}

z2k_ow_hash_file() {
    [ -f "$1" ] || return 0
    printf 'file=%s\n' "$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v cksum >/dev/null 2>&1; then
        cksum "$1" | awk '{print $1 ":" $2}'
    else
        return 1
    fi
}

# Fingerprint semantic inputs, never mtimes.  The generated NFQWS2_OPT block
# is excluded from the user-config part because it is the output we publish;
# all other assignments (including RT/TG/WARP wiring and feature flags) are
# semantic inputs.  Payload generator code and materialized strategies are
# included so an updater can explicitly invalidate the published artifact by
# changing the payload without relying on timestamps.
z2k_ow_config_fingerprint() {
    local _cfg="${1:-$Z2K_CONFIG}" _f _d
    {
        printf 'z2k-config-fingerprint-v1\n'
        if [ -f "$_cfg" ]; then
            awk '
                /^NFQWS2_OPT="/ { in_opt=1; next }
                in_opt && /^"[[:space:]]*$/ { in_opt=0; next }
                !in_opt { print }
            ' "$_cfg"
        fi
        for _f in \
            "$Z2K_LIB/config_official.sh" "$Z2K_LIB/strategies.sh" \
            "$Z2K_LIB/utils.sh" "$Z2K_ROOT/strats_new2.txt" \
            "$Z2K_CONF_DIR/strategies.conf" "$Z2K_CONF_DIR/quic_strategies.conf" \
            "$Z2K_HOSTLIST_EXCLUDE_EXTRA"; do
            z2k_ow_hash_file "$_f" || return 1
        done
        for _d in "$Z2K_EXTRA_STRATS_DIR" "$Z2K_LISTS_DIR" "$Z2K_USER_LISTS"; do
            [ -d "$_d" ] || continue
            find "$_d" -type f -print 2>/dev/null | sort | while IFS= read -r _f; do
                z2k_ow_hash_file "$_f" || exit 1
            done
        done
    } | z2k_ow_hash_text
}

z2k_ow_config_looks_valid() {
    [ -s "$Z2K_CONFIG" ] || return 1
    grep -q '^NFQWS2_OPT="' "$Z2K_CONFIG" || return 1
    # The generated multiline assignment must have a closing quote.  This is
    # deliberately a cheap structural gate used only to adopt an old config
    # that predates the generation marker; dirty configs still regenerate.
    awk '
        /^NFQWS2_OPT="/ { in_opt=1; next }
        in_opt && /^"[[:space:]]*$/ { found=1; exit }
        END { exit(found ? 0 : 1) }
    ' "$Z2K_CONFIG"
}

z2k_ow_config_backup_prune() {
    local _keep="${Z2K_CONFIG_BACKUP_KEEP:-3}" _n=0 _f
    case "$_keep" in ''|*[!0-9]*) _keep=3 ;; esac
    # The upstream helper names these by second.  Keep the newest bounded set;
    # pruning is only part of an actual regeneration, never a healthy start.
    for _f in $(ls -1t "$(dirname "$Z2K_CONFIG")/$(basename "$Z2K_CONFIG").backup."* 2>/dev/null); do
        _n=$((_n + 1))
        [ "$_n" -le "$_keep" ] || rm -f "$_f" 2>/dev/null || true
    done
}

z2k_ow_generate() {
    [ -f "$Z2K_CONFIG" ] || { echo "z2k-openwrt: нет $Z2K_CONFIG (сначала bootstrap)" >&2; return 1; }
    local _fp _old _dirty=0 _force="${Z2K_FORCE_CONFIG_REGEN:-0}"
    _fp=$(z2k_ow_config_fingerprint) || {
        echo "z2k-openwrt: не удалось посчитать fingerprint входов config" >&2
        return 1
    }
    [ -f "${Z2K_AU_DIRTY_TREE_FILE:-}" ] && _dirty=1
    if [ "$_force" != "1" ] && [ "$_dirty" = "0" ] && [ -s "$Z2K_CONFIG_GENERATION_MARKER" ]; then
        _old=$(cat "$Z2K_CONFIG_GENERATION_MARKER" 2>/dev/null)
        if [ "$_old" = "$_fp" ] && z2k_ow_config_looks_valid; then
            return 0
        fi
    fi
    # Adopt a valid pre-marker config once.  This avoids a surprise rewrite on
    # the first restart after upgrading the adapter; subsequent starts are
    # guarded by the content fingerprint.
    if [ "$_force" != "1" ] && [ "$_dirty" = "0" ] && \
       [ ! -s "$Z2K_CONFIG_GENERATION_MARKER" ] && z2k_ow_config_looks_valid; then
        mkdir -p "$(dirname "$Z2K_CONFIG_GENERATION_MARKER")" 2>/dev/null || return 1
        printf '%s\n' "$_fp" > "$Z2K_CONFIG_GENERATION_MARKER" || return 1
        return 0
    fi
    # create_official_config intentionally consumes FLOWOFFLOAD from its
    # environment.  On OpenWrt the selected mode is also a persisted config
    # value, so feed it back only when the caller did not provide an explicit
    # override.  Keep the variable local: one generation must not contaminate
    # a later operation in the long-lived init shell.
    local _flowoffload_env_set=0 _flowoffload
    [ "${FLOWOFFLOAD+x}" = x ] && _flowoffload_env_set=1
    local FLOWOFFLOAD="${FLOWOFFLOAD-}"
    if [ "$_flowoffload_env_set" = "0" ] && [ -f "$Z2K_CONFIG" ]; then
        _flowoffload=$(sed -n 's/^[[:space:]]*FLOWOFFLOAD[[:space:]]*=[[:space:]]*//p' \
            "$Z2K_CONFIG" 2>/dev/null | tail -1 | tr -d "[:space:]'\"")
        case "$_flowoffload" in
            none|software|hardware|donttouch) FLOWOFFLOAD="$_flowoffload" ;;
        esac
    fi
    create_official_config "$Z2K_CONFIG" || return 1
    mkdir -p "$(dirname "$Z2K_CONFIG_GENERATION_MARKER")" 2>/dev/null || return 1
    printf '%s\n' "$_fp" > "$Z2K_CONFIG_GENERATION_MARKER" || return 1
    [ -f "${Z2K_AU_DIRTY_TREE_FILE:-}" ] && rm -f "$Z2K_AU_DIRTY_TREE_FILE" 2>/dev/null || true
    z2k_ow_config_backup_prune
    # Мост $Z2K_ROOT/config обязан остаться симлинком: генератор пишет
    # "$Z2K_CONFIG.new.$$"+rename по ЯВНОМУ пути, но если кто-то начнёт
    # писать в ${ZAPRET2_DIR}/config — rename подменит симлинк файлом и
    # /etc/z2k/config протухнет. Ловим класс целиком.
    if [ ! -L "$Z2K_ROOT/config" ]; then
        echo "z2k-openwrt: $Z2K_ROOT/config больше не симлинк — кто-то пишет в \${ZAPRET2_DIR}/config" >&2
        return 1
    fi
    return 0
}
