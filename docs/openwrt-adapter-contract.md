# z2k OpenWrt adapter — контракт

Минимальный слой поверх почти нетронутого upstream z2k (baseline: `2ba48c0`,
p-84.7, ветка `feat/openwrt-adapter`). Правило: сначала adapter/hook, common
меняется только если доказано, что иначе OpenWrt поддержать нельзя.

## Что есть что

- **common z2k = upstream.** `lib/*`, `files/*`, `strats_new2.txt`,
  `quic_strats.ini` — читаем и вызываем, не правим. Генерация стратегий
  (`generate_nfqws2_opt_from_strategies`, `create_official_config`) уже
  параметризована окружением — десятки upstream-тестов вызывают её с
  `ZAPRET2_DIR="$root"`, мы делаем то же самое.
- **adapter = `platform/openwrt/` + `package/openwrt/`.** Пути, env-мост,
  сборка argv, bootstrap, делегация firewall, UCI-чтения, procd-сервис,
  hotplug, package skeleton. Ничего больше.
- **zapret2-z2k runtime — чужой, authoritative.** nfqws2-бинарник,
  `common/*.sh`, `init.d/openwrt/functions`, fork-lua, nft lifecycle,
  lan/wan ifsets, flow offload. Адаптер его ВЫЗЫВАЕТ, не копирует.

## Владение ресурсами (единственный владелец у каждого)

| Ресурс | Владелец | Почему |
|---|---|---|
| процесс nfqws2 | z2k procd-сервис | OPT_BASE stock zapret2-init зашит в скрипте без z2k lua-init/--blob/--bind-fix — через конфиг не инжектится |
| nft-таблица zapret, ifsets | zapret2 (`zapret_apply/remove/reload_ifsets`) | не строим второй firewall-фреймворк |
| QNUM/marks/ports | ОБЩИЕ: один файл `/etc/z2k/config`, демон и firewall читают его же | тест сверяет равенство |
| flow offload | zapret2 (`FLOWOFFLOAD` из того же конфига) | своих offload-правил у адаптера нет |
| custom.d | РАЗДЕЛЬНО: zapret2 — runtime'а; z2k — свой раннер (`z2k_custom_daemons`) | будущие TG/RT/WARP-хуки |
| сервис zapret2 | DISABLED | его daemon-половина не используется, firewall-функции вызываются напрямую |

## Filesystem

```text
/etc/z2k/            config (канонический), state/, user-lists/, conf/
/usr/lib/z2k/        payload read-only: lib/ lua/ fake/ lists/ extra_strats/
                     strats_new2.txt + quic_strats.ini (в корне, как на
                     Keenetic — regen-step читает их оттуда напрямую),
                     etc/ platform/ share/ (+ симлинк config -> /etc)
/tmp/z2k/            runtime/ locks/ logs/ downloads/ generated/
```

Мосты через симлинки (read-пути; запись всегда явным путём мимо них, тест
`ow-generate` ловит подмену симлинка файлом):

- `$Z2K_ROOT/config -> /etc/z2k/config` — supplementary-чтения
  `${ZAPRET2_DIR}/config` внутри `generate_*` (иначе флаги из /etc молча
  заменялись бы дефолтами — доказано тестом на `Z2K_NFQWS2_TEMPLATES=0`);
- `lists/whitelist.txt -> /etc/z2k/user-lists/whitelist.txt` (user-owned);
- `lists/discovered-domains.txt -> /etc/z2k/state/discovered-domains.txt`.

Strategy.txt прематериализованы СБОРКОЙ (`materialize.sh`: манифесты ->
`strategies.conf` -> `Strategy.txt`); в boot-пути только fail-closed
проверка наличия. Причина: `/usr/lib` на роутере read-only.

## Вертикальный срез core

```text
/etc/z2k/config
  -> create_official_config (upstream, без правок) -> NFQWS2_OPT + QNUM/marks/ports
  -> optbase.sh (LUAOPT/blobs/bind-fix — порт блока S99, это init-логика)
  -> procd nfqws2 --qnum=$QNUM $OPT_BASE $NFQWS2_OPT
  -> zapret_apply_firewall (тот же конфиг) -> nft/NFQUEUE
```

WAN-события: hotplug `90-z2k` дёргает только `reload_ifsets`, демон не
трогаем (NFQUEUE от имён интерфейсов не зависит). UCI: своей схемы нет,
читаем только системное (`dhcp.@dnsmasq`, в будущем); LAN — из `OPENWRT_LAN`.

## Sync invariant

`tests/openwrt/test_ow_upstream_diff.sh` (`UPSTREAM_ADAPTER_BOUNDARY`):
дифф против BASELINE обязан лежать в `platform/`, `package/`,
`tests/openwrt/`, этом файле — плюс allowlisted хуки:
`.gitattributes` (только +eol=lf), `lib/config_official.sh` (PHASE3 через
`${ZAPRET2_DIR}`), `lib/release_map.sh` (platform-диспетчер),
`lib/auto_update.sh` (targetless fail-safe, `Z2K_CONFIG_FILE`/merge хуки,
platform gate, reinstall executor, converge dirty-refusal + TARGET_REF pin,
merge failure propagation), `scripts/gen_file_hashes.sh` (platform-маркер
только для non-keenetic; keenetic-реген байт-идентичен),
`files/z2k-config-validator.sh` (FAKE_DIR + lua EXTRA),
`UPDATES.json` (только files_sha256 hash-обновления allowlisted lib-файлов —
манифест следует за деревом на каждом релизе),
`z2k-warpd/builds/*` (deliberate build refresh: бинарники, пересобранные
каноническим тулчейном z2k-warpd/Makefile; БАЙТ-АВТОРИТЕТ — CI-джоба
"Отгружаемые бинарники", не этот guard: path-based проверка отличить
refresh от подмены не может, content держит пересборка+sha256 каждый ран),
`lib/strategies.sh` + `z2k.sh` + `tests/test_au_compat.sh` (busybox-safe
tr-idiom Stage 8: замена GNU-классов явными наборами, GNU-эквивалент),
`webpanel/www/js/pages/warp.js` + `tests/test_panel_frontend_contract.sh`
(platform-neutral WARP detached-DOM lifecycle guard and its regression
scenario; common frontend behavior, no OpenWrt fork),
`README.md` (deliberate owner rewrite под адаптер; семантику подсказки
держит test_exclude_hint_truthful, не этот guard).
Нарушение seam'а печатается
с категорией (lua/detectors/strategies/webpanel/update-system/warp).
После каждого upstream sync BASELINE сдвигается на новый upstream HEAD.

## Известные щели (не чиним на этом этапе, зафиксированы осознанно)

1. ~~`lib/config_official.sh:65`~~ ЗАКРЫТА (§2): чтение через `${ZAPRET2_DIR}`.
2. Dry-run валидация в `create_official_config` ищет
   `/opt/zapret2/common/*.sh` литералом — на OpenWrt молча пропускается;
   валидатором служит старт демона под procd + closure-тесты.
3. `CUSTOM_DIR="/opt/z2k...keenetic"` и `POLICY_NAME` в генерируемом конфиге —
   мертвы на OpenWrt (CUSTOM_DIR перезаписывает сам zapret2-functions после
   сорсинга; POLICY читает только S99). Не трогаем.
4. `z2k-silence.lua` transitional guard из S99 не портирован: Keenetic-only
   защита апгрейда p-84.4…p-84.6, в свежем payload файла нет.
5. Autohostlist/ipset-записи (`${ZAPRET2_DIR}/ipset`) и tcp16-проба — следующие
   слои; core идёт с дефолтами (autohostlist=0, пустые tcp16-карты).
6. Merge extra-domains на OpenWrt работает через хуки путей (§3), но сам
   `au_merge_extra_domains` вызывается только из updater-контекста —
   он появится вместе со следующим слоем (scheduler/updater port).

## Update/ownership architecture (этап 2)

### Keenetic-only Instagram/WhatsApp refresher

`files/z2k-insta-ip-refresh.sh` остаётся upstream-помощником Keenetic: он
управляет `ndmc ip host` и вызывается только из полного цикла Keenetic
`files/z2k-update-lists.sh`. OpenWrt доставляет тот же общий helper в payload,
но запускает только его `warp-games` entrypoint из собственной cron-строки;
Keenetic-only insta/ndmc путь в OpenWrt не вызывается.

Ранее WARP gaming lists оставались пустыми из-за отсутствующего OpenWrt
install-map target. Теперь target `/usr/lib/z2k/z2k-update-lists.sh` и marker
`z2k-warp-games` закрывают эту delivery-дыру; если внешний `sources.json`
недоступен, helper оставляет старые списки и UI честно показывает ошибку.

Модель доставки: `git diff -> release builder (Z2K_PLATFORM) -> UPDATES.json
(install_map + steps, данными) -> installed updater executes`. Роутер пути
не угадывает; старый апдейтер непонятный шаг/отсутствие карты трактует как
«нужна переустановка» (rc 2); безадресный не-builds файл в changed_files —
провал без движения тега (fail-safe вместо silent skip).

Platform-различие — только на build/mapping-стороне:
`z2k_install_paths_for <platform> <path>` (дефолт keenetic, побайтово как
раньше). Keenetic-доставляемый файл без openwrt-маппинга — только из явного
списка в drift-тесте, иначе FAIL (молча не теряется).

Граница владения (машиночитаемо: `package/openwrt/ownership.map`):
пакет — adapter/init/hotplug/bootstrap/шаблон/seed.tar.gz; апдейтер — весь
payload (lib/lua/fake/lists/extra_strats/strats/validator/pem). Model A:
adapter-файлы НЕ имеют updater-маппингов (только opkg, иначе флаппинг);
пакет НЕ ставит payload напрямую (только seed.tar.gz -> postinst extract).
Конфликт = `PACKAGE_UPDATER_OWNERSHIP_CONFLICT`.

User-owned (`/etc/z2k/config`, `state/*`, `user-lists/*`): пакет не поставляет
(bootstrap — только если отсутствует), conffiles на init/hotplug, генератор
сохраняет флаги (saved_*).

Шаги — те же семантические имена, исполнитель платформенный через env:
`INIT_SCRIPT=/etc/init.d/z2k` (restart-service -> procd),
`Z2K_CONFIG_FILE=/etc/z2k/config` (мимо симлинка-моста),
`Z2K_AU_SBIN=/usr/lib/z2k/bin` (persistent, без /tmp-кеша),
`Z2K_EXTRA_DOMAINS_{SHIPPED,RUNTIME}`, `STATE_FILE`.
Бинарники: `uname -m` (aarch64 -> arm64) и `z2k_ow_goarch` для target-строк
(aarch64_cortex-a53 -> arm64) — имена GOARCH не меняем; подмена атомарна
(tmp + sha + mv, старый цел при провале) — сторожит тест паттерна.
Пакетный менеджер: apk если есть, иначе opkg (`pkg.sh`, без абстракций).

## Corrective pass 2.1: seed/channel/conffiles

Seed — только bootstrap пустой установки (Model A, инвариант в
`z2k_ow_seed_ensure`): marker `/etc/z2k/.payload-initialized` ставится
только после extract+bootstrap+verify (`Z2K_PAYLOAD_REQUIRED`, 7 файлов);
package upgrade при целом payload ничего не извлекает (updater-правки
сохраняются побайтово); провал — без marker (retry идёт); marker + битый
payload — громкий провал без авто-recovery (repair: удалить marker).
Новый seed из пакета ждёт только fresh/repair. Purpose seed задокументирован
в `package/openwrt/make-seed.sh` и ownership.map.

Канал обновлений (вариант A): production-ветка `z2k-enhanced-openwrt`
(создаётся к первому OpenWrt-релизу; dev-ветки не опрашиваются), репо
`t0fox/z2kOW` — всё через env (`Z2K_AU_BRANCH/_REPO_RAW`, `GITHUB_RAW`;
`Z2K_AU_MANIFEST_URL` выводится сам). Keenetic-дефолты не тронуты.
Манифест несёт `"platform": "openwrt"` (пишет gen_file_hashes.sh только при
non-keenetic; старые парсеры слепы — значение не hex и не массив).
Gate `au_manifest_platform_ok` в fetch (single choke): без ключа или с
keenetic-целями (`/opt/etc/`) — отказ до применения, тег стоит.

Conffiles отсутствуют осознанно: init/hotplug — package-owned код
(обновляется с пакетом); `/etc/z2k/*` пакет не поставляет (bootstrap/user).
Владение трёхклассовое: package / updater / user (см. ownership.map).

## Updater execution (этап 2.2)

Entry — `platform/openwrt/update.sh [apply|check]` (package-owned, НЕ форк):
`paths.sh -> env.sh -> utils.sh -> auto_update.sh`, затем гейт
`Z2K_AUTO_UPDATE_ENABLED` (ручной `Z2K_AU_MANUAL=1` обходит), jitter
`z2k_host_jitter` только плановому пути, затем `au_run_apply`/`au_run_check`.
Branch-file gate нет: канал = env. PATH докладывается sbin впереди, не сброс.

Канал: `Z2K_AU_BRANCH=z2k-enhanced-openwrt` (production, создаётся к первому
релизу), `Z2K_AU_REPO_RAW`/`GITHUB_RAW`/`Z2K_AU_RAW_BASE` — один origin
`t0fox/z2kOW` (manifest == payload lineage). Неизменяемые ref — `$BASE/$ref`
(хук `au_repo_base`; fork-only ref никогда не уходит в necronicle).

Состояние: tag `state/installed-tag`, trust `etc/.trust/pinned`,
lock/log/tmp — в `/tmp/z2k/*`. Pubkey/verify — через существующие
`ZAPRET2_DIR`/`Z2K_AU_SBIN`-дефолты (проверено тестом, common не тронут).

QUIC rotation state is migrated by the OpenWrt adapter before procd creates
the nfqws2 instance: `/etc/z2k/state/state.tsv`, the
`Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE` copy, and the pre-p-84.23
`/tmp/z2k-autocircular-state.tsv` path are scanned, and only a first-field
`yt_quic` is atomically renamed to `quic`. The migration uses the same lock,
stale-lock, metadata-preservation, and retry semantics as the Lua writer;
unrelated pools and strategy numbers remain byte-for-byte intact.

Reinstall: `Z2K_AU_REINSTALL_EXECUTOR` (одна точка в `au_apply_reinstall`).
Keenetic — legacy `z2k.sh`-путь без изменений. OpenWrt —
`z2k_ow_reinstall_unsupported`: fail closed (тег стоит, payload цел,
`z2k.sh` не скачивается и не исполняется; причина — в лог).

Периодика: OpenWrt-планировщик хранит выбранный `Z2K_AU_HOUR` (00..23,
по умолчанию `02`) и конвергирует одну cron-строку вида `17 HH * * *
update.sh apply` в `/etc/crontabs/root` (postinst/API ставят её идемпотентно,
изменение часа не плодит записи, prerm снимает; cron enable/start best-effort).
Launcher добавляет детерминированный разброс 0..3599 секунд (до 60 минут).
Procd-демона ради суточной задачи нет осознанно.
