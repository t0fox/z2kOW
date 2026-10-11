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
| Instagram по адресу, полученному локальным DoH | `https://www.instagram.com/robots.txt`: HTTP 200, 7 528 байт содержимого. Это проверка HTTP-сервиса и тела ответа, а не только TLS handshake. Счётчик блокировки VPS остался 0. |
| RT proxy runtime | Собранный статический `z2k-rt-proxy` x86/64 запустил `--help` в OpenWrt 25.12.5. В двух E2E upstream pool был заведомо недоступен (`127.0.0.1:1`): Cloudflare ответил через TLS 1.3 и полный `GET /cdn-cgi/trace` с HTTP 200 (`warp=off`); `rutracker.org/forum/index.php` ответил HTTP 200, 96 400 байт HTML, TLS verify 0, direct fallback через `172.67.182.196`. В госте были только `lo`, `eth0`, `eth1`, `br-lan`, не было `/dev/net/tun` и HTTP(S)/ALL proxy-переменных. Счётчики блокировки обоих VPS IP — 0; процесс, тестовые файлы и nft-таблицы удалены. |
| Проверка системных часов | Изолированная `clock_skew_vs_relay` в госте использовала прямой HTTPS Date, вернула расхождение `0` секунд; старые VPS IP были заблокированы, оба счётчика — 0. Временный nft-набор и функция удалены. |
| Отказ всех трёх DoH IP | Заблокированы `1.1.1.1`, `8.8.8.8`, `94.140.14.14`; счётчик правила — 9 пакетов. Функция вернула кэшированные адреса. |
| Просроченный кэш | При сдвиге тестового времени за TTL и stale grace функция завершилась кодом 1 и не вернула адреса. |
| dnsmasq addnhosts | Через UCI зарегистрирован временный файл, запись `192.0.2.123 vps-free-test.invalid` разрешилась через `192.168.1.1`. После удаления адаптер убрал собственную ссылку и файл; исходный UCI export восстановлен. |
| Bootstrap metadata | В текущей QEMU VM прямой GitHub и jsDelivr отдали идентичные `UPDATES.json`/`.sig`; SHA-256 манифеста `b2e3c96b04d1a36c23e22942e2878a42810a98266143b63175db4eeeee86759e`, подпись успешно проверена ключом с ID `916b1459a03961d66af48ddb2165afbed3c0d7445f75c8b7c95adbb5fc044bae`. Старые VPS IP блокировались nft; счётчики — 0. Временные файлы и правило удалены. |
| Bootstrap manifest helper | Production-функция `fetch_verified_manifest` выполнена в OpenWrt QEMU 25.12.5 с реальным `jsonfilter` и временно установленным из официального feed `openssl-util`. В test wrapper отказ raw GitHub origin был задан искусственно; manifest, открытый ключ и подпись реально скачаны с jsDelivr, закреплённый fingerprint и Ed25519 подпись проверены OpenSSL. SHA-256 manifest `b2e3c96b04d1a36c23e22942e2878a42810a98266143b63175db4eeeee86759e`, key ID `916b1459a03961d66af48ddb2165afbed3c0d7445f75c8b7c95adbb5fc044bae`. Два старых VPS IP были заблокированы nft, счётчики — 0. После теста `openssl-util` и его две зависимости удалены; `/etc/apk/world` и `/lib/apk/db/installed` совпали с pre-test копиями побайтно, бинарник, временный cache и nft-таблица очищены. |
| Release downloader | В госте вызван `z2k_ow_download`: прямой файл `docs/openwrt-release-operations.md` принят при SHA-256 `83e4470b4318df3b7ab936022ce70aa75a55befa28bb14e111f7562a3eacc88c`, размер 7 582 байта. При блокировке двух VPS-IP и всех четырёх адресов `raw.githubusercontent.com` тот же ожидаемый digest/размер получен через `ghproxy.net`; проверка прошла. Это проверка общего загрузчика, не скачивание rootfs релиза. |
| Geosite release asset при отключённом VPS | Вызван штатный `fetch_to_tmp ru-blocked.txt` из текущего `files/z2k-geosite.sh`. В госте `github.com` временно направлялся на loopback, а nft блокировал оба VPS-IP. Origin не отвечал; загрузчик получил HTTP 200 через `ghproxy.net`, 1 731 646 байт, SHA-256 `8b8d8d1ce37edbdc550bbb73f473f072b15432bf42b1fac5b35f95a603fec77d`. Хеш и размер совпали с прямой контрольной копией на хосте. Счётчики блокировки обоих VPS-IP: 0. После прогона `/etc/hosts` возвращён из копии, временная nft-таблица удалена. |
| Перезапуск VM | OpenWrt загрузился повторно, WAN и HTTPS к GitHub API работали. Восстановление SSH потребовало временно добавить правило только для TCP/22 на WAN тестовой VM; правило удалено после проверки. |

Проверялись адаптерные скрипты напрямую в VM; полный продуктовый rootfs туда не устанавливался.
В чистом базовом образе `curl` отсутствовал. Для сетевых сценариев его установили в госте; штатный OpenWrt release installer включает `curl` в runtime-пакеты, а bootstrap устанавливает `jsonfilter`. Поэтому это не требование к предустановленному образу, но проверка полного package lifecycle остаётся открытой.

## Отдельный бинарник WARP daemon

`z2k-warpd` собирался отдельно от release builder командой Go с OpenWrt build tag и `openwrt-overlay/overlay.json`. Все семь target получили корректный ELF machine/endianness и статическую линковку: `arm64` (AArch64), `arm` (ARM EABI5), `amd64` (x86-64, `CGO_ENABLED=0`), `386` (i386), `mips` (MIPS32 big-endian, softfloat), `mipsle` (MIPS32 little-endian, softfloat), `riscv64` (RISC-V double-float ABI).

`GOTOOLCHAIN=local go test -tags openwrt -overlay openwrt-overlay/overlay.json ./...` прошёл для всех пакетов `z2k-warpd`. Это доказывает компиляцию и unit suite; кроме smoke-проверки x86/64 ниже, собранные бинарники не запускались в QEMU и на реальных устройствах.

В OpenWrt 25.12.5 x86/64 VM временно запущен собранный `amd64` бинарник с командой `version`; получен ответ `z2k-warpd dev`. Временный файл из `/tmp` удалён. Это smoke-проверка запуска на x86/64, не проверка регистрации в Cloudflare или работы туннеля.

## Отдельный бинарник RT proxy

`rt-proxy` unit suite прошёл. По release target matrix собраны статические `z2k-rt-proxy` для `arm64`, `arm`, `amd64`, `386`, `mips` (big-endian softfloat), `mipsle` (little-endian softfloat) и `riscv64`; x86/64 бинарник выполнил `--help` в OpenWrt QEMU.

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
- WARP остаётся отдельной опциональной функцией. В проверенном `HEAD` OpenWrt WARP registration/license всё ещё имеют fallback на собственный VPS-релей (`platform/openwrt/warp.sh`); значит, VPS-free поведение этого отдельного компонента не подтверждено. Фактическое соединение с Cloudflare в любом случае требует доступного внешнего маршрута и не заменяет VPS-функции.
- Наличие нескольких внешних DoH/CDN endpoints снижает зависимость от одного провайдера, но не обеспечивает работу при полном отсутствии Интернет-доступа.

## Карта OpenWrt VPS-зависимостей

| Функция | Найденная зависимость | Реализация/статус OpenWrt |
|---|---|---|
| Bootstrap | GitHub release metadata и payload | Прямой HTTPS, независимый jsDelivr для пары metadata/key, зеркала для payload; подпись и SHA/размер остаются обязательными. Размер и SHA-ошибки различаются в диагностике; узкий тест загрузчика пройден. Полный bootstrap на устройстве не проверен. |
| Обновление продукта | GitHub release, `UPDATES.json`, `install_release(tag)` | Существующая транзакция/подпись и rollback сохранены; прямой путь и независимые зеркала. Полное обновление и rollback продукта в QEMU ещё не принимались. |
| `z2k_fetch` и списки | Исторический VPS `--resolve` в shared transport | OpenWrt экспортирует `Z2K_FETCH_VPS_OUT=1`; расписание для warp-games задаёт его явно. В geosite ранее оставалась отдельная копия Layer 0 — теперь она уважает флаг и после origin пробует HTTPS зеркала. Geosite подтверждён live с заблокированным origin. |
| Insta-IP refresh | HMAC `/resolve` на VPS (Keenetic path) | OpenWrt использует локальный DoH discovery, проверку кандидатов, TTL, кэш и ограниченное stale восстановление; общий Keenetic путь сохранён. QEMU подтвердил DoH/кэш и отказ поставщиков. |
| DNS LAN | DNS провайдера/настройка роутера; не старый VPS | Используются локальные средства OpenWrt/dnsmasq и существующая upstream DNS конфигурация. Проверена запись addnhosts; отказ всех DoH кандидатов не выдаёт просроченный IP. |
| WARP | Cloudflare registration/license использовали собственный VPS proxy как fallback | В проверенном `HEAD` OpenWrt adapter всё ещё задаёт старый VPS proxy по умолчанию и использует его после прямой ошибки (`platform/openwrt/warp.sh`). Поэтому VPS-free путь даже для отдельной опции WARP не подтверждён; полное соединение с Cloudflare требует внешнего доступа. Текущие незакоммиченные изменения адаптера не входят в этот аудит и здесь не оцениваются. |
| RuTracker RT proxy | Upstream pool `ps1.blockme.site` — независимая сторонняя egress-услуга | Proxy engine не зависит от нашей VPS и по умолчанию разрешает прямое соединение для явного списка RuTracker hostnames, если pool не смог обслужить запрос. Внешний pool не обязателен, когда сайт доступен напрямую; если провайдер блокирует прямой маршрут и сторонний pool недоступен, обход без любого внешнего egress невозможен. Варианты: прямой доступ, сторонний pool или собственный egress по выбору оператора. Unit suite, семь сборок и прямые TLS/HTTP E2E в QEMU прошли: Cloudflare и сам `rutracker.org` вернули HTTP 200 при недоступном pool и заблокированных VPS IP. |
| Диагностика | Общий `files/z2k-diag.sh` проверял VPS ping и сверял часы через relay | OpenWrt пропускает VPS ping и проверяет часы по прямому HTTPS Date от Cloudflare с Google как вторым источником; Keenetic сохраняет прежний ping и закреплённый relay. Изолированный тест `7/7`; QEMU clock probe при блокировке VPS ранее вернул `0` секунд расхождения. |
| Telegram | Пользователь исключил компонент из текущей работы | Не проверялся и не изменялся в рамках этой приёмки; другой агент отвечает за него. |

Отдельные legacy VPS-строки остаются в shared Keenetic и в OpenWrt WARP adapter; путь clock-skew теперь выбирается по платформе и на OpenWrt использует прямые origin’ы. Полный жизненный цикл релизов остаётся пунктом незавершённой приёмки.
