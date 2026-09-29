# z2kOW

`z2kOW` — OpenWrt-адаптация [z2k](https://github.com/necronicle/z2k) с нативным lifecycle, firewall/routing-интеграцией, пакетами и webpanel для OpenWrt.

Панель использует общий интерфейс z2k; OpenWrt-адаптер передаёт локальный профиль бренда `z2kOW` / `OpenWrt edition`.
Поддержка и обсуждение: [Telegram-группа @zapret2keenetic](https://t.me/zapret2keenetic).

Статус: **Beta; первый production-релиз ещё не опубликован**

```text
client traffic
     |
     v
OpenWrt / fw4 / nftables
     |
     v
z2kOW adapter
     |
     +--> nfqws2 / strategies / autocircular
     +--> Telegram / CDN
     +--> RT proxy
     +--> WARP
     +--> webpanel
```

> [!IMPORTANT]
> z2kOW — отдельный OpenWrt-проект, а не слепое зеркало upstream. Общая логика z2k синхронизируется из `necronicle/z2k`, а OpenWrt-слой развивается и тестируется отдельно.
>
> Список «Протестировано» ниже означает проверку текущего поведения автоматическими тестами и CI. Совместимость не привязана в README к конкретным моделям роутеров.

## Возможности

- стратегии z2k и `autocircular` с сохранением выбранного состояния;
- `nftables/fw4` + NFQUEUE вместо Keenetic-specific firewall glue;
- `procd` lifecycle для core и связанных процессов;
- OpenWrt paths, UCI/dnsmasq integration и package lifecycle;
- webpanel с управлением сервисом, стратегиями, списками и диагностикой;
- прозрачный Telegram transport и CDN redirect;
- RuTracker RT proxy;
- WARP с policy routing, доменными/клиентскими списками и fail-open поведением;
- пользовательские списки, custom strategies и persistent state;
- signed payload updater;
- отдельные APK для adapter, webpanel и runtime;
- controlled upstream sync через временные `sync/<version>` ветки.

## Протестировано

Текущий OpenWrt-контур проверяется отдельным набором regression/contract тестов и общим CI.

| Область | Что проверяется |
|---|---|
| **Package** | сборка через pinned OpenWrt SDK, APK metadata/dependencies, runtime closure, `packages.adb`, install/upgrade paths |
| **Lifecycle** | start/stop/reload, procd ownership, config convergence, restart/recovery и сохранение persistent state |
| **Firewall** | nftables/NFQUEUE rules, marks, redirects, fw4 integration и отсутствие лишнего ownership |
| **Strategies** | генерация конфигурации, autocircular, strategy pools, custom strategies, state persistence |
| **Lists** | whitelist, extra domains, exclude, autohostlist и user-owned data lifecycle |
| **Telegram** | process lifecycle, redirect rules, CDN path и platform contracts |
| **RT proxy** | DNS/sentinel path, transparent redirect и lifecycle |
| **WARP** | install/enable/disable/remove, PBR, domain/client routing, recovery, fail-open и runtime state |
| **Webpanel** | CGI/API, routes, pages, capabilities, restart jobs, config/update paths |
| **Updater** | manifest handling, signature checks, state transitions, payload convergence и upgrade regressions |
| **Binaries** | Go builds, reproducibility checks и соответствие исходникам |
| **Quality gates** | ShellCheck, Luacheck, ESLint, Go tests, workflow lint и mutation tests |

Основной OpenWrt suite запускается с `OW_STRICT=1`: любой нарушенный platform contract блокирует package build.

Актуальный результат смотрите в [GitHub Actions](https://github.com/t0fox/z2kOW/actions/workflows/ci.yml) для точного SHA нужного коммита.

## Установка

Первый production-релиз пока не опубликован, поэтому production-установка ещё недоступна. После закрытия release acceptance и настройки production signing key установите z2kOW одной командой по SSH на поддерживаемом OpenWrt:

```sh
wget -qO- https://github.com/t0fox/z2kOW/releases/latest/download/install.sh | sh
```

Installer проверяет OpenWrt 25.12.5, target `mediatek/filogic`, APK architecture и закреплённый fingerprint production-ключа. Он добавляет отдельный feed, устанавливает `z2k-adapter` и `z2k-webpanel` из подписанного APK feed, а затем проверяет core и панель. Ключ и repository entry повторно используются; `distfeeds.list` не меняется. Package lifecycle сам включает и запускает службы.

После установки панель доступна по адресу `http://<IP роутера>:8088`.

Обновляйте production-пакеты одной командой CLI или с карточки обновления в webpanel:

```sh
z2kow update
```

Удаление пакетов сохраняет конфигурацию и persistent state:

```sh
z2kow uninstall
```

Для полного удаления конфигурации используйте явный opt-in `z2kow uninstall --purge`; обычное удаление оставляет `/etc/z2k/config`, WARP identity, persistent state и пользовательские списки.

### Development / Testing

CI snapshots предназначены только для тестового устройства и не являются production feed. Установите APK из artifact одного зелёного CI run точного SHA:

```sh
apk add --allow-untrusted ./z2k-adapter-*.apk ./z2k-webpanel-*.apk
```

У snapshot-пакетов может быть отдельный временный feed key. Не используйте snapshot для обычного обновления и не копируйте эту команду в production-инструкции.

## Использование

Основное управление:

```sh
/etc/init.d/z2k start
/etc/init.d/z2k stop
/etc/init.d/z2k restart
/etc/init.d/z2k reload
/etc/init.d/z2k status
```

Основные пути:

```text
/etc/z2k/config               основной конфиг
/etc/z2k/state/               persistent state
/etc/z2k/user-lists/          пользовательские списки и стратегии
/usr/lib/z2k/                 payload
/usr/lib/z2k/platform/openwrt OpenWrt adapter
/tmp/z2k/                     runtime, logs, generated state
```

## Стратегии

Логика остаётся общей с z2k: трафик разделяется по strategy pools, а `autocircular` перебирает варианты и закрепляет рабочее состояние.

Типовой flow:

```text
request failed
      |
      v
autocircular
      |
      v
next strategy
      |
      v
successful strategy
      |
      v
persistent state
```

Пользовательские стратегии и списки лежат отдельно от updater-owned payload и не должны затираться обычным обновлением.

### Экспериментальный уникальный набор стратегий

Подбор проверяет цели в среднем около 20 минут. Для YouTube используются `i.ytimg.com` и `googlevideo.com`; пулы — `yt_tcp`, `gv_tcp`, `quic`, `rkn_tcp`. RKN-зонд идёт по `discord.com`, `instagram.com`, затем `rutor.org`; при отсутствии общего RKN-результата используется Discord fallback.

Проверка использует два IPv4-адреса одной цели: кандидат должен работать на обоих. Если общий кандидат не найден, пул не применяется и существующие стратегии остаются на месте. Это не обещание универсально подходящей стратегии: результат зависит от сети и измеренных адресов.

### Исключения и пользовательские списки

В пользовательских списках адресов одна запись указывается на строку. Пустые строки и комментарии после `#` разрешены; доменные имена не разрешаются в IP и пропускаются с сообщением при старте. Изменение через панель применяется сразу, ручная правка файла — после перезапуска firewall.

## Telegram

Telegram/CDN работает через отдельный runtime внутри общего z2k lifecycle.

```text
LAN client
    |
    v
nft redirect
    |
    +--> :1443 Telegram
    +--> :1444 CDN
```

Ручная настройка proxy на клиентских устройствах не требуется.

## RT proxy

RT proxy интегрирован в тот же lifecycle и transparent routing.

Пользователю не требуется отдельный init-script или отдельный firewall stack: нужные правила создаются и удаляются вместе с z2kOW.

## WARP

WARP используется для трафика, который должен идти через отдельный route path, а не только через desync strategies.

Управление:

```sh
/usr/lib/z2k/platform/openwrt/warp.sh install
/usr/lib/z2k/platform/openwrt/warp.sh enable
/usr/lib/z2k/platform/openwrt/warp.sh status
/usr/lib/z2k/platform/openwrt/warp.sh disable
/usr/lib/z2k/platform/openwrt/warp.sh remove
```

Основной принцип — **fail-open**: если WARP runtime не готов, его PBR/routing state должен сниматься, а обычный трафик не должен уходить в blackhole.

## Обновления

У z2kOW два слоя обновлений.

**Payload update** — общая логика z2k, Lua, strategies, lists, webpanel assets и updater-owned binaries.

Проверить:

```sh
/usr/lib/z2k/platform/openwrt/update.sh check
```

Применить вручную:

```sh
Z2K_AU_MANUAL=1 /usr/lib/z2k/platform/openwrt/update.sh apply
```

Отпечаток публичного ключа подписанных обновлений:

```text
1041720fa0dff53e2babbf547a705c2f43c30bca2c6ca2ddf7144cfe3b470a01
```

При подтверждении замены ключа сравните показанный установщиком отпечаток с этим значением. Ошибка подписи сама по себе не требует ручной переустановки: автоматическое обновление отклоняется, установленный обход остаётся запущен.

**APK update** нужен, когда меняется сам OpenWrt adapter, package metadata, init/hotplug integration или platform API.

## Upstream sync

Upstream: [necronicle/z2k](https://github.com/necronicle/z2k)

Текущий baseline хранится в [UPSTREAM.json](./UPSTREAM.json).

Синхронизация не выполняется напрямую в `main`:

```text
necronicle/z2k
      |
      v
sync/<version>
      |
      +--> merge/audit
      +--> OpenWrt tests
      +--> CI
      |
      v
main
```

Для ручной синхронизации есть **Actions → Sync upstream → Run workflow**.

Подробно: [UPSTREAM.md](./UPSTREAM.md).

## Документация

- [OpenWrt adapter contract](./docs/openwrt-adapter-contract.md)
- [Webpanel contract](./docs/openwrt-webpanel-contract.md)
- [Telegram contract](./docs/openwrt-telegram-contract.md)
- [RT proxy contract](./docs/openwrt-rt-proxy-contract.md)
- [WARP contract](./docs/openwrt-warp-contract.md)
- [Release contract](./docs/openwrt-release-contract.md)
- [Release operations](./docs/openwrt-release-operations.md)
- [Upstream contracts](./docs/UPSTREAM-CONTRACTS.md)
- [Upstream sync](./docs/UPSTREAM-SYNC.md)

## Тесты

Основной OpenWrt test suite:

```sh
OW_STRICT=1 sh tests/openwrt/run.sh
```

Общий CI дополнительно проверяет shell, Lua, JavaScript, Go-компоненты, workflow-файлы, package build и reproducibility.

## Огромная благодарность спонсорам проекта

- **SupWgeneral**
- **Alexey**
- **Jet_sk_ya**
- **Suharik39**
- **ZyaK<-**
- **Алексей Стрельцов**
- **Diman86RUS**
- **Alex**
- **GRM**
- **Dez**
- **hoaxx**
- **Mansurchick**
- **Dkarloff - SEO отец**
- **KIBERPANK**
- **olmer2002**
- **TiaMax**
- **Denis**
- **Mega Man**
- **TheGreatYogo**
- **logistik77**
- **b11d11**
- **BloodKnife39**
- **SIGogelon**
- **yozh**
- **Altaec**
- **DIDIQ Rawa**

## Лицензия

MIT. См. [LICENSE](./LICENSE).

## Upstream

z2kOW основан на [necronicle/z2k](https://github.com/necronicle/z2k) и использует [zapret2](https://github.com/bol-van/zapret2) как dataplane/runtime основу.

Происхождение upstream сохраняется в Git history и в [UPSTREAM.md](./UPSTREAM.md).
