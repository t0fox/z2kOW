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

Для сценариев независимости nft правило фильтровало только исходящий TCP/443 к IPv4 `213.176.74.63` и `79.137.196.7` внутри гостевой VM; DNS и остальные адреса не совпадали с правилом. WAN проверялся отдельно. SSH через QEMU host-forward не подтверждён.

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
| Insta-IP refresh | Исторически OpenWrt-вариант вызывал VPS `/resolve`; Keenetic использует этот HMAC-механизм и дальше. | OpenWrt использует прямой DoH Cloudflare, Google и AdGuard, TTL/provenance-кэш, stale grace, фильтр Meta-диапазонов и HTTPS probe. Runtime `26/26`, boundary `35/35`, no-op/rollback `11/11`; полный QEMU refresh с реальным UCI/dnsmasq обновил 11 из 12 hostname-ов при блокировке VPS-IP, сохранил пользовательскую запись и удалил прежний A-адрес. Один hostname оставил прежние записи, так как HTTPS-пробы кандидатов не прошли. Keenetic HMAC path сохранён. |
| DNS LAN | DNS провайдера/настройка роутера; не старый VPS | Используются локальный OpenWrt/dnsmasq и существующая upstream DNS конфигурация. Live E2E подтвердил пользовательский addnhosts после refresh. Перезапуск dnsmasq очищает прежние A-записи; в QEMU он занял `3,24 с`, локальный DNS восстановился в течение двух секунд после команды. Пауза на реальном роутере не измерена. |
| DNS-диагностика WebPanel | Общего VPS endpoint нет; сравниваются публичные UDP/DoH/DoT резолверы напрямую | Общий `files/z2k-dns-check.sh` поставляется в OpenWrt rootfs и вызывается WebPanel API. DoH использует прямые HTTPS-запросы с `--resolve` на адрес проверяемого резолвера; старые VPS-IP и proxy-переменные не используются. При блокировке всех проверяемых внешних DNS-провайдеров неполон только диагностический отчёт; системный DNS/dnsmasq и пользовательский трафик этим скриптом не заменяются. OpenWrt parser suite `tests/openwrt/test_ow_dns_check.sh` прошёл `2/2`; live availability каждого публичного провайдера не подтверждена.
| WARP | Исторические Keenetic-файлы `files/z2k-warp.sh` и `files/init.d/S51z2k-warp` содержат VPS proxy default. OpenWrt adapter не вызывает этот launcher и управляет WARP через `platform/openwrt/warp.sh`. | В `ca0371ee` встроенный default OpenWrt adapter удалён, legacy URL на `213.176.74.63`, его nip.io-имя и `79.137.196.7` фильтруются; пользовательский non-VPS proxy остаётся отдельной настройкой. `test_ow_warp_static.sh` и `test_ow_warp_parity.sh` прошли `92/92` и `39/39`. Реальная регистрация/лицензирование и работа Cloudflare-туннеля в QEMU не проверялись. |
| RuTracker RT proxy | Upstream pool `ps1.blockme.site` — независимая сторонняя egress-услуга | Proxy engine не зависит от нашей VPS и по умолчанию разрешает прямое соединение для явного списка RuTracker hostnames, если pool не смог обслужить запрос. Внешний pool не обязателен, когда сайт доступен напрямую; если провайдер блокирует прямой маршрут и сторонний pool недоступен, обход без любого внешнего egress невозможен. Варианты: прямой доступ, сторонний pool или собственный egress по выбору оператора. Unit suite, семь сборок и прямые TLS/HTTP E2E в QEMU прошли: Cloudflare и сам `rutracker.org` вернули HTTP 200 при недоступном pool и заблокированных VPS IP. |
| Диагностика | Общий `files/z2k-diag.sh` проверял VPS ping и сверял часы через relay | OpenWrt пропускает VPS ping и проверяет часы по прямому HTTPS Date от Cloudflare с Google как вторым источником; Keenetic сохраняет прежний ping и закреплённый relay. Изолированный тест `7/7`; QEMU clock probe при блокировке VPS ранее вернул `0` секунд расхождения. |
| Telegram | Пользователь исключил компонент из текущей работы | Не проверялся и не изменялся в рамках этой приёмки; другой агент отвечает за него. |

Контрольный поиск по committed `platform/openwrt/` и `scripts/openwrt/` по адресам старых VPS, `nip.io` и `vps-relay` (исключая TG-файлы) нашёл одно совпадение: `platform/openwrt/warp.sh` отклоняет сохранённые legacy URL как необязательный proxy. Общие Keenetic transport и Insta-IP relay остаются в shared-файлах, но OpenWrt entry points направляют загрузки через `Z2K_FETCH_VPS_OUT=1`, а Insta-IP использует отдельный прямой DoH адаптер.

### Сводная матрица приёмки

| Область | Независимый путь OpenWrt | Подтверждение | Статус и ограничение |
|---|---|---|---|
| Подписанный bootstrap manifest | Прямой GitHub; при отказе — jsDelivr; закреплённый ключ и Ed25519 подпись обязательны | QEMU: production `fetch_verified_manifest()` выбрал CDN при отказе raw origin и блокировке обоих VPS IP; ключ, подпись, `p-86.18`, `seq=142` проверены | **Частично**: helper подтверждён, полный bootstrap и установка не проходили |
| Release payload | Прямой GitHub и проверяемая цепочка HTTPS mirrors; размер и SHA берутся только из подписанного manifest | QEMU: прямой запрос x86/64 asset без proxy-переменных и с точечной блокировкой VPS дал размер/SHA из manifest; production `download_verified_artifact()` принял x86/64 через mirror; все 7 опубликованных архитектурных архивов совпали по размеру/SHA и прошли `gzip -t` | **Частично**: direct и mirror доставка подтверждены, транзакционная установка/обновление не проверены; runtime QEMU только x86/64 |
| `z2k_fetch`, списки и geosite | OpenWrt задаёт `Z2K_FETCH_VPS_OUT=1`; origin и зеркала используются без VPS layer | `fetch_vps_layer_budget` и `geosite_vps_independence`; QEMU `show ru-blocked.txt` получил тело через mirror при блокировке VPS и отказе origin | **Частично**: подтверждены transport и один live list path, полный refresh всех списков в расписании не проверен |
| Cron и updater entry points | OpenWrt env-adapter отключает legacy VPS layer; cron для WARP games задаёт тот же режим | `test_ow_schedule` `40/40`, update entry `12/12`, WebPanel transport call-path и post-install seed suites | **Частично**: entry points проверены; cron-driven обновление установленного продукта в QEMU не запускалось |
| Insta-IP refresh | Локальные DoH источники, TTL/provenance cache, фильтрация Meta CIDR, HTTPS/SNI probe и атомарный dnsmasq adapter | QEMU full refresh при блокировке VPS: 11 доменов обновлены, user record сохранён, старый A удалён; boundary/runtime/no-op rollback `35/35`, `26/26`, `11/11` | **Частично**: один домен сохранил предыдущие записи из-за непрошедших HTTPS probes; частичный отказ безопасно переносится, полного offline-install lifecycle нет |
| LAN DNS | Локальный dnsmasq и системная upstream DNS конфигурация; VPS не нужен | QEMU: пользовательская запись пережила refresh, DNS восстановился после dnsmasq restart; при полном DoH outage используется допустимый кэш | **Сетевой E2E пройден** для проверенных сценариев; недоступность всей сети закономерно исключает новые внешние ответы |
| Диагностика и WebPanel | OpenWrt clock probe использует прямой HTTPS Date; WebPanel и list refresh наследуют OpenWrt fetch env | QEMU clock skew `0` секунд при блокировке VPS; suites diagnostics `26/26`, source order `2/2`, WebPanel unit `37/37` | **Частично**: transport подтверждён; публичные DNS/API и все WebPanel действия не проверялись end-to-end |
| WARP | Отдельная опциональная функция; OpenWrt adapter не подставляет свой VPS, WARP не используется для базовых функций | Static/parity `92/92`, `39/39`; исходники OpenWrt отклоняют legacy VPS proxy URL | **Опциональная функция, live не принята**: регистрация, лицензирование и Cloudflare tunnel в QEMU не проверялись; WARP не нужен основному режиму |
| RuTracker RT proxy | Независимый сторонний pool с прямым fallback; не использует собственную VPS | QEMU x86/64: полный HTTP ответ Cloudflare и `rutracker.org` при недоступном pool и блокировке VPS; RT proxy suites `171/171` | **Условно подтверждён**: если провайдер блокирует прямой сайт и сторонний pool недоступен, никакой маршрут без внешнего egress не гарантируется |
| Telegram | Отдельный Rust-путь в работе другого агента | В рамках этой задачи Telegram код, тесты и runtime не проверялись | **Вне текущей проверки** по прямому указанию пользователя |
| Чистая установка, обновление, rollback и удаление | Существующий signed `install_release(tag)` transaction, настройки и rollback сохранены | Bootstrap/update/recovery и release safety suites; один QEMU install attempt откатился до приёмки, когда общий start попытался задеть Telegram | **Не принято**: полный продуктовый lifecycle отсутствует как доказательство; общий CI также не запускался |
| Архитектуры | Штатный OpenWrt runtime и дополнительные `z2k-warpd`/`z2k-rt-proxy` проверены отдельно по 7 целям | На `9e7bdc37`: OpenWrt arch `26/26`, pinned runtime artifact `29/29` (SHA совпал), WARP archmap `6/6`; на `7b7b00bd`: `nfqws2 --version` + профильный `--dry-run` под QEMU user-mode `14/14`; ранее 7 payload hashes/gzip и ABI двух дополнительных ELF `14/14` | **Частично**: QEMU/live runtime выполнен только x86/64; остальные ABI прошли CLI/parser smoke, но не полный OpenWrt runtime или сетевую NFQUEUE проверку |

**Готовность к слиянию: не готово.** Главные незакрытые проверки — чистый install, обновление, полный rollback и uninstall в QEMU без запуска Telegram; live WARP control/data plane; runtime на остальных архитектурах. Локальные suites не являются GitHub CI; ветка не публиковалась.

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

Извлечены только 20-байтовые ELF-заголовки, без запуска файлов. `z2k-rt-proxy` и `z2k-warpd` отдельно совпали с целевыми ELF ABI на всех семи архитектурах (14/14): arm64 — ELF64 LE/EM_AARCH64, arm — ELF32 LE/EM_ARM, x86_64 — ELF64 LE/EM_X86_64, x86 — ELF32 LE/EM_386, mips — ELF32 BE/EM_MIPS, mipsel — ELF32 LE/EM_MIPS, riscv64 — ELF64 LE/EM_RISCV. Архивная проверка подтверждает транспорт и ELF ABI этих двух артефактов, но не их runtime или сетевую работу. Счётчики старых VPS-IP были нулевыми; после теста таблица удалена, временные файлы удалены, осталась штатная `inet fw4`.

Дополнительный архитектурный smoke: `z2k-detect -h` и `z2k-warpd version` исполнились под WSL QEMU user-mode/binfmt на каждой из 7 OpenWrt-архитектур — `14/14`. Команды не выполняли сетевые действия и не регистрировали WARP. Это подтверждает запуск безопасной CLI-точки входа под соответствующим ABI, но не полный runtime на целевой OpenWrt системе.

На feature-ветке build matrix и `rt-proxy/Makefile` расширены до всех 7 OpenWrt GOARCH: добавлены `386 → x86` и `riscv64`. Закреплённый Go 1.25.13 скачан во временный каталог с go.dev и прошёл SHA-256-проверку; `make all` собрал все 7 целей и alias `mipsle`. Unit suite прошёл нативно на amd64 и под QEMU user-mode на остальных 6 архитектурах; CLI `-h` прошёл `7/7`. Статическая связка проверена: `scripts/openwrt/build-release.sh` уже перечисляет 7 пар GOARCH/runtime-архитектура, а `scripts/openwrt/stage-rootfs.sh` упаковывает каждый `linux-*` RT-бинарник. Реальный внешний proxy-pool E2E для каждой архитектуры не проверялся; общий release builder не запускался; собранные файлы оставлены в `/tmp`, релизные артефакты и `UPDATES.json` не менялись.

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

## Повторная проверка WARP/OpenWrt границы

12 октября 2026 года статически прослежен вызов WARP из WebPanel: `api.sh` загружает `webpanel/cgi/platform.sh` до и после общего `actions.sh`; OpenWrt-ветка задаёт `WARP_SCRIPT=$Z2K_ROOT/platform/openwrt/warp.sh`, поэтому WARP install/register/license и list refresh используют OpenWrt-адаптер. `platform/openwrt/release.sh`, cron и `platform/openwrt/list-refresh.sh` также передают `Z2K_WARP_IPSET_SCRIPT` на этот адаптер. `scripts/openwrt/stage-rootfs.sh` устанавливает OpenWrt init-службу из `platform/openwrt/files/etc/init.d/z2k`; legacy `files/init.d/S51z2k-warp` в OpenWrt rootfs не копируется.

OpenWrt-адаптер не задаёт proxy по умолчанию и отбрасывает сохранённые адреса старого VPS; использоваться может только явно заданный оператором внешний proxy, не совпадающий со старым endpoint. Регистрация и лицензия WARP идут к Cloudflare напрямую, если такой proxy не настроен. Поэтому опциональная функция WARP требует доступности Cloudflare API или отдельного пользовательского proxy; при недоступности API регистрация/лицензия не сработает. Это ограничение отдельной функции, а не основной работы z2kOW: WARP по умолчанию выключен, основной OpenWrt transport имеет прямые/зеркальные пути, и WARP не используется как резерв VPS. Legacy VPS-default в общем Keenetic `files/z2k-warp.sh` и Entware `files/init.d/S51z2k-warp` сохранены и не являются OpenWrt entry points.

Повтор локальной проверки 12 октября: `test_ow_warp_static.sh` прошёл `92/92`. `test_ow_warp_parity.sh` не засчитан: текущая Windows shell-среда не содержит `chmod` и `sleep`, поэтому заглушки теста не получили ожидаемые права, а ожидание async-state не отработало; suite был прерван. Это ограничение test host, не результат проверки OpenWrt и не основание для изменения адаптера. Suite не обращается к Telegram; продуктовые файлы и release metadata не менялись.
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

Полный refresh на том же QEMU: штатные `z2k-insta-ip-refresh.sh` и OpenWrt adapter, настоящие `curl`/`jsonfilter`, прямые DNS ответы и HTTPS candidate probes. При блокировке обоих VPS-IP обновлены все 12 управляемых hostname-ов за 9 секунд; кэш содержит 36 candidate rows, вызван один reload. Временный hosts-файл заменил старые адреса и сохранил комментарий и сторонний `user.example`. UCI и dnsmasq init были направлены в заглушки, чтобы не менять системный `/etc/config/dhcp`; после теста его SHA совпал, nft вернулась к `inet fw4`, пакеты не устанавливались, fixture удалён. Проверен полный refresh workflow с сетевыми обращениями и кандидатами, но не реальное применение через системный dnsmasq.

Потребитель addnhosts проверен отдельно на том же временном hosts-файле: запущен второй `dnsmasq 2.93`, ограниченный `127.0.0.2:53`, с `--addn-hosts` на результат refresh. Реальные A-запросы через BusyBox `nslookup` вернули для `instagram.com` адрес `157.240.205.174`, а для стороннего `user.example` — `192.0.2.250`. Тестовый процесс завершён; штатные dnsmasq PID/listeners остались прежними, на `127.0.0.2:53` больше никто не слушает, nft и `/etc/config/dhcp` совпадают с baseline.

## QEMU geosite mirror E2E

Локальное воспроизведение показало, что документированная команда `show` использовала только origin. Исправление перевело её на общий `fetch_to_tmp` с временным ETag-каталогом: stdout по-прежнему содержит только список, production-файлы не меняются. Тест `test_geosite_vps_independence.sh` теперь проверяет отказ origin, переход через первое зеркало с HTTP 503 ко второму и возврат тела без `--resolve`.

В OpenWrt 25.12.5 x86/64 обновлённый `files/z2k-geosite.sh` запущен из временного каталога. `github.com` был временно направлен на loopback, nft блокировал старые VPS-IP, а `Z2K_FETCH_VPS_OUT=1` отключал Layer 0. Штатная команда `show ru-blocked.txt` получила через `ghproxy.net` HTTP 200, `1 731 646` байт, SHA-256 `8b8d8d1ce37edbdc550bbb73f473f072b15432bf42b1fac5b35f95a603fec77d`; счётчики блокировки обоих VPS-IP остались `0`. После прогона `/etc/hosts` восстановлен, временная nft-таблица удалена, осталась только `inet fw4`, временный payload и HTTP-сервер доставки удалены/остановлены. Полный `fetch_all` и применение списков в продуктовый каталог в этом сценарии не запускались.

## Повторная классификация legacy VPS ссылок в non-TG OpenWrt

- Общие `Z2K_VPS_GH_IP` defaults сохранены для Keenetic; `platform/openwrt/env.sh` экспортирует `Z2K_FETCH_VPS_OUT=1`, а OpenWrt cron entry для WARP game lists задаёт его явно. Fetch и geosite fallback выше проверены с отключённым Layer 0.
- В `lib/install.sh` legacy relay pin/unpin операции окружены проверкой `command -v ndmc`; это Keenetic-ветки, на OpenWrt без `ndmc` они не выполняются.
- `files/z2k-insta-ip-refresh.sh` сохраняет HMAC relay для Keenetic, но при `Z2K_PLATFORM=openwrt` выбирает локальный DoH и dnsmasq adapter; live refresh при заблокированных VPS-IP описан выше.
- `platform/openwrt/warp.sh` начинает регистрацию напрямую. Сохраненный `Z2K_WARP_VPS_PROXY` не обязателен, а два старых VPS IP отклоняются фильтром. `test_ow_warp_parity.sh` повторно прошёл `39/39`; этот тест не подтверждает доступность регистрации WARP у провайдера.

## QEMU verified downloader: отказ и восстановление

В OpenWrt 25.12.5 x86/64 отдельно вызвана только production-функция `download_verified_artifact` из `scripts/openwrt/install.sh`; installer не запускался. Для контролируемого отказа GitHub origin и два штатных HTTPS mirror временно направлены на loopback, старые VPS-IP блокировались отдельной nft output-таблицей, custom mirror был выключен. Helper вернул ошибку, не оставил файл назначения или `.download` временный файл. Затем включён локальный fixture mirror и повторён тот же запрос: helper принял только ожидаемые `26` байт с SHA-256 `406a2fd352e723f10cb93620be9b301e29b1e8e6d2ec2982aedc2f82411ca2e9`. Счётчики старых VPS-IP — `0`. После теста `/etc/hosts` восстановлен, временная nft-таблица удалена, осталась только `inet fw4`, локальный сервер остановлен, тестовые файлы удалены. Это проверяет fail-closed и восстановление транспортного helper на fixture-артефакте, но не является скачиванием или установкой product release.

## QEMU диагностика и состав WARP адаптеров

`scripts/openwrt/stage-rootfs.sh` включает `files/z2k-diag.sh`. OpenWrt-ветка `clock_skew_vs_relay` получает `Date` с прямого HTTPS Cloudflare/Google, а не с nip.io relay; `test_diag_clock_skew_vps_free.sh` прошёл `7/7`. В OpenWrt 25.12.5 x86/64 запущена только эта функция из временного файла при nft-блокировке старых VPS-IP: получено расхождение `0`, счётчики VPS — `0`. После проверки осталась штатная `inet fw4`, тестовые файлы и сервер удалены.

Legacy `files/z2k-warp.sh` с VPS proxy default не включён в OpenWrt rootfs builder и не вызывается OpenWrt adapter; для платформы используется `platform/openwrt/warp.sh`. VPS default общего скрипта относится к Keenetic-пути, а OpenWrt adapter запускает регистрацию напрямую и отклоняет оба legacy VPS endpoint как proxy.

## Повторный прямой HTTPS E2E в чистом QEMU

12 октября 2026 года повторно проверена VM `z2k-vps-free-test` через serial-консоль: OpenWrt 25.12.5 x86/64, без установленного продукта (`install_release` и `/usr/lib/z2k` отсутствуют). Временное nft output-правило отклоняло TCP/443 только к `213.176.74.63` и `79.137.196.7`. Прямой `curl --proxy '' --noproxy '*' https://api.github.com/zen` вернул HTTP 200 и 31 байт; оба счётчика старых VPS endpoint равны 0. В госте отсутствуют `/dev/net/tun` и HTTP(S)/ALL proxy-переменные. После проверки временная таблица удалена; осталась только штатная `inet fw4`. Это подтверждает прямой HTTPS из чистого OpenWrt при недоступности старых VPS, но не заменяет проверку полного product install/update/rollback/uninstall.

Повторный non-TG DNS/HTTPS сценарий в той же чистой VM: при временной блокировке исходящего TCP/443 только к обоим VPS-IP локальный dnsmasq разрешил `api.github.com` в `140.82.114.5`; прямой DoH Cloudflare вернул HTTP 200 и A-запись `4.225.11.201` с TTL 4; прямой `https://api.github.com/zen` также вернул HTTP 200. Счётчики обоих VPS правил — `0`; в госте нет proxy-переменных и `/dev/net/tun`. Временная таблица удалена, осталась только `inet fw4`. Это подтверждает доступность конкретных DNS/HTTPS путей в этом запуске, а не их доступность при блокировке самих DNS/CDN провайдеров.

## Повторные non-TG регрессии на `5ea94222`

После QEMU E2E повторно прошли изолированные suites:

- Fetch/geosite: `test_fetch_vps_layer_budget` `48/48`, `test_geosite_vps_independence` `2/2`, `test_geosite_cache_survives_reinstall` `41/41`, `test_geosite_apply_guard` `17/17`, `test_geosite_inject` `19/19`, `test_geosite_rkn_asset` `9/9` — всего `136/136`.
- Bootstrap/updater: `test_ow_bootstrap_download_validation` `8/8`, `test_ow_bootstrap_manifest_mirrors` `7/7`, `test_ow_update_entry` `12/12`, `test_ow_updater_failsafe` `5/5`, `test_ow_updater_state` `7/7`, `test_ow_recovery` `13/13` — `52/52`.
- Insta-IP: `test_ow_insta_boundary` `35/35`, `test_ow_insta_runtime` `24/24`, `test_ow_insta_refresh_noop_backup` `11/11` — `70/70`; `test_diag_clock_skew_vps_free` — `7/7`.
- WARP: `test_ow_warp_static` `92/92`, `test_ow_warp_parity` `39/39`, `test_ow_warp_archmap` `6/6` — `137/137`.
- Release/offload: `test_ow_release_signing.py` `12/12`, `test_ow_immutable_release_check.py` `6/6`, `test_ow_offload_benchmark` `142/142` — `160/160`.
- Локальные lifecycle/recovery/storage: `test_ow_lifecycle` `27/27`, `test_ow_boot_recovery` `28/28`, `test_ow_storage_persistence` `17/17`, `test_ow_atomic` `8/8`, `test_ow_preserve` `10/10` — `90/90`.

Итого `652/652`. Suites Telegram, изменённый другим агентом `platform/openwrt/release.sh`, installer и unified-release не запускались. Эти проверки не являются полным продуктовым install/update/rollback/uninstall в QEMU.

## Insta-IP: сохранение кэша при частичном отказе DoH

Воспроизведение выявило потерю последней записи кэша: если один домен списка обновился, а все три DoH endpoint отказали для другого, устаревший кандидат ещё возвращался в текущем результате, но новый общий файл кэша уже не сохранял запись отказавшего домена. Регрессия сначала завершилась `25/26` из-за отсутствующей строки кэша. Исправление сохраняет записи в пределах TTL и stale-grace для имён без свежего ответа; ошибка записи временного результата завершает resolver до замены предыдущего кэша.

Проверки после исправления: `test_ow_insta_runtime.sh` `26/26`, `test_ow_insta_boundary.sh` `35/35`, `test_ow_insta_refresh_noop_backup.sh` `11/11`, `sh -n` для адаптера и refresh script.

В OpenWrt 25.12.5 x86/64 QEMU временный адаптер запущен напрямую из `/tmp`. Для `instagram.com` curl обращался к Cloudflare, Google Public DNS и AdGuard DoH и получил `31.13.72.174`, `157.240.205.174`, `157.240.26.174`; тестовая обёртка curl отказала только для `www.instagram.com`, где использовался кэшированный адрес с expiry `900` при test time `1000` и grace `86400`. Устаревший кандидат вернулся и остался в кэш-файле после успешного обновления первого домена. nft блокировал только старые VPS-IP; счётчики — `0`. `/dev/net/tun` и proxy-переменных нет. Временные скрипты/правило удалены, host transfer server остановлен; в госте осталась только `inet fw4`. Это проверка resolver при частичном DNS отказе, не полного refresh и системного dnsmasq reload.

## Insta-IP: применение заменённых записей в dnsmasq

Live-проверка штатного полного refresh выявила проблему, которую не обнаруживали stub-тесты: после атомарной замены addnhosts и `dnsmasq reload` локальный DNS продолжал возвращать старый тестовый адрес `203.0.113.9` для `instagram.com`. Отдельный минимальный QEMU сценарий подтвердил, что при замене `192.0.2.1` на `192.0.2.2` через `reload` старый адрес оставался в ответе. Перезапуск dnsmasq возвращал только новый адрес. Вариант с каталогом в `addnhosts` привёл к падению dnsmasq с general protection fault на тестовом OpenWrt, поэтому он отклонён.

OpenWrt adapter теперь выполняет штатный `restart` после изменения UCI/hosts-файла и при удалении принадлежащей ему записи. После изменения stub-тест сначала упал на ожидании `restart`; после исправления прошли `test_ow_insta_runtime.sh` `26/26`, `test_ow_insta_boundary.sh` `35/35`, `test_ow_insta_refresh_noop_backup.sh` `11/11`.

Повторный полный refresh в OpenWrt 25.12.5 x86/64 QEMU прошёл с nft-блокировкой TCP/443 только к `213.176.74.63` и `79.137.196.7`: обновлены 11 доменов, один домен без прошедшей HTTPS-пробы оставил прежние записи. Фактические запросы к локальному dnsmasq вернули пользовательский `user.example → 192.0.2.250`, новые адреса `graph.instagram.com` и `instagram.com`; устаревший `203.0.113.9` исчез. Оба счётчика блокировки VPS равны нулю. В конце `/etc/config/dhcp` восстановлен побайтно (MD5 `ce584f6a2028294e0b5989ec222a36e1` до и после), временная nft-таблица удалена, осталась только `inet fw4`; гостевая VM перезагружена, чтобы удалить временные procd mounts. Перезапуск dnsmasq нужен для удаления старых статических A-записей; длительность паузы на реальном роутере не измерялась. Это проверка прямого DNS/refresh в чистой VM, не install/update/rollback/uninstall продукта.

Дополнительный замер на чистой VM: `dnsmasq restart` занял `3,24 с`; непосредственный запрос к локальному DNS получил `connection refused`, через 2 секунды локальный dnsmasq разрешил `api.github.com`. Прямой `curl --proxy '' --noproxy '*' https://api.github.com/zen` завершился HTTP 200, два VPS-block counter — 0, после cleanup осталась `inet fw4`. Правило затрагивало только исходящий TCP/443 к двум VPS IP и не матчило входящий SSH. Dropbear работал до и после, но SSH banner через QEMU host-forward получить не удалось, поэтому SSH E2E не засчитан.

## Повторные targeted non-TG регрессии на `f761598d`

12 октября 2026 года отдельно повторены 15 non-TG suites: fetch/geosite `136/136`, clock diagnostics `7/7`, bootstrap download/manifest mirrors `15/15`, Insta-IP boundary/runtime/no-op rollback `72/72`, WARP static/parity/archmap `137/137`. Итого `367/367`. Telegram, scheduler, installer, shared release и unified-release tests исключены из-за отдельной незакоммиченной работы агента над Telegram.

## Повторные bootstrap/update/recovery проверки на текущем HEAD

12 октября 2026 года на `c01256fe` повторно запущены только целевые локальные suites: bootstrap download validation `8/8`, bootstrap manifest mirrors `7/7`, update entry `12/12`, updater failsafe `5/5`, updater state `7/7`, recovery `13/13`. Итого `52/52`, ошибок нет. Это unit/regression проверки скриптов и recovery-состояний; они не подтверждают полный install, обновление подписанного продукта, rollback и uninstall в QEMU. Общий release-процесс не запускался.

## Повторные RT proxy регрессии на текущем HEAD

12 октября 2026 года на `164df65a` повторно запущены изолированные suites RuTracker proxy: static `70/70`, DNS `41/41`, firewall `43/43`, SO_MARK `17/17`. Итого `171/171`, ошибок нет. Это локальные проверки адаптера и сетевой политики; они не заменяют архитектурный QEMU E2E и проверку доступности стороннего proxy pool.

## Runtime artifact и OpenWrt archmap

12 октября 2026 года на `18be002d` `test_ow_runtime_artifact.sh` прошёл `29/29` на архиве, загруженном по URL из `platform/openwrt/runtime-pin`: размер `4 339 405` байт, SHA-256 `02eec373b093083b426c27191bb6af260ac51e4e2739c51270270a351d2a1a16`. Suite подтвердил наличие `nfqws2`, `ip2net` и `mdig` для семи OpenWrt архитектур и запуск закреплённого x86/64 движка. `test_ow_warp_archmap.sh` прошёл `6/6`. Архив удалён после теста; продуктовый release builder не запускался.

## Повторный QEMU direct HTTPS при блокировке VPS

12 октября 2026 года на чистой OpenWrt 25.12.5 x86/64 QEMU, на HEAD `525f3316`, временные nft output drop-правила затрагивали только TCP/443 к `213.176.74.63` и `79.137.196.7`. При отсутствии proxy-переменных и `/dev/net/tun` прямой запрос к `https://api.github.com/zen` завершился `HTTP 200`, TLS verify `0`, endpoint `140.82.113.6`. Счётчики обоих VPS-drop правил остались `0`; после проверки временная таблица удалена, осталась только штатная `inet fw4`. Это подтверждает прямой HTTPS маршрут при недоступном старом VPS, но не полный install/update/rollback продукта.

## DNS/DoH OpenWrt регрессии

12 октября 2026 года на `7df1e68a` повторно прошли `test_ow_doh.sh` `266/266`, `test_ow_dnsproxy.sh` `266/266`, `test_ow_dns_check.sh` `2/2` и `test_ow_dns_detect_path.sh` `5/5`. Итого `539/539`, ошибок нет. Suites проверяют локальное управление dnsproxy/DoH, сохранение существующих dnsmasq overrides и диагностику; они не заменяют проверку пользовательского трафика после полной установки.

## Env, geosite и list refresh регрессии

12 октября 2026 года на `56736f16` прошли `test_ow_env.sh` `34/34`, `test_ow_geosite_adapter.sh` `9/9` и `test_ow_list_refresh_adapter.sh` `9/9`. Итого `52/52`, ошибок нет. Проверена передача OpenWrt transport-настроек в общий код и адаптер обновления geosite/списков; это локальные suites, не полный сетевой update продукта.

## QEMU DNS recovery и HTTPS после dnsmasq restart при блокировке VPS

12 октября 2026 года в той же чистой OpenWrt 25.12.5 x86/64 QEMU временные output drop-правила блокировали только TCP/443 к `213.176.74.63` и `79.137.196.7`. После `/etc/init.d/dnsmasq restart` локальный DNS разрешил `api.github.com` с первой проверки; прямой `curl` к API завершился `HTTP 200`, TLS verify `0`, endpoint `140.82.113.5`. Оба block counter — `0`. Во время restart init-скрипт вывел `udhcpc: no lease`, но последующие DNS и HTTPS проверки прошли. Временная nft-таблица удалена, осталась только `inet fw4`.

## Lifecycle, restart и state persistence регрессии

12 октября 2026 года на `167ef750` прошли `test_ow_lifecycle.sh` `27/27`, `test_ow_restart.sh` `6/6` и `test_ow_state_persist.sh` `16/16`. Итого `49/49`, ошибок нет. Проверены OpenWrt procd start/stop rollback, общий updater restart hook и сохранение strategy state; общий release path не задействовался.

## Post-install WARP game seed transport

12 октября 2026 года аудит call path нашёл post-install background seed, который запускал `z2k-update-lists.sh warp-games` без `Z2K_FETCH_VPS_OUT=1`. Новый regression сначала упал `1/5` при очищенном окружении, подтверждая пропуск; OpenWrt release adapter теперь выставляет флаг только внутри seed subshell. После исправления прошли `test_ow_release_warp_seed.sh` `5/5`, `test_ow_warp_games_flow.sh` `4/4`, `test_ow_warp_manifest_env.sh` `5/5` и `test_ow_env.sh` `34/34` — итого `48/48`. Это закрывает post-install transport path; полный подписанный install/update/rollback всё ещё требует QEMU acceptance.

## Call-path аудит общего Insta-IP refresh

12 октября 2026 года подтверждено, что `platform/openwrt/diag.sh` и `list-refresh.sh` входят в общий updater с `Z2K_PLATFORM=openwrt`; `files/z2k-insta-ip-refresh.sh` тогда выбирает `platform/openwrt/insta-ip.sh` и прямые DoH резолверы. HMAC POST на старый `/resolve` остаётся только в ветке Keenetic. Повторные boundary/runtime/no-op rollback suites прошли `35/35`, `26/26` и `11/11` (итого `72/72`).

## WebPanel transport call path

12 октября 2026 года повторно прослежен update-manifest путь WebPanel: `api.sh` загружает `webpanel/cgi/platform.sh` до `actions.sh`, а platform seam подключает `platform/openwrt/env.sh`, экспортирующий `Z2K_FETCH_VPS_OUT=1`; вложенный `z2k_fetch` наследует этот режим. `test_ow_source_order.sh` прошёл `2/2`, `test_ow_webpanel_unit.sh` — `37/37`. Вместе с list-refresh wrapper, WARP games cron и исправленным post-install seed закрыты обнаруженные OpenWrt caller-ы общего fetch transport.

## WARP optional-function regressions

12 октября 2026 года на `b0228261` повторно прошли `test_ow_warp_static.sh` `92/92` и `test_ow_warp_parity.sh` `39/39` — `131/131`. Проверки подтверждают статическую конфигурацию и parity WARP-путей; сами по себе они не доказывают полноценный продуктовый VPS-free install/update lifecycle. Telegram не затрагивался.

## Дополнительные WARP lifecycle и функциональные регрессии

12 октября 2026 года на `fe104a97` прошли `test_ow_warp_lifecycle.sh` `440/440`, `test_ow_warp_functional.sh` `160/160`, `test_ow_warp_domain_paths.sh` `9/9`, `test_ow_warp_games_flow.sh` `4/4` и `test_ow_warp_manifest_env.sh` `5/5` — `618/618`. Вместе с повторными static/parity проверками выше это `749/749` WARP assertions. Suites локальные; они подтверждают адаптер, lifecycle, routing и список игр, но не требуют WARP для основного VPS-free режима и не являются live acceptance внешней инфраструктуры.

## Прерванная QEMU-попытка release lifecycle

12 октября 2026 года предпринята установка в чистой OpenWrt 25.12.5 x86/64 QEMU через `scripts/openwrt/install.sh` и реальный `install_release`, с локально подписанным временным manifest для `p-86.18`, `seq=142`, и точечными nft drop только на TCP/443 к `213.176.74.63` и `79.137.196.7`. Для исключения сборки/проверки Telegram test rootfs содержал failing stub; общий `z2k-start` всё равно попытался запустить TG, и установщик отменил операцию. Получен `Z2KOW_ROLLBACK=complete`, затем проверены отсутствие installed-release и `/usr/lib/z2k`; счётчики VPS-drop оставались нулевыми. Запуск не засчитывается как install acceptance, поскольку тест затронул TG. После rollback обнаруженная тестом `inet zapret2` удалена вручную; в госте осталась только исходная `inet fw4`. Сгенерированный `/etc/z2k` не удалялся, так как rollback сохраняет пользовательские данные. Полный install/update/rollback/uninstall QEMU цикл остаётся непроверенным.

## Изолированные release safety regression suites

12 октября 2026 года из чистого detached snapshot `7d789e73` прошли suites без ссылок на TG: archive validation `7/7`, immutable release ref `6/6`, Ed25519 manifest signing `19/19`, storage persistence/path safety `17/17` — всего `49/49`. Они проверяют валидацию архива, подписи и хранилища; live запуск служб и полный install/update/rollback/uninstall цикл не подтверждают.

## Изоляция OpenWrt geosite mirrors от Keenetic

12 октября 2026 года проверка общего `files/z2k-geosite.sh` выявила, что добавленные для OpenWrt HTTPS mirrors также вызывались на Keenetic, а `show` перестал использовать прежний прямой запрос. Новые Keenetic assertions сначала упали: при отказе direct/VPS выполнялись оба mirror-запроса, а `show` проходил через VPS и mirrors. В `656decc0` mirror fallback и новый `show` transport ограничены `Z2K_PLATFORM=openwrt`; Keenetic получил исходное поведение. После исправления прошли fetch/geosite suites: `test_fetch_vps_layer_budget` `48/48`, VPS independence `4/4`, cache reinstall `41/41`, apply guard `17/17`, inject `19/19`, RKN asset `9/9`, OpenWrt geosite adapter `9/9`, list refresh adapter `9/9` — `156/156`; `sh -n` успешен.

## Общий Insta-IP и diagnostics: проверка границ платформ

12 октября 2026 года на `dff5a191` прошли `test_insta_dns_opt_out` `9/9`, `test_insta_refresh_cert_mismatch` `13/13`, OpenWrt Insta-IP boundary/runtime/no-op rollback `35/35`, `26/26`, `11/11` — `94/94`. Общие Keenetic assertions проверяют старый `ndmc`/HMAC `/resolve` маршрут и пользовательский `Z2K_INSTA_DNS`; OpenWrt suites покрывают прямой DoH adapter, кэш и откат записей.

В тот же день `test_diag_clock_skew_vps_free.sh` прошёл `7/7`, включая прямой OpenWrt HTTPS и сохранение Keenetic relay path; `test_diag_agh_upstream.sh` — `19/19`. Итого diagnostics `26/26`. Telegram suites не запускались.

## Повторные WARP/bootstrap регрессии в Debian WSL

12 октября 2026 года после невалидного запуска parity-suite в урезанном Windows shell повторно запущены в Debian WSL suites `test_ow_warp_static.sh` `92/92`, `test_ow_warp_parity.sh` `39/39`, `test_ow_warp_lifecycle.sh` `440/440`, `test_ow_warp_functional.sh` `160/160`, `test_ow_bootstrap_download_validation.sh` `8/8` и `test_ow_bootstrap_manifest_mirrors.sh` `7/7` — итого `746/746`. Linux parity-run заменяет прежний незасчитанный Windows-run. Эти suites не обращаются к Telegram и не вызывают product release/start lifecycle.

## QEMU: signed manifest и независимая доставка release payload без VPS

12 октября 2026 года в работающей OpenWrt 25.12.5 x86/64 QEMU проверена сеть без proxy-переменных и без активного VPN/WARP-интерфейса. В госте не было `/usr/lib/z2k`; исходно присутствовала только nft-таблица `inet fw4`. Временная output-chain блокировала TCP/443 к старым VPS IP `213.176.74.63`, `79.137.196.7` и всем четырём IPv4 `raw.githubusercontent.com` (`185.199.108.133`, `.109.133`, `.110.133`, `.111.133`). Прямой raw-origin запрос завершился timeout (curl 28). Через jsDelivr `cdn.jsdelivr.net/gh/t0fox/z2kOW@main` получены manifest, подпись и ключ, каждый HTTP 200 с endpoint `104.17.207.5`; `jsonfilter` показал `p-86.18`, `seq=142`, key ID `916b1459a03961d66af48ddb2165afbed3c0d7445f75c8b7c95adbb5fc044bae`. SHA-256 manifest — `b2e3c96b04d1a36c23e22942e2878a42810a98266143b63175db4eeeee86759e`, подписи — `aedb42d21959727a46f790bd1d2aa5d75b91cd6d1b828d837336c24a16e64cca`, ключа — `3afa2ad6bed59d5878156f891522b89df817cf6b3b412f4acb03d6f4164e80f3`; `openssl pkeyutl -verify -rawin` завершился `Signature Verified Successfully`. VPS drop-counters — 0; каждый raw-origin адрес получил 3 drop-пакета.

Затем тот же подписанный manifest указал x86/64 payload `13 707 778` байт, SHA-256 `f041dc6accf362793ec2731fe661bfa7b584da408d40b68c6fd39be9cc79e1d4`. Заблокированы старые VPS-IP и четыре IPv4 `release-assets.githubusercontent.com`. Прямой GitHub release URL вернул редирект HTTP 302, после чего transfer к release-assets завершился timeout; зеркало `ghproxy.net` отдало HTTP 200 с endpoint `5.135.5.132`, а `gh-proxy.com` — HTTP 200 с endpoint `172.64.154.60`. Оба файла совпали по размеру и SHA-256 с подписанным manifest, оба прошли `gzip -t`. Примечание: DNS GitHub в этом запросе вернул `140.82.113.3`, тогда как отдельное правило было адресовано `140.82.112.3`; origin успел ответить 302, отказ произошёл на заблокированном release-assets endpoint. Старые VPS counters — 0, release-assets rules получили по 3 drop-пакета.

Тест не распаковывал и не устанавливал продукт, не менял `/etc/z2k`, пакеты, boot или release state и не запускал сервисы. После прогона удалены тестовые nft-таблица и архивы; в госте снова только `inet fw4`. Это подтверждает подписанный mirror-bootstrap и обе независимые доставки x86/64 payload при недоступности старого VPS и release-assets endpoint; install/update/rollback/uninstall acceptance остаётся отдельным незавершённым этапом.

В той же QEMU повторно вызвана production-функция `download_verified_artifact()` без остального installer-кода: извлечена ровно функция из feature `scripts/openwrt/install.sh`, остальные действия installer не исполнялись. При блокировке двух старых VPS IP и четырёх release-assets IP прямой GitHub release source вернул HTTP 302, затем transfer к заблокированному release-assets завершился curl 28 через 10,001 с; функция перешла к настроенному mirror chain и приняла x86/64 архив только после совпадения подписанных `size_bytes=13707778` и SHA-256 `f041dc6accf362793ec2731fe661bfa7b584da408d40b68c6fd39be9cc79e1d4`. Файл прошёл `gzip -t`, выведен `PRODUCTION_DOWNLOADER_ACCEPTED`. Счётчики старых VPS — 0, каждый release-assets IP получил 7 drop-пакетов. Trap удалил test function, архив и временную nft-таблицу; итоговый `nft list tables` показал только `inet fw4`. Сам installer, распаковка, подпись/запись installed-release, запуск компонентов, update и rollback в этом тесте не выполнялись.

Отдельно проверена прямая доставка самого asset из точного URL, прочитанного из `UPDATES.json` для `openwrt-42e4dfa791bf53314fecbc75919df50fa6739088/openwrt-rootfs-x86_64.tar.gz`. В чистой OpenWrt 25.12.5 x86/64 QEMU `env | grep -i proxy` не нашёл proxy-переменных; временная nft output-chain блокировала только TCP/443 к `213.176.74.63` и `79.137.196.7`. BusyBox `wget --no-proxy` скачал файл размером `13707778`; SHA-256 совпал с подписанным manifest: `f041dc6accf362793ec2731fe661bfa7b584da408d40b68c6fd39be9cc79e1d4`. Оба VPS counter — 0. Таблица и архив удалены, после проверки осталась только `inet fw4`. Это подтверждает прямую доставку x86/64 release asset без WARP и прокси в сети данного QEMU; другие сетевые регионы этим не покрыты.

Также в госте вызвана production-функция `fetch_verified_manifest()` из того же `install.sh` с её installer-кодом загрузки и `value()` parser. Для старого VPS оставлены точечные TCP/443 drop-правила; четыре raw-origin IP получили временный TCP reset, чтобы прямой `wget` быстро отказал. Функция переключилась на `https://cdn.jsdelivr.net/gh/t0fox/z2kOW@main/UPDATES.json`, закреплённый key ID совпал, подпись прошла внутри helper; итоговый manifest — `p-86.18`, `seq=142`, SHA-256 `b2e3c96b04d1a36c23e22942e2878a42810a98266143b63175db4eeeee86759e`, подписи — `aedb42d21959727a46f790bd1d2aa5d75b91cd6d1b828d837336c24a16e64cca`, ключа — `3afa2ad6bed59d5878156f891522b89df817cf6b3b412f4acb03d6f4164e80f3`. Выбранный `MANIFEST_URL` указывал на CDN. Старые VPS counters — 0; каждый raw-origin reject counter — 1. Временная таблица и файлы удалены, осталась только `inet fw4`. Installer целиком, запись installed-release и запуск служб не выполнялись.

## Повторные targeted non-TG регрессии на текущем HEAD

12 октября 2026 года на `1f11d3ee` повторно прошли bootstrap download validation `8/8`, bootstrap manifest mirrors `7/7`, fetch layer budget `48/48`, geosite VPS independence `4/4`, Insta-IP boundary/runtime/no-op rollback `35/35`, `26/26`, `11/11`, OpenWrt env `34/34`, WARP static/parity `92/92` и `39/39` — итого `304/304`. Suites не запускают Telegram, общий installer или release/start lifecycle. Это регрессии локальных transport/adapters; они не закрывают полную установку, обновление, rollback и удаление продукта.

## Повторная архитектурная проверка без Telegram

12 октября 2026 года на `9e7bdc37` прошли `test_ow_arch.sh` `26/26`, `test_ow_runtime_artifact.sh` `29/29` и `test_ow_warp_archmap.sh` `6/6` — `61/61`. Runtime archive перед тестом скачан по закреплённому URL; размер `4 339 405` байт и SHA-256 `02eec373b093083b426c27191bb6af260ac51e4e2739c51270270a351d2a1a16` совпали с `platform/openwrt/runtime-pin`. Архив проверил наличие `nfqws2`, `ip2net` и `mdig` по семи OpenWrt ABI, installer digest, версию движка и запуск dry-run под x86/64. Временный архив удалён. Suites не затрагивают Telegram; остальные архитектуры подтверждены структурой/ограниченными smoke, но не полным OpenWrt runtime.

## `nfqws2` runtime smoke по семи ABI

12 октября 2026 года из того же закреплённого runtime archive извлечены только `binaries/linux-*/nfqws2`. Все семь ELF статически связаны; под установленным в Debian QEMU user-mode/binfmt каждый запустил `--version` и `--dry-run --qnum=200 --filter-tcp=443 --filter-l7=tls`: `14/14`, версия `v1.0.5.2-z2k-r0`. Проверка не открывала NFQUEUE и не генерировала пользовательский сетевой трафик, поэтому это ABI/CLI smoke, а не полноценный OpenWrt runtime. Архив и извлечённые бинарники из `/tmp` удалены.
