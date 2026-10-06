# z2kOW — OpenWrt port of z2k

z2kOW — независимая адаптация [z2k](https://github.com/necronicle/z2k) для OpenWrt.

Исходный код: [github.com/t0fox/z2kOW](https://github.com/t0fox/z2kOW).

Цель проекта — сохранить функциональность и поведение upstream z2k максимально близко к оригиналу, заменив только то, что жёстко завязано на Keenetic и Entware: управление сервисами, firewall, сетевые события, пути файлов, планировщик и доставку релизов.

> z2kOW не является отдельной реализацией z2k и не развивает параллельную продуктовую архитектуру. Источник истины по общему поведению — upstream z2k; OpenWrt-специфика находится в адаптерном слое. Проект развивается независимо от команды z2k.

## Назначение и границы

z2kOW — open-source программное обеспечение для обработки сетевого трафика и интеграции сетевых механизмов z2k с OpenWrt. Проект включает NFQUEUE-обработку, traffic classification, policy routing, локальные proxy/tunnel-компоненты, диагностику, WebPanel, обновление конфигурационных данных и платформенную автоматику.

Проект не является хостинговым VPN-, proxy- или иным сервисом доступа и не предоставляет пользователям внешний сетевой канал, учётную запись или гарантированный доступ к какому-либо стороннему ресурсу.

Оператор устройства самостоятельно отвечает за допустимость выбранной конфигурации и соблюдение применимого законодательства, правил сети и условий сторонних сервисов. Подробнее: [LEGAL.md](LEGAL.md).

## Поддержать проект

Если z2kOW оказался полезен, проект можно поддержать через Streamiverse:

**[donation.streamiverse.io/t0fox](https://donation.streamiverse.io/t0fox)**

<a href="https://donation.streamiverse.io/t0fox">
  <img src="platform/openwrt/webpanel-brand/streamiverse-donation.svg" width="280" alt="QR-код Streamiverse для поддержки z2kOW">
</a>

Поддержка добровольная и не открывает платные функции, сетевой доступ, отдельные конфигурации или приоритет.

## Спонсоры проекта

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

---

## Что это

z2kOW переносит общую сетевую логику z2k на OpenWrt и добавляет платформенную интеграцию:

- автоподбор стратегий;
- постоянное состояние подобранных стратегий;
- пользовательские списки и исключения;
- WebPanel;
- Telegram-туннель;
- RT proxy;
- split-routing backend через WARP;
- диагностику;
- обновление списков и обслуживающие задачи;
- проверку линии на обрыв 16–20 КБ;
- подписанные обновления z2kOW.

На OpenWrt вместо Keenetic-механизмов используются procd, fw4/nftables, netifd, ubus, UCI и hotplug.

---

## Особенности

### Сетевые стратегии

- Общий с upstream z2k генератор конфигурации nfqws2 и та же модель autocircular.
- Отдельные TCP-пулы с автоматической ротацией стратегий; внутренние upstream-имена сохранены для совместимости.
- Общий QUIC-пул для UDP/443 с отдельной детекцией прогресса QUIC.
- Отдельный **Discord voice/video** профиль для Discord/STUN UDP.
- Найденное состояние стратегий сохраняется между перезапусками.
- Hostlist-режим: выбранная обработка применяется к соответствующим доменным правилам, а не ко всему трафику подряд.
- Дополнительные пользовательские домены, whitelist и исключения.
- Автохостлист — nfqws2 может самостоятельно накопить домены, для которых требуется выбранная обработка.
- Пользовательские стратегии позволяют переопределить отдельный пул, не форкая всю конфигурацию.

### Списки пользовательских исключений

Файл `/etc/z2k/ipset/zapret-hosts-user-exclude.txt` принимает IP-адреса и подсети IPv4/IPv6, по одной записи на строку. Пустые строки и комментарии после `#` разрешены. Домены в этом файле не разрешаются в адреса и пропускаются с сообщением; для исключения домена используйте раздел «Исключения» в WebPanel или `lists/whitelist.txt`. Изменение через WebPanel применяется сразу, ручная правка файла — после перезапуска сервиса.

### OpenWrt-интеграция

- **procd** — жизненный цикл основного сервиса, WebPanel, Telegram, RT proxy и WARP.
- **fw4/nftables** — NFQUEUE, redirects, sets и policy marking.
- **netifd / ubus / UCI** — состояние интерфейсов, LAN/WAN и OpenWrt-конфигурация.
- **hotplug** — восстановление runtime после сетевых событий.
- **cron** — обновления, списки, TCP16 и self-heal задачи.
- `/etc/z2k` — пользовательская конфигурация и постоянное состояние.
- `/usr/lib/z2k` — заменяемый payload текущего релиза.
- `/tmp/z2k` — runtime, временные файлы и журналы.

### Сеть и прокси

- **Telegram** — прозрачный туннель для устройств в LAN без настройки proxy на каждом клиенте.
- отдельные upstream traffic classes обслуживаются соответствующими TCP/TLS и UDP-профилями.
- **RT proxy** — отдельный proxy с OpenWrt DNS/firewall-интеграцией.
- **WARP** — split-routing для IP/CIDR, доменов, игровых списков и выбранных устройств.
- IPv4/IPv6 обслуживаются общей логикой z2k и соответствующими OpenWrt backend'ами.

### Инструменты и обслуживание

- **WebPanel** — сервис, режимы, стратегии, списки, WARP, диагностика, обновления, благодарности и донаты.
- **z2k diag** — одна сводка по procd, nftables/NFQUEUE, сети, Telegram, WARP, TCP16 и состоянию релиза.
- **z2k-detect** — проверки домена и сетевых стадий.
- **TCP16** — отдельная проба поведения network path при ограниченном объёме передачи.
- **Config validator** — проверка собранной конфигурации до применения.
- **Blocked monitor** — диагностический просмотр проблемных сетевых сессий.
- Подписанный release manifest и проверка целостности полного OpenWrt payload.

---

## Установка и релизы

z2kOW использует подписанную OpenWrt release-модель. Bootstrap и updater работают с root-привилегиями, поэтому перед развёртыванием рекомендуется ознакомиться с исходным кодом, [SECURITY.md](SECURITY.md), [LEGAL.md](LEGAL.md) и release-документацией.

Canonical bootstrap находится в `scripts/openwrt/install.sh`. Подробности процесса установки и восстановления описаны в [docs/openwrt-release-operations.md](docs/openwrt-release-operations.md).

Установщик:

1. ставит только необходимые системные зависимости OpenWrt;
2. получает контролируемый `UPDATES.json`;
3. проверяет подпись release metadata;
4. проверяет размер и SHA-256 release artifact;
5. применяет релиз через `install_release`;
6. запускает OpenWrt convergence и health gate.

Release lifecycle собирает компоненты в единый проверяемый OpenWrt payload.

---

## Веб-панель

После установки панель доступна по адресу:

```text
http://<адрес-роутера>:8088
```

Панель предназначена для локальной сети. Не публикуйте её напрямую в интернет.

---

## Командная строка

Основная команда:

```sh
z2kow <команда>
```

| Команда | Описание |
|---|---|
| `status` | Статус установленного релиза и сервиса |
| `check` | Проверить доступный релиз |
| `update` | Применить доступное обновление |
| `restart` | Перезапустить основной сервис |
| `blocked-monitor` | Управление диагностическим монитором сетевых сессий |

Сервисом также можно управлять штатно через OpenWrt:

```sh
/etc/init.d/z2k start
/etc/init.d/z2k stop
/etc/init.d/z2k restart
/etc/init.d/z2k status
```

---

## Как работает autocircular

z2k не требует вручную подбирать одну универсальную строку desync. У каждого пула есть набор стратегий: nfqws2 наблюдает новые соединения и при повторяющихся неудачах переключает стратегию для следующих соединений.

```text
новое соединение
      ↓
текущая стратегия пула
      ↓
наблюдение TCP / TLS / HTTP / QUIC
      ↓
успех ───────────────→ оставить стратегию
      ↓
повторяющиеся неудачи
      ↓
следующая стратегия
      ↓
состояние сохраняется
```

TCP, QUIC и Discord используют разные критерии прогресса. Обрыв на 16–20 КБ в эту ротацию не входит — для него существует отдельная система TCP16.

---

## Измерение и подбор сетевых стратегий

WebPanel может измерить сеть и подобрать отдельные стратегии для провайдера. Полный набор занимает в среднем около 20 минут и применяется только после успешных обязательных замеров.

Порядок внутренних пулов сохраняется совместимым с upstream. Некоторые probe-наборы используют внешние домены как технические тестовые цели; они нужны для воспроизводимости измерений и не являются обещанием доступности соответствующих сторонних сервисов.

Часть upstream probe-наборов использует конкретные внешние домены как технические тестовые цели. Эти цели сохраняются для воспроизводимости и parity с upstream и не являются обещанием доступности соответствующих сторонних сервисов.

## Upstream service-specific traffic classes

Некоторые upstream traffic classes используют отдельные TCP/UDP профили и тестовые идентификаторы.

### TCP/TLS traffic

Соответствующие доменные правила подключаются к общему hostlist + autocircular механизму.

### UDP traffic

Для голосовых и видеосессий используется отдельный `discord_udp` профиль:

- фильтрация идёт по сигнатурам `discord` и `stun`;
- охватываются Discord voice/STUN UDP-порты;
- используется отдельный набор fallback-стратегий;
- circular хранит общее состояние voice-пула, где обычно нет нормального hostname/SNI;
- desync применяется только к началу медиапотока, а не гонит весь высокобитрейтный звонок через NFQUEUE.

Это особенно важно для слабых роутеров: задача — повлиять на установление UDP-сессии, а не постоянно обрабатывать каждый пакет голоса или стрима.

В репозитории также сохранён upstream fallback:

```text
extras/discord-voice-hosts.txt
```

Это upstream-совместимый вспомогательный список; основной OpenWrt-путь — роутерный UDP-профиль.

---

## Telegram

Telegram работает прозрачно для устройств в локальной сети: клиентам не нужно прописывать отдельный proxy.

На OpenWrt procd владеет процессом туннеля, nftables направляет Telegram traffic на локальные listeners, а health-check восстанавливает принадлежащие z2kOW runtime-правила. Пользовательское выключение Telegram считается нормальным состоянием и не должно самопроизвольно отменяться self-heal'ом.

Общий клиент находится в `mtproxy-client/`, OpenWrt glue — в `platform/openwrt/tg.sh`.

---
## Обрыв на 16–20 КБ

Это отдельный механизм от autocircular.

Если соединение устанавливается, но передача обрывается после первых примерно 16 КБ, обычная ротация стратегий может не помочь. z2k использует отдельную пробу линии и карту сетей, чтобы подобрать подходящее имя для проблемных сетей.

На OpenWrt используются те же продуктовые сущности upstream:

- `z2k-tcp16-probe.sh` — измерение линии;
- `z2k-tcp16.lua` — runtime-подстановка;
- `tcp16_nets.txt` — карта сетей;
- persistent state — результат последнего измерения;
- ручной запуск через WebPanel;
- периодический запуск через OpenWrt scheduler.

---

## WARP split-routing backend

WARP в z2kOW — это **split-routing backend** для выбранного traffic scope, а не маршрут для всего роутера:

```text
выбранный IP / CIDR / домен / устройство
                   ↓
             nftables mark
                   ↓
               ip rule
                   ↓
          отдельная route table
                   ↓
               z2k-warpd
                   ↓
            Cloudflare WARP
```

Весь остальной трафик продолжает идти обычным маршрутом.

### Собственный движок z2k-warpd

WARP работает на собственном движке `z2k-warpd`, который лежит прямо в репозитории.

У него два транспорта:

- **WireGuard/UDP** — основной быстрый транспорт. Используются WARP registration data и Cloudflare reserved bytes; перед первым WG handshake движок добавляет короткую маскировочную последовательность.
- **MASQUE CONNECT-IP поверх HTTP/2/TCP 443** — запасной транспорт на случай недоступного UDP.

В режиме `auto` движок сам выбирает рабочий путь и следит за его состоянием. Наличие процесса само по себе не считается готовностью: OpenWrt backend также проверяет tunnel/interface и policy-routing state.

### Установка и включение

WARP — опциональная функция:

```text
Установить WARP
      ↓
получить движок
      ↓
зарегистрировать device identity
      ↓
Включить
      ↓
дождаться ready
      ↓
поднять nftables + policy routing
```

Device identity хранится в persistent state отдельно от заменяемого release payload.

### Игровые списки

Опциональные категорийные IP/CIDR-списки могут синхронизироваться из внешних community-источников. z2kOW хранит их раздельно, чтобы пользователь явно выбирал необходимый scope.

Это сделано вместо одного глобального ipset: включение одной категории не должно случайно менять маршрут посторонних сетей. Списки обновляются планировщиком независимо от релиза z2kOW.

### Пользовательские IP, CIDR и домены

В собственные WARP-списки можно добавлять IP/CIDR и поддерживаемые доменные правила.

Для доменов OpenWrt использует пассивное наблюдение DNS:

1. роутер видит DNS-ответ клиента;
2. сопоставляет ответ с WARP domain rules;
3. создаёт временную пару «клиент → IP»;
4. только трафик этого клиента к этому адресу получает WARP mark;
5. запись истекает по TTL.

Поэтому доменное правило не превращается в глобальный маршрут для всей LAN. Если приложение использует собственный DoH/DoT и DNS-ответ не виден роутеру, остаются IP/CIDR или маршрутизация выбранного устройства.

### Устройства целиком через WARP

Можно выбрать LAN-клиента по IP/MAC. OpenWrt-адаптер разрешает MAC в актуальный адрес активного клиента и не должен превращать старую DHCP lease в постоянный маршрут.

### Fail-open и self-heal

Если `z2k-warpd` перестал быть ready, z2kOW сначала снимает рабочий policy-routing path. Выбранный трафик не должен оставаться направленным в мёртвый туннель.

Self-heal затем восстанавливает процесс, nftables state и PBR. Смысл тот же, что у upstream: временный прямой маршрут лучше blackhole.

---

## Обновления

Роутеры используют только контролируемый z2kOW `UPDATES.json`.

Сам факт появления новой версии upstream z2k не означает автоматическую публикацию обновления для OpenWrt. Сначала upstream-изменения адаптируются, после чего публикуется отдельный подписанный z2kOW release.

```text
upstream z2k
     ↓
адаптация под OpenWrt
     ↓
z2kOW release
     ↓
signed UPDATES.json
     ↓
install_release
```

Конфигурация, пользовательские списки и постоянное состояние хранятся в `/etc/z2k` и отделены от заменяемого payload в `/usr/lib/z2k`.

---

## Структура проекта

Как и upstream z2k, репозиторий разделён на общую продуктовую часть и платформенную адаптацию. Главное дополнение z2kOW — `platform/openwrt/` и OpenWrt release tooling.

```text
z2kOW/
├── z2k.sh                         # upstream/common bootstrap и общая логика z2k
├── z2kow.sh                       # публичная OpenWrt bootstrap-команда
├── strats_new2.txt                # база TCP-стратегий
├── quic_strats.ini                # QUIC / Discord UDP strategy definitions
│
├── lib/                           # общие модули z2k
│   ├── utils.sh                   # shell helpers и safe config access
│   ├── install.sh                 # upstream lifecycle semantics
│   ├── strategies.sh              # strategy parsing/materialization
│   ├── config.sh                  # управление конфигурацией
│   ├── config_official.sh         # сборка nfqws2 config
│   ├── webpanel.sh                # общий WebPanel helper
│   ├── auto_update.sh             # общая update-логика и platform seams
│   └── release_map.sh             # build-time карта доставки файлов
│
├── files/                         # общий runtime payload
│   ├── lua/
│   │   ├── z2k-state-persist.lua # persistent autocircular state
│   │   ├── z2k-alert.lua         # TCP/TLS/HTTP failure detection
│   │   ├── z2k-quic-silence.lua  # QUIC progress/silence detector
│   │   ├── z2k-modern-core.lua   # morph/fragmentation/host-key helpers
│   │   ├── z2k-fooling-ext.lua   # dynamic TTL/fooling helpers
│   │   └── z2k-tcp16.lua         # TCP16 runtime map
│   ├── lists/                    # domain/IP/TCP16/WARP data
│   ├── fake/                     # protocol blobs
│   ├── z2k-tcp16-probe.sh        # проба линии 16–20 КБ
│   ├── z2k-update-lists.sh       # доменные и WARP game lists
│   ├── z2k-geosite.sh            # geosite / managed list import
│   ├── z2k-config-validator.sh   # валидация конфигурации
│   ├── z2k-blocked-monitor.sh    # монитор проблемных сессий
│   ├── z2k-stats-upload.sh       # strategy telemetry helper
│   └── z2k-diag.sh               # общая диагностическая оболочка
│
├── platform/openwrt/              # тонкий OpenWrt adapter
│   ├── paths.sh                   # /etc/z2k, /usr/lib/z2k, /tmp/z2k
│   ├── env.sh                     # common → OpenWrt environment map
│   ├── generate.sh                # platform generation hooks
│   ├── firewall.sh                # fw4/nftables/NFQUEUE
│   ├── state.sh                   # persistent state helpers
│   ├── schedule.sh                # cron schedules
│   ├── tg.sh                      # Telegram backend
│   ├── rt.sh                      # RT proxy backend
│   ├── warp.sh                    # WARP lifecycle, nftables и PBR
│   ├── warp-domain.sh             # client-scoped domain routing
│   ├── diag.sh                    # OpenWrt diagnostics
│   ├── uninstall.sh               # OpenWrt removal backend
│   ├── update.sh                  # device updater frontend
│   ├── release.sh                 # canonical release transaction
│   ├── release_state.sh           # installed tag + seq
│   ├── z2kow.sh                   # установленный operator CLI
│   └── webpanel-brand/            # logo/theme/profile/donation assets
│
├── scripts/openwrt/               # build/release/bootstrap tooling
│   ├── install.sh                 # fresh-install bootstrap
│   ├── install_release.sh         # canonical install_release <tag>
│   ├── stage-common-payload.sh    # common payload staging
│   ├── stage-rootfs.sh            # final OpenWrt rootfs
│   ├── build-release.sh           # release artifact build
│   ├── sign_release.py            # release signing
│   └── controlled_release.py      # controlled publication
│
├── webpanel/                      # общий CGI + frontend WebPanel
├── z2k-warpd/                     # WARP engine: WireGuard + MASQUE/H2
├── z2k-detect/                    # network/domain detector
├── z2k-verify/                    # verification utility
├── mtproxy-client/                # Telegram tunnel client
├── rt-proxy/                      # RT proxy
├── vps-relay/                     # relay-side components
├── vps-stats/                     # statistics receiver
├── extras/                        # дополнительные client helpers
├── tests/                         # common + OpenWrt tests
├── docs/                          # contracts и parity docs
├── UPDATES.json                   # production update manifest
└── UPDATES.json.sig               # подпись manifest
```

Ключевое правило: если код можно оставить общим с upstream, он остаётся в common-части. В `platform/openwrt/` уходит только эффект, который действительно зависит от OpenWrt.

---
## Архитектура

Основная идея проекта:

```text
upstream z2k
├── lib/
├── files/
├── webpanel/
└── общая продуктовая логика
        │
        └── platform/openwrt/
            ├── procd
            ├── fw4 / nftables
            ├── UCI / ubus / netifd
            ├── hotplug
            ├── scheduler
            ├── routing
            └── release lifecycle
```

Если функцию можно оставить общей с upstream — она остаётся общей. OpenWrt-реализация нужна только там, где отличается сама платформа.

Подробнее:

- [Архитектура](ARCHITECTURE.md)
- [Политика синхронизации с upstream](UPSTREAM.md)
- [Матрица parity](docs/UPSTREAM-PARITY-MATRIX.md)
- [Документация](docs/README.md)
- [Безопасность](SECURITY.md)

---

## Подпись обновлений

Production release metadata подписываются отдельным ключом z2kOW. Устройство проверяет подпись manifest и только после этого доверяет URL, размеру и SHA-256 release artifact.

Приватный production-ключ в репозитории не хранится.

SHA-256 fingerprint текущего публичного ключа `files/etc/z2k-update-pub.pem`:

```text
1041720fa0dff53e2babbf547a705c2f43c30bca2c6ca2ddf7144cfe3b470a01
```

---

## Для тех, кто собирается править код

| Документ | О чём |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Границы common-кода и OpenWrt-адаптера |
| [UPSTREAM.md](UPSTREAM.md) | Правила сохранения upstream parity |
| [RELEASING.md](RELEASING.md) | Как устроен выпуск OpenWrt-релизов |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Правила разработки |
| [SECURITY.md](SECURITY.md) | Модель доверия и границы безопасности |

---

## Лицензия

MIT

Лицензия на исходный код не отменяет требований применимого законодательства и условий сторонних сетей и сервисов. См. [LEGAL.md](LEGAL.md).
