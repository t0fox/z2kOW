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
                     manifests/ platform/ share/ (+ симлинк config -> /etc)
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
`${ZAPRET2_DIR}`), `lib/release_map.sh` (platform-диспетчер), `lib/auto_update.sh`
(targetless fail-safe, `Z2K_CONFIG_FILE`, merge-пути). Нарушение seam'а
печатается с категорией (lua/detectors/strategies/webpanel/update-system/warp).
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
payload (lib/lua/fake/lists/strategies/manifests/validator/pem). Model A:
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
