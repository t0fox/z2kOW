# docs/openwrt-release-contract.md — Stage 7: two delivery lanes.

> Статус: PACKAGING/RELEASE PASS там, где проверено офлайн; пункты, требующие
> SDK/подписи/роутера, честно помечены PARTIAL (§68/§69 правил). Живой роутер
> (Cudy WR3000 v1, OpenWrt 25.12.5, mediatek/filogic) — Stage 8, не здесь.

## §0. Главный invariant: два независимых lane

```text
COMMON CHANGE → signed payload update → NO apk rebuild        (частый lane)
adapter change → z2k-adapter.apk upgrade                       (редкий lane)
```

- `platform/openwrt/*`, `package/openwrt/*`, `/etc/init.d/z2k`, hotplug,
  метаданные пакета → только через upgrade пакета.
- Всё остальное (lib/lua/lists/webpanel/etc) → подписанным payload update.
- Проверка архитектуры в конце: будущий upstream-релиз → generate/sign
  OpenWrt-манифеста → обычный payload update, БЕЗ пересборки APK.

## §1. Trust model: reuse, не fork (§2 спеки)

Common updater уже имеет: signed `UPDATES.json`, Ed25519, `files_sha256`,
immutable refs, trust pin/ratchet, `payload.meta`, installed-tag. OpenWrt
использует ТОТ ЖЕ updater через `platform/openwrt/update.sh`. Запрещены:
`openwrt-updater-v2`, новый JSON-формат, второй hash verifier, второй
downloader. Источник правды — `lib/auto_update.sh` (3029 строк, сентябрь
2026): fetch→decide→converge/legacy→steps→meta→tag.

## §2. Канал: `z2k-enhanced-openwrt` — pointer, не fork

- Production pointer `z2k-enhanced-openwrt` механически выводится из того же
  release candidate, что и common-релиз: `scripts/openwrt/gen-openwrt-manifest.sh`
  трансформирует common `UPDATES.json`, history НЕ копируется вручную.
- OpenWrt-манифест: `branch = z2k-enhanced-openwrt`, `"platform": "openwrt"`,
  openwrt `install_map` (repo-path → openwrt dests через `z2k_install_paths`
  при `Z2K_PLATFORM=openwrt`), те же `current/history/seq/files_sha256/refs`.
- Файлы качаются по тем же immutable refs (имена тегов вида `p-84.7`) из того
  же repo (`Z2K_AU_RAW_BASE` → `t0fox/z2kOW`); ветка — только discovery
  текущего манифеста, не integrity-источник байтов.
- Ручная разработка на release-ветке запрещена (поток: candidate → тесты →
  manifest generation → signature → promotion).

## §3. Две оси версий (никогда не смешивать)

- PAYLOAD VERSION (`p-84.7…`): `UPDATES.json` current/history, updater-owned
  файлы. Тот же stream, что common.
- ADAPTER PACKAGE VERSION (`z2k-adapter.apk`): package-owned файлы.
- Package version НИКОГДА не используется вместо payload tag, и наоборот.

## §4. OpenWrt install_map: только updater-owned targets

Генерируется (`Z2K_PLATFORM=openwrt`, `z2k_install_paths`, `z2k_steps_for`),
руками не правится. В OpenWrt-манифесте НЕ ДОЛЖНО быть назначений:
`/opt/*`, `/opt/etc/init.d/*`, `files/ndm → Keenetic target`, `S99zapret2`,
`S51z2k-warp`, `S98tg-tunnel` (Keenetic-only — в openwrt-таблице им пусто
по построению; сторожит `au_manifest_platform_ok` + drift-тест).
Manifest MUST NOT перезаписывать package-owned:
`platform/openwrt/*`, `package/openwrt/*`, `/etc/init.d/z2k`,
`/etc/hotplug.d/iface/90-z2k`, webpanel procd glue.
Guard: `PACKAGE ∩ UPDATER = ∅` для production-манифеста (тест).

## §5. Webpanel ownership = итог Stage 6, без передела

Common CGI/static/template — UPDATER; service glue/init — PACKAGE;
настройки `/etc/z2k/webpanel/*` — USER; сгенерированный конфиг/логи/pid —
TRANSIENT. Отдельный `z2k-webpanel.apk` доводится до production packaging,
обратно не объединяется. Удаление webpanel-пакета НЕ останавливает core.

## §6. ADAPTER API: monotonic integer, не SemVer

- Source of truth: `package/openwrt/ADAPTER_API` (целое, сейчас `1`).
- Пакет ставит `/usr/lib/z2k/share/adapter.api` (PACKAGE-owned; updater его
  НИКОГДА не перезаписывает; reinstall/seed его не трогают).
- Манифест несёт опциональное `openwrt_adapter_api_min` на entry
  (backward-compatible: отсутствие = 1; старые апдейтеры игнорируют
  неизвестные поля). Эффективное требование окна обновления — max по
  записям после installed tag.
- Increment ТОЛЬКО если новый payload реально требует новый platform
  contract (новый `wp_platform_*`-примитив, updater hook, lifecycle seam,
  смена WARP backend-интерфейса). НЕ increment: комментарии, тесты,
  метаданные пакета, внутренние фиксы.

## §7. API gate: до ЛЮБОЙ payload mutation (§9)

В `platform/openwrt/update.sh`, ДО `seed_ensure` (гейт не требует ничего,
кроме env + common libs):

```text
required <= installed → update proceeds
required > installed  → FAIL CLOSED: «adapter package upgrade required»,
                        ноль мутаций файлов, meta/tag не двигаются
```

- `apply`: отказ кодом 1, громко в журнал.
- `check`: отказ строкой `ADAPTER_UPDATE_REQUIRED`, код 2 (payload-статусы:
  `PAYLOAD_UPDATE_AVAILABLE` / `UP_TO_DATE` — из обычного `au_run_check`;
  никакого generic «update failed» вместо точной причины).
- Updater НИКОГДА не зовёт `apk upgrade` (§56). При старом адаптере — только
  точная package-specific инструкция человеку.

## §8. Release ordering при новом API

1. build new APK → 2. publish APK/feed → 3. verify package available →
4. ONLY THEN publish signed OpenWrt payload manifest. Манифест с
`required API=2` при feed с `API=1` — запрещён (проверяет promotion gate).

## §9. Full payload reinstall (закрывает `z2k_ow_reinstall_unsupported`)

Исполнитель `z2k_ow_payload_reinstall` (`platform/openwrt/reinstall.sh`,
через существующий `Z2K_AU_REINSTALL_EXECUTOR`-hook — common НЕ меняется).
Модель = полный verified converge, reuse существующего:

```text
signed manifest verified (выше по стеку, au_apply_reinstall)
  → API gate re-check (defense in depth)
  → plan = ALL updater-owned OpenWrt payload files (ключи install_map
    манифеста ∩ openwrt-dests; ИСКЛЮЧЕНИЯ: share/seed.tar.gz,
    share/adapter.api — package-owned; /etc — только merge extra-domains)
  → snapshot текущих целей (au_snapshot_for_patch)
  → download ALL to staging (au_download_repo_file_retry)
  → verify ALL sha256 (au_manifest_file_sha; mirror-miss → отказ)
  → NO mutation until all valid
  → per-file tmp+rename replace (атомарно пофайлово; §36-честность:
    кросс-файловой атомарности ФС не даёт)
  → steps доставленным кодом (как au_apply_converge: re-source
    доставленного lib/auto_update.sh в подоболочке, fallback — текущий)
  → reset_state-флаг → au_step_reset_state (reinstall + reset=1);
    без флага состояние НЕ трогаем (reinstall + reset=0)
  → au_prune_orphans → au_write_payload_meta → installed-tag LAST
  → ошибка до tag: au_rollback_patch (старый payload, старый tag/meta)
```

НЕ трогает (§14): `platform/openwrt/*`, `/etc/init.d/z2k`, hotplug,
метаданные пакета, `seed.tar.gz`, `adapter.api`.
Сохраняет (§15): `/etc/z2k/config`, `/etc/z2k/state/*` (включая WARP
device identity), `/etc/z2k/user-lists/*` (включая WARP-листы и custom
strategies), `/etc/z2k/webpanel/*`. Никакого `rm -rf /etc/z2k`.
Crash-порядок (§45): files → payload.meta → installed-tag.
- crash после files (mid-replace): marker+partial → frozen seed_ensure
  (invalidate + fail), следующий прогон — re-seed; детерминировано,
  никакого false-current.
- crash после meta / до tag: payload цел + meta нова → reconcile
  tag:=meta, converge no-op; восстановление ВПЕРЁД.
- download N-of-M fail / hash mismatch / bad signature / API too old:
  НОЛЬ мутаций целей, старые payload/meta/tag (§44).

## §10. Seed contract (§17)

Seed — только bootstrap пустой установки; дальше updater владеет
извлечённым. Production build доказывает:
`seed.meta.tag == payload manifest current` на момент сборки;
`seed.meta.ref` — immutable remote-resolvable commit/ref (проверка
`git ls-remote` в build script при наличии сети; локально — существование
коммита). Запрещены `unknown` / dirty tree / local-only ref в артефакте.
Package upgrade при здоровом payload НЕ ресидит: живой payload новее seed —
байт-в-байт цел, tag цел (frozen I5; тест R4 на артефакте).

## §11. Package versioning (§19) и arch (§20)

- `PKG_VERSION`/`PKG_RELEASE` + source commit + adapter API — воспроизводимо;
  фиксируется в `dist/provenance.json` на BUILD-время (роутер рантайм версию
  из ветки НЕ выводит). Постоянных `0.1.0/1` без релизного процесса нет.
- Arch: пакет везёт только shell/data (seed — lib/lua/fake/lists/strats;
  TG/RT/WARP/`z2k-detect` едут updater binary flow, НЕ в APK — иначе каждый
  апстрим-бинер требовал бы пересборки). Доказательство отсутствия ELF в
  seed → `PKGARCH:=all`. Появится arch-специфика — arch станет target'ной.

## §12. Dependencies: точные, проверенные (§21–§22)

Core: только то, что реально используется кодом (`kmod-nft-queue`,
`conntrack` + рантайм `nft`/`ip`/`ubus`/`uci`/cron/TLS-fetch — по факту
вызовов, не по dev-образу). Webpanel: `lighttpd` + точные mod-пакеты 25.12
(`mod_cgi`/`mod_setenv` имена — сверить с живым фидом, Stage 8; в Makefile
только подтверждённое). Без Entware. CGI НИКОГДА не ставит пакеты рантайма.
Имена, не сверенные с живым 25.12-фидом офлайн, помечены и тестом
зафиксированы как allowlist (§21 PARTIAL до Stage 8).

## §13. Build: real SDK, pinned, один entrypoint (§23–§25)

- Только настоящий OpenWrt 25.12.5 SDK/buildroot, target `mediatek/filogic`.
  Fake-tarball-`.apk` = провал гейта (§68).
- Один канонический entrypoint: `scripts/openwrt/build-release.sh`:
  clean tree (иначе отказ; dev — только явный флаг), Stage-тесты,
  manifest/seed coherence, exact SDK (URL+sha256 зафиксированы; SDK
  отсутствует → громкий отказ, не mock), build package(s), артефакты,
  inspect metadata, checksums.
- Provenance (machine-readable, `dist/provenance.json`): OpenWrt release,
  SDK URL/sha256, target, arch, source commit, package version, adapter API,
  seed tag/ref. `dist/` НЕ коммитится в source branch (§63).

## §14. Feed и подпись (§26–§30)

- Feed layout — обычные APK-семантики: `z2k-adapter-*.apk`,
  `[z2k-webpanel-*.apk]`, `packages.adb`, `sha256sums`, provenance. Никаких
  JSON-фидов. Один канонический HTTPS-путь (§64), не пять зеркал.
- Trust domains разделены: APK feed key ≠ z2k payload manifest key (§27).
  Production private APK key: НЕ в git/логах/фикстурах/артефактах (§65).
- CI/Actions production-приватный ключ НЕ держат (§28): build/test/unsigned
  candidate/verify — да; подпись — офлайн у оператора.
- Тесты — ephemeral-ключ: packages/sha256sums sign → accept правильным,
  reject чужим/подменённым (§29/§59-уровень примитива; настоящий packages.adb
  без `apk`-тулчейна — PARTIAL, не fake-PASS §30).

## §15. Bootstrap и lifecycle (§31–§38, §50–§52)

- First install:feed-ключ → feed-URL идемпотентно → `apk update` →
  `apk add z2k-adapter`. `distfeeds.list` НЕ трогаем; никакого blanket
  `apk upgrade`; никакого `--allow-untrusted` в проде (только явные
  dev-тесты артефактов).
- `/etc/apk/keys/<z2k>.pem` + `/etc/apk/repositories.d/<z2k>.list` владеет
  bootstrap (не payload, не runtime); uninstall их НЕ сносит (иначе ломаем
  reinstall и — неожиданно — чужие репозитории); `distfeeds.list` — никогда.
- Upgrade пакета: running z2k → package-файлы заменены → procd сходится →
  payload/config/state целы; reboot не требуется.
- Broken postinst: user data цела, payload не ресидится/не даунгрейдится,
  tag не фальсифицируется; гарантии — ровно те, что даёт APK (без выдумок
  транзакционности).
- Uninstall: stop owned processes, снять свои nft/rules, cron, glue; user
  data (config/state/user-lists/WARP identity/webpanel settings) — keep
  (purge только явный). Reinstall reuse: конфиг/state/WARP identity
  переиспользуются; payload — healthy-reuse или seed/heal по frozen machine;
  без дублей cron/hotplug.
- Webpanel獨立: удаление `z2k-webpanel` НЕ останавливает core/TG/RT/WARP и
  не трогает данные; core update не требует webpanel.
- WARP: base APK НЕ везёт движок (`GAME_WARP_ENABLED=0`, бинаря нет);
  upgrade сохраняет установленный опциональный бинарь.
- TG/RT/`z2k-detect`: verified binary flow как сейчас; в APK НЕ переезжают.

## §16. Release types (§53–§55)

- Package-only (adapter fix, payload unchanged): новый APK, тот же payload
  current/tag, fake payload-релиз запрещён.
- Payload-only (common change, contract unchanged): новый signed OpenWrt
  manifest, та же APK-версия. Это ОБЫЧНЫЙ случай.
- Combined: СНАЧАЛА APK (опубликован + доступен), ПОТОМ manifest с required API.

## §17. R-сценарии → тесты (§61)

R1 clean build / R2 dirty build → build script tests. R3 fresh install /
R4 upgrade-no-reseed / R5 missing payload / R6 partial payload → seed/lc
тесты на артефакте. R7 patch / R8 full reinstall / R9 download-fail /
R10 bad signature / R11 bad hash / R12 API-too-old → reinstall/release
тесты (локальный manifest + file://-транспорт). R13/R14/R15 → manifest-gen
тесты (package-only diff — пустой deliverable-набор; common-only —
манифест без API bump; combined — ordering gate). R16 uninstall/reinstall /
R17 WARP absent / R18 webpanel independence → lifecycle tests. R19/R20 feed
sign/verify → ephemeral-key tests (примитив; настоящий adb — PARTIAL).

## §18. PARTIAL-реестр (честно, не fake-PASS)

1. Real `.apk` из SDK (§23/§68) — нет сети/SDK в песочнице.
2. Точные имена 25.12-зависимостей по живому фиду (§21/§22) — allowlist в
   тесте, сверка в Stage 8.
3. Настоящий `packages.adb` + index tooling (§26/§59) — примитив подписи
   доказан на sha256sums; adb-формат без `apk(1)` не подделываем.
4. Production APK private key (§30/§65) — нет материала; процедура offline.
5. Live router acceptance (§69) — это Stage 8.

## §19. Common diff budget (Stage 7)

Трогаем: `package/openwrt/*`, `platform/openwrt/update.sh`,
`platform/openwrt/env.sh` (+новый `platform/openwrt/reinstall.sh`),
`package/openwrt/ADAPTER_API` (new), `lib/release_map.sh`
(только если потребует manifest-gen — иначе нет), release tooling
(`scripts/openwrt/*`), `tests/openwrt/*`, `docs/*`, workflows/scripts —
минимально. НЕ трогаем: detectors, Lua, strategies, TG/RT/WARP
implementation, webpanel application logic, `lib/auto_update.sh`
(только существующие hooks: `Z2K_AU_REINSTALL_EXECUTOR`, verified fetch,
snapshot/rollback, steps, meta/tag writers).
