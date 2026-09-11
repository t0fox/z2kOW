#!/bin/sh
# tests/openwrt/lc_harness.sh - Level B/C lifecycle harness (sourced, не тест).
#
# Fake OpenWrt root ($LC_SYS) + fake origin ($LC_ORIGIN) + точечные stub'ы.
# Stub boundary (только она): сеть (z2k_fetch/au_fetch_pair/curl), подписи
# (au_manifest_verify), процессы (pgrep), init-сервис. ВСЁ остальное —
# настоящий код: tar, converge, steps, rollback, tag, health, sh -n.
# Код выполняется ИЗ sysroot (как на роутере): outer flow — установленная
# версия, steps — доставленная (см. au_apply_converge).
#
# Использование в сценарии:
#   . helper.sh; . lc_harness.sh; lc_init
#   lc_fresh_sysroot            # seed -> postinst -> S2/S3
#   lc_mkorigin ... / lc_manifest ...
#   lc_apply                    # au_run_apply, rc в $LC_RC
#   lc_mutlog snap1 snap2       # блок мутаций по §26

# --- fetch: upstream override point (utils.sh: `if ! command -v z2k_fetch`) ----
# Префиксы — через настоящие au_repo_base/REPO_RAW (проверяем и URL-конструирование).
# Z2K_FETCH_SHA256 сверяем по-честному. LC_FETCH_FAIL=подстрока URL — fault
# injection на сетевой границе (сценарии обрывов; честная точка отказа).
z2k_fetch() {
    # $1 url, $2 dest
    echo "fetch:$1" >> "${LC_T:-/tmp}/fetch.log"
    [ -n "${LC_T:-}" ] || return 1
    if [ -n "${LC_FETCH_FAIL:-}" ]; then
        case "$1" in
            *"$LC_FETCH_FAIL"*) return 1 ;;
        esac
    fi
    local _rel=""
    case "$1" in
        "${Z2K_AU_REPO_RAW}/"*) _rel=${1#"${Z2K_AU_REPO_RAW}/"} ;;
        *)
            local _base
            _base=$(au_repo_base 2>/dev/null) || return 1
            case "$1" in
                "${_base}/"*) _rel=${1#"${_base}/"} ;;
                *) return 1 ;;
            esac ;;
    esac
    [ -n "$_rel" ] || return 1
    # Origin — плоское зеркало дерева: query cache-buster режем всегда;
    # компонент ref/branch (raw-семантика <repo>/<ref>/<path>) — если без
    # него файл не найден (ветка без ref идёт голым путём).
    _rel=${_rel%%\?*}
    if [ ! -f "$LC_ORIGIN/files/$_rel" ]; then
        _rel2=${_rel#*/}
        if [ -n "$_rel2" ] && [ -f "$LC_ORIGIN/files/$_rel2" ]; then
            _rel="$_rel2"
        else
            return 1
        fi
    fi
    if [ -n "${Z2K_FETCH_SHA256:-}" ]; then
        local _got
        _got=$(sha256sum "$LC_ORIGIN/files/$_rel" 2>/dev/null | awk '{print $1}')
        [ "$_got" = "$Z2K_FETCH_SHA256" ] || return 1
    fi
    mkdir -p "$(dirname "$2")" 2>/dev/null || return 1
    cp -f "$LC_ORIGIN/files/$_rel" "$2" || return 1
    return 0
}

# --- init: tmp, seed (один на файл), stub bin --------------------------------
lc_init() {
    [ -n "${LC_REPO:-}" ] || { echo "lc_harness: нужен LC_REPO" >&2; return 1; }
    LC_T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-lc.XXXXXX")" || return 1
    LC_SYS="$LC_T/sys"
    LC_ORIGIN="$LC_T/origin"
    LC_BIN="$LC_T/bin"
    mkdir -p "$LC_T/snaps" "$LC_ORIGIN/files" "$LC_BIN" || return 1
    export PATH="$LC_BIN:/usr/bin:/bin"
    # настоящий seed из дерева (один на файл; переиспользуем если уже есть)
    if [ -z "${LC_SEED_TARBALL:-}" ] || [ ! -f "$LC_SEED_TARBALL" ]; then
        LC_SEED_TARBALL="$LC_T/seed.tar.gz"
        "$LC_REPO/package/openwrt/make-seed.sh" "$LC_REPO" "$LC_SEED_TARBALL" \
            >/dev/null 2>&1 || return 1
    fi
    export LC_SEED_TARBALL
    # stub pgrep: nfqws2 — по alive-файлу, остальное — настоящий pgrep
    cat > "$LC_BIN/pgrep" <<EOF
#!/bin/sh
case "\$*" in
    *nfqws2*) [ -f "$LC_T/daemon-alive" ] && exit 0 || exit 1 ;;
esac
exec /usr/bin/pgrep "\$@"
EOF
    chmod +x "$LC_BIN/pgrep"
    # stub curl: управляемый rc (GH-probe)
    printf '#!/bin/sh\nexit ${LC_CURL_RC:-0}\n' > "$LC_BIN/curl"
    chmod +x "$LC_BIN/curl"
    : > "$LC_T/fetch.log"
    return 0
}

# --- sysroot env (экспортирует всё для updater/adapter) -----------------------
lc_sysenv() {
    # $1 — sysroot
    export Z2K_ROOT="$1/usr/lib/z2k" Z2K_ETC="$1/etc/z2k" Z2K_TMP="$1/tmp/z2k"
    export ZAPRET2_DIR="$Z2K_ROOT" CONFIG_DIR="$Z2K_ETC/conf" LISTS_DIR="$Z2K_ROOT/lists"
    export Z2K_CONFIG_FILE="$Z2K_ETC/config"
    export INIT_SCRIPT="$1/etc/init.d/z2k"
    export Z2K_AU_LOG_FILE="$Z2K_TMP/logs/z2k-auto-update.log"
    export Z2K_AU_TMP_DIR="$Z2K_TMP/update"
    export Z2K_AU_INSTALLED_TAG_FILE="$Z2K_ETC/state/installed-tag"
    export Z2K_AU_LOCK_FILE="$Z2K_TMP/locks/update.lock"
    export Z2K_AU_TRUST_PIN="$Z2K_ETC/.trust/pinned"
    export Z2K_AU_FAILS_FILE="$Z2K_ETC/state/au-delivery-fails"
    export Z2K_AU_DIRTY_TREE_FILE="$Z2K_ETC/state/dirty-tree"
    export Z2K_PLATFORM=openwrt FWTYPE=nftables
    export Z2K_AU_HEALTH_TIMEOUT=0 Z2K_AU_DELIVERY_GIVEUP=3
    export Z2K_AU_SBIN="$Z2K_ROOT/bin"
    export Z2K_AU_BRANCH=z2k-enhanced-openwrt
    export Z2K_AU_REPO_RAW="file://$LC_ORIGIN"
    export Z2K_AU_RAW_BASE="file://$LC_ORIGIN"
    export Z2K_CRON_TAB="$1/etc/crontabs/root"
    unset Z2K_AU_TARGET_REF Z2K_AU_REINSTALL_EXECUTOR
}

# --- свежий sysroot: seed + postinst-эквивалент + init-stub -------------------
lc_fresh_sysroot() {
    rm -rf "$LC_SYS"
    mkdir -p "$LC_SYS" || return 1
    lc_sysenv "$LC_SYS" || return 1
    # fake zapret2 runtime: только nfqws2-бинарник для валидатора (остальное —
    # EXTERNAL_ZAPRET2, в lifecycle не эмулируется; firewall — ownership-тесты).
    # --dry-run всегда ok: эмуляция production-движка (graceful skip при его
    # отсутствии покрыт юнит-уровнем, здесь — полный pass-путь).
    mkdir -p "$LC_T/fake-runtime/nfq2" || return 1
    printf '#!/bin/sh\nif [ "$1" = "--help" ]; then echo "nfqws2 fake-runtime"; echo "--dry-run"; exit 0; fi\nexit 0\n' \
        > "$LC_T/fake-runtime/nfq2/nfqws2" || return 1
    chmod +x "$LC_T/fake-runtime/nfq2/nfqws2" || return 1
    export Z2K_ZAPRET2_RUNTIME="$LC_T/fake-runtime"
    # postinst-эквивалент: seed_ensure + cron (paths/bootstrap/schedule ИЗ seed?
    # нет — seed не содержит adapter: берём adapter из РЕПО как "установленный
    # пакетом" (роль opkg), payload приедет из seed).
    mkdir -p "$Z2K_ROOT/platform/openwrt" "$Z2K_ROOT/share"
    for _f in "$LC_REPO"/platform/openwrt/*.sh; do
        cp -f "$_f" "$Z2K_ROOT/platform/openwrt/" || return 1
    done
    cp -f "$LC_REPO/package/openwrt/files/etc/z2k/config.default" "$Z2K_ROOT/share/" || return 1
    cp -f "$LC_SEED_TARBALL" "$Z2K_ROOT/share/seed.tar.gz" || return 1
    export Z2K_SEED_TARBALL="$Z2K_ROOT/share/seed.tar.gz" Z2K_SEED_DEST="$LC_SYS"
    export Z2K_CRON_TAB="$LC_SYS/etc/crontabs/root"
    # shellcheck disable=SC1090,SC1091
    . "$Z2K_ROOT/platform/openwrt/paths.sh" || return 1
    . "$Z2K_ROOT/platform/openwrt/env.sh" || return 1
    . "$Z2K_ROOT/platform/openwrt/bootstrap.sh" || return 1
    . "$Z2K_ROOT/platform/openwrt/schedule.sh" || return 1
    . "$Z2K_ROOT/platform/openwrt/uninstall.sh" || return 1
    z2k_ow_seed_ensure >/dev/null 2>&1 || return 1
    z2k_ow_cron_install >/dev/null 2>&1 || return 1
    # init-stub (ENABLED-gate как настоящий сервис; пишет daemon-alive).
    # LC_INIT_KILLS=1: restart убивает демона (симуляция падающего нового
    # конфига для health-fail сценариев; fault injection на границе сервиса).
    mkdir -p "$LC_SYS/etc/init.d"
    cat > "$INIT_SCRIPT" <<EOF
#!/bin/sh
echo "init:\$1" >> "$LC_T/calls-init"
_cfg="$Z2K_ETC/config"
_en=1
[ -f "\$_cfg" ] && _en=\$(grep -m1 '^ENABLED=' "\$_cfg" 2>/dev/null | cut -d= -f2 | tr -d '" ')
[ "\$_en" = "0" ] && exit 1
case "\$1" in
    start|restart) : > "$LC_T/daemon-alive" ;;
    stop) rm -f "$LC_T/daemon-alive" ;;
    enabled) exit 0 ;;
esac
[ "\${LC_INIT_KILLS:-0}" = "1" ] && rm -f "$LC_T/daemon-alive"
exit 0
EOF
    chmod +x "$INIT_SCRIPT"
    # сорсим ИСПОЛНЯЕМЫЙ код из sysroot (как на роутере).
    # z2k_fetch НЕ переопределяем здесь: он задан наверху harness и utils.sh
    # его не трогает (command -v guard). au_fetch_pair — настоящий (делегирует
    # нашему z2k_fetch). au_manifest_verify — stub (подписи — upstream-тесты).
    # shellcheck disable=SC1090,SC1091
    . "$Z2K_LIB/utils.sh" >/dev/null 2>&1 || return 1
    . "$Z2K_LIB/strategies.sh" >/dev/null 2>&1 || return 1
    . "$Z2K_LIB/config_official.sh" >/dev/null 2>&1 || return 1
    . "$Z2K_LIB/auto_update.sh" >/dev/null 2>&1 || return 1
    au_manifest_verify() { return ${LC_VERIFY_RC:-0}; }
    return 0
}

# --- origin: файлы + манифест ------------------------------------------------------
# lc_origin_put <repo_path> : stdin -> $ORIGIN/files/<repo_path>
lc_origin_put() {
    mkdir -p "$LC_ORIGIN/files/$(dirname "$1")" || return 1
    cat > "$LC_ORIGIN/files/$1" || return 1
}
# lc_manifest <current> : entries со stdin ("v|type|ref|files,csv|steps,csv|full|reset")
# platform=openwrt всегда; install_map/sha — по РЕАЛЬНОЙ таблице+файлам origin.
lc_manifest() {
    local _cur="$1" _hist="$LC_T/history.jsonl" _map="$LC_T/map.jsonl" _sha="$LC_T/sha.jsonl"
    : > "$_hist"; : > "$_map"; : > "$_sha"
    # shellcheck disable=SC1090,SC1091
    . "$LC_REPO/lib/release_map.sh" 2>/dev/null || return 1
    while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        local _v _ty _ref _fl _st _fu _rs
        _v=$(printf '%s' "$_line" | cut -d'|' -f1)
        _ty=$(printf '%s' "$_line" | cut -d'|' -f2)
        _ref=$(printf '%s' "$_line" | cut -d'|' -f3)
        _fl=$(printf '%s' "$_line" | cut -d'|' -f4 | tr ',' ' ')
        _st=$(printf '%s' "$_line" | cut -d'|' -f5 | tr ',' ' ')
        _fu=$(printf '%s' "$_line" | cut -d'|' -f6)
        _rs=$(printf '%s' "$_line" | cut -d'|' -f7)
        local _jl="$_fl" _f _sl=""
        for _f in $_jl; do _sl="$_sl\"$_f\", "; done
        _sl=$(printf '%s' "$_sl" | sed 's/, $//')
        local _stj="" _s
        for _s in $_st; do
            [ -n "$_s" ] && _stj="$_stj\"$_s\", "
        done
        _stj=$(printf '%s' "$_stj" | sed 's/, $//')
        printf '{"v": "%s", "type": "%s", "ref": "%s", "changed_files": [%s], "steps": [%s], "full_install": %s, "reset_state": %s}\n' \
            "$_v" "$_ty" "$_ref" "$_sl" "$_stj" "${_fu:-false}" "${_rs:-false}" >> "$_hist"
        local _t
        for _f in $_jl; do
            Z2K_PLATFORM=openwrt z2k_install_paths "$_f" 2>/dev/null | while IFS= read -r _t; do
                [ -n "$_t" ] || continue
                # Строки карты — с висячей запятой; паттерн обязан её учитывать,
                # иначе dedup молча не срабатывает и bulk двоит цели.
                grep -qxF "  \"$_f\": [\"$_t\"]," "$_map" 2>/dev/null || \
                    printf '  "%s": ["%s"],\n' "$_f" "$_t" >> "$_map"
            done
            if [ -f "$LC_ORIGIN/files/$_f" ]; then
                grep -q "\"$_f\":" "$_sha" 2>/dev/null || \
                    printf '  "%s": "%s",\n' "$_f" "$(sha256sum "$LC_ORIGIN/files/$_f" | awk '{print $1}')" >> "$_sha"
            fi
        done
    done
    { printf '{"current": "%s",\n  "platform": "openwrt",\n  "install_map": {\n' "$_cur"
      sed '$ s/,$//' "$_map" 2>/dev/null
      printf '  },\n  "files_sha256": {\n'
      sed '$ s/,$//' "$_sha" 2>/dev/null
      printf '  },\n  "history": [\n'
      cat "$_hist"
      printf '  ]}\n'
    } > "$LC_ORIGIN/manifest.json"
    # au_fetch_pair тянет манифест как обычный файл (UPDATES.json) — кладём
    # копию в files/ (настоящий au_fetch_pair + настоящий z2k_fetch их найдут).
    mkdir -p "$LC_ORIGIN/files" || return 1
    cp -f "$LC_ORIGIN/manifest.json" "$LC_ORIGIN/files/UPDATES.json" || return 1
    # Релокация назначений в sysroot: production-манифест несёт абсолютные
    # /usr/lib/z2k + /etc/z2k (проверено drift-тестом); фикстура меняет ТОЛЬКО
    # корневой префикс, относительная структура и контент — как в проде.
    # Без этого converge писал бы в настоящий /usr/lib (или падал без root).
    local _rr="${Z2K_ROOT:-/usr/lib/z2k}" _re="${Z2K_ETC:-/etc/z2k}"
    if [ "$_rr" != "/usr/lib/z2k" ] || [ "$_re" != "/etc/z2k" ]; then
        sed -e "s|/usr/lib/z2k|$_rr|g" -e "s|/etc/z2k|$_re|g" \
            "$LC_ORIGIN/manifest.json" > "$LC_ORIGIN/manifest.json.new" 2>/dev/null || return 1
        mv -f "$LC_ORIGIN/manifest.json.new" "$LC_ORIGIN/manifest.json" || return 1
        cp -f "$LC_ORIGIN/manifest.json" "$LC_ORIGIN/files/UPDATES.json" || return 1
    fi
}

# --- apply + postinst/prerm-эквиваленты + снимки ---------------------------------------
lc_apply() {
    : > "$LC_T/calls-init"
    au_run_apply >/dev/null 2>&1
    LC_RC=$?
}
lc_postinst() {
    z2k_ow_seed_ensure >/dev/null 2>&1 || return 1
    z2k_ow_cron_install >/dev/null 2>&1 || return 1
    return 0
}
# prerm-эквивалент: настоящая z2k_ow_uninstall с init-override.
lc_prerm() {
    Z2K_INITSRC="$INIT_SCRIPT" z2k_ow_uninstall >/dev/null 2>&1 || return 1
    return 0
}
# lc_invariant <label>: глобальные I1/I2 (§13, QUIESCENT states only!).
# Проверяет: marker⇒payload_ok; tag⇒marker+meta+равенство; empty⇒без marker/tag.
# Crash-состояния mid-transaction НАМЕРЕННО валят проверку (детект, не баг):
# тесты assert'ят FAIL там и OK после repair. Печатает INVARIANT-строку.
lc_invariant() {
    local _label="$1" _fail="" _tag="" _meta=""
    if [ -f "$Z2K_ETC/.payload-initialized" ]; then
        z2k_ow_payload_ok 2>/dev/null || _fail="${_fail} I1(marker-without-payload)"
    fi
    [ -f "$Z2K_AU_INSTALLED_TAG_FILE" ] && \
        _tag=$(tr -d '[:space:]' < "$Z2K_AU_INSTALLED_TAG_FILE" 2>/dev/null)
    if [ -n "$_tag" ]; then
        [ -f "$Z2K_ETC/.payload-initialized" ] || _fail="${_fail} I2a(tag-without-marker)"
        _meta=$(z2k_ow_payload_meta_tag 2>/dev/null) || _fail="${_fail} I2b(tag-without-meta)"
        if [ -z "$_fail" ] && [ "$_tag" != "$_meta" ]; then
            _fail="${_fail} I2c(tag[$_tag]!=meta[$_meta])"
        fi
    fi
    if z2k_ow_payload_empty 2>/dev/null; then
        [ -f "$Z2K_ETC/.payload-initialized" ] && _fail="${_fail} I-empty-marker"
        [ -n "$_tag" ] && _fail="${_fail} I-empty-tag"
    fi
    if [ -z "$_fail" ]; then
        printf 'INVARIANT %s: OK\n' "$_label"
        return 0
    fi
    printf 'INVARIANT %s: FAIL%s\n' "$_label" "$_fail"
    return 1
}
lc_tag() { tr -d '[:space:]' < "$Z2K_AU_INSTALLED_TAG_FILE" 2>/dev/null; }
# lc_set_version <tag>: КОНСИСТЕНТНЫЙ backdate (tag+meta вместе, как после
# настоящего update). Ручная правка только tag создаёт расхождение, которое
# invariant справедливо бракует, — этим helper'ом симулируем "старую установку".
lc_set_version() {
    printf '%s\n' "$1" > "$Z2K_AU_INSTALLED_TAG_FILE" || return 1
    { printf 'platform=openwrt\n'
      printf 'tag=%s\n' "$1"
      printf 'ref=\n'
    } > "$Z2K_ROOT/share/payload.meta" 2>/dev/null || return 1
    return 0
}
lc_payload_ver() {
    printf '%s/%s' "$(lc_tag)" "$(sha256sum "$Z2K_ROOT/lib/utils.sh" 2>/dev/null | awk '{print $1}')"
}
lc_snap() {
    # $1 имя снимка
    ( cd "$LC_SYS" && find . -type f | LC_ALL=C sort | while IFS= read -r _f; do
        cksum "./$_f" 2>/dev/null
    done ) > "$LC_T/snaps/$1" 2>/dev/null
}
lc_mutlog() {
    # $1 before $2 after [$3 label]: блок мутаций по §26. Один awk, без
    # process substitution (dash): CREATED/MODIFIED/DELETED — имена,
    # PRESERVED — счёт, TAG/PAYLOAD — версии.
    local _b="$LC_T/snaps/$1" _a="$LC_T/snaps/$2" _label="${3:-$1->$2}"
    printf 'MUTATIONS %s:\n' "$_label"
    awk 'FNR==NR { bcrc[$3]=$1; next }
        { if ($3 in bcrc) { if (bcrc[$3] == $1) pres++; else print "MODIFIED: " $3; seen[$3]=1 }
          else print "CREATED: " $3 }
        END { for (f in bcrc) if (!(f in seen)) print "DELETED: " f
              print "PRESERVED-COUNT: " pres+0 }' "$_b" "$_a" \
    | LC_ALL=C sort | awk '
        /^MODIFIED/ { m=m " " $2; next }
        /^CREATED/ { c=c " " $2; next }
        /^DELETED/ { d=d " " $2; next }
        /^PRESERVED-COUNT/ { p=$2; next }
        END { printf "CREATED:%s\nMODIFIED:%s\nDELETED:%s\nPRESERVED: %s files\n", c, m, d, p }'
    printf 'TAG_BEFORE: %s TAG_AFTER: %s\n' "$LC_TAG_BEFORE" "$(lc_tag)"
    printf 'PAYLOAD_BEFORE: %s\nPAYLOAD_AFTER: %s\n' "$LC_PAYLOAD_BEFORE" "$(lc_payload_ver)"
}
lc_begin() {
    # $1 label: запомнить TAG/PAYLOAD до фазы
    LC_TAG_BEFORE="$(lc_tag)"
    LC_PAYLOAD_BEFORE="$(lc_payload_ver)"
}
