#!/bin/sh
# tests/openwrt/test_ow_upstream_diff.sh - §8/§13: UPSTREAM_ADAPTER_BOUNDARY.
# Всё, что этап добавил/изменил относительно BASELINE, обязано лежать в:
#   platform/  package/  tests/openwrt/  docs/openwrt-adapter-contract.md
#   docs/openwrt-telegram-contract.md (Stage 3: TG contract, docs, не код)
#   docs/openwrt-rt-proxy-contract.md (Stage 4: RT contract, docs, не код)
#   docs/openwrt-warp-contract.md + docs/openwrt-mark-allocation.md
#     (Stage 5: WARP contracts, docs, не код)
#   z2k-warpd external-backend seam (Stage 5: 3 Go-файла, см. ALLOWLIST)
# плюс allowlisted common-хуки (см. ALLOWLIST ниже). Иначе — провал с
# категорией seam'а: будущий upstream merge, задевший наш seam, виден сразу.
#
# После каждого upstream sync BASELINE сдвигается на новый upstream HEAD
# (иначе легитимные upstream-изменения вечно краснят guard).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-upstream-diff"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BASELINE="$(cat "$REPO/tests/openwrt/BASELINE")"
export GIT_CONFIG_NOSYSTEM=1
_g="git -c safe.directory=$REPO -C $REPO"

# Разрешённые common-модификации (файл: зачем). Расширять — только с записью
# сюда и в contract § sync invariant.
#   .gitattributes: только +eol=lf (проверяется отдельно ниже)
#   lib/config_official.sh: PHASE3-чтение через ${ZAPRET2_DIR} (§2)
#   lib/release_map.sh: platform-диспетчер + openwrt-таблица (§3)
#   lib/auto_update.sh: targetless fail-safe, Z2K_CONFIG_FILE/merge хуки,
#     platform gate (§3/§6/§2.1) + Z2K_AU_NO_OWNER_START в refresh-binaries
#     (только fresh-provisioning без owner bounce; дефолт — поведение 1-в-1)
#     + Z2K_AU_STATE_FALLBACK в reset-state (p-84.17 sync: OW-fallback state
#     живёт в $Z2K_TMP, unset = keenetic 1-в-1)
#   scripts/gen_file_hashes.sh: platform-маркер только для non-keenetic (§2.1;
#     keenetic-реген байт-идентичен — сторожит channel-тест)
#   files/z2k-config-validator.sh: FAKE_DIR + lua EXTRA хуки (freeze audit:
#     без них validate ветирует любой OpenWrt-конфиг)
#   UPDATES.json: ТОЛЬКО files_sha256 hash-обновления allowlisted lib-файлов
#   docs/openwrt-foundation-state-machine.md: модель аудита (docs, не код)
#   docs/openwrt-telegram-contract.md: TG contract Stage 3 (docs, не код)
#   docs/openwrt-rt-proxy-contract.md: RT contract Stage 4 (docs, не код)
#   docs/openwrt-warp-contract.md: WARP contract Stage 5 (docs, не код)
#   docs/openwrt-mark-allocation.md: карта marks Stage 5 (docs, не код)
#   z2k-warpd/cmd/z2k-warpd/main.go + internal/engine/engine.go +
#     internal/engine/netsetup_test.go: external-net-backend seam Stage 5
#     (--net-backend=/SkipNetSetup; Keenetic-дефолт нетронут — сторожит
#     netsetup_test; только подмена TUN/create/address/transport/health)
#   z2k-warpd/builds/*: deliberate build refresh (closure): отгружаемые
#     бинарники, пересобранные каноническим тулчейном (Go 1.25.13,
#     CGO_ENABLED=0, -trimpath -buildvcs=false -ldflags="-s -w" из
#     z2k-warpd/Makefile). БАЙТ-АВТОРИТЕТ — НЕ здесь, а в CI-джобе
#     "Отгружаемые бинарники" (пересборка из исходника + sha256 равенство
#     каждый ран): path-based guard отличить refresh от подмены не может
#     в принципе, поэтому content держит тот гейт. Правка исходника без
#     пересборки краснит binaries; легитимная пересборка всегда меняет
#     эти пути — это ожидаемо, а не seam.
#   webpanel/cgi/platform.sh: tiny platform frontend Stage 6 (NEW, small seam)
#   webpanel/cgi/api.sh: 2× source platform.sh + openwrt-only /status keys
#     + GET /toggles (common fix: фронт telemetry.js звал его всегда, кейса
#     не было ни на одной платформе; плоская форма вложенного "toggles"
#     из /status, Keenetic-байты нетронуты)
#   webpanel/cgi/actions.sh: manifest-URL var + DEBUG_FLAG_FILE var (2 строки)
#   webpanel/cgi/auth.sh: Z2K_PANEL_DIR seam для bind/hosts (USER-дерево)
#   webpanel/install.sh: PLATFORM_ENV-подстановка Stage 6 (инсталлер обязан
#     знать новый плейсхолдер, иначе уходит в конфиг как есть)
#   webpanel/lighttpd.conf: @PLATFORM_ENV@ Stage 6 (единственный новый
#     плейсхолдер шаблона)
#   webpanel/www/js/core/loadorder.js + webpanel/www/js/pages/toggles.js +
#     webpanel/www/js/pages/telemetry.js + webpanel/www/app.js +
#     webpanel/www/js/router.js: applyCapabilities Stage 6 (только visibility;
#     capability-логика вне этих файлов запрещена) + Stage 8: OW-текст
#     dynamic_ttl (TTL-fix Keenetic там не существует), <title> вкладки через
#     тот же capabilities-сигнал, недостающий ROUTE_TITLES.autohostlist
#     (fallback врал на обеих платформах) и guard навигационной гонки в
#     renderStatsNotice (TypeError после ухода со страницы — обе платформы);
#     upstream-тексты и поведение 1-в-1
#   docs/openwrt-webpanel-contract.md: webpanel contract Stage 6 (docs, не код)
#   docs/openwrt-release-contract.md: release contract Stage 7 (docs, не код)
#   scripts/openwrt/gen-openwrt-manifest.sh: генерация OpenWrt-манифеста
#     Stage 7 (NEW; common-манифест не трогает, только читает)
#   scripts/openwrt/build-release.sh + scripts/openwrt/write-provenance.sh:
#     каноническая сборка APK-релиза Stage 7 (NEW; только гейты+артефакты)
#     + runtime pin/provenance (RUNTIME_*; формат владеет юнит-тест)
#   scripts/openwrt/verify-runtime.sh: гейт runtime tarball (NEW; только
#     проверки pin/closure/ELF, сеть не нужна — tarball даёт вызывающий)
#   scripts/rehearse_update.sh: ref-префиксы + hermetic RAW_BASE (closure;
#     чинит репетицию под ref-pinning Stage 2.2.2, прод-механика та же)
#   tests/test_manifest_signature.sh: eval platform gate (closure; список
#     выдёргиваемых функций обязан следовать за хуками au_fetch_manifest)
#   tests/test_webpanel_api_contract.sh: блок GET /toggles (common fix выше;
#     плоская проекция, Keenetic-дефолт; без него Keenetic-регрессии слепы
#     к новому маршруту)
#   tests/panel_harness.js: Z2K_OW_CAPS-ветка фикстур (inert по умолчанию:
#     без env — Keenetic 1-в-1; исполняет OW-ветки фронта в OW pages-тесте)
#   tests/test_release_tooling.sh: fixture-теги предыдущих релизов (closure;
#     hermetic вместо ambient remote state — форк без тегов)
#   lib/strategies.sh: busybox-safe tr-idiom Stage 8 (live-дефект: BusyBox tr
#     не знает POSIX-классов и вырезал буквы; замена '[:space:]' на ' \t\r\n'
#     побайтово эквивалентна на GNU и чинит роутер; digits-only контекст)
#   z2k.sh: busybox-safe tr-idiom Stage 8 (то же: '[:alnum:]' -> 'A-Za-z0-9'
#     в DoH-pool ключе; на BusyBox complement от литералов портил ключи)
#   tests/test_au_compat.sh: тот же tr-idiom в assert'ах (тест, GNU-эквивалент)
#   README.md: deliberate owner rewrite под OpenWrt-адаптер (34bbe16/8c79079;
#     Stage 8: без регистрации любой docs-коммит краснит guard). Content-уровень
#     держит test_exclude_hint_truthful (семантика подсказки/засева/README),
#     path-guard здесь только фиксирует факт намеренного реврайта.
#   .github/workflows/ci.yml: openwrt-package job на pinned SDK (closure;
#     остальной workflow не тронут, permissions contents:read + actions:write
#     точечно на джобу)
ALLOWLIST=".gitattributes lib/config_official.sh lib/release_map.sh lib/auto_update.sh scripts/gen_file_hashes.sh files/z2k-config-validator.sh UPDATES.json docs/openwrt-foundation-state-machine.md docs/openwrt-telegram-contract.md docs/openwrt-rt-proxy-contract.md docs/openwrt-warp-contract.md docs/openwrt-mark-allocation.md z2k-warpd/cmd/z2k-warpd/main.go z2k-warpd/internal/engine/engine.go z2k-warpd/internal/engine/netsetup_test.go z2k-warpd/builds/* webpanel/cgi/platform.sh webpanel/cgi/api.sh webpanel/cgi/actions.sh webpanel/cgi/auth.sh webpanel/install.sh webpanel/lighttpd.conf webpanel/www/js/core/loadorder.js webpanel/www/js/pages/toggles.js webpanel/www/js/pages/telemetry.js webpanel/www/js/router.js webpanel/www/app.js docs/openwrt-webpanel-contract.md docs/openwrt-release-contract.md scripts/openwrt/gen-openwrt-manifest.sh scripts/openwrt/build-release.sh scripts/openwrt/write-provenance.sh scripts/openwrt/verify-runtime.sh .github/workflows/ci.yml scripts/rehearse_update.sh tests/test_manifest_signature.sh tests/test_webpanel_api_contract.sh tests/panel_harness.js tests/test_release_tooling.sh lib/strategies.sh z2k.sh tests/test_au_compat.sh README.md"

# Граница меряется от production-ветки, когда она видна: то, что уже
# опубликовано production-релизом (манифест, подпись, index.html...), —
# не наш seam (closure §1: published snapshot не трогаем, свежесть манифеста
# — свойство релиза). Без origin — строгий fallback на BASELINE.
_REF="$BASELINE"
if git -c safe.directory="$REPO" -C "$REPO" rev-parse --verify origin/z2k-enhanced >/dev/null 2>&1; then
    _REF="origin/z2k-enhanced"
fi
_changed="$($_g diff --name-only "$_REF"...HEAD 2>/dev/null)"
# --ignore-cr-at-eol: на Windows-чекаутах (autocrlf) весь worktree выглядит
# изменённым; флаг гасит чисто-CRLF шум, настоящие правки остаются видны.
_staged="$($_g diff --ignore-cr-at-eol --name-only --cached 2>/dev/null)"
_unstaged="$($_g diff --ignore-cr-at-eol --name-only 2>/dev/null)"
# -uall: новые каталоги раскрывать пофайлово, иначе guard слеп к составу.
_untracked="$($_g status --porcelain -uall 2>/dev/null | sed -n 's/^?? //p')"
_all="$(printf '%s\n%s\n%s\n%s' "$_changed" "$_staged" "$_unstaged" "$_untracked" | sed '/^[[:space:]]*$/d' | sort -u)"

echo "UPSTREAM_ADAPTER_BOUNDARY:"
echo "COMMON_UPSTREAM_DIFF:"

_seam_of() {
    # $1 — путь; печатает категорию seam'а
    case "$1" in
        files/lua/*) echo "lua" ;;
        *detect*|*circular*|*rotat*) echo "detectors" ;;
        strats_new2.txt|quic_strats.ini|lib/strategies.sh|lib/config_official.sh) echo "strategies" ;;
        webpanel/*) echo "common-webpanel" ;;
        scripts/openwrt/*|scripts/rehearse_update.sh) echo "release-tooling" ;;
        tests/*) echo "common-tests" ;;
        lib/auto_update.sh|lib/release_map.sh|files/z2k-config-validator.sh|scripts/gen_file_hashes.sh) echo "update-system" ;;
        *warp*|*Warp*|*WARP*) echo "warp" ;;
        *) echo "other-common" ;;
    esac
}

if [ -z "$_all" ]; then
    echo "none"
    _t_ok
else
    _bad="$(printf '%s\n' "$_all" | grep -vE '^(platform/|package/|tests/openwrt/|docs/openwrt-adapter-contract\.md$)' || true)"
    # .gitattributes: только чистое добавление eol=lf-строк.
    _attr_ok=""
    if printf '%s\n' "$_bad" | grep -qx '.gitattributes'; then
        _attr_all="$( { $_g diff "$_REF"...HEAD -- .gitattributes 2>/dev/null; \
                        $_g diff --cached -- .gitattributes 2>/dev/null; } \
            | grep -E '^[+-]' | grep -vE '^[+-]{3}' || true)"
        _attr_removed="$(printf '%s\n' "$_attr_all" | grep -E '^-' || true)"
        _attr_added="$(printf '%s\n' "$_attr_all" | grep -E '^\+' || true)"
        _attr_foreign="$(printf '%s\n' "$_attr_added" | grep -v -e 'eol=lf' -e '^+#' -e '^\+$' || true)"
        if [ -z "$_attr_removed" ] && [ -n "$_attr_added" ] && [ -z "$_attr_foreign" ]; then
            _attr_ok="1"
        fi
    fi
    _unallowed=""
    for _f in $_bad; do
        case "$_f" in
            .gitattributes) [ -n "$_attr_ok" ] && continue ;;
            lib/config_official.sh|lib/release_map.sh|lib/auto_update.sh|scripts/gen_file_hashes.sh|files/z2k-config-validator.sh|docs/openwrt-foundation-state-machine.md|docs/openwrt-telegram-contract.md|docs/openwrt-rt-proxy-contract.md|docs/openwrt-warp-contract.md|docs/openwrt-mark-allocation.md|z2k-warpd/cmd/z2k-warpd/main.go|z2k-warpd/internal/engine/engine.go|z2k-warpd/internal/engine/netsetup_test.go|z2k-warpd/builds/*|webpanel/cgi/platform.sh|webpanel/cgi/api.sh|webpanel/cgi/actions.sh|webpanel/cgi/auth.sh|webpanel/install.sh|webpanel/lighttpd.conf|webpanel/www/js/core/loadorder.js|webpanel/www/js/pages/toggles.js|webpanel/www/js/pages/telemetry.js|webpanel/www/js/router.js|webpanel/www/app.js|docs/openwrt-webpanel-contract.md|docs/openwrt-release-contract.md|scripts/openwrt/gen-openwrt-manifest.sh|scripts/openwrt/build-release.sh|scripts/openwrt/write-provenance.sh|scripts/openwrt/verify-runtime.sh|.github/workflows/ci.yml|scripts/rehearse_update.sh|tests/test_manifest_signature.sh|tests/test_webpanel_api_contract.sh|tests/panel_harness.js|tests/test_release_tooling.sh|lib/strategies.sh|z2k.sh|tests/test_au_compat.sh|README.md) continue ;;
            UPDATES.json)
                # Манифест следует за деревом: разрешены hash-обновления
                # файлов, чьи правки сами allowlisted (хеш следует за
                # контентом — связку доказывает channel-тест побайтово),
                # плюс ДОБАВЛЕНИЯ install_map для allowlisted файлов.
                # Запрещены всегда: current/seq/branch/history-правки на
                # feature-ветке, удаления/изменения существующих map-назначений.
                # --ignore-cr-at-eol на worktree-диффах: Windows-чекаут красит
                # весь файл в CRLF-шум (см. шапку файла).
                _umd="$( { $_g diff "$_REF"...HEAD -- UPDATES.json 2>/dev/null; \
                            $_g diff --cached -- UPDATES.json 2>/dev/null; \
                            $_g diff --ignore-cr-at-eol -- UPDATES.json 2>/dev/null; } \
                    | grep -E '^[+-]' | grep -vE '^[+-]{3}' || true)"
                _umd_bad="$(printf '%s\n' "$_umd" \
                    | grep -vE '^[+-]  "(lib/(config_official|release_map|auto_update)\.sh|files/z2k-config-validator\.sh|webpanel/(cgi/(platform|api|actions|auth)\.sh|install\.sh|lighttpd\.conf|www/(app\.js|js/core/loadorder\.js|js/pages/(toggles|telemetry)\.js|js/router\.js)))": "[0-9a-f]{64}",?$' \
                    | grep -vE '^[+]  "webpanel/cgi/platform\.sh": \[' || true)"
                [ -z "$_umd_bad" ] && continue ;;
        esac
        _unallowed="$_unallowed $_f:$(_seam_of "$_f")"
    done
    if [ -z "$_unallowed" ]; then
        echo "none (adapter-only files: $(printf '%s' "$_all" | wc -l | tr -d ' '))"
        echo "ALLOWLISTED: $ALLOWLIST"
        _t_ok
    else
        echo "$_unallowed"
        _t_bad "seam нарушен:$_unallowed"
    fi
fi

_t_done
