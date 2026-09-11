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

`tests/openwrt/test_ow_upstream_diff.sh`: дифф против BASELINE обязан лежать
в `platform/`, `package/`, `tests/openwrt/`, этом файле. Иначе — стоп-сигнал.
Единственное исключение: `.gitattributes`, только добавление `eol=lf`-строк
для extensionless файлов слоя (Makefile/init/hotplug ломаются от CRLF —
это показало предупреждение самого git при staging).

## Известные щели (не чиним на этом этапе, зафиксированы осознанно)

1. `lib/config_official.sh:65` — `Z2K_REFACTOR_PHASE3` читается из
   захардкоженного `/opt/zapret2/config` (единственное такое чтение в
   argv-конвейере; остальные ~30 — через `${ZAPRET2_DIR}`). Доказательство
   не-обходности: литерал в коде, `safe_config_read` — только файл, без env.
   Влияние: только явный opt-in экспериментального флага (дефолт 0 совпадает).
   Кандидат в однострочный allowlist-хук на следующем слое.
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
