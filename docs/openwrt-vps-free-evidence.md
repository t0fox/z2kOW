# Доказательства проверки OpenWrt VPS-free

Дата: 12 октября 2026 года. Ветка: `feat/openwrt-vps-free`.

Этот журнал фиксирует только выполненные проверки. Полная приёмка проекта ещё не пройдена.

Сверка с `main`: `UPDATES.json` совпадает; в feature-коммитах нет изменений release metadata или `seq`.

## Итерация Insta-IP: воспроизведение и исправление

В чистой VM OpenWrt 25.12.5 x86/64 локальный DoH endpoint Cloudflare отвечал HTTP 200 и возвращал A-запись. Функция `z2k_ow_insta_resolve_hosts` при этом возвращала ошибку: штатный BusyBox не содержит applet `paste`, который использовался для объединения IP-адресов с TTL.

Добавлен тест, отключающий `paste` в `PATH`. До исправления он завершился с `pass=18 fail=6`: не было кандидатов, записей кэша и ответа из кэша. Минимальное исправление заменило `paste` на POSIX `awk` для попарного чтения двух файлов.

После исправления:

- `tests/openwrt/test_ow_insta_runtime.sh`: `pass=24 fail=0`.
- `tests/openwrt/test_ow_insta_boundary.sh`: `pass=35 fail=0`.
- `sh -n` для изменённых shell-файлов: успешно.

## QEMU OpenWrt

Использован официальный OpenWrt 25.12.5 x86/64, kernel 6.12.94, в отдельном QEMU overlay. WAN работал через отдельный NAT интерфейс. Тестовые nftables таблицы удалялись trap-обработчиками; тестовый UCI конфиг dnsmasq сохранялся и восстанавливался.

Для сценариев независимости блокировались только IPv4 `213.176.74.63` и `79.137.196.7` внутри гостевой VM. WAN, DNS, SSH и остальные адреса не блокировались.

| Сценарий | Наблюдаемый результат |
|---|---|
| DoH для `github.com` и `raw.githubusercontent.com` | Получены A-записи от Cloudflare, Google Public DNS и AdGuard DNS. TTL и источник сохранены в локальном кэше. |
| GitHub API при блокировке двух VPS-IP | `https://api.github.com/zen`: HTTP 200, 37 байт. Счётчик правила блокировки VPS остался 0. |
| Повторный WAN E2E на чистой VM (12 октября) | При временной блокировке nft только для `213.176.74.63` и `79.137.196.7` GitHub API вернул HTTP 200 и тело 19 байт; Cloudflare DoH по закреплённому `1.1.1.1` вернул HTTP 200 и JSON 182 байта. VPN-интерфейса, `/dev/net/tun` и proxy-переменных не было; оба счётчика VPS — 0. После проверки тестовая nft-таблица и временные файлы удалены; пакеты и постоянные настройки не менялись. Это подтверждает прямой WAN/DoH в базовом OpenWrt, не полный продуктовый updater. |
| Instagram по адресу, полученному локальным DoH | `https://www.instagram.com/robots.txt`: HTTP 200, 7 528 байт содержимого. Это проверка HTTP-сервиса и тела ответа, а не только TLS handshake. Счётчик блокировки VPS остался 0. |
| RT proxy runtime | Собранный статический `z2k-rt-proxy` x86/64 запустил `--help` в OpenWrt 25.12.5. В двух E2E upstream pool был заведомо недоступен (`127.0.0.1:1`): Cloudflare ответил через TLS 1.3 и полный `GET /cdn-cgi/trace` с HTTP 200 (`warp=off`); `rutracker.org/forum/index.php` ответил HTTP 200, 96 400 байт HTML, TLS verify 0, direct fallback через `172.67.182.196`. В госте были только `lo`, `eth0`, `eth1`, `br-lan`, не было `/dev/net/tun` и HTTP(S)/ALL proxy-переменных. Счётчики блокировки обоих VPS IP — 0; процесс, тестовые файлы и nft-таблицы удалены. |
| Проверка системных часов | Изолированная `clock_skew_vs_relay` в госте использовала прямой HTTPS Date, вернула расхождение `0` секунд; старые VPS IP были заблокированы, оба счётчика — 0. Временный nft-набор и функция удалены. |
| Отказ всех трёх DoH IP | Заблокированы `1.1.1.1`, `8.8.8.8`, `94.140.14.14`; счётчик правила — 9 пакетов. Функция вернула кэшированные адреса. |
| Просроченный кэш | При сдвиге тестового времени за TTL и stale grace функция завершилась кодом 1 и не вернула адреса. |
| dnsmasq addnhosts | Через UCI зарегистрирован временный файл, запись `192.0.2.123 vps-free-test.invalid` разрешилась через `192.168.1.1`. После удаления адаптер убрал собственную ссылку и файл; исходный UCI export восстановлен. |
| Insta-IP full refresh (`a85f3be4`) | В QEMU 25.12.5 запущены закоммиченные `z2k-insta-ip-refresh.sh` и OpenWrt adapter. Прямой DoH, фильтр диапазонов и HTTPS-probe обновили 12 hostname-ов; старая запись Instagram заменена, комментарий и пользовательский `user.example` сохранены. VPS-IP `213.176.74.63` и `79.137.196.7` заблокированы nft, оба счётчика — 0. UCI и reload dnsmasq были изолированы стабами, чтобы не менять настройки VM; `/etc/apk/world` совпал до/после. Временные файлы, nft-таблица и `/tmp/z2k-log` восстановлены/удалены. No-op и восстановление при ошибке reload покрыты отдельным suite `7/7`; live QEMU прогон подтверждает обновление, а не отказ reload. |
| Insta-IP отказ DNS | В QEMU напрямую вызван `z2k_ow_insta_resolve_hosts instagram.com`: ответы Cloudflare/Google/AdGuard получены при заблокированных VPS-IP. Затем nft временно отклонил HTTPS к трём DoH-IP; кэш вернул те же кандидаты. При времени за TTL и stale grace функция завершилась кодом 1. Счётчики старых VPS-IP — 0; правило и кэш удалены. Проверена функция resolver, не полный refresh при отказе всех DNS-провайдеров. |
| Bootstrap metadata | В текущей QEMU VM прямой GitHub и jsDelivr отдали идентичные `UPDATES.json`/`.sig`; SHA-256 манифеста `b2e3c96b04d1a36c23e22942e2878a42810a98266143b63175db4eeeee86759e`, подпись успешно проверена ключом с ID `916b1459a03961d66af48ddb2165afbed3c0d7445f75c8b7c95adbb5fc044bae`. Старые VPS IP блокировались nft; счётчики — 0. Временные файлы и правило удалены. |
| Bootstrap manifest helper | Production-функция `fetch_verified_manifest` выполнена в OpenWrt QEMU 25.12.5 с реальным `jsonfilter` и временно установленным из официального feed `openssl-util`. В test wrapper отказ raw GitHub origin был задан искусственно; manifest, открытый ключ и подпись реально скачаны с jsDelivr, закреплённый fingerprint и Ed25519 подпись проверены OpenSSL. SHA-256 manifest `b2e3c96b04d1a36c23e22942e2878a42810a98266143b63175db4eeeee86759e`, key ID `916b1459a03961d66af48ddb2165afbed3c0d7445f75c8b7c95adbb5fc044bae`. Два старых VPS IP были заблокированы nft, счётчики — 0. После теста `openssl-util` и его две зависимости удалены; `/etc/apk/world` и `/lib/apk/db/installed` совпали с pre-test копиями побайтно, бинарник, временный cache и nft-таблица очищены. |
| Release downloader | В госте вызван `z2k_ow_download`: прямой файл `docs/openwrt-release-operations.md` принят при SHA-256 `83e4470b4318df3b7ab936022ce70aa75a55befa28bb14e111f7562a3eacc88c`, размер 7 582 байта. При блокировке двух VPS-IP и всех четырёх адресов `raw.githubusercontent.com` тот же ожидаемый digest/размер получен через `ghproxy.net`; проверка прошла. Это проверка общего загрузчика, не скачивание rootfs релиза. |
| Geosite release asset при отключённом VPS | Вызван штатный `fetch_to_tmp ru-blocked.txt` из текущего `files/z2k-geosite.sh`. В госте `github.com` временно направлялся на loopback, а nft блокировал оба VPS-IP. Origin не отвечал; загрузчик получил HTTP 200 через `ghproxy.net`, 1 731 646 байт, SHA-256 `8b8d8d1ce37edbdc550bbb73f473f072b15432bf42b1fac5b35f95a603fec77d`. Хеш и размер совпали с прямой контрольной копией на хосте. Счётчики блокировки обоих VPS-IP: 0. После прогона `/etc/hosts` возвращён из копии, временная nft-таблица удалена. |
| Перезапуск VM | OpenWrt загрузился повторно, WAN и HTTPS к GitHub API работали. Восстановление SSH потребовало временно добавить правило только для TCP/22 на WAN тестовой VM; правило удалено после проверки. |

Проверялись адаптерные скрипты напрямую в VM; полный продуктовый rootfs туда не устанавливался.
В чистом базовом образе `curl` отсутствовал. Для сетевых сценариев его установили в госте; штатный OpenWrt release installer включает `curl` в runtime-пакеты, а bootstrap устанавливает `jsonfilter`. Поэтому это не требование к предустановленному образу, но проверка полного package lifecycle остаётся открытой.

## Отдельный бинарник WARP daemon

`build-matrix.tsv` задаёт для `z2k-warpd` девять GOARCH: `arm64`, `arm`, `amd64`, `386`, `mips`, `mipsle`, `mips64le`, `ppc64`, `riscv64` (10 имён tracked-файлов с совместимым alias). OpenWrt release builder использует отдельную production-матрицу из семи целей: `arm64`, `arm`, `amd64`, `386`, `mips`, `mipsle`, `riscv64`; `mips64le` не входит, так как pinned upstream runtime его не поддерживает.

Структурная сверка tracked артефактов по `build-matrix.tsv` проверила 34 записи для `z2k-detect`, `z2k-verify`, `rt-proxy` и `z2k-warpd`: ELF class, endian и machine совпали с GOARCH; у всех файлов отсутствует `PT_INTERP`. Это проверяет форматы имеющихся файлов, а не runtime всех архитектур.

В этой сессии закреплённый Go 1.25.13 прошёл SHA-256 проверку. `rt-proxy` unit suite прошёл; пять отдельных GOARCH пересобраны, их шесть tracked имён побайтно совпали. `z2k-warpd` OpenWrt unit suite прошёл; дополнительно проверена расширенная Makefile-матрица из девяти GOARCH и десяти имён, но её tracked бинарники отличаются от текущего source. OpenWrt release builder эти файлы не пакует: он компилирует оба бинарника из source при каждой сборке release.

Текущие исходники повторно собраны с production-флагами builder для всех семи целей `rt-proxy` и `z2k-warpd`; все 14 результатов прошли проверку ELF class/endian/machine и отсутствия `PT_INTERP`. Для WARP включены OpenWrt build tag и overlay, версия взята из текущего `UPDATES.json` (`p-86.18`), release metadata не менялись. Свежие amd64-бинарники временно доставлены в OpenWrt QEMU 25.12.5 по локальному NAT HTTP: `z2k-warpd version` вернул `z2k-warpd p-86.18`, а `z2k-rt-proxy --help` выполнился. После smoke-проверки временные файлы удалены, в nft осталась только штатная таблица `inet fw4`; постоянные настройки и пакеты не менялись. Runtime остальных архитектур не подтверждён.

В OpenWrt 25.12.5 x86/64 VM временно запущен собранный `amd64` бинарник с командой `version`; получен ответ `z2k-warpd dev`. Временный файл из `/tmp` удалён. Это smoke-проверка запуска на x86/64, не проверка регистрации в Cloudflare или работы туннеля.

## Отдельный бинарник RT proxy

`rt-proxy` unit suite прошёл. В `build-matrix.tsv` перечислены пять GOARCH для `z2k-rt-proxy`: `arm64`, `arm`, `amd64`, `mips` (big-endian softfloat) и `mipsle` (little-endian softfloat); шестое имя файла — совместимый alias `mipsle`. Структурная проверка выше подтвердила ELF-заголовки и статичность всех перечисленных файлов. x86/64 бинарник выполнил `--help` в OpenWrt QEMU; E2E direct HTTP/HTTPS ранее прошёл на x86/64.

## Локальные suites

Все перечисленные ниже suites завершились без ошибок:

- `tests/test_fetch_vps_layer_budget.sh`: 48/48.
- `tests/openwrt/test_ow_env.sh`: 34/34.
- `tests/openwrt/test_ow_schedule.sh`: 40/40.
- `tests/openwrt/test_ow_installer.sh`: 38/38.
- `tests/openwrt/test_ow_unified_release.sh`: 71/71.
- `tests/openwrt/test_ow_warp_static.sh`: 92/92.
- `tests/openwrt/test_ow_warp_parity.sh`: 39/39.
- `tests/openwrt/test_ow_warp_archmap.sh`: 6/6; карта OpenWrt target для WARP.
- `tests/openwrt/test_ow_warp_lifecycle.sh`: 440/440.
- `tests/test_geosite_vps_independence.sh`: 1/1.
- `tests/test_geosite_cache_survives_reinstall.sh`: 41/41.
- `tests/test_geosite_apply_guard.sh`: 17/17.
- `tests/test_geosite_inject.sh`: 19/19.
- `tests/test_geosite_rkn_asset.sh`: 9/9.
- `tests/openwrt/test_ow_update_entry.sh`: 12/12; проверяет точки входа OpenWrt updater.
- `tests/openwrt/test_ow_updater_failsafe.sh`: 5/5; проверяет восстановление updater при отказах.
- `tests/openwrt/test_ow_updater_state.sh`: 7/7; проверяет состояние updater.
- `tests/openwrt/test_ow_bootstrap_download_validation.sh`: 8/8; проверяет отдельную функцию скачивания, точные сообщения о неверном размере/SHA-256 и отсутствие публикации недоверенного файла.
- `tests/openwrt/test_ow_bootstrap_manifest_mirrors.sh`: 7/7; проверяет отклонение плохой подписи origin, принятие подписанного зеркала и fail-closed при плохих подписях всех источников.
- Повторные release-gate suites без TG fixture: `test_ow_manifest_signing.sh` 19/19 на изолированной копии non-TG исходников `HEAD` (suite исправлен: отсутствующий `rg` больше не превращает пропуск проверки в PASS), `test_ow_release_workflow.py` 26/26, `test_ow_immutable_release_check.py` 6/6 и `test_ow_changelog_release.sh` 13/13.
- Повторные lifecycle-проверки без TG fixture: `test_ow_archive_validation.sh` 7/7, `test_ow_reinstall_guard.sh` 11/11, `test_ow_release_signing.py` 12/12 и `test_ow_release_warp_seed.sh` 5/5. Они проверяют отдельные предохранители архива, повторной установки, подписи и WARP seed; не подтверждают установку или обновление полного продукта.
- Дополнительные core lifecycle/recovery suites без TG-ссылок и fixture: `test_ow_lifecycle.sh` 27/27, `test_ow_recovery.sh` 13/13, `test_ow_boot_recovery.sh` 28/28, `test_ow_storage_persistence.sh` 17/17, `test_ow_atomic.sh` 8/8 и `test_ow_preserve.sh` 10/10. Подтверждают переходы состояний, восстановление, устойчивость хранилища, атомарность и сохранение чужих файлов в тестовых каталогах; полного подписанного install/update/rollback продукта в QEMU не заменяют.
- `tests/openwrt/test_ow_insta_refresh_noop_backup.sh`: 7/7; OpenWrt refresh без изменений удаляет временный backup, а отказ dnsmasq reload восстанавливает предыдущий файл.
- Keenetic Insta-IP regression suites: `test_insta_refresh_async.sh` 13/13, `test_insta_refresh_cert_mismatch.sh` 13/13, `test_insta_dns_opt_out.sh` 9/9.
- `tests/test_diag_clock_skew_vps_free.sh`: 7/7; OpenWrt не отправляет VPS ping и сверяет время по прямому HTTPS, прежний Keenetic relay сохраняется.
- `GOTOOLCHAIN=local go test ./...` в `rt-proxy`: все пакеты прошли.

В журналах installer/release присутствуют ожидаемые сообщения тестовых сценариев о восстановлении транзакции и отклонении неправильной SHA-256/размера; сами suites завершились успешно.

Последний запуск `tests/openwrt/test_ow_bootstrap_engine.sh` до исправления сообщений завершился `33/35`: два сценария размера получали общий текст «не удалось скачать архив», поскольку новый downloader отвергал файл раньше пост-проверки. Диагностика исправлена, узкий тест функции скачивания прошёл `8/8`. Полный suite после исправления не запускался: его fixture формирует общий rootfs с placeholder-файлом TG, поэтому он исключён из текущего прогона по ограничению пользователя.

`tests/openwrt/test_ow_warp_lifecycle.sh` ранее завершался `440/440`; повторный запуск на текущем worktree был остановлен до результата, поскольку общий fixture подключает TG-адаптер. Этот повтор не засчитывается как текущая проверка lifecycle.

## Границы этих доказательств

- QEMU проверки OpenWrt выполнены только на x86/64. `z2k-warpd` и `z2k-rt-proxy` собраны на всех семи targets; runtime на остальных архитектурах не подтверждён.
- Полная чистая установка продукта, реальное обновление подписанного rootfs, полный rollback и удаление продукта в QEMU не выполнялись.
- CI на GitHub не запускался: ветка не публиковалась. Локальные результаты не являются результатами CI.
- Telegram исключён из этой работы по указанию пользователя и остаётся вне этой приёмки.
- WARP остаётся отдельной опциональной функцией. В `ca0371ee` удалён встроенный VPS fallback из OpenWrt-адаптера и отфильтрованы legacy URL старого VPS; явно заданный пользовательский non-VPS proxy остаётся опциональным. Статические проверки прошли `92/92` и parity — `39/39`; регистрация, лицензирование и туннель Cloudflare в QEMU не проверялись. Для самой функции WARP нужен внешний маршрут к Cloudflare, и она не заменяет VPS-функции.
- Наличие нескольких внешних DoH/CDN endpoints снижает зависимость от одного провайдера, но не обеспечивает работу при полном отсутствии Интернет-доступа.

## Карта OpenWrt VPS-зависимостей

| Функция | Найденная зависимость | Реализация/статус OpenWrt |
|---|---|---|
| Bootstrap | GitHub release metadata и payload | Прямой HTTPS, независимый jsDelivr для пары metadata/key, зеркала для payload; подпись и SHA/размер остаются обязательными. Размер и SHA-ошибки различаются в диагностике; узкий тест загрузчика пройден. Полный bootstrap на устройстве не проверен. |
| Обновление продукта | GitHub release, `UPDATES.json`, `install_release(tag)` | Существующая транзакция/подпись и rollback сохранены; прямой путь и независимые зеркала. Полное обновление и rollback продукта в QEMU ещё не принимались. |
| Планировщик и cron | Суточные задачи запускают обновление, списки и WARP game list | `update.sh` и `list-refresh.sh` передают общий код через `platform/openwrt/env.sh`, где `Z2K_FETCH_VPS_OUT=1`; отдельная cron-строка `warp-games` задаёт тот же флаг явно. Проверки `test_ow_schedule.sh` (`40/40`), `test_ow_update_entry.sh` (`12/12`) и QEMU-загрузка подтверждают конфигурацию/точки входа, но полный cron-driven install/update в QEMU не выполнялся. |
| `z2k_fetch` и списки | Исторический VPS `--resolve` в shared transport | OpenWrt экспортирует `Z2K_FETCH_VPS_OUT=1`; расписание для warp-games задаёт его явно. В geosite ранее оставалась отдельная копия Layer 0 — теперь она уважает флаг и после origin пробует HTTPS зеркала. Geosite подтверждён live с заблокированным origin. |
| Insta-IP refresh | Исторически OpenWrt-вариант вызывал VPS `/resolve`; Keenetic использует этот HMAC-механизм и дальше. | В `a85f3be4` OpenWrt переведён на прямой DoH Cloudflare, Google и AdGuard, TTL/provenance-кэш, stale grace, проверку Meta диапазонов и HTTPS probe. Runtime `24/24`, boundary `35/35`, lifecycle no-op/rollback `7/7`; полный live refresh в QEMU обновил 12 hostname-ов с заблокированными VPS-IP, UCI/dnsmasq были изолированы стабами. Keenetic HMAC path сохранён. |
| DNS LAN | DNS провайдера/настройка роутера; не старый VPS | Используются локальные средства OpenWrt/dnsmasq и существующая upstream DNS конфигурация. Проверена запись addnhosts; отказ всех DoH кандидатов не выдаёт просроченный IP. |
| WARP | Исторические Keenetic-файлы `files/z2k-warp.sh` и `files/init.d/S51z2k-warp` содержат VPS proxy default. OpenWrt adapter не вызывает этот launcher и управляет WARP через `platform/openwrt/warp.sh`. | В `ca0371ee` встроенный default OpenWrt adapter удалён, legacy URL на `213.176.74.63`, его nip.io-имя и `79.137.196.7` фильтруются; пользовательский non-VPS proxy остаётся отдельной настройкой. `test_ow_warp_static.sh` и `test_ow_warp_parity.sh` прошли `92/92` и `39/39`. Реальная регистрация/лицензирование и работа Cloudflare-туннеля в QEMU не проверялись. |
| RuTracker RT proxy | Upstream pool `ps1.blockme.site` — независимая сторонняя egress-услуга | Proxy engine не зависит от нашей VPS и по умолчанию разрешает прямое соединение для явного списка RuTracker hostnames, если pool не смог обслужить запрос. Внешний pool не обязателен, когда сайт доступен напрямую; если провайдер блокирует прямой маршрут и сторонний pool недоступен, обход без любого внешнего egress невозможен. Варианты: прямой доступ, сторонний pool или собственный egress по выбору оператора. Unit suite, семь сборок и прямые TLS/HTTP E2E в QEMU прошли: Cloudflare и сам `rutracker.org` вернули HTTP 200 при недоступном pool и заблокированных VPS IP. |
| Диагностика | Общий `files/z2k-diag.sh` проверял VPS ping и сверял часы через relay | OpenWrt пропускает VPS ping и проверяет часы по прямому HTTPS Date от Cloudflare с Google как вторым источником; Keenetic сохраняет прежний ping и закреплённый relay. Изолированный тест `7/7`; QEMU clock probe при блокировке VPS ранее вернул `0` секунд расхождения. |
| Telegram | Пользователь исключил компонент из текущей работы | Не проверялся и не изменялся в рамках этой приёмки; другой агент отвечает за него. |

Контрольный поиск по committed `platform/openwrt/` и `scripts/openwrt/` по адресам старых VPS, `nip.io` и `vps-relay` (исключая TG-файлы) нашёл одно совпадение: `platform/openwrt/warp.sh` отклоняет сохранённые legacy URL как необязательный proxy. Общие Keenetic transport и Insta-IP relay остаются в shared-файлах, но OpenWrt entry points направляют загрузки через `Z2K_FETCH_VPS_OUT=1`, а Insta-IP использует отдельный прямой DoH адаптер.

## Дополнительный QEMU E2E: закреплённый bootstrap runtime

12 октября 2026 года в чистой OpenWrt 25.12.5 x86/64 QEMU временно установлен отдельный nft output-фильтр только для старых VPS-IP `213.176.74.63` и `79.137.196.7`. С роутера напрямую по HTTPS загружен закреплённый `runtime-pin` архив `zapret2-v1.0.5.2-z2k-r0-openwrt-embedded.tar.gz`: HTTP 200, endpoint `185.199.110.133`, 4 339 405 байт, время 3.139 секунды. SHA-256 `02eec373b093083b426c27191bb6af260ac51e4e2739c51270270a351d2a1a16` совпал с pin; `gzip -t` завершился с кодом 0, `tar -tzf` прочитал список файлов. Счётчики обоих блокирующих правил равны нулю.

Проверена только прямая доставка закреплённого runtime payload; это не подтверждает полный bootstrap, проверку релизной подписи, установку продукта или обновление/rollback. После проверки nft-таблица удалена, осталась штатная `inet fw4`, временный архив удалён.

В том же QEMU отдельно проверен failover подписанного `UPDATES.json`: основной `raw.githubusercontent.com` для одной команды был адресован через `curl --resolve` на loopback и отклонён проверкой TLS-сертификата; jsDelivr вернул манифест, подпись и ключ с HTTP 200 (`104.17.208.5`). SHA-256 DER-ключа совпал с закреплённым `916b1459a03961d66af48ddb2165afbed3c0d7445f75c8b7c95adbb5fc044bae`, `openssl pkeyutl -verify -rawin` подтвердил подпись, `seq` равен `142`. SHA-256 полученного манифеста: `b2e3c96b04d1a36c23e22942e2878a42810a98266143b63175db4eeeee86759e`; подписи: `aedb42d21959727a46f790bd1d2aa5d75b91cd6d1b828d837336c24a16e64cca`. Для проверки временно установлен пакет `openssl-util`, который установщик ставит штатно; пакет и зависимости удалены после проверки. Остались только таблица `inet fw4`, пустой `/var/cache/apk` и штатные 185 пакетов. Счётчики блокировки старых VPS-IP — нулевые.

Проверена и доставка подписанного x86/64 rootfs payload: для одной команды исходный `github.com` URL также был направлен через `curl --resolve` на loopback и отклонён TLS-проверкой. Оба настроенных HTTPS-зеркала `ghproxy.net` и `gh-proxy.com` вернули HTTP 200 с соответствующими endpoint-IP `5.135.5.132` и `104.18.42.54`; размеры обоих файлов — `13 707 778` байт, SHA-256 обоих — `f041dc6accf362793ec2731fe661bfa7b584da408d40b68c6fd39be9cc79e1d4`, что совпало с подписанным `UPDATES.json` для `x86_64`. Первая загрузка заняла 13.772 секунды, вторая — 4.974 секунды; `gzip -t` и чтение tar-индекса прошли. Счётчики старых VPS-IP были нулевыми; после прогона nft-таблица удалена, временные архивы удалены. Это подтверждает транспорт и SHA x86/64 payload, но не установку архива или полный release rollback.

## QEMU матрица release payload и дополнительных бинарников

В OpenWrt 25.12.5 x86/64 QEMU при блокировке `213.176.74.63` и `79.137.196.7` через `ghproxy.net` загружены все семь payload из подписанного `UPDATES.json` (`seq=142`). Для каждого проверены HTTP 200, точный размер, SHA-256 и `gzip -t`; время — секундомер curl:

| Архитектура | Размер, байт | Время, с | Результат |
|---|---:|---:|---|
| arm64 | 12 813 985 | 14.443 | SHA/размер/gzip совпали |
| arm | 11 198 489 | 6.982 | SHA/размер/gzip совпали |
| x86_64 | 13 707 778 | 8.838 | SHA/размер/gzip совпали |
| x86 | 11 222 761 | 14.104 | SHA/размер/gzip совпали |
| mips | 10 983 127 | 9.169 | SHA/размер/gzip совпали |
| mipsel | 10 931 574 | 12.538 | SHA/размер/gzip совпали |
| riscv64 | 11 001 720 | 8.552 | SHA/размер/gzip совпали |

Извлечены только 20-байтовые ELF-заголовки, без запуска файлов. `z2k-rt-proxy` и `z2k-warpd` отдельно совпали с целевыми ELF ABI на всех семи архитектурах (14/14): arm64 — ELF64 LE/EM_AARCH64, arm — ELF32 LE/EM_ARM, x86_64 — ELF64 LE/EM_X86_64, x86 — ELF32 LE/EM_386, mips — ELF32 BE/EM_MIPS, mipsel — ELF32 LE/EM_MIPS, riscv64 — ELF64 LE/EM_RISCV. Эти проверки подтверждают транспорт и заголовок бинарника внутри каждого опубликованного архива, но не исполнение на физических устройствах или эмуляцию всех семи CPU. Счётчики старых VPS-IP были нулевыми; после теста таблица удалена, временные файлы удалены, осталась штатная `inet fw4`.

Эти семь payload — опубликованные артефакты `p-86.18` из неизменённого `UPDATES.json`, а не сборка feature-ветки. Их проверка доказывает работоспособность внешней доставки и совпадение опубликованных архивов с подписанным manifest; она не является установкой или runtime-приёмкой изменений этой ветки.

## QEMU сетевые отказы и восстановление

На чистой OpenWrt QEMU локальный resolver (`127.0.0.1`) сначала успешно разрешил `github.com`. Временное правило output для UDP/TCP 53 привело к ошибке `nslookup` (`no servers could be reached`); счётчик UDP — 2 пакета. После удаления только DNS-таблицы `nslookup` снова разрешил `github.com`, осталась штатная `inet fw4`.

Отдельно заблокирован HTTPS к endpoint `ghproxy.net` (`5.135.5.132:443`): запрос завершился curl rc 7, счётчик правила — 1 пакет. После этого `gh-proxy.com` отдал x86_64 архив с HTTP 200, 13 707 778 байт и ожидаемым SHA-256 `f041dc6accf362793ec2731fe661bfa7b584da408d40b68c6fd39be9cc79e1d4`; `gzip -t` прошёл. Оба старых VPS-IP имели нулевые счётчики. Все временные nft-таблицы и файлы удалены. Это подтверждает сетевую доступность альтернативного CDN и восстановление базового DNS после снятия отказа; поведение установленного продукта при длительном полном DNS outage отдельно не подтверждено.

После тестов выполнен restart чистой QEMU OpenWrt 25.12.5 (гостевой reboot с последующим QEMU `system_reset`, затем активация serial-консоли). После загрузки `nslookup github.com` завершился успешно, `nft list tables` показал только штатную `inet fw4`, временного архива в `/tmp` не осталось. Это проверяет восстановление базовой сети и отсутствие временных правил после рестарта; жизненный цикл установленного z2kOW после reboot пока не проверен.

## Regression suites без Telegram

На feature-ветке прошли шесть независимых suites (52/52): `test_ow_bootstrap_download_validation.sh` (8/8), `test_ow_bootstrap_manifest_mirrors.sh` (7/7), `test_ow_recovery.sh` (13/13), `test_ow_update_entry.sh` (12/12), `test_ow_updater_failsafe.sh` (5/5), `test_ow_updater_state.sh` (7/7). Транзакционные fault/rollback, installer, boot-recovery и uninstall parity suites не запускались: они включают TG-фикстуры/проверки либо читают изменённый другим агентом `platform/openwrt/release.sh`. Поэтому эти результаты подтверждают updater entry/state и ошибки bootstrap, но не полную транзакцию обновления, rollback или удаление продукта.

Дополнительно прошли `test_ow_release_signing.py` (12/12), `test_ow_immutable_release_check.py` (6/6) и `test_ow_release_workflow.py` (26/26). Итого в этих девяти изолированных non-TG suites — 96/96; они не запускают производственный release workflow и не изменяют `UPDATES.json`, но также не закрывают runtime install/rollback.

Legacy VPS defaults остаются в `files/z2k-warp.sh` и `files/init.d/S51z2k-warp` для Keenetic. OpenWrt WARP adapter больше не имеет встроенного VPS proxy и не вызывает этот launcher; путь clock-skew выбирается по платформе и на OpenWrt использует прямые origin’ы. Полный жизненный цикл релизов остаётся пунктом незавершённой приёмки.

## Прямые внешние API, не являющиеся VPS-зависимостью

- TikTok CDN discovery использует Check-Host как дополнительный источник распределённых DNS-наблюдений (кэш на 6 часов). При его отказе адаптер оставляет локальные DNS/curated-кандидаты и кэш последнего наблюдения, затем проверяет каждый IP по TLS/SNI. Suites `test_ow_tiktok_checkhost.sh` (`25/25`), `test_ow_tiktok_runtime.sh` (`196/196`) и `test_ow_tiktok_cli.sh` (`3/3`) прошли. В OpenWrt QEMU x86/64 при блокировке `213.176.74.63` и `79.137.196.7` прямой TikTok oEmbed вернул HTTP 200 и 1 747 байт; счётчики блокировки — `0`. Это подтверждает доступность API через WAN без VPS.
- Ограничение проверки TikTok: `_z2k_ow_tiktok_probe_report` отправляет GET `/` и считает `curl`+TLS успешным транспортом независимо от HTTP-кода; в том же QEMU CDN root вернул HTTP 403 и 868 байт, а существующий тест намеренно принимает HTTP 403. Код сохраняет HTTP-код как диагностику и `media_status=not-verified`, но домен затем получает `transport-confirmed`/`healthy`. oEmbed не доказывает воспроизведение медиа, поэтому TikTok playback не засчитывается как проверенный. Официальный TikTok Display API выдаёт `cover_image_url` как часть авторизованного ответа; примеры содержат временные `x-expires`/`x-signature`, поэтому статический media URL нельзя считать универсальным probe ([Display API](https://developers.tiktok.com/docs/en/display-api-get-started), [Query Videos](https://developers.tiktok.com/docs/en/tiktok-api-v2-video-query)). Варианты для отдельной доработки: оставить статус только transport-level либо добавить opt-in проверку по пользовательскому актуальному media URL. Ни один вариант не внедрён в рамках VPS-free изменений. После прогона nft-таблица удалена, осталась только штатная `inet fw4`; временные файлы удалены; оба счётчика старых VPS-IP были `0`.
- FLOWOFFLOAD benchmark запускается пользователем отдельно и использует прямые endpoints выбранного провайдера: Yandex Internetometer или Cloudflare Speed Test. Если API выбранного провайдера недоступно, benchmark не стартует; основной OpenWrt datapath от него не зависит. `test_ow_offload_benchmark.sh` прошёл `142/142` на детерминированных измерительных заглушках; это не live-замер WAN.

## Insta-IP: отказ восстановления hosts

Fault injection: запись нового hosts-файла и reload dnsmasq завершились ошибкой, после чего восстановление исходного hosts-файла также было искусственно прервано. До исправления refresh возвращал `0`, удалял резервную копию и очищал conntrack; тест воспроизвёл все три нарушения. После минимального исправления refresh возвращает ошибку, сохраняет исходный backup и не очищает conntrack до подтверждённого восстановления. Результаты локально: `test_ow_insta_refresh_noop_backup.sh` — 11/11, `test_ow_insta_runtime.sh` — 24/24, `test_ow_insta_boundary.sh` — 35/35. Результат той же fault-injection проверки в OpenWrt QEMU приведён ниже.

## QEMU fault-injection восстановления Insta-IP

В OpenWrt 25.12.5 x86/64 (`z2k-vps-free-test`) по serial-консоли запущен `test_ow_insta_refresh_noop_backup.sh` (`11/11`). В fixture переданы только refresh script, OpenWrt Insta-IP adapter, список диапазонов Meta и тест. curl/jsonfilter/UCI/dnsmasq заменены штатными для этого теста заглушками; `cp` специально отказывает при чтении исходного backup для rollback. Проверено, что refresh возвращает ошибку, исходный backup остаётся, а conntrack flush не выполняется. SSH host-forward в эту сессию сбрасывал соединение; serial prompt был доступен после пустого Enter. SHA-256 `/etc/config/dhcp` до/после совпал (`c43757c2778625fb709c0f6124c50173c6330641dc1426d20a8766481bf3fe40`), `nft list tables` до/после показал только `inet fw4`. Тестовые файлы удалены с гостя и хоста; установка продукта и реальные UCI/dnsmasq reload не выполнялись.

## Повторные non-TG регрессии на `dab1cca8`

На текущей feature-ветке повторно прошли девять изолированных suites: bootstrap download validation `8/8`, manifest mirrors `7/7`, OpenWrt recovery `13/13`, update entry `12/12`, updater failsafe `5/5`, updater state `7/7`, release signing `12/12`, immutable release check `6/6`, release workflow `26/26` — всего `96/96`. Suites запускались отдельно от изменённого другим агентом Telegram installer. Они не проверяют clean install, полный update, transaction rollback и uninstall в QEMU.

## Повторные env/cron/WARP регрессии

На feature-ветке после QEMU Insta-IP fault-injection прошли `test_ow_env.sh` (`34/34`), `test_ow_schedule.sh` (`40/40`), `test_ow_warp_static.sh` (`92/92`), `test_ow_warp_parity.sh` (`39/39`) и `test_ow_warp_archmap.sh` (`6/6`) — всего `211/211`. Они проверяют OpenWrt окружение, cron entry points, фильтрацию старого VPS proxy и архитектурную карту WARP; не подтверждают регистрацию Cloudflare, работу туннеля или lifecycle полного installer. WARP остаётся опциональной функцией.

## Повторные fetch/geosite регрессии

На feature-ветке повторно прошли `test_fetch_vps_layer_budget.sh` (`48/48`), `test_geosite_vps_independence.sh` (`1/1`), `test_geosite_cache_survives_reinstall.sh` (`41/41`), `test_geosite_apply_guard.sh` (`17/17`), `test_geosite_inject.sh` (`19/19`) и `test_geosite_rkn_asset.sh` (`9/9`) — всего `135/135`. Проверены retry/fallback общего fetch, прямой OpenWrt path с независимыми зеркалами и сохранение geosite cache/ETag и пользовательских данных. Это локальные тесты, не полный подписанный install/update на устройстве.

## Повторные lifecycle/recovery/storage регрессии

Повторно прошли `test_ow_lifecycle.sh` (`27/27`), `test_ow_boot_recovery.sh` (`28/28`), `test_ow_storage_persistence.sh` (`17/17`), `test_ow_atomic.sh` (`8/8`) и `test_ow_preserve.sh` (`10/10`) — всего `90/90`. Подтверждены локальные переходы состояния, boot recovery, устойчивость storage, атомарные операции и сохранение чужих файлов; это не полный подписанный продуктовый install/update/rollback/uninstall в QEMU.

## QEMU прямой Insta-IP DoH при отказе VPS и DNS

На OpenWrt 25.12.5 x86/64 через serial запущен `z2k_ow_insta_resolve_hosts instagram.com` из штатного адаптера с настоящими `curl` и `jsonfilter`. Временная nft output-таблица блокировала только старые VPS-IP `213.176.74.63` и `79.137.196.7`; запросы прошли по прямому DoH и вернули `157.240.205.174`, `157.240.224.174`, `157.240.26.174`, счётчики обоих VPS правил — `0`. Затем заблокированы все три DoH endpoint IP (`1.1.1.1`, `8.8.8.8`, `94.140.14.14`, TCP/443): кэш вернул те же адреса; каждый endpoint получил по 6 отброшенных пакетов в ходе cache/TTL проверок. Сдвиг времени за TTL + stale grace отверг кэш. HTTP proxy переменные сняты. После теста nft содержит только `inet fw4`, SHA `/etc/config/dhcp` совпал до/после, пакеты не устанавливались, временные файлы и сервер доставки удалены. Это live DoH/cache E2E, не проверка полного refresh с реальным dnsmasq reload.

Отдельный live failover: при блокировке только Cloudflare DoH (`1.1.1.1:443`) resolver переключился на `dns.google` и `dns.adguard-dns.com`, вернул кандидаты `157.240.205.174` и `157.240.26.174` за 4 секунды. Счётчик Cloudflare block — 3 пакета; оба старых VPS-IP — 0. Временная таблица удалена trap-ом, после проверки осталась только `inet fw4`; конфигурация dnsmasq не менялась.
