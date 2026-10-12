# Журнал проверок независимости OpenWrt от VPS

Дата: 12 октября 2026 года. Ветка: `feat/openwrt-vps-free`.

**Исторический журнал:** здесь сохранены наблюдения с датами, ветками, коммитами и ограничениями. Большинство записей уже на русском; команды, названия тестов, статусы и вывод инструментов оставлены в исходном виде ради воспроизводимости. Этот документ не является актуальным интерфейсным или архитектурным контрактом.

После объединения направления VPS-free с `main` актуальные требования смотрите в [README](../README.md), [архитектуре](../ARCHITECTURE.md) и [контракте Telegram](openwrt-telegram-contract.md). Перечень проверок ниже не подтверждает автоматически весь релиз и работу на физическом роутере. Полная приёмка проекта ещё не пройдена.

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

## Отдельный исполняемый файл WARP

`build-matrix.tsv` задаёт для `z2k-warpd` девять GOARCH: `arm64`, `arm`, `amd64`, `386`, `mips`, `mipsle`, `mips64le`, `ppc64`, `riscv64` (10 имён tracked-файлов с совместимым alias). OpenWrt release builder использует отдельную production-матрицу из семи целей: `arm64`, `arm`, `amd64`, `386`, `mips`, `mipsle`, `riscv64`; `mips64le` не входит, так как pinned upstream runtime его не поддерживает.

Структурная сверка tracked артефактов по `build-matrix.tsv` проверила 34 записи для `z2k-detect`, `z2k-verify`, `rt-proxy` и `z2k-warpd`: ELF class, endian и machine совпали с GOARCH; у всех файлов отсутствует `PT_INTERP`. Это проверяет форматы имеющихся файлов, а не runtime всех архитектур.

В этой сессии закреплённый Go 1.25.13 прошёл SHA-256 проверку. `rt-proxy` unit suite прошёл; пять отдельных GOARCH пересобраны, их шесть tracked имён побайтно совпали. `z2k-warpd` OpenWrt unit suite прошёл; дополнительно проверена расширенная Makefile-матрица из девяти GOARCH и десяти имён, но её tracked бинарники отличаются от текущего source. OpenWrt release builder эти файлы не пакует: он компилирует оба бинарника из source при каждой сборке release.

Текущие исходники повторно собраны с production-флагами builder для всех семи целей `rt-proxy` и `z2k-warpd`; все 14 результатов прошли проверку ELF class/endian/machine и отсутствия `PT_INTERP`. Для WARP включены OpenWrt build tag и overlay, версия взята из текущего `UPDATES.json` (`p-86.18`), release metadata не менялись. Свежие amd64-бинарники временно доставлены в OpenWrt QEMU 25.12.5 по локальному NAT HTTP: `z2k-warpd version` вернул `z2k-warpd p-86.18`, а `z2k-rt-proxy --help` выполнился. После smoke-проверки временные файлы удалены, в nft осталась только штатная таблица `inet fw4`; постоянные настройки и пакеты не менялись. Runtime остальных архитектур не подтверждён.

В OpenWrt 25.12.5 x86/64 VM временно запущен собранный `amd64` бинарник с командой `version`; получен ответ `z2k-warpd dev`. Временный файл из `/tmp` удалён. Это smoke-проверка запуска на x86/64, не проверка регистрации в Cloudflare или работы туннеля.

## Отдельный исполняемый файл RT proxy

`rt-proxy` unit suite прошёл. В `build-matrix.tsv` перечислены пять GOARCH для `z2k-rt-proxy`: `arm64`, `arm`, `amd64`, `mips` (big-endian softfloat) и `mipsle` (little-endian softfloat); шестое имя файла — совместимый alias `mipsle`. Структурная проверка выше подтвердила ELF-заголовки и статичность всех перечисленных файлов. x86/64 бинарник выполнил `--help` в OpenWrt QEMU; E2E direct HTTP/HTTPS ранее прошёл на x86/64.

## Локальные наборы тестов

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

В предыдущем локальном прогоне `tests/openwrt/test_ow_bootstrap_engine.sh` завершился `33/35`: два сценария размера получали общий текст «не удалось скачать архив», поскольку новый downloader отвергал файл раньше пост-проверки. Диагностика исправлена; последующие GitHub CI Shell tests и OpenWrt acceptance shards прошли на `346226f4`.

`tests/openwrt/test_ow_warp_lifecycle.sh` ранее завершался `440/440`; повторный запуск на worktree тогда был остановлен до результата из-за общей TG fixture. В актуальном CI на `346226f4` полный набор OpenWrt acceptance прошёл во всех четырёх shards.

## Границы этих доказательств

- QEMU проверки OpenWrt выполнены только на x86/64. `z2k-warpd` и `z2k-rt-proxy` собраны на всех семи targets; runtime на остальных архитектурах не подтверждён.
- Полный lifecycle продукта в OpenWrt 25.12.5 x86/64 QEMU пройден 12 октября на локальном тестовом payload: clean install, update, deliberate rollback после отказа старта службы, reinstall, reboot/autostart, WebPanel uninstall, CLI uninstall и повторное удаление. Пользовательские UCI и WARP-настройки сохранились; счётчики заблокированных старых VPS endpoint — 0. Тест подтверждает только x86/64; он не подтверждает вход в Telegram и загрузку медиа.
- GitHub CI для `346226f4` завершился успешно: [run 38238233556](https://github.com/t0fox/z2kOW/actions/runs/38238233556). Это CI на feature-ветке, не production release.
- Telegram включён в работу: Go MTProxy/VPS реализация удалена; новые архитектурные rootfs архивы содержат Rust `tg-ws-proxy` только для ARM64/x86_64. QEMU подтвердил прозрачный TCP/5222 → Rust → WSS → Telegram DC запрос и валидный `resPQ`; старые VPS endpoint были заблокированы, их счётчики равны нулю. Реальная сессия приложения на телефоне, сообщения и медиа ещё не проверены.
- Rootfs staging и архитектурные архивы не содержат старого имени. Универсальный fallback временно добавляет относительную ссылку `tg-mtproxy-client -> z2k-rt-proxy`: неизменяемый updater p-86.17 требует исполняемый путь с этим именем и не запускает его. При первом старте OpenWrt TG адаптер удаляет только эту ссылку после остановки прежнего процесса; чужой файл или ссылку с иной целью он не трогает. Так в установленной системе не остаётся Go Telegram-клиента. Локальный переход p-86.17 → текущий p-86.18 candidate прошёл; CI теперь запускает переход на текущем candidate вместо исторического r-86.5.
- WARP остаётся отдельной опциональной функцией. В `ca0371ee` удалён встроенный VPS fallback из OpenWrt-адаптера и отфильтрованы legacy URL старого VPS; явно заданный пользовательский non-VPS proxy остаётся опциональным. Статические проверки прошли `92/92` и parity — `39/39`; регистрация, лицензирование и туннель Cloudflare в QEMU не проверялись. Для самой функции WARP нужен внешний маршрут к Cloudflare, и она не заменяет VPS-функции.
- Наличие нескольких внешних DoH/CDN endpoints снижает зависимость от одного провайдера, но не обеспечивает работу при полном отсутствии Интернет-доступа.

## Карта OpenWrt VPS-зависимостей

| Функция | Найденная зависимость | Реализация/статус OpenWrt |
|---|---|---|
| Bootstrap | GitHub release metadata и payload | Прямой HTTPS, независимый jsDelivr для пары metadata/key, зеркала для payload; подпись и SHA/размер остаются обязательными. Размер и SHA-ошибки различаются в диагностике; узкий тест загрузчика пройден. Полный bootstrap на устройстве не проверен. |
| Обновление продукта | GitHub release, `UPDATES.json`, `install_release(tag)` | Существующая транзакция/подпись и rollback сохранены; прямой путь и независимые зеркала. Локальный p-86.17 → p-86.18 переход прошёл на текущем generic candidate, включая отказ на tmpfs, успешную установку, rollback и следующее обновление; полный QEMU lifecycle именно этого candidate ещё не повторён. |
| Планировщик и cron | Суточные задачи запускают обновление, списки и WARP game list | `update.sh` и `list-refresh.sh` передают общий код через `platform/openwrt/env.sh`, где `Z2K_FETCH_VPS_OUT=1`; отдельная cron-строка `warp-games` задаёт тот же флаг явно. Проверки `test_ow_schedule.sh` (`40/40`), `test_ow_update_entry.sh` (`12/12`) и QEMU-загрузка подтверждают конфигурацию/точки входа, но полный cron-driven install/update в QEMU не выполнялся. |
| `z2k_fetch` и списки | Исторический VPS `--resolve` в shared transport | OpenWrt экспортирует `Z2K_FETCH_VPS_OUT=1`; расписание для warp-games задаёт его явно. В geosite ранее оставалась отдельная копия Layer 0 — теперь она уважает флаг и после origin пробует HTTPS зеркала. Geosite подтверждён live с заблокированным origin. |
| Insta-IP refresh | Исторически OpenWrt-вариант вызывал VPS `/resolve`; Keenetic использует этот HMAC-механизм и дальше. | OpenWrt использует прямой DoH Cloudflare, Google и AdGuard, TTL/provenance-кэш, stale grace, фильтр Meta-диапазонов и HTTPS probe. Runtime `26/26`, boundary `35/35`, no-op/rollback `11/11`; полный QEMU refresh с реальным UCI/dnsmasq обновил 11 из 12 hostname-ов при блокировке VPS-IP, сохранил пользовательскую запись и удалил прежний A-адрес. Один hostname оставил прежние записи, так как HTTPS-пробы кандидатов не прошли. Keenetic HMAC path сохранён. |
| DNS LAN | DNS провайдера/настройка роутера; не старый VPS | Используются локальный OpenWrt/dnsmasq и существующая upstream DNS конфигурация. Live E2E подтвердил пользовательский addnhosts после refresh. Перезапуск dnsmasq очищает прежние A-записи; в QEMU он занял `3,24 с`, локальный DNS восстановился в течение двух секунд после команды. Пауза на реальном роутере не измерена. |
| DNS-диагностика WebPanel | Общего VPS endpoint нет; сравниваются публичные UDP/DoH/DoT резолверы напрямую | Общий `files/z2k-dns-check.sh` поставляется в OpenWrt rootfs и вызывается WebPanel API. DoH использует прямые HTTPS-запросы с `--resolve` на адрес проверяемого резолвера; старые VPS-IP и proxy-переменные не используются. При блокировке всех проверяемых внешних DNS-провайдеров неполон только диагностический отчёт; системный DNS/dnsmasq и пользовательский трафик этим скриптом не заменяются. OpenWrt parser suite `tests/openwrt/test_ow_dns_check.sh` прошёл `2/2`; live availability каждого публичного провайдера не подтверждена.
| WARP | WARP control plane обращается к Cloudflare напрямую по умолчанию. Явно заданный пользовательский proxy остаётся необязательной настройкой. OpenWrt управляет WARP через `platform/openwrt/warp.sh`. | В OpenWrt adapter встроенный default удалён, legacy URL на `213.176.74.63`, его nip.io-имя и `79.137.196.7` фильтруются; явно настроенный non-VPS proxy остаётся отдельной настройкой. Общий Keenetic launcher сохраняет такой же opt-in proxy без встроенного VPS default. `test_ow_warp_static.sh`, `test_ow_warp_parity.sh`, `test_warp_script.sh` и `test_warp_init_thin.sh` проверяют эти границы. Реальная регистрация/лицензирование и работа Cloudflare-туннеля в QEMU не проверялись. |
| RuTracker RT proxy | Upstream pool `ps1.blockme.site` — независимая сторонняя egress-услуга | Proxy engine не зависит от нашей VPS и по умолчанию разрешает прямое соединение для явного списка RuTracker hostnames, если pool не смог обслужить запрос. Внешний pool не обязателен, когда сайт доступен напрямую; если провайдер блокирует прямой маршрут и сторонний pool недоступен, обход без любого внешнего egress невозможен. Варианты: прямой доступ, сторонний pool или собственный egress по выбору оператора. Unit suite, семь сборок и прямые TLS/HTTP E2E в QEMU прошли: Cloudflare и сам `rutracker.org` вернули HTTP 200 при недоступном pool и заблокированных VPS IP. |
| Диагностика | Общий `files/z2k-diag.sh` проверял VPS ping и сверял часы через relay | OpenWrt пропускает VPS ping и проверяет часы по прямому HTTPS Date от Cloudflare с Google как вторым источником; Keenetic сохраняет прежний ping и закреплённый relay. Изолированный тест `7/7`; QEMU clock probe при блокировке VPS ранее вернул `0` секунд расхождения. |
| Telegram | Старый Go MTProxy зависел от собственной VPS; OpenWrt использует локальный Rust WS Proxy | Go-каталог, сборки, заглушка и CI module jobs удалены. Rust `tg-ws-proxy` собирается и тестируется CI для ARM64/x86_64. `test_ow_payload_bundle.py` проверяет отсутствие Go-бинарника и проверяет, что только generic fallback содержит безопасную ссылку старого имени на Rust wrapper; per-arch архивы ссылки не содержат. Живой Telegram пользовательский E2E в этой приёмке не запускался. |

Контрольный поиск по committed `platform/openwrt/` и `scripts/openwrt/` по адресам старых VPS, `nip.io` и `vps-relay` (исключая TG-файлы) нашёл одно совпадение: `platform/openwrt/warp.sh` отклоняет сохранённые legacy URL как необязательный proxy. Общие Keenetic transport и Insta-IP relay остаются в shared-файлах, но OpenWrt entry points направляют загрузки через `Z2K_FETCH_VPS_OUT=1`, а Insta-IP использует отдельный прямой DoH адаптер.

Повторный вызов `z2k_install_paths_for openwrt` на feature HEAD подтвердил границу упаковки: `files/z2k-warp.sh` и `files/init.d/S51z2k-warp` не имеют OpenWrt destination; shared `files/z2k-insta-ip-refresh.sh`, `files/z2k-update-lists.sh` и `files/z2k-geosite.sh` доставляются в `/usr/lib/z2k/` и используют platform adapters. `files/z2k-diag.sh` также не доставляется file-updater картой, но включается отдельно rootfs builder-ом. В общей Keenetic-карте `files/z2k-warp.sh` и `S51z2k-warp` сохраняют штатные `/opt/zapret2/z2k-warp.sh` и `/opt/etc/init.d/S51z2k-warp`; встроенный VPS fallback удалён, а явно настроенный proxy остаётся необязательной настройкой.

### Сводная матрица приёмки

| Область | Независимый путь OpenWrt | Подтверждение | Статус и ограничение |
|---|---|---|---|
| Подписанный bootstrap manifest | Прямой GitHub; при отказе — jsDelivr; закреплённый ключ и Ed25519 подпись обязательны | QEMU: production `fetch_verified_manifest()` прошёл оба направления failover: CDN при отказе raw origin и raw GitHub при блокировке jsDelivr; в обоих случаях блокировались оба старых VPS IP, ключ, подпись, `p-86.18`, `seq=142` проверены | **Частично**: helper и оба transport fallback подтверждены, полный bootstrap и установка не проходили |
| Release payload | Прямой GitHub и проверяемая цепочка HTTPS mirrors; размер и SHA берутся только из подписанного manifest | QEMU: прямой запрос x86/64 asset без proxy-переменных и с точечной блокировкой VPS дал размер/SHA из manifest; production `download_verified_artifact()` принял x86/64 через mirror; все 7 опубликованных архитектурных архивов совпали по размеру/SHA и прошли `gzip -t` | **Частично**: direct и mirror доставка подтверждены, транзакционная установка/обновление не проверены; runtime QEMU только x86/64 |
| `z2k_fetch`, списки и geosite | OpenWrt задаёт `Z2K_FETCH_VPS_OUT=1`; origin и зеркала используются без VPS layer | `fetch_vps_layer_budget` и `geosite_vps_independence`; QEMU `show ru-blocked.txt` получил тело через mirror при блокировке VPS и отказе origin | **Частично**: подтверждены transport и один live list path, полный refresh всех списков в расписании не проверен |
| Планировщик и точки входа обновления | Адаптер OpenWrt отключает старый VPS-слой загрузки; задания используют этот режим | `test_ow_schedule` `40/40`, `test_ow_update_entry` `12/12`, проверки транспорта WebPanel и seed-списка после установки; QEMU crond: `warp-games` — `32` списка, а `update.sh check` — подписанный `p-86.18`, `seq=142`; счётчики VPS `0` | **Частично**: обновление списков из cron и проверка только для чтения подтверждены; apply и rollback установленного продукта в QEMU не проверялись |
| Insta-IP refresh | Локальные DoH источники, TTL/provenance cache, фильтрация Meta CIDR, HTTPS/SNI probe и атомарный dnsmasq adapter | QEMU full refresh при блокировке VPS: 11 доменов обновлены, user record сохранён, старый A удалён; boundary/runtime/no-op rollback `35/35`, `26/26`, `11/11` | **Частично**: один домен сохранил предыдущие записи из-за непрошедших HTTPS probes; частичный отказ безопасно переносится, полного offline-install lifecycle нет |
| LAN DNS | Локальный dnsmasq и системная upstream DNS конфигурация; VPS не нужен | QEMU: пользовательская запись пережила refresh, DNS восстановился после dnsmasq restart; при полном DoH outage используется допустимый кэш | **Сетевой E2E пройден** для проверенных сценариев; недоступность всей сети закономерно исключает новые внешние ответы |
| Диагностика и WebPanel | OpenWrt clock probe использует прямой HTTPS Date; WebPanel и list refresh наследуют OpenWrt fetch env | QEMU clock skew `0` секунд при блокировке VPS; suites diagnostics `26/26`, source order `2/2`, WebPanel unit `37/37` | **Частично**: transport подтверждён; публичные DNS/API и все WebPanel действия не проверялись end-to-end |
| WARP | Отдельная опциональная функция; OpenWrt adapter не подставляет свой VPS, WARP не используется для базовых функций | Static/parity `92/92`, `39/39`; QEMU `warp-games` обновил `32/32` списка при блокировке обоих старых VPS IP и `GAME_WARP_ENABLED=0` | **Опциональная функция, tunnel не принят**: список обновляется без VPS, но регистрация, лицензирование и Cloudflare tunnel в QEMU не проверялись; WARP не нужен основному режиму |
| RuTracker RT proxy | Независимый сторонний pool с прямым fallback; не использует собственную VPS | QEMU x86/64: полный HTTP ответ Cloudflare и `rutracker.org` при недоступном pool и блокировке VPS; RT proxy suites `171/171` | **Условно подтверждён**: если провайдер блокирует прямой сайт и сторонний pool недоступен, никакой маршрут без внешнего egress не гарантируется |
| Основной NFQUEUE engine | Локальный OpenWrt `nfqws2`; не зависит от VPS, VPN, WARP или proxy для обработки пакетов | QEMU x86/64: реальный TLS-запрос через `nfqws2` с Lua `multisplit` вернул Cloudflare HTTP 200 (`warp=off`); отдельный LAN-клиент получил HTTP-тело через qnum `201` (7 пакетов); старые VPS counters `0`; proxy-переменных нет | **Частично**: router-origin TLS desync и LAN pass-through подтверждены; внешний WAN от LAN-клиента и DPI-обход не приняты |
| Telegram | Локальный Rust `tg-ws-proxy`, без старого Go MTProxy/VPS клиента | CI собрал ARM64/x86_64; OpenWrt QEMU перенаправил `149.154.167.51:5222` на Rust listener, затем настоящий `req_pq_multi` получил валидный Telegram `resPQ` (`0x05162463`, 104 байта) по WSS через Cloudflare; счётчики старых VPS endpoint — `0`. Тесты полного и per-arch архивов подтверждают отсутствие старого имени; legacy update переход p-86.17 также прошёл. | **Частично**: сетевой MTProto service E2E подтверждён, но вход в аккаунт, отправка сообщений и загрузка медиа тестовым аккаунтом пока не проверены. |
| Чистая установка, обновление, rollback и удаление | Существующий signed `install_release(tag)` transaction, настройки и rollback сохранены | QEMU lifecycle x86/64 ранее прошёл на отдельном тестовом payload: clean install, update, rollback, reinstall, reboot/autostart, WebPanel/CLI uninstall и повторное удаление. Отдельная локальная acceptance проверка p-86.17 → текущий p-86.18 candidate также прошла | **Частично принято**: lifecycle и migration подтверждены на x86/64; полный QEMU lifecycle текущего candidate и другие ABI требуют отдельного подтверждения |
| Архитектуры | Штатный OpenWrt runtime и дополнительные `z2k-warpd`/`z2k-rt-proxy` проверены отдельно по 7 целям | На `9e7bdc37`: OpenWrt arch `26/26`, pinned runtime artifact `29/29`, WARP archmap `6/6`; на `7b7b00bd`: `nfqws2` CLI под QEMU user-mode `14/14`; на `148e89be`: версия и профильный `--dry-run` `nfqws2` внутри OpenWrt QEMU x86/64; ранее 7 payload hashes/gzip и ABI двух дополнительных ELF `14/14` | **Частично**: QEMU runtime проверен только на x86/64; во всех ABI подтверждён запуск CLI, но не полный OpenWrt runtime или сетевой NFQUEUE трафик |

**Готовность к переносу в `main`: ожидает Telegram media E2E.** Полный локальный CI и QEMU lifecycle x86/64 завершились успешно. Реальный аккаунт ещё не авторизован, поэтому нет подтверждения входа, отправки сообщения и загрузки подготовленных медиа; этот сценарий обязателен для заявления о готовности Telegram. Дополнительно не проверены WARP control/data plane, `nfqws2` desync-профиль и LAN-client WAN трафик в QEMU, а также полный runtime на ABI кроме x86/64.

GitHub CI для feature-ветки `feat/openwrt-vps-free` запущен после push коммита `346226f4` и завершился успешно: [run 38238233556](https://github.com/t0fox/z2kOW/actions/runs/38238233556). Ветка не создаёт PR и не меняет production release.

## QEMU: чистая установка без обращений к старым VPS

12 октября 2026 года в отдельный OpenWrt 25.12.5 x86/64 QEMU overlay установлена сборка из CI с `tag=p-86.18`, `seq=142`. Для изолированной проверки manifest был заново подписан временным тестовым Ed25519 ключом; manifest и rootfs передавались с локального HTTP сервера. Поэтому это проверка installer/payload path, не проверка production-ключа или production `UPDATES.json`. Installer завершился `rc=0`, установил выпуск, Rust `tg-ws-proxy` присутствовал и работал с `--port=1443 --transparent`, прежний Go `tg-mtproxy-client` отсутствовал. WebPanel вернул HTTP 200.

До установки в госте сохранены baseline сети, nft и списка пакетов. Временное nft правило блокировало только TCP/443 к старым VPS IP `213.176.74.63` и `79.137.196.7`; счётчики обоих правил после установки и проверки были `0`. Тестовый гостевой WAN оставался рабочим. Активный ранее QEMU и базовый образ не менялись.

Это подтверждает clean install candidate и запуск Rust процесса при недоступных старых VPS endpoint. Установка payload шла с локального HTTP сервера, так что независимость именно доставки rootfs ещё подтверждается отдельными прямыми/mirror тестами выше. Запрос через настоящий Telegram LAN-клиент, штатный production-key update, rollback и uninstall в этой VM не выполнялись.

## QEMU: Telegram через TCP/5222 без старых VPS

В том же отдельном OpenWrt 25.12.5 x86/64 overlay запущен локальный тестовый Rust binary, собранный из закреплённого upstream commit `53c8bfe5e9efa561cf61a862c0371f1f8ba33869` и текущего OpenWrt-патча. `build_tg_ws_proxy.sh --test` прошёл; статические бинарники ARM64 и x86_64 имеют SHA-256 `8ab2b6047c483ab294ab77afcb612ca056d694a80145fada8ff8ba229861f9bc` и `cf91a7c6d9682689fe610704cbe8233e653eb67cfc9b5a7fc1a802993d6d2730`. Постоянный release binary не заменялся. Временная nft output rule перенаправляла только `149.154.167.51:5222` на тестовый listener `:1444`; Rust был запущен с политикой портов `443,5222`, CIDR `149.154.0.0/16` и без исходящего прокси. Две временные filter rules блокировали только TCP/443 к старым VPS-IP `213.176.74.63` и `79.137.196.7`.

Синтетический клиент передал настоящий obfuscated2 handshake и `req_pq_multi` без авторизации. Rust прочитал исходное назначение `149.154.167.51:5222`, выбрал DC2, установил WSS через Cloudflare fallback и вернул 104 байта; клиент проверил ответ Telegram `resPQ`, constructor `0x05162463` — `TELEGRAM_RESPQ=PASS`. Счётчик redirect — 6 пакетов; оба счётчика блокировки старых VPS — `0`. Это доказывает ответ Telegram DC поверх TCP/5222/WSS, но не пользовательский вход, переписку или медиа.

После проверки временная nft-таблица удалена, тестовый процесс остановлен, оставлены штатные `inet fw4` и `inet zapret2`, QEMU выключен. Ранее работавшая отдельная VM не затронута.

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

## Регрессионные тесты без Telegram

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

## QEMU: проверенная загрузка, отказ и восстановление

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

## Runtime-артефакты и соответствие архитектур OpenWrt

12 октября 2026 года на `18be002d` `test_ow_runtime_artifact.sh` прошёл `29/29` на архиве, загруженном по URL из `platform/openwrt/runtime-pin`: размер `4 339 405` байт, SHA-256 `02eec373b093083b426c27191bb6af260ac51e4e2739c51270270a351d2a1a16`. Suite подтвердил наличие `nfqws2`, `ip2net` и `mdig` для семи OpenWrt архитектур и запуск закреплённого x86/64 движка. `test_ow_warp_archmap.sh` прошёл `6/6`. Архив удалён после теста; продуктовый release builder не запускался.

## Повторный QEMU direct HTTPS при блокировке VPS

12 октября 2026 года на чистой OpenWrt 25.12.5 x86/64 QEMU, на HEAD `525f3316`, временные nft output drop-правила затрагивали только TCP/443 к `213.176.74.63` и `79.137.196.7`. При отсутствии proxy-переменных и `/dev/net/tun` прямой запрос к `https://api.github.com/zen` завершился `HTTP 200`, TLS verify `0`, endpoint `140.82.113.6`. Счётчики обоих VPS-drop правил остались `0`; после проверки временная таблица удалена, осталась только штатная `inet fw4`. Это подтверждает прямой HTTPS маршрут при недоступном старом VPS, но не полный install/update/rollback продукта.

## Регрессионные тесты DNS/DoH для OpenWrt

12 октября 2026 года на `7df1e68a` повторно прошли `test_ow_doh.sh` `266/266`, `test_ow_dnsproxy.sh` `266/266`, `test_ow_dns_check.sh` `2/2` и `test_ow_dns_detect_path.sh` `5/5`. Итого `539/539`, ошибок нет. Suites проверяют локальное управление dnsproxy/DoH, сохранение существующих dnsmasq overrides и диагностику; они не заменяют проверку пользовательского трафика после полной установки.

## Env, geosite и list refresh регрессии

12 октября 2026 года на `56736f16` прошли `test_ow_env.sh` `34/34`, `test_ow_geosite_adapter.sh` `9/9` и `test_ow_list_refresh_adapter.sh` `9/9`. Итого `52/52`, ошибок нет. Проверена передача OpenWrt transport-настроек в общий код и адаптер обновления geosite/списков; это локальные suites, не полный сетевой update продукта.

## QEMU DNS recovery и HTTPS после dnsmasq restart при блокировке VPS

12 октября 2026 года в той же чистой OpenWrt 25.12.5 x86/64 QEMU временные output drop-правила блокировали только TCP/443 к `213.176.74.63` и `79.137.196.7`. После `/etc/init.d/dnsmasq restart` локальный DNS разрешил `api.github.com` с первой проверки; прямой `curl` к API завершился `HTTP 200`, TLS verify `0`, endpoint `140.82.113.5`. Оба block counter — `0`. Во время restart init-скрипт вывел `udhcpc: no lease`, но последующие DNS и HTTPS проверки прошли. Временная nft-таблица удалена, осталась только `inet fw4`.

## Lifecycle, restart и state persistence регрессии

12 октября 2026 года на `167ef750` прошли `test_ow_lifecycle.sh` `27/27`, `test_ow_restart.sh` `6/6` и `test_ow_state_persist.sh` `16/16`. Итого `49/49`, ошибок нет. Проверены OpenWrt procd start/stop rollback, общий updater restart hook и сохранение strategy state; общий release path не задействовался.

## Доставка игровых списков WARP после установки

12 октября 2026 года аудит call path нашёл post-install background seed, который запускал `z2k-update-lists.sh warp-games` без `Z2K_FETCH_VPS_OUT=1`. Новый regression сначала упал `1/5` при очищенном окружении, подтверждая пропуск; OpenWrt release adapter теперь выставляет флаг только внутри seed subshell. После исправления прошли `test_ow_release_warp_seed.sh` `5/5`, `test_ow_warp_games_flow.sh` `4/4`, `test_ow_warp_manifest_env.sh` `5/5` и `test_ow_env.sh` `34/34` — итого `48/48`. Это закрывает post-install transport path; полный подписанный install/update/rollback всё ещё требует QEMU acceptance.

## Аудит пути вызовов общего обновления Insta-IP

12 октября 2026 года подтверждено, что `platform/openwrt/diag.sh` и `list-refresh.sh` входят в общий updater с `Z2K_PLATFORM=openwrt`; `files/z2k-insta-ip-refresh.sh` тогда выбирает `platform/openwrt/insta-ip.sh` и прямые DoH резолверы. HMAC POST на старый `/resolve` остаётся только в ветке Keenetic. Повторные boundary/runtime/no-op rollback suites прошли `35/35`, `26/26` и `11/11` (итого `72/72`).

## Путь вызовов транспорта WebPanel

12 октября 2026 года повторно прослежен update-manifest путь WebPanel: `api.sh` загружает `webpanel/cgi/platform.sh` до `actions.sh`, а platform seam подключает `platform/openwrt/env.sh`, экспортирующий `Z2K_FETCH_VPS_OUT=1`; вложенный `z2k_fetch` наследует этот режим. `test_ow_source_order.sh` прошёл `2/2`, `test_ow_webpanel_unit.sh` — `37/37`. Вместе с list-refresh wrapper, WARP games cron и исправленным post-install seed закрыты обнаруженные OpenWrt caller-ы общего fetch transport.

## Регрессионные проверки необязательного WARP

12 октября 2026 года на `b0228261` повторно прошли `test_ow_warp_static.sh` `92/92` и `test_ow_warp_parity.sh` `39/39` — `131/131`. Проверки подтверждают статическую конфигурацию и parity WARP-путей; сами по себе они не доказывают полноценный продуктовый VPS-free install/update lifecycle. Telegram не затрагивался.

## Дополнительные WARP lifecycle и функциональные регрессии

12 октября 2026 года на `fe104a97` прошли `test_ow_warp_lifecycle.sh` `440/440`, `test_ow_warp_functional.sh` `160/160`, `test_ow_warp_domain_paths.sh` `9/9`, `test_ow_warp_games_flow.sh` `4/4` и `test_ow_warp_manifest_env.sh` `5/5` — `618/618`. Вместе с повторными static/parity проверками выше это `749/749` WARP assertions. Suites локальные; они подтверждают адаптер, lifecycle, routing и список игр, но не требуют WARP для основного VPS-free режима и не являются live acceptance внешней инфраструктуры.

## Прерванная QEMU-попытка release lifecycle

12 октября 2026 года ранняя установка в чистой OpenWrt 25.12.5 x86/64 QEMU через `scripts/openwrt/install.sh` откатилась: экспериментальный test rootfs содержал failing TG stub, из-за чего общий `z2k-start` отменил установку. Получен `Z2KOW_ROLLBACK=complete`; проверены отсутствие installed-release и `/usr/lib/z2k`, счётчики VPS-drop оставались нулевыми. Этот rollback-сценарий был начальной проверкой и позже был дополнен успешным полным QEMU lifecycle из матрицы выше. Ошибочно созданная тестом `inet zapret2` удалена, пользовательский `/etc/z2k` оставлен.

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

## Повторные целевые регрессионные проверки без Telegram на текущем HEAD

12 октября 2026 года на `1f11d3ee` повторно прошли bootstrap download validation `8/8`, bootstrap manifest mirrors `7/7`, fetch layer budget `48/48`, geosite VPS independence `4/4`, Insta-IP boundary/runtime/no-op rollback `35/35`, `26/26`, `11/11`, OpenWrt env `34/34`, WARP static/parity `92/92` и `39/39` — итого `304/304`. Suites не запускают Telegram, общий installer или release/start lifecycle. Это регрессии локальных transport/adapters; они не закрывают полную установку, обновление, rollback и удаление продукта.

## Повторная архитектурная проверка без Telegram

12 октября 2026 года на `9e7bdc37` прошли `test_ow_arch.sh` `26/26`, `test_ow_runtime_artifact.sh` `29/29` и `test_ow_warp_archmap.sh` `6/6` — `61/61`. Runtime archive перед тестом скачан по закреплённому URL; размер `4 339 405` байт и SHA-256 `02eec373b093083b426c27191bb6af260ac51e4e2739c51270270a351d2a1a16` совпали с `platform/openwrt/runtime-pin`. Архив проверил наличие `nfqws2`, `ip2net` и `mdig` по семи OpenWrt ABI, installer digest, версию движка и запуск dry-run под x86/64. Временный архив удалён. Suites не затрагивают Telegram; остальные архитектуры подтверждены структурой/ограниченными smoke, но не полным OpenWrt runtime.

## Дымовая проверка nfqws2 на семи ABI

12 октября 2026 года из того же закреплённого runtime archive извлечены только `binaries/linux-*/nfqws2`. Все семь ELF статически связаны; под установленным в Debian QEMU user-mode/binfmt каждый запустил `--version` и `--dry-run --qnum=200 --filter-tcp=443 --filter-l7=tls`: `14/14`, версия `v1.0.5.2-z2k-r0`. Проверка не открывала NFQUEUE и не генерировала пользовательский сетевой трафик, поэтому это ABI/CLI smoke, а не полноценный OpenWrt runtime. Архив и извлечённые бинарники из `/tmp` удалены.

## `nfqws2` на OpenWrt QEMU

12 октября 2026 года на `148e89be` закреплённый embedded runtime archive скачан и проверен по SHA-256 `02eec373b093083b426c27191bb6af260ac51e4e2739c51270270a351d2a1a16`. Только `linux-x86_64/nfqws2` передан в OpenWrt 25.12.5 x86/64 QEMU через временный локальный HTTP server; SHA-256 в госте совпал (`e8ff58236ba75c55f9bb67b38d0109fdd40cbb5718d0ffa31f59e9ebd2ad1726`). В госте `--version` сообщил `v1.0.5.2-z2k-r0`, а `--dry-run --qnum=200 --filter-tcp=443 --filter-l7=tls` — `command line parameters verified`. Это реальный запуск движка на OpenWrt, но dry-run не открывает NFQUEUE и не доказывает обработку LAN-пакетов или VPS-free пользовательский трафик. Гостевой бинарник удалён; host HTTP server остановлен и временные файлы удалены; в QEMU осталась только штатная `inet fw4`.

## QEMU: прохождение NFQUEUE при недоступном VPS

12 октября 2026 года на кодовом HEAD `10d89fc8` тот же pinned `nfqws2` запущен в OpenWrt 25.12.5 x86/64 QEMU с `--qnum=200 --filter-tcp=18766`. Временный nft output chain направил TCP к локальному NAT host `10.0.2.2:18766` в queue 200 и точечно блокировал TCP/443 к старым VPS IP `213.176.74.63` и `79.137.196.7`. `wget --no-proxy` получил HTTP тело `nfqueue-e2e-ok`; nft counter очереди — 7 пакетов, оба VPS counters — 0. Это подтверждает живую передачу пакетов через NFQUEUE и pass-through в тестовом маршруте, но профиль desync не задавался и отдельный LAN-клиент не использовался. Процесс `nfqws2`, тестовые файлы и nft-таблица удалены; host HTTP server остановлен; в госте осталась только `inet fw4`.

## QEMU: отдельный LAN-клиент через NFQUEUE

12 октября 2026 года временная вторая OpenWrt 25.12.5 VM была подключена к `br-lan` первой VM через QEMU socket network. После отключения её временного bridge она получила DHCP lease `192.168.1.108/24` от первой VM (`192.168.1.1`), разрешила `www.cloudflare.com` через DNS роутера и достигла локального HTTP fixture на host `10.0.2.2:18083` через роутер.

На первой VM запущен pinned `nfqws2` x86/64 (`e8ff58236ba75c55f9bb67b38d0109fdd40cbb5718d0ffa31f59e9ebd2ad1726`) на qnum `201`; временный postrouting NFQUEUE охватывал TCP/18083, а forward rule блокировал старые VPS `213.176.74.63` и `79.137.196.7` на TCP/443. Второй VM `wget` получил тело `lan-e2e-ok`; queue counter — 7 пакетов, оба старых VPS counters — 0. На клиенте не было HTTP(S)/ALL proxy-переменных. Это подтверждает LAN-to-router-to-NFQUEUE pass-through в QEMU на локальном fixture.

Отдельная попытка клиента обратиться к внешнему Cloudflare HTTP(S) в этой QEMU-схеме до NFQUEUE завершилась `Operation not permitted`; причина в тестовой топологии не локализована, поэтому внешний WAN для отдельного клиента не засчитывается. `nfqws2`, временная nft-таблица и обе VM остановлены; lease `192.168.1.108` и связанные neighbor entries удалены, host server и временные файлы убраны. В основной VM осталась только штатная `inet fw4`, `/usr/lib/z2k` отсутствует. Пользовательский роутер и продуктовый installer не запускались.

## QEMU: TLS desync через NFQUEUE без VPS и прокси

12 октября 2026 года из архива, закреплённого в `platform/openwrt/runtime-pin`, извлечены `nfqws2` x86/64 (SHA-256 `e8ff58236ba75c55f9bb67b38d0109fdd40cbb5718d0ffa31f59e9ebd2ad1726`) и upstream Lua-модули `zapret-lib.lua` (`b67a470f23b00a8d6e732c4e5135a39b224511e0b71809d5f4616adf62674980`) и `zapret-antidpi.lua` (`83d4c85f74dc672d4da04e34a81601e92cf3cf140e5f0c94f3904bb6024b02a5`). Все три файла проверены по SHA после доставки в OpenWrt 25.12.5 x86/64 QEMU.

Первая попытка запустить `--lua-desync=multisplit:pos=1` без Lua-модулей завершилась ошибкой `desync function 'multisplit' does not exist`; очередь не получила тестовый запрос. После добавления двух pinned upstream Lua-модулей команда `--dry-run` прошла. Затем `nfqws2` работал на queue 200 с TLS-фильтром и `multisplit:pos=1`; временное nft-правило блокировало TCP/443 к старым VPS `213.176.74.63` и `79.137.196.7`, а остальной TCP/443 направляло в NFQUEUE. При отсутствии HTTP(S)/ALL proxy-переменных `curl -4 --noproxy '*' https://www.cloudflare.com/cdn-cgi/trace` получил HTTP 200, 214 байта от `104.16.124.96`; тело содержало `warp=off`. Счётчик NFQUEUE — 14 пакетов, счётчики обоих VPS — 0.

После прогона `nfqws2` остановлен, тестовые файлы и временная таблица удалены; проверено, что осталась только штатная `inet fw4`, процесс отсутствует, `/usr/lib/z2k` не установлен. Host HTTP server и временный pinned archive остановлены/удалены. Это подтверждает обработку реального TLS-потока локальным движком без VPS, WARP и proxy в сети QEMU; обход DPI и отдельный LAN-клиент не проверялись.

## Повторные регрессии обновления и восстановления без Telegram

12 октября 2026 года на `de0829fa` прошли `test_ow_update_entry.sh` `12/12`, `test_ow_updater_failsafe.sh` `5/5`, `test_ow_updater_state.sh` `7/7` и `test_ow_recovery.sh` `13/13` — `37/37`. Suites проверяют входные условия updater, fail-safe state и recovery без общего product start. Они не подтверждают полное применение подписанного rootfs, пользовательские настройки в реальном update или полный rollback/uninstall на установленном продукте.

## Повторные регрессии DNS и диагностики без Telegram

12 октября 2026 года на `0365c3c8` прошли clock skew direct-path `7/7`, AGH upstream diagnostics `19/19`, DNS/DoH adapter `266/266`, DNS check `2/2` и DNS path detection `5/5` — `299/299` уникальных assertions. Совместимый alias `test_ow_doh.sh` повторно запустил тот же DNS/DoH suite (`266/266`); повторный прогон в итог не суммируется. Сообщение `Direct DNS probe failed after 3 attempts` — ожидаемый отказной сценарий внутри suite; итоговый код каждой команды был `0`. Проверены unit/regression paths, не live-доступность всех внешних DNS-провайдеров.

## Регрессии адаптера TCP16 SNI без Telegram

12 октября 2026 года `tests/openwrt/test_ow_tcp16_runtime.sh` прошёл `13/13`. Проверены Lua `z2k_sni_pick(ctx, desync)`, интеграция OpenWrt-адаптера, сгенерированная конфигурация, сохранение verdict между проверками после reboot и очистка после успешного probe. Это локальная регрессия адаптера и состояния: отдельный LAN ClientHello, успешная обработка пользовательского TLS и реальный desync в сети не проверялись. Хостовый smoke с устаревшим `--dpi-desync=fake` отклонён закреплённым `nfqws2` как неизвестный параметр; текущая реализация использует Lua actions.

## Повторные регрессии Insta-IP без Telegram

12 октября 2026 года на базе HEAD `1b616abc` повторно прошли `test_ow_insta_boundary.sh` `35/35`, `test_ow_insta_runtime.sh` `26/26` и `test_ow_insta_refresh_noop_backup.sh` `11/11` — `72/72`. Проверены границы OpenWrt/общего транспорта, runtime выбора и кэширования кандидатов, no-op, сохранение полного файла при неудаче restart, rollback и удержание backup при неудаче восстановления. Это изолированные regression suites, не новый live refresh. Чистая QEMU VM доступна через serial; состояние перед дальнейшими сценариями: только штатная nft-таблица `inet fw4`, дерева `/usr/lib/z2k` и `/etc/z2k/state/installed-release` нет. Установщик и сервисы не запускались.

## QEMU: отказ DNS и восстановление без Telegram

12 октября 2026 года в чистой OpenWrt 25.12.5 x86/64 QEMU временная таблица `inet vpsfree_probe` отбрасывала исходящие UDP/TCP DNS и TCP/443 только к старым VPS `213.176.74.63`, `79.137.196.7`. До отказа `nslookup github.com 127.0.0.1` вернул `140.82.114.4`. При блокировке уникальный DNS-запрос завис; его вручную прервали примерно через 30 секунд. DNS drop counter — 1 пакет, оба VPS counters — 0. Таблица удалена, `nft list tables` показал только штатную `inet fw4`; после этого повторный lookup `github.com` снова вернул `140.82.114.4`. Восстановление подтверждено, но это проверка системного dnsmasq, не продукта: `/usr/lib/z2k` и installed-release в VM отсутствуют. init/start и Telegram не запускались.

## Повторная архитектурная проверка без Telegram

12 октября 2026 года на базе HEAD `31122916` повторно прошли `test_ow_arch.sh` `26/26`, `test_ow_runtime_artifact.sh` `29/29` и `test_ow_warp_archmap.sh` `6/6` — `61/61`. Runtime archive загружен напрямую без proxy из `platform/openwrt/runtime-pin`; SHA-256 совпал: `02eec373b093083b426c27191bb6af260ac51e4e2739c51270270a351d2a1a16`. Проверены карта ABI и наличие `nfqws2`, `ip2net`, `mdig` для семи целей, installer digest и x86/64 dry-run; архив удалён после прогона. Это не доказывает полный runtime на каждой архитектуре и не заменяет QEMU на отдельных ABI. Product builder и сервисы не запускались.

## Неопределённый прямой raw-origin probe

12 октября 2026 года после восстановления DNS в OpenWrt QEMU при блокировке только TCP/443 к старым VPS был запущен прямой BusyBox `wget` для `https://raw.githubusercontent.com/necronicle/z2kOW/main/UPDATES.json`. За примерно 24 секунды команда не вернула статус, размер или хэш; запрос остановлен вручную. Это неопределённый probe без результата, не доказательство отказа производственного downloader: CDN fallback этим вызовом не проверялся. Счётчик правила старых VPS был 0. Временная таблица и файл удалены; проверка `nft list tables` показала только `inet fw4`.

## QEMU: прямой доступ к манифесту jsDelivr после восстановления DNS

12 октября 2026 года в OpenWrt 25.12.5 x86/64 QEMU без proxy выполнен `curl` к `https://cdn.jsdelivr.net/gh/t0fox/z2kOW@main/UPDATES.json` при временной блокировке TCP/443 только к старым VPS `213.176.74.63` и `79.137.196.7`. `curl` завершился кодом `0`; размер — `297794` байт; SHA-256 `b2e3c96b04d1a36c23e22942e2878a42810a98266143b63175db4eeeee86759e` совпал с локальным `UPDATES.json`. Оба VPS counters — `0`. Вызов проверил доставку и целостность по локальному hash, но не выполнял проверку подписи. Временные таблица и файл удалены; после теста осталась только штатная `inet fw4`. В VM нет установленного продукта, сервисы не запускались.

## Приоритет зеркала при установке и ограничение времени ожидания

12 октября 2026 года QEMU показал, что DNS-запрос к `raw.githubusercontent.com` не завершался в течение наблюдения; прямой `wget` был отменён. Поэтому в обычном bootstrap независимый jsDelivr теперь проверяется первым, а raw-origin остаётся fallback. Явный приёмочный источник сохраняет приоритет. Тайм-аут BusyBox `wget` снижен с `60` до `15` секунд для сетевого чтения. Новый regression сначала подтвердил прежнее значение `60` и упал, затем прошёл после исправления; manifest mirror suite прошёл `10/10`, download validation `8/8`, shell syntax — успешно.

После изменения в OpenWrt 25.12.5 x86/64 QEMU запущена именно извлечённая из feature production-функция `fetch_verified_manifest()` с настоящими `wget`, `jsonfilter` и OpenSSL; тестовый сервис получил только этот helper по временной локальной HTTP-раздаче. При точечной TCP/443 блокировке старых VPS функция первой скачала manifest, закреплённый ключ и подпись с jsDelivr и успешно прошла Ed25519 verification. Результат: `MANIFEST_URL=https://cdn.jsdelivr.net/gh/t0fox/z2kOW@main/UPDATES.json`, key ID `916b1459a03961d66af48ddb2165afbed3c0d7445f75c8b7c95adbb5fc044bae`, `p-86.18`, `seq=142`, SHA-256 `b2e3c96b04d1a36c23e22942e2878a42810a98266143b63175db4eeeee86759e`; VPS counters — 0. Server, helper и nft-таблица удалены, в VM осталась только `inet fw4`. Установка продукта и запуск сервисов не выполнялись.

## Резервная загрузка из подписанного прямого источника

После переноса обычного bootstrap на CDN-first расширен `test_ow_bootstrap_manifest_mirrors.sh`: при отказе CDN suite принимает raw-origin только с валидной Ed25519-подписью, а также проверяет сохранение приоритета явного приёмочного источника. Suite прошёл `13/13`; timeout и download validation — `1/1` и `8/8`. Raw-origin fallback подтверждён на изолированной подписанной fixture; live raw-host запрос в текущей QEMU-сети остаётся неопределённым из-за задержки DNS.

## Ограничение DNS timeout в BusyBox

В OpenWrt QEMU команда `timeout` отсутствует. Документация BusyBox уточняет, что `wget -T` ограничивает connect/read, но не DNS query ([описание BusyBox](https://lists.busybox.net/pipermail/busybox-cvs/2013-October/034219.html)). Это остаётся ограничением резервной ветки `wget`; основной bootstrap теперь требует `curl` через APK и выбирает его первым, поэтому тайм-аут DNS задаётся `--connect-timeout`.

### Итерация: ограничение DNS ожидания bootstrap через curl

12 октября добавлен `curl` в обязательную установку bootstrap и его downloader выбирает первым. `--connect-timeout 10` ограничивает фазу соединения вместе с DNS lookup, TCP и TLS handshake; `--max-time 600` ограничивает весь перевод, включая большие релизные архивы ([официальная документация curl](https://curl.se/docs/manpage.html)). При зависшем DNS одного зеркала это позволяет вернуться в цикл проверки источников, сохранив подпись манифеста и проверку размера/SHA-256 артефакта. Существующий `wget -T 15` оставлен как резервная ветка.

В Debian WSL повторно прошли `test_ow_bootstrap_timeout.sh` (`1/1`), `test_ow_bootstrap_download_validation.sh` (`8/8`), `test_ow_bootstrap_manifest_mirrors.sh` (`13/13`) и `sh -n` для installer и нового теста.

В OpenWrt 25.12.5 x86/64 QEMU при временных правилах TCP/443 только для старых VPS `213.176.74.63` и `79.137.196.7` прямой curl к jsDelivr скачал `UPDATES.json` за `0,46 с`: `297794` байта, SHA-256 `b2e3c96b04d1a36c23e22942e2878a42810a98266143b63175db4eeeee86759e`. Там же скачаны манифест, `.sig` и закреплённый ключ ID `916b1459a03961d66af48ddb2165afbed3c0d7445f75c8b7c95adbb5fc044bae`; `openssl pkeyutl -verify -rawin` завершился `rc=0` (`Signature Verified Successfully`). `apk --no-cache update` получил индексы всех настроенных прямых feed OpenWrt и завершился `rc=0`, `11247` distinct packages available. Счётчики обоих VPS правил остались `0`. После проверки правила удалены по handles; `nft list tables` снова показывает только `inet fw4`, а `fw4 output` совпадает с исходным набором правил. Сервисы продукта не запускались.

Один raw-origin probe в этой итерации использовал ошибочный owner `necronicle` и получил HTTP `404` за `0,45 с`; это не проверка DNS timeout и не входит в подтверждённые результаты. Закреплённый production helper в этой итерации не запускался целиком с curl: в QEMU отдельно проверена та же цепочка доставки и Ed25519-проверки. Предыдущий полный helper E2E использовал BusyBox wget.

Остаточные ограничения: полный bootstrap, установка, обновление, rollback и удаление продукта в QEMU ещё не приняты; запуск helper с curl и сценарий зависшего DNS требуют отдельной проверки. `apk update` остаётся до установки curl, хотя в этом прогоне прямые OpenWrt feeds успешно обновились при блокировке обоих VPS.

## Повторные OpenWrt регрессии и устранение устаревшей проверки

12 октября 2026 года в ветке `feat/openwrt-vps-free` повторно прошли bootstrap timeout/download/mirrors `1/1`, `8/8`, `13/13`; Insta-IP boundary/runtime/no-op rollback `35/35`, `26/26`, `11/11`; updater entry/failsafe/state/recovery `12/12`, `5/5`, `7/7`, `13/13`; uninstall parity `85/85` — всего `216/216` assertions. Все suites запускались в Debian WSL, Telegram suites не запускались.

Первый запуск uninstall parity выявил устаревшую фикстуру: она ожидала upstream commit `43b98092c5a337a35f5c094363f469243d7b8b80`, тогда как неизменённый подписанный `UPDATES.json` закрепляет текущий полный commit `b820fdfa406acdee6e42cd6d29b46db966453857` (`p-86.18`, `seq=142`). Проверка изменена на валидацию формата SHA-1 поля именно в объекте `upstream`; после этого suite прошёл `85/85`. `UPDATES.json` и подпись не изменялись.

Повторная проверка состояния QEMU после сетевых probes подтвердила только штатную nft-таблицу `inet fw4`; `/usr/lib/z2k` и installed-release отсутствуют. Поэтому эти регрессии не являются приёмкой clean install/update/rollback/uninstall продукта. Полная сборка штатного rootfs включает `scripts/openwrt/build_tg_ws_proxy.sh`; она не запускалась, чтобы не собирать и не затрагивать Telegram-компонент, который выполняет другой агент. Полная QEMU-жизненная приёмка остаётся незакрытой.

## QEMU: производственный загрузчик curl при отказе DNS и блокировке VPS

12 октября 2026 года в том же OpenWrt 25.12.5 x86/64 госте извлечена без изменений функция `fetch_verified_manifest()` из текущего `scripts/openwrt/install.sh`; wrapper использовал тот же `curl --connect-timeout 10 --max-time 600`, `jsonfilter`, закреплённый key ID и Ed25519-проверку. При временном drop UDP/TCP 53 запросы к CDN и raw-origin завершились контролируемой ошибкой `curl (6) Could not resolve` за 10 секунд, `verified=0`, helper вернул отказ. Счётчик DNS drop — 16; оба точечных VPS TCP/443 counters — 0.

Затем при восстановленном DNS и временном drop TCP/443 только к `213.176.74.63` и `79.137.196.7` тот же production helper выбрал `https://cdn.jsdelivr.net/gh/t0fox/z2kOW@main/UPDATES.json`, завершился успешно (`verified=1`, менее одной секунды с секундной точностью), проверил подпись закреплённым ключом и получил `p-86.18`, `seq=142`. SHA-256 полученного манифеста — `b2e3c96b04d1a36c23e22942e2878a42810a98266143b63175db4eeeee86759e`; размер подписи — 64 байта. Оба VPS counters — 0.

После обоих прогонов временные правила удалены по сохранённым handles, тестовые helper/файлы удалены. В госте осталась только штатная `inet fw4`, цепочка `output` восстановлена до исходных handles `190`, `192`, `193`, `194`; `nslookup github.com 127.0.0.1` снова успешно вернул `140.82.114.3`. Локальный HTTP server остановлен. Проверка подтверждает production helper при DNS отказе и при старой VPS недоступной; полный installer и lifecycle продукта по-прежнему не запускались.

После этого в Debian WSL повторно прошли независимые общие regression suites без Telegram: `test_fetch_vps_layer_budget.sh` `48/48`, `test_geosite_vps_independence.sh` `4/4`, `test_diag_clock_skew_vps_free.sh` `7/7` — итого `59/59`. Проверки сохраняют Keenetic relay behavior и подтверждают OpenWrt direct/mirror и clock-diagnostic paths.

## QEMU: системные APK через репозитории OpenWrt без VPS

12 октября 2026 года в OpenWrt 25.12.5 x86/64 QEMU временно заблокированы TCP/443 к `213.176.74.63` и `79.137.196.7`; штатный `apk fetch --output /tmp/z2k-apk-vpsfree-probe ca-bundle openssl-util jsonfilter curl` завершился `rc=0`. Из configured OpenWrt repositories напрямую получены пакеты: `ca-bundle-20260816-r1.apk` (107 337 байт, SHA-256 `22f49453c235d2caefe6859bf797a96bfcd874b1f43df6ee45dc6a48a37e57d3`), `curl-8.22.0-r1.apk` (73 944, `a5e0d63d721ccc570eeb1e9962b63b7898a610eacddf1f1a95be0e67139e7c5c`), `jsonfilter-2026.03.16~b9034210-r1.apk` (10 343, `ec2499f386a7432407bb1d1581681aac6dcd17a85469e2d0a280a01d5aab7389`) и `openssl-util-3.5.9-r1.apk` (385 462, `f975772e376ce05c46efbc4f4f2bee1575109454cb928333b65010dd526b1783`). Все четыре пакета уже были установлены до теста; команда только скачала архивы, package database и system root не менялись. Оба VPS counters остались `0`.

После прогона архивы удалены, правила удалены по handles; осталась только штатная `inet fw4` с исходными output handles `190`, `192`, `193`, `194`. `nslookup github.com 127.0.0.1` снова успешен (`140.82.114.4`). Это подтверждает доступность bootstrap dependency packages по прямым OpenWrt feeds без VPS, но не заменяет install transaction или clean product lifecycle acceptance.

## QEMU: переход с недоступного CDN на raw GitHub

12 октября 2026 года в OpenWrt 25.12.5 x86/64 QEMU повторно запущена извлечённая без изменений функция `fetch_verified_manifest()` из текущего `scripts/openwrt/install.sh`, с production downloader на `curl --connect-timeout 10 --max-time 600`, `jsonfilter` и закреплённой проверкой Ed25519. До прогона в госте была только штатная `inet fw4`, а каталог `/usr/lib/z2k` отсутствовал.

Временная nft-таблица блокировала TCP/443 к двум IPv4 jsDelivr, двум его IPv6 адресам и старым VPS `213.176.74.63` и `79.137.196.7`. Запрос к заблокированному CDN завершился `curl (28)` после 10 секунд, после чего тот же helper переключился на `https://raw.githubusercontent.com/t0fox/z2kOW/main/UPDATES.json`. Манифест принят после проверки подписи: `verified=1`, `p-86.18`, `seq=142`, SHA-256 `b2e3c96b04d1a36c23e22942e2878a42810a98266143b63175db4eeeee86759e`. CDN IPv4 drop counter — 14; IPv6 CDN — 0; оба старых VPS counters — 0. Это подтверждает fallback при отказе CDN в данной сети, когда raw GitHub доступен.

После прогона временная nft-таблица удалена, `/tmp` helper и временные файлы очищены; `nft list tables` показал только штатную `inet fw4`. Package database и постоянные настройки не менялись, локальный HTTP server остановлен. Это проверка transport helper, а не чистой установки или полного product lifecycle.

## QEMU: клиент LAN через прямой WAN при блокировке старого VPS

12 октября 2026 года к основной OpenWrt 25.12.5 x86/64 QEMU по изолированному socket LAN была временно подключена вторая чистая OpenWrt VM. Она получила DHCP-адрес `192.168.1.108`; её трафик проходил через LAN→WAN forwarding и IPv4 masquerade основной VM. Временное правило блокировало TCP/443 к старым VPS `213.176.74.63` и `79.137.196.7`; счётчик блокировки остался `0`.

Первый запрос по имени завершился `Operation not permitted`, потому что чистый тестовый образ клиента использовал собственный `127.0.0.1` resolver, который отвечал `REFUSED`. После явного указания DNS основной LAN-роутер разрешил `www.cloudflare.com` в `104.16.123.96` и `104.16.124.96`. С того же LAN-клиента BusyBox `wget` получил полный ответ Cloudflare по HTTP (`rc=0`, 205 байт) и HTTPS (`rc=0`, 213 байт); повторный HTTPS при активной блокировке старой VPS тоже завершился `rc=0` и вернул 218 байт. HTTP-запрос по голому IP получил ожидаемый Cloudflare `403` и не используется как успешная проверка приложения.

После теста в основной VM удалены временная nft-таблица, DHCP lease и neighbor entries; тестовая VM остановлена. В основной VM осталась только штатная `inet fw4`, SSH/WAN не затрагивались. Это реальная проверка прозрачного прямого LAN→WAN HTTPS и DNS через роутер в данной QEMU-топологии без VPN, WARP, proxy и старой VPS. Она не запускает установленный z2kOW и не подтверждает clean install, updater или работу через DPI; тестовому клиенту DNS пришлось указать явно из-за его изолированного локального resolver.

## Уточнение аудита оставшихся legacy endpoint в общих исходниках

Поиск по OpenWrt-адаптерам и вызываемым общим скриптам находит оставшиеся VPS URL/IP в `files/z2k-insta-ip-refresh.sh`, `files/z2k-update-lists.sh`, `files/z2k-geosite.sh`, `files/z2k-diag.sh`, `files/z2k-warp.sh` и legacy `files/init.d/S51z2k-warp`. Кроме того, Keenetic `lib/install.sh` содержит статические WhatsApp/Ticketmaster relay pins и старую процедуру GitHub bootstrap, а `files/init.d/S96z2k-rt-proxy` — Keenetic RT init/offload path. Эти строки нельзя трактовать как доказательство OpenWrt-вызова: OpenWrt bootstrap проходит `scripts/openwrt/install.sh` → `scripts/openwrt/install_release.sh` → `platform/openwrt/release.sh`; OpenWrt RT service использует `platform/openwrt/rt.sh`. В OpenWrt installer/adapter call paths ссылки на `lib/install.sh` и `S96z2k-rt-proxy` не найдены. Keenetic-механизмы оставлены без изменений.

Для списков `platform/openwrt/list-refresh.sh` загружает `paths.sh` и `env.sh`; последний выставляет `Z2K_PLATFORM=openwrt` и `Z2K_FETCH_VPS_OUT=1`. Поэтому общий `z2k-update-lists.sh` запускает Insta-IP helper, но сам helper выбирает OpenWrt-ветку с DoH Cloudflare/Google/AdGuard и `platform/openwrt/insta-ip.sh`; HMAC POST к `/resolve` остаётся в Keenetic-ветке. Отдельный cron `warp-games` также явно отключает VPS layer. Для геосайтов OpenWrt использует прямой origin с независимыми mirrors после ошибки.

Для диагностики общий скрипт сохраняет VPS ping/relay только вне OpenWrt; OpenWrt clock check идёт по прямому HTTPS к Cloudflare, затем Google, а OpenWrt-диагностика читает Insta hostname list и runtime через свой адаптер. Для WARP OpenWrt WebPanel назначает `platform/openwrt/warp.sh` и `/etc/init.d/z2k`; адаптер отбрасывает сохранённый старый VPS proxy, оставляя заданный оператором независимый proxy опциональным. Legacy Keenetic WARP launcher остаётся в исходниках. Проверки WARP static/parity покрывают правила адаптера, но чистая установка пока не доказывает, какие legacy init-файлы физически окажутся в установленном rootfs; реальная регистрация и туннель WARP в QEMU также не подтверждены.

Этот аудит отделяет сохранённую совместимость от OpenWrt call path и не удаляет legacy функции. Различие подтверждено статическим маршрутом исходников; физическое наличие и запуск всех legacy файлов в установленном полном rootfs останутся предметом незавершённой lifecycle приёмки. Подтверждённые живые прогоны, блокировки VPS и оставшиеся пробелы перечислены в основной матрице выше; полная product lifecycle приёмка всё ещё открыта.

## QEMU: дымовая проверка дополнительных бинарников OpenWrt

12 октября 2026 года закреплённым Go `1.25.13` повторно собраны только OpenWrt `z2k-rt-proxy` и `z2k-warpd` из production-команд `scripts/openwrt/build-release.sh`: `CGO_ENABLED=0`, `-trimpath`, `-buildvcs=false`; для MIPS — `GOMIPS=softfloat`; WARP собран с OpenWrt tag/overlay и версией `p-86.18`. Telegram-сборщик и общий release builder не запускались. Временные бинарники удалены после проверки.

QEMU user-mode исполнил `z2k-warpd version` и `z2k-rt-proxy --help` для всех семи OpenWrt release целей: `arm64`, `arm` (GOARM=7), `amd64`, `386`, `mips`, `mipsle` и `riscv64`. На каждой цели WARP вернул `z2k-warpd p-86.18`, RT proxy успешно показал help, а ELF `Machine` совпал с целевой архитектурой. Это расширяет прежний runtime smoke за пределы amd64 для самих бинарников, но не запускает полный OpenWrt kernel/rootfs на каждой архитектуре и не проверяет сетевое туннелирование, NFQUEUE или регистрацию WARP.

## Аудит статистики, отправлявшейся на VPS

Статистика выбора стратегий не является оставшейся OpenWrt функцией: её uploader, серверный collector, API и элементы панели уже удалены из текущего upstream до этой работы. Повторный `tests/test_strategy_telemetry_retired.sh` прошёл `29/29`; он подтверждает отсутствие uploader/API/collector и сохранение локального autocircular telemetry state. `platform/openwrt/schedule.sh` удаляет старую marker-строку `# z2k-stats-upload` при схождении расписания. Следовательно, заменять VPS-сбор статистики не требуется; чистая сборка полного rootfs по-прежнему не принята, поэтому физический состав окончательного архива остаётся lifecycle-пробелом.

## QEMU: Insta-IP refresh через настоящий UCI и dnsmasq

12 октября 2026 года в отдельной snapshot-VM OpenWrt 25.12.5 x86/64 проверен актуальный Insta-IP helper с настоящими UCI и `/etc/init.d/dnsmasq`; старые VPS `213.176.74.63` и `79.137.196.7` были заблокированы только для исходящего TCP/443. С чистого образа прямые OpenWrt APK feeds успешно обновились (`11247` пакетов), затем для проверки временно установлен `curl`. Счётчики блокировки старой VPS оставались нулевыми.

Успешное обновление завершилось `rc=0`: helper атомарно записал 24 A-записи для 12 hostname, добавил принадлежащую адаптеру запись `addnhosts` в UCI и перезапустил dnsmasq. Сгенерированный runtime-конфиг dnsmasq содержал правильный путь; `nslookup instagram.com 127.0.0.1` получил ответы из этого файла. `/etc/config/network` не менялся.

Для отказного прогона кэш кандидатов временно удалён; исходящие запросы к трём настроенным DoH resolver сначала молча отбрасывались (по 33 пакета на каждом правиле), затем правила заменены на reject для детерминированного завершения. Без сети и допустимого кэша helper вернул `rc=1` примерно через 106 секунд. Существующий файл из 24 A-записей и UCI-конфигурация остались неизменны, а локальный dnsmasq продолжил отвечать. Счётчики старой VPS — 0. После восстановления прямого DoH повторный запуск завершился `rc=0`, обновил 9 hostname и снова перезагрузил dnsmasq.

В конце вызван штатный uninstall адаптера: его UCI entry и принадлежащие ему файлы удалены, исходный хэш `/etc/config/dhcp` восстановлен (`c43757c2778625fb709c0f6124c50173c6330641dc1426d20a8766481bf3fe40`). Временные nft-правила удалены; цепочка `inet fw4 output` вернулась к исходным правилам. `curl` удалён, `/etc/apk/world` совпал с исходной копией. Snapshot-VM и временный HTTP server остановлены; постоянный сетевой конфиг не изменялся.

Это реальная компонентная проверка Insta-IP refresh, отказа и восстановления на x86/64, а не clean install всего продукта. Ограничение: при недоступности всех DoH resolver и пустом кэше отказ занял около 106 секунд; быстрый failover/общий верхний deadline для этой процедуры остаётся незакрытым вопросом. Полный OpenWrt lifecycle и другие архитектуры этой проверкой не подтверждаются.

## Insta-IP: общий deadline прямого DNS и сохранение кэша

В ответ на измеренную задержку добавлен общий 30-секундный бюджет DoH-запросов на весь список hostname. Последний `curl` получает оставшееся время как `--max-time`; после исчерпания бюджета новые сетевые запросы не начинаются, но helper дочитывает допустимые TTL/stale записи кэша для всех оставшихся hostname. Неуспешное разрешение не перезаписывает кэш. В unit regression сначала проверено отсутствие общего deadline, затем добавлены проверки на ограничение числа запросов, per-request timeout, возврат кэша всех hostname и неизменность кэш-файла.

12 октября 2026 года обновлённый production helper повторно запущен в OpenWrt QEMU при молчаливом drop TCP/443 к трём DoH IP и старым VPS `213.176.74.63`, `79.137.196.7`; для прогона задан сокращённый общий бюджет 5 секунд. Вызов вернулся примерно за 5,7 секунды, выдал обе заранее кэшированные записи (`instagram.com` и `www.instagram.com`), а SHA-256 кэша до и после совпал (`c9da54594ef2375548fa46f43cc3baef7417388b538ada1a0c8ddd2e9b0864c6`). Счётчики DoH drop достигли 9 и 8 пакетов; старые VPS — 0. Это подтверждает bounded fallback на cache-hit, но не быстрый первичный refresh при пустом кэше: в таком случае функция вернёт ошибку после общего срока, сохранив установленные dnsmasq записи.

После прогона временная nft-таблица и файлы `/tmp` удалены; в QEMU осталась только штатная `inet fw4`. Targeted suites прошли: Insta runtime `31/31`, boundary `35/35`, rollback/no-op backup `11/11`; `sh -n` и `git diff --check` успешны. Полный OpenWrt lifecycle эта правка не проверяет.

## Повторные проверки updater lifecycle

12 октября повторно прошли изолированные OpenWrt suites: lifecycle `27/27`, recovery `13/13`, update entry `12/12`, updater failsafe `5/5`, updater state `7/7` — итого `64/64`. `test_ow_upgrade_acceptance.py` прошёл `2/2` на синтетических Ed25519-подписанных baseline/candidate fixture. Эти проверки покрывают локальные переходы состояния, fail-safe и валидатор приёмочной квитанции; они не устанавливают production archive и не доказывают чистую установку, реальное обновление/rollback или удаление продукта на полном OpenWrt rootfs.

## QEMU: полный Insta-IP refresh при пустом кэше и отказе DoH

В OpenWrt 25.12.5 x86/64 QEMU повторно запущен production `z2k-insta-ip-refresh.sh` с актуальным adapter, настоящими UCI и dnsmasq. Временный nft output chain молча отбрасывал TCP/443 к трём DoH resolver и обоим старым VPS (`213.176.74.63`, `79.137.196.7`); общий бюджет DNS был снижен до 5 секунд, кэш кандидатов пуст. До запуска в тестовом host-файле были две Instagram-записи и пользовательская `user.example`.

Refresh зарегистрировал свой `addnhosts` через UCI и перезапустил настоящий dnsmasq, затем завершился с ненулевым кодом после отказа resolver. SHA-256 host-файла остался `590eed96e16c666ad8da1a72e548c06c75fd1539953cdc5fdfb6fb0326cf2845`; UCI include и runtime `addn-hosts` оставались активны, `nslookup instagram.com 127.0.0.1` вернул прежний `157.240.1.1`. Старые VPS counters — 0. Это подтверждает, что при пустом кэше отказ не удаляет рабочие DNS-записи, а возвращает ошибку примерно после заданного общего бюджета.

После теста UCI-конфиг восстановлен из точной копии (`/etc/config/dhcp` SHA-256 до/после `c43757c2778625fb709c0f6124c50173c6330641dc1426d20a8766481bf3fe40`), dnsmasq перезапущен; временная nft-таблица и каталог fixture удалены, осталась только `inet fw4`. WAN сохранил маршрут через `10.0.2.2`, прямой запрос к GitHub API вернул HTTP 200. Очистку UCI в этом отказном harness выполнил восстановлением backup, поэтому этот прогон не засчитывается как проверка штатного uninstall.

В тот же день повторно прошли transport regressions: direct-first `13/13`, VPS-layer budget `48/48`, geosite VPS independence `4/4`, WARP fetch-chain `3/3`, OpenWrt list-refresh adapter `9/9`. Они проверяют локальные call paths; результат не заменяет запуск cron-driven list refresh на установленном полном продукте.

## Повторная проверка release-предохранителей

На текущем feature HEAD повторно прошли `test_ow_archive_validation.sh` `7/7`, `test_ow_reinstall_guard.sh` `11/11`, `test_ow_release_signing.py` `12/12` и `test_ow_release_warp_seed.sh` `5/5` — всего `35/35`. Это подтверждает локальные проверки архива, reinstall guard, подписи и WARP seed. Сценарии используют fixtures и не являются приёмкой чистой установки, обновления, rollback или uninstall полного продукта в QEMU.

## Проверки OpenWrt после уточнения области работ

12 октября повторно прошли независимые наборы: bootstrap timeout `1/1`, OpenWrt architecture `26/26` и list-refresh adapter `9/9` — всего `36/36`. Проверка интеграционного bootstrap harness завершилась `15/20`: локальный HTTP fixture на `127.0.0.1:17778` не принимал соединение, поэтому свежая установка не дошла до получения манифеста и дальнейшие assertions не являются результатом проверки продукта. Этот запуск не засчитывается как install E2E; повтор интеграционного набора исключён из текущей области работ. Полная чистая установка, обновление, rollback и удаление продукта в QEMU остаются неподтверждёнными.

## QEMU: проверка производственного подписанного манифеста при блокировке VPS

В работающей OpenWrt 25.12.5 x86/64 VM проверена production-функция `z2k_ow_manifest_prepare_production` из текущего feature HEAD. В `/tmp` гостя переданы только `paths.sh`, `env.sh`, `arch.sh`, `manifest.sh`, `release_state.sh`, общие `utils.sh`/`auto_update.sh` и штатный открытый ключ; rootfs продукта не устанавливался. Временная nft output-таблица отбрасывала только TCP/443 к `213.176.74.63` и `79.137.196.7`. Proxy-переменных не было; в госте были интерфейсы `lo`, `eth0`, `br-lan`, а таблица fw4 оставалась штатной.

Production helper скачал `UPDATES.json` с подписью, проверил Ed25519 и структуру release для x86/64: SHA-256 `b2e3c96b04d1a36c23e22942e2878a42810a98266143b63175db4eeeee86759e`, `current=p-86.18`, `seq=142`, key ID `916b1459a03961d66af48ddb2165afbed3c0d7445f75c8b7c95adbb5fc044bae`, `release_artifact=verified`. В отдельном прямом запросе `raw.githubusercontent.com/.../UPDATES.json` вернул HTTP 200 и 297 794 байта при той же блокировке; счётчики обоих старых VPS-IP — 0.

Проверка подтверждает подписанный сетевой этап updater на OpenWrt с заблокированным старым VPS. Это не запуск `platform/openwrt/update.sh check`, не скачивание и применение release archive и не полный install/update/rollback/uninstall. После теста nft вернулась к единственной `inet fw4`, временные файлы гостя и хоста удалены, HTTP-сервер остановлен; пакеты и постоянные настройки не менялись.

## QEMU: штатный `update.sh check` при блокировке VPS

В той же OpenWrt VM временно размещён root из текущего committed HEAD только с OpenWrt updater и его общими manifest/release helpers; тестовое состояние установлено в `tag=p-86.17`, `seq=141`. Рабочие незакоммиченные файлы не использовались. При nft drop только TCP/443 к двум старым VPS `platform/openwrt/update.sh check` вернул `Доступен полный выпуск p-86.18`, код `0`; загруженный и проверенный подписанный manifest имел SHA-256 `b2e3c96b04d1a36c23e22942e2878a42810a98266143b63175db4eeeee86759e`, sequence `142`, а metadata release archive для x86/64 прошла валидацию. Счётчики обоих endpoint были `0`. Proxy-переменных не было; direct raw GitHub GET в отдельном запросе при том же endpoint drop вернул HTTP 200, 297 794 байта.

Это подтверждает путь `update.sh check` и подписанный выбор доступного выпуска без старой VPS. Команда `check` не скачивает и не устанавливает archive; полный update, транзакционный rollback и uninstall здесь не проверялись. Временный payload/state удалён, `/usr/lib/z2k` остался отсутствующим, nft вернулась к `inet fw4`, transfer server остановлен, package database и постоянные конфиги не менялись.

## QEMU: updater failover на независимый CDN

Повторён production `platform/openwrt/update.sh check` на той же временной базе `p-86.17/seq=141`. Чтобы проверить источник failover, только внутри гостя `raw.githubusercontent.com` и `gh-proxy.com` временно направлялись на loopback; `/etc/hosts` был сохранён и восстановлен с совпавшим SHA-256. Одновременно nft блокировал только старые VPS-IP на TCP/443. При чистом временном каталоге updater получил manifest с SHA-256 `b2e3c96b04d1a36c23e22942e2878a42810a98266143b63175db4eeeee86759e`, проверил подпись и сообщил `Доступен полный выпуск p-86.18` (`rc=0`). В `lib/utils.sh` после raw origin и до `gh-proxy.com` задан путь `cdn.jsdelivr.net`; с обоими другими источниками недоступными успешный путь прошёл через независимый CDN. Счётчики старых VPS — `0/0`.

После сценария `/etc/hosts` совпал с исходным файлом, временная nft-таблица удалена, осталась только `inet fw4`; тестовый payload/state и transfer server удалены, продукт не устанавливался и системные пакеты/постоянные конфиги не менялись. Это проверяет подписанный manifest failover; скачивание полного release archive и его применение остаются отдельной незакрытой приёмкой.

## Повторные регрессии без Telegram на `b78f457a`

12 октября на актуальном feature HEAD повторно прошли `test_ow_insta_runtime.sh` (`31/31`), `test_ow_insta_boundary.sh` (`35/35`), `test_fetch_vps_layer_budget.sh` (`48/48`) и `test_geosite_vps_independence.sh` (`4/4`) — всего `118/118`. Эти наборы проверяют bounded DoH/cache поведение, платформенное отключение старого fetch-слоя и независимые geosite mirrors. Они не являются полным install/update/rollback/uninstall E2E; сетевые отказы этих suites моделируются локальными fixtures.

## QEMU: отказ всех updater CDN и восстановление

12 октября на OpenWrt 25.12.5 x86/64 проверен штатный `platform/openwrt/update.sh check` с временным updater root из committed HEAD. Тестовое состояние было `p-86.17/seq=141`. Во время первого запуска старые VPS-IP блокировались nft только на TCP/443, а `raw.githubusercontent.com`, `cdn.jsdelivr.net` и `gh-proxy.com` временно указывали на loopback. `check` завершился `rc=1`, сообщил об ошибке получения манифеста, не оставил частичный `UPDATES.json`; SHA установленного state до/после совпал. Счётчики обоих VPS endpoint — `0`.

Затем исходный `/etc/hosts` восстановлен, VPS drop оставлен активным. Повторный `check` получил валидный подписанный manifest и сообщил `Доступен полный выпуск p-86.18` (`rc=0`); установленное состояние осталось неизменным. SHA `/etc/hosts` до/после совпал. После теста в госте осталась только `inet fw4`, transfer server и временный payload удалены, `/usr/lib/z2k` по-прежнему отсутствовал, package database и постоянные конфиги не менялись.

Это проверяет fail-closed отказ updater при недоступности origin и mirrors и последующее восстановление прямого канала без старой VPS. Установка самого архива, rollback транзакции и uninstall полного продукта этим сценарием не проверялись.

## Повторная проверка отдельности WARP

На feature HEAD `0e748a25` повторно прошли non-TG наборы `test_ow_warp_static.sh` (`92/92`), `test_ow_warp_parity.sh` (`39/39`) и `test_ow_warp_archmap.sh` (`6/6`) — `137/137`. Они подтверждают, что OpenWrt adapter не использует сохранённый старый VPS proxy и сохраняет карту поддерживаемых целей. Это не подтверждает регистрацию аккаунта или живой Cloudflare tunnel; WARP остаётся отдельной опцией и не является транспортом основной VPS-free функциональности.

## QEMU: OpenWrt WARP game-list refresh без VPS и WARP tunnel

На OpenWrt 25.12.5 x86/64 запущен production `files/z2k-update-lists.sh warp-games` с тем же `Z2K_FETCH_VPS_OUT=1` и изолированными каталогами. Тестовый UCI/config fixture задавал `GAME_WARP_ENABLED=0`, поэтому проверялся только список, а не запуск WARP routing. Временный nft output chain блокировал TCP/443 к `213.176.74.63` и `79.137.196.7`; счётчики обоих VPS остались `0`. Proxy-переменные были сняты.

Штатный индекс `YOZH3G/ru-gaming-blocklist` и файлы игр загрузились по прямому/fallback HTTPS пути; helper завершился `rc=0`, обработал `32` списка, `0` недоступных, и создал `32` отфильтрованных `.txt`. Это реальный OpenWrt list-refresh entrypoint, но не запуск crond и не проверка регистрации или туннеля WARP.

После прогона временная таблица и fixture удалены; в QEMU осталась только `inet fw4`, transfer server остановлен. `/usr/lib/z2k`, системные пакеты и постоянные настройки не менялись.

## QEMU: ограничение DoH Insta-IP и кэш при блокировке VPS

В OpenWrt QEMU 25.12.5 x86/64 вызвана production-функция `z2k_ow_insta_resolve_hosts()` из `platform/openwrt/insta-ip.sh` для 12 штатных имён хостов. Временная цепочка nft output блокировала TCP/443 к Cloudflare, Google и AdGuard DoH адресам, а также к обоим старым адресам VPS (`213.176.74.63`, `79.137.196.7`).

Результат: `rc=0`, время выполнения — `30` секунд, возвращены все `12/12` записей из TTL-кэша; SHA-256 кэш-файла до и после совпал (`123b1b057f240ca23c95b6235af41377311a680a601ecac140014ba5ff26a9ce`). Счётчик блокировки DoH — `30` пакетов, счётчик старых VPS — `0`. Обработчик сообщил об исчерпании бюджета и использовал доступные кэш-записи.

Проверялся только слой DNS-разрешения и кэша с тестовыми записями; фильтр IP-кандидатов, HTTPS/SNI-проверка, применение dnsmasq и пользовательский трафик этим прогоном не подтверждаются. После теста временная nft-таблица и гостевые файлы удалены: в госте осталась только `inet fw4`, `/usr/lib/z2k` отсутствовал.

## QEMU: запуск обновления списков WARP через crond без VPS

В OpenWrt QEMU 25.12.5 x86/64 запущен штатный BusyBox `crond -f` с отдельным временным каталогом заданий и единственным заданием `warp-games`. Конфигурация задавала `GAME_WARP_ENABLED=0`, для загрузки включался `Z2K_FETCH_VPS_OUT=1`, переменные прокси снимались. TCP/443 к обоим старым адресам VPS (`213.176.74.63`, `79.137.196.7`) блокировался отдельной временной nft-таблицей.

Планировщик выполнил задание через `56` секунд: `rc=0`, создано `32` списка, `0` недоступных; штатный журнал сообщил `warp game lists refreshed (32 lists, 0 unavailable)`. Счётчики блокировки старых VPS — `0`.

Проверено одно изолированное задание планировщика и только обновление списков; маршрутизация WARP, регистрация и туннель не запускались. После теста временный `crond` остановлен; штатный процесс остался с каталогом `/etc/crontabs`. Временный каталог заданий, тестовые файлы и nft-таблица удалены; в госте осталась только `inet fw4`, `/usr/lib/z2k` отсутствовал.

## QEMU: updater `check` из crond при блокировке VPS

В OpenWrt QEMU 25.12.5 x86/64 с отдельным временным каталогом заданий запущено единственное задание планировщика с `platform/openwrt/update.sh check`. Начальная тестовая запись: `p-86.17`, `seq=141`; `Z2K_FETCH_VPS_OUT=1`, переменные прокси сняты. TCP/443 к старым VPS адресам (`213.176.74.63`, `79.137.196.7`) блокировался временной nft-таблицей. Изолированная копия включала зафиксированные файлы updater; незакоммиченные изменения общего рабочего дерева в неё не включались.

Планировщик выполнил проверку через `47` секунд. Штатный updater принял подписанный manifest `p-86.18`, `seq=142` и сообщил `Доступен полный выпуск p-86.18`; `rc=0`. SHA-256 файла installed-release до и после совпал (`3a3bf7cb95173ccf931249ef8f0e54ea179ae91ca761a92681338b062a34ad37`), счётчики старых VPS — `0`.

Проверена только команда `check`, которая не меняет установленный выпуск: архив не загружался и не устанавливался; команды apply, rollback и uninstall не запускались. После теста временный `crond` остановлен, тестовые файлы и nft-таблица удалены; в госте осталась штатная `inet fw4`, `/usr/lib/z2k` отсутствовал.

## QEMU: Insta-IP пустой кэш после уточнения диагностики

Проверена production-функция `z2k_ow_insta_resolve_hosts()` из `platform/openwrt/insta-ip.sh` на OpenWrt 25.12.5 x86/64; SHA-256 развернутого адаптера `a8f97ec846d29ed2deb590bd43bab0ea69c29d8c58ab1eaaaa8132ec4f00c772`. Изолированный тест блокировал TCP/443 к Cloudflare, Google и AdGuard DoH IP и к старым VPS IP `213.176.74.63` и `79.137.196.7`; использовался пустой кэш и бюджет 30 секунд.

Итерация 1 использовала один hostname: resolver вернул `rc=1` за 9 секунд, кэш и результат остались пустыми. Эта fixture не исчерпала общий deadline, поэтому диагностическая ветка таймаута не была достигнута; условие теста правильно потребовало расширить fixture.

Итерация 2 использовала все 12 штатных hostname: `rc=1`, `30` секунд, `0` строк результата, кэш не создан. Журнал сообщил `Срок прямых DoH-запросов исчерпан; кэш не предоставил доступных записей`. Счётчик заблокированных DoH-запросов — `30`; оба счётчика старых VPS — `0`. После trap/cleanup в госте осталась только таблица `inet fw4`, `/usr/lib/z2k` отсутствовал.

Это подтверждает только поведение production resolver при пустом кэше и недоступных DoH endpoint. Установка продукта, отбор кандидатов по диапазонам, HTTPS/SNI probe, применение dnsmasq и пользовательский трафик этим прогоном не подтверждаются. После исправления также прошли `test_ow_insta_runtime.sh` (`37/37`), `test_fetch_vps_layer_budget.sh` (`48/48`), `test_ow_schedule.sh` (`40/40`) и `sh -n` для адаптера и его suite.

## GitHub Actions: удаление старых VPS и Telegram Go jobs

В feature-коммите `f7ee6f9d` удалены `vps/`, `vps-relay/` и `mtproxy-client/`; Go module, reproducibility и security jobs для `vps-relay`/старого MTProxy удалены. CI run `38238233556` подтвердил Rust TG build ARM64/x86_64, четыре OpenWrt acceptance shards и переход p-86.17 → r-86.5. Последующий локальный `scripts/ci_local.sh` прошёл: 220 suites, 4 457 проверок, 0 failures; 7 проверок были явно пропущены как непроверенные. Целевые rootfs проверки прошли: stage `349/349`, archive packer `9/9`; старого имени нет в полном fallback и per-arch архивах. Исторические ссылки в неизменённом подписанном `UPDATES.json` сохранены.

Уточнение: run `38238233556` проверял исторический r-86.5 и не принимал текущий архив. Текущий локальный p-86.17 → p-86.18 generic candidate прошёл acceptance; CI workflow теперь проверяет этот актуальный переход. Generic fallback содержит только переходную legacy-ссылку, которая удаляется при первом старте TG адаптера; архитектурные архивы и staging legacy-имени не содержат.

## GitHub Actions: переносимость shell и регрессия WARP (`921c4d93`)

Run: [GitHub Actions `38222770881`](https://github.com/t0fox/z2kOW/actions/runs/38222770881). CI использовал ShellCheck `0.9.0` и нашёл `SC2097`/`SC2098` в пяти вызовах `test_ow_bootstrap_manifest_mirrors.sh`; `T` и `FUNCTION_FILE` экспортированы один раз до вызовов. Локально suite прошёл `13/13`, ShellCheck `0.10.0` завершился с кодом `0`.

Тот же запуск выявил `test_ow_forbidden.sh` failure из-за класса `tr '[:upper:]' '[:lower:]'` в OpenWrt WARP adapter. Нормализация заменена на `LC_ALL=C tr 'A-Z' 'a-z'`; после исправления `test_ow_forbidden.sh` прошёл `4/4`, `test_ow_warp_static.sh` — `92/92`, `test_ow_warp_parity.sh` — `39/39`.

`test_ow_insta_refresh_noop_backup.sh` завершился ошибкой в CI, но локально повторно прошёл `11/11`; первопричина CI расхождения не подтверждена. Несколько других job в запуске также были красными. Поэтому этот CI run не считается успешным; нужна повторная проверка после отправки исправлений и отдельная диагностика оставшихся ошибок.

## QEMU: успешное удаление после исправления загрузки stop verifier

12 октября на отдельной OpenWrt 25.12.5 x86/64 lifecycle-VM после production-подписанной переустановки `p-86.18` повторный `z2kow uninstall` воспроизвёл ошибку: `z2k_ow_stop_verify: not found`. Причина — проверка определялась только в `/etc/init.d/z2k`, а uninstaller загружал платформенные адаптеры отдельно; после частичного удаления init-скрипта тот же порядок мешал безопасному повтору.

Минимальное исправление перенесло verifier в общий `platform/openwrt/firewall.sh`, который загружают обе стороны, и научило проверку остатка установки игнорировать пустой `/etc/z2k/state` вместе с сохранёнными данными WARP. `test_ow_uninstall_parity.sh` прошёл `88/88`.

Для фактической проверки на disposable VM перед повтором сохранены копии двух затрагиваемых скриптов в `/tmp/vps-free-uninstall-backup`; обновлённые `uninstall.sh` и `firewall.sh` переданы по SSH в установленный экземпляр. `Z2K_UNINSTALL_CONFIRMED=1 /usr/bin/z2kow uninstall` завершился с `rc=0`. После удаления CLI, init и `/usr/lib/z2k` отсутствовали, WebPanel не отвечал на `127.0.0.1:8088`, пользовательская UCI-настройка `option addnhosts '/etc/vps-free-sentinel.hosts'` сохранилась. Временные правила блокировки обоих VPS endpoint остались с нулевыми пакетами; основной ruleset содержал `inet fw4`.

Граница результата: это фактическая проверка uninstaller с вручную развернутыми двумя исправленными shell-файлами поверх production-подписанного установленного выпуска, а не подписанная установка полного feature payload. Ветка остаётся без merge/release; `UPDATES.json`, подпись и `seq=142` не менялись.
