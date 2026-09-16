#!/bin/sh
# platform/openwrt/bootstrap.sh - идемпотентный bootstrap persistent-состояния.
#
# Вызывается из procd-сервиса перед генерацией (и из package postinst).
# НЕ пишет в payload ($Z2K_ROOT read-only): только /etc/z2k и /tmp/z2k.
#
# Маркер инициализации payload и seed-tarball. Model A: seed — ТОЛЬКО
# bootstrap для пустой установки, никогда — upgrade payload. Правило см.
# z2k_ow_seed_ensure ниже.
Z2K_PAYLOAD_MARKER="${Z2K_PAYLOAD_MARKER:-$Z2K_ETC/.payload-initialized}"
Z2K_SEED_TARBALL="${Z2K_SEED_TARBALL:-$Z2K_ROOT/share/seed.tar.gz}"
# Корень извлечения seed ("/" в проде; тестам — sysroot).
Z2K_SEED_DEST="${Z2K_SEED_DEST:-/}"
# Минимальный обязательный payload (относительно $Z2K_ROOT): marker ставится
# только когда всё это на месте, и проверяется при каждом ensure.
# share/seed.meta — тоже required: без него tag установить не из чего.
Z2K_PAYLOAD_REQUIRED="${Z2K_PAYLOAD_REQUIRED:-lib/utils.sh lib/config_official.sh lib/strategies.sh lua/z2k-alert.lua lua/z2k-state-persist.lua strats_new2.txt extra_strats/TCP/RKN/Strategy.txt share/seed.meta}"
#
# Мосты, которые создаёт z2k_ow_bootstrap (обоснование — в contract):
#   $Z2K_ROOT/config → /etc/z2k/config (чтения ${ZAPRET2_DIR}/config внутри
#     generate_*; запись идёт явным путём мимо симлинка, он в безопасности);
#   lists/whitelist.txt → /etc/z2k/user-lists/whitelist.txt (user-owned);
#   lists/discovered-domains.txt → /etc/z2k/state/discovered-domains.txt
#     (публикации демона; генератор ссылается безусловно).
#
# Требует выставленных путей (env.sh).

z2k_ow_bootstrap() {
    # --- каталоги ---
    mkdir -p "$Z2K_ETC" "$Z2K_STATE" "$Z2K_USER_LISTS" "$Z2K_CONF_DIR" \
             "$Z2K_RUN" "$Z2K_LOCKS" "$Z2K_LOG" "$Z2K_DOWNLOADS" "$Z2K_GENERATED" \
        || return 1

    # --- канонический конфиг ---
    if [ ! -f "$Z2K_CONFIG" ]; then
        if [ -f "$Z2K_ROOT/share/config.default" ]; then
            cp -f "$Z2K_ROOT/share/config.default" "$Z2K_CONFIG" || return 1
        else
            echo "z2k-openwrt: нет ни $Z2K_CONFIG, ни дефолта" >&2
            return 1
        fi
    fi

    # --- мост supplementary-reads ---
    if [ ! -L "$Z2K_ROOT/config" ]; then
        [ -e "$Z2K_ROOT/config" ] && {
            echo "z2k-openwrt: $Z2K_ROOT/config существует и не симлинк — отказываюсь" >&2
            return 1
        }
        ln -s "$Z2K_CONFIG" "$Z2K_ROOT/config" || return 1
    fi

    # --- stateful-члены lists (пустые плейсхолдеры по образцу install.sh) ---
    if [ ! -L "$Z2K_LISTS_DIR/whitelist.txt" ]; then
        [ -e "$Z2K_LISTS_DIR/whitelist.txt" ] && {
            echo "z2k-openwrt: lists/whitelist.txt существует и не симлинк" >&2
            return 1
        }
        # Create the user-owned source before linking.  BusyBox accepts a
        # dangling link, but Windows-backed test filesystems reject it.
        [ -e "$Z2K_USER_LISTS/whitelist.txt" ] || : > "$Z2K_USER_LISTS/whitelist.txt" || return 1
        ln -s "$Z2K_USER_LISTS/whitelist.txt" "$Z2K_LISTS_DIR/whitelist.txt" || return 1
    fi
    if [ ! -L "$Z2K_LISTS_DIR/discovered-domains.txt" ]; then
        [ -e "$Z2K_LISTS_DIR/discovered-domains.txt" ] && {
            echo "z2k-openwrt: lists/discovered-domains.txt существует и не симлинк" >&2
            return 1
        }
        [ -e "$Z2K_STATE/discovered-domains.txt" ] || : > "$Z2K_STATE/discovered-domains.txt" || return 1
        ln -s "$Z2K_STATE/discovered-domains.txt" "$Z2K_LISTS_DIR/discovered-domains.txt" || return 1
    fi
    for _f in "$Z2K_USER_LISTS/whitelist.txt" "$Z2K_STATE/discovered-domains.txt" \
             "$Z2K_STATE/tcp16_asn.txt" "$Z2K_STATE/tcp16_sni.txt"; do
        [ -e "$_f" ] || : > "$_f" || return 1
    done

    # Runtime-копия extra-domains сидируется shipped-базой (как install.sh на
    # Keenetic): пользователь правит файл, который видит, а 3-way merge
    # считает добавленные строки его собственными.
    if [ ! -e "$Z2K_USER_LISTS/extra-domains.txt" ]; then
        if [ -s "$Z2K_LISTS_DIR/extra-domains.txt" ]; then
            cp -f "$Z2K_LISTS_DIR/extra-domains.txt" "$Z2K_USER_LISTS/extra-domains.txt" || return 1
        else
            : > "$Z2K_USER_LISTS/extra-domains.txt" || return 1
        fi
    fi

    # --- Strategy.txt прематериализованы сборкой; отсутствие = fail-closed ---
    for _p in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
        [ -s "$Z2K_EXTRA_STRATS_DIR/$_p/Strategy.txt" ] || {
            echo "z2k-openwrt: нет $Z2K_EXTRA_STRATS_DIR/$_p/Strategy.txt (сборка не материализовала стратегии)" >&2
            return 1
        }
    done

    # --- fork-lua в runtime: только предупреждение (зависимость пакета) ---
    for _f in zapret-lib.lua zapret-antidpi.lua zapret-auto.lua; do
        if [ ! -f "$Z2K_ZAPRET2_RUNTIME/lua/$_f" ] && \
           [ ! -f "$Z2K_ZAPRET2_RUNTIME/lua/$_f.gz" ]; then
            echo "z2k-openwrt: предупреждение: нет $Z2K_ZAPRET2_RUNTIME/lua/$_f (поставьте zapret2 runtime)" >&2
        fi
    done
    return 0
}

# z2k_ow_payload_ok — 0, если весь Z2K_PAYLOAD_REQUIRED на месте и непуст.
z2k_ow_payload_ok() {
    local _r
    for _r in $Z2K_PAYLOAD_REQUIRED; do
        [ -s "$Z2K_ROOT/$_r" ] || return 1
    done
    return 0
}

# z2k_ow_payload_empty — 0, если от payload нет НИЧЕГО (ни одного required).
# Отличие empty от partial — load-bearing: empty = известные хорошие состояния
# (fresh, prerm-purge, sysupgrade-wipe) — seed content там правильный ответ;
# partial = неизвестное повреждение — seed content мог бы откатить updater-
# файлы под стоящим тегом (Scenario D), поэтому только громкий провал.
z2k_ow_payload_empty() {
    local _r
    for _r in $Z2K_PAYLOAD_REQUIRED; do
        [ -e "$Z2K_ROOT/$_r" ] && return 1
    done
    return 0
}

# z2k_ow_payload_meta_tag — tag из payload.meta (пусто если нет/битая).
z2k_ow_payload_meta_tag() {
    [ -f "$Z2K_ROOT/share/payload.meta" ] || return 1
    local _t
    _t=$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/payload.meta" 2>/dev/null | head -1 | tr -d ' \t\r\n')
    case "$_t" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    printf '%s' "$_t"
    return 0
}

# z2k_ow_reconcile_tag — tag := payload.meta (идемпотентно).
# Единственное место, пишущее installed-tag в adapter'е. Правила:
#   meta валидна + tag любой -> tag := meta (ПЕРЕЗАПИСЬ при расхождении).
#     Это НЕ откат: meta пишется только ПОСЛЕ доказанной полноты payload
#     (seed: extract+verify; update: files+verify pre-tag), а tag — всегда
#     ПОСЛЕ meta. Значит meta новее-or-равна истине о payload, а tag, ей
#     противоречащий, — ложь (crash между meta и tag; stale после wipe+
#     reextract). Ошибка возможна лишь в сторону повторной доставки.
#   tag == meta -> ничего (normal upgrade: tag НЕ трогаем никогда — I5).
#   meta отсутствует/бита + tag ЕСТЬ + payload ok -> meta := tag (ADOPT,
#     громко; одноразовое заживление pre-meta эпохи, см. тело).
#   meta отсутствует/бита + tag отсутствует -> провал (истины нет нигде).
# Формат записи — как au_write_installed_tag (tmp+rename+re-read).
z2k_ow_reconcile_tag() {
    local _tagfile="${Z2K_AU_INSTALLED_TAG_FILE:-$Z2K_STATE/installed-tag}"
    local _meta="" _cur="" _have_tag=0
    _meta=$(z2k_ow_payload_meta_tag 2>/dev/null) || _meta=""
    [ -f "$_tagfile" ] && \
        _cur=$(tr -d ' \t\r\n' < "$_tagfile" 2>/dev/null)
    [ -n "$_cur" ] && _have_tag=1
    if [ -z "$_meta" ]; then
        # ADOPT (одноразово, громко): meta нет, но tag есть и payload цел.
        # Pre-meta эпоха: tag двигался только после доставки, payload_ok gate
        # держит — утверждение "payload==tag" ошибается лишь в сторону
        # повторной доставки, никогда в false-current. Без adopt апгрейд со
        # старого пакета умирал бы с невозможностью обновляться.
        # meta нет + tag нет -> FAIL (истины нет нигде).
        [ "$_have_tag" = "1" ] || {
            echo "z2k-openwrt: нет валидной payload.meta и нет tag — версию установить не из чего" >&2
            return 1
        }
        mkdir -p "$(dirname "$Z2K_ROOT/share/payload.meta")" 2>/dev/null || return 1
        { printf 'platform=%s\n' "${Z2K_PLATFORM:-openwrt}"
          printf 'tag=%s\n' "$_cur"
          printf 'ref=\n'
        } > "$Z2K_ROOT/share/payload.meta.new.$$" 2>/dev/null || return 1
        mv -f "$Z2K_ROOT/share/payload.meta.new.$$" "$Z2K_ROOT/share/payload.meta" 2>/dev/null || return 1
        echo "z2k-openwrt: payload.meta reconstructed from installed-tag $_cur (pre-meta era, once)" >&2
        return 0
    fi
    [ "$_cur" = "$_meta" ] && return 0
    mkdir -p "$(dirname "$_tagfile")" 2>/dev/null || return 1
    printf '%s\n' "$_meta" > "${_tagfile}.new.$$" 2>/dev/null || return 1
    mv -f "${_tagfile}.new.$$" "$_tagfile" 2>/dev/null || return 1
    _cur=$(tr -d ' \t\r\n' < "$_tagfile" 2>/dev/null)
    [ "$_cur" = "$_meta" ] || return 1
    return 0
}

# z2k_ow_reseed_from_seed — ЕДИНСТВЕННАЯ операция замены payload seed'ом.
# Транзакция (marker снимается ПЕРВЫМ, ставится ПОСЛЕДНИМ):
#   1. invalidate marker (rm -f; дальше любой провал = marker absent)
#   2. extract seed (tarball обязан существовать)
#   3. bootstrap
#   4. verify required payload (включая payload.meta из tarball)
#   5. reconcile tag := payload.meta (I3: re-seed ВСЕГДА переписывает tag,
#      даже поверх более нового — payload теперь seed, tag обязан сказать X)
#   6. marker ПОСЛЕДНИМ
# Любой провал -> marker absent (I1: marker ⇒ verified). Повтор сходится.
z2k_ow_reseed_from_seed() {
    local _tagfile="${Z2K_AU_INSTALLED_TAG_FILE:-$Z2K_STATE/installed-tag}"
    rm -f "$Z2K_PAYLOAD_MARKER" 2>/dev/null
    # Провал на ЛЮБОМ шаге снимает и stale tag (rm): tag без marker + без
    # гарантии payload — ложное утверждение версии (I2). Чистый S1 вместо него.
    [ -f "$Z2K_SEED_TARBALL" ] || {
        echo "z2k-openwrt: нет seed $Z2K_SEED_TARBALL — re-seed невозможен" >&2
        rm -f "$_tagfile" 2>/dev/null; return 1
    }
    tar -xzf "$Z2K_SEED_TARBALL" -C "$Z2K_SEED_DEST" || {
        echo "z2k-openwrt: извлечение seed не удалось" >&2
        rm -f "$_tagfile" 2>/dev/null; return 1
    }
    z2k_ow_bootstrap || { rm -f "$_tagfile" 2>/dev/null; return 1; }
    z2k_ow_payload_ok || {
        echo "z2k-openwrt: payload неполон после extract — молчаливого success не будет" >&2
        rm -f "$_tagfile" 2>/dev/null; return 1
    }
    z2k_ow_reconcile_tag || { rm -f "$_tagfile" 2>/dev/null; return 1; }
    : > "$Z2K_PAYLOAD_MARKER" || { rm -f "$_tagfile" 2>/dev/null; return 1; }
    return 0
}

# z2k_ow_seed_ensure — диспетчер (НЕ извлекает сам, кроме вызова транзакции).
#   marker + payload ok -> bootstrap + verify (upgrade: НИЧЕГО не трогаем,
#     tag/payload побайтово целы — I5);
#   no marker + payload ok -> bootstrap + verify + reconcile-if-missing +
#     mark (идемпотентное завершение);
#   payload empty (+ tarball) -> re-seed transaction (prerm-purge/sysupgrade
#     repair; fresh install);
#   marker + partial -> invalidate marker + FAIL (неизвестное повреждение:
#     blind overwrite запрещён; следующий запуск увидит no-marker+partial
#     и сделает re-seed с нуля — damage уже не verified, терять нечего);
#   no marker + partial -> re-seed transaction (ничего verified не было);
#   tarball отсутствует там, где нужен -> FAIL.
z2k_ow_seed_ensure() {
    if z2k_ow_payload_ok; then
        z2k_ow_bootstrap || return 1
        z2k_ow_payload_ok || return 1
        # Reconcile ВСЕГДА (не только без marker): updater-crash оставляет
        # marker + tag != meta; equal-case — noop (I5: upgrade ничего не пишет).
        z2k_ow_reconcile_tag || return 1
        if [ ! -f "$Z2K_PAYLOAD_MARKER" ]; then
            : > "$Z2K_PAYLOAD_MARKER" || return 1
        fi
        return 0
    fi
    if [ -f "$Z2K_PAYLOAD_MARKER" ] && ! z2k_ow_payload_empty; then
        echo "z2k-openwrt: payload частичен при marker — снимаю marker, авто-recovery запрещён" >&2
        rm -f "$Z2K_PAYLOAD_MARKER" 2>/dev/null
        return 1
    fi
    z2k_ow_reseed_from_seed
}

# (Старая версия seed_ensure с preserve-tag удалена здесь: она нарушала I3.
# См. z2k_ow_seed_ensure выше и state-machine §2.)
