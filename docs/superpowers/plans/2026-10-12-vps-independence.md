# План работ: независимость OpenWrt от старого VPS

Рабочая ветка: `feat/openwrt-vps-free`. Основа: одобренная спецификация `docs/superpowers/specs/2026-10-12-vps-independence-design.md`, уточнённая пользователем: основным функциям не разрешено полагаться на VPS, VPN, WARP или обязательный внешний proxy; WARP — опционален.

## Защитные условия

- Перед каждым этапом сверять текущую ветку и статус; все новые изменения делать только в feature worktree.
- Не включать исходные unstaged/untracked изменения TG-прототипа в сторонние коммиты. Считать их входной базой и продолжать поверх неё.
- Не менять `UPDATES.json`, upstream tag `p-86.18`, `seq 142`, pinned Rust version или подписи. Не обходить `install_release(tag)` и штатный rollback.
- Не удалять Keenetic и relay server-side код, пока статический и packaging аудит не докажет, что это безопасно.
- Live-router действия запрещены до подтверждения адреса через существующий доверенный SSH alias/коннектор и фиксации baseline/rollback. Не угадывать адрес.
- Endpoint block должен совпадать только с подтверждённым VPS IP/именем, быть ограничен тестовым traffic path и автоматически сниматься watchdog-ом.

## Этап 1. Закрыть аудит runtime и packaging

1. Инвентаризировать все ссылочные пути VPS/прокси: GitHub fetch/bootstrap/release layers, WARP API proxy, Telegram relay, Insta-IP resolver, DNS, диагностика, cron и server-side компоненты.
2. Проследить OpenWrt rootfs staging от source-файлов до установленных путей и служб; подтвердить, какие общие скрипты source-ятся OpenWrt runtime, а какие принадлежат только Keenetic.
3. Проверить `install_release` install/update/rollback/uninstall ownership и сохранение пользовательских UCI/dnsmasq/WARP данных.
4. Составить фактическую матрицу ABI из `build-release.sh`, `arch.sh` и runtime artifact tests. Для Telegram отдельно проверить Rust toolchains/targets и текущие staged binaries.
5. Добавить в локальную evidence-запись выводы, команды, результаты и неразрешённые вопросы; секреты не сохранять.

6. Подготовить воспроизводимую QEMU OpenWrt среду и зафиксировать образ/sha256/QEMU version/network topology. Для всех сетевых запросов описать контролируемые failure seams.

Выход этапа: перечень допустимых OpenWrt точек изменения, полный inventory VPS-функций, проверенная матрица архитектур и QEMU baseline.

## Этап 2. Реализовать независимые OpenWrt замены тест-first

Для каждой функции сначала добавить минимальный падающий тест, затем исправление и пройти относящиеся тесты.

1. Fetch/bootstrap/release: отключить VPS layer во всех OpenWrt entry points и добавить прямой HTTPS плюс несколько независимых mirror URLs. Каждый объект проверяется подписью существующего release flow и/или digest из доверенного manifest. Сохранить `UPDATES.json`, `install_release(tag)` и rollback; отказ всех источников должен быть видимым и оставлять предыдущую установку рабочей.
2. WARP: убрать OpenWrt VPS proxy fallback. WARP не может быть fetch/DNS/TG fallback. Существующий явный non-VPS user proxy остаётся отдельной настройкой только WARP; старый VPS host игнорируется.
3. Insta-IP: helper подтверждённо входит в OpenWrt rootfs и вызывается list refresh. Реализовать локальный resolver union, TTL, кэш кандидатов, Meta CIDR filtering, HTTPS/SNI probe, атомарную замену и сохранение прежних записей при сетевом отказе. Проверить dnsmasq ownership и user records.
4. Telegram: продолжить существующий Rust prototype, сохраняя его тесты/патчи. Проверить port/CIDR policy, оригинальный dst, runtime fallback и graceful rollback. Legacy заглушку/переходный архив сохранять до клиентской E2E приёмки.
5. После каждого самостоятельного изменения создать атомарный commit из явно выбранных файлов; перед commit проверить status и полный staged diff.

Выход этапа: воспроизводимые тесты и минимальные OpenWrt-only изменения для каждой заменяемой функции.

## Этап 3. Сборка и архитектурное подтверждение

1. Собрать полный OpenWrt release rootfs по штатному `scripts/openwrt/build-release.sh` без изменения production manifest.
2. Для `arm64`, `arm`, `x86_64`, `x86`, `mips`, `mipsel`, `riscv64` проверить staging, ABI selection, install и наличие штатных функций.
3. Для Rust Telegram отдельно зафиксировать target, toolchain, build result, ELF ABI, dynamic dependencies, минимальный запуск и причину отказа, если архитектура не поддержана. Нельзя засчитывать заглушку как реализацию.
4. Сверить размеры/hash кандидатов и сохранить отдельные локальные unsigned artifacts с provenance; ничего не публиковать.

Выход этапа: таблица по каждой архитектуре и воспроизводимые локальные кандидаты.

## Этап 4. QEMU и реальный E2E с точечной блокировкой VPS

### QEMU

1. Загрузить официальный OpenWrt x86/64 combined образ и сверить checksum с опубликованным официальным индексом.
2. Поднять гостя с отдельными WAN/LAN интерфейсами; настроить LAN client namespace/VM без второго выхода в интернет.
3. Выполнить clean install и acceptance candidate; управлять DNS/WAN/CDN/VPS outage через гостевые nft rules или локальный controllable resolver, не меняя host network.
4. Проверить candidate fetch, signed manifest, artifact digest, install/update/rollback/uninstall, перезапуск во время download/refresh и сохранность настроек при отключённых VPS/VPN/WARP/proxy.
5. Сохранить QEMU command line, image SHA256, guest version, test logs и все временные правила/restore proof.

### Подготовка

1. Подтвердить целевой тестовый router из существующей SSH конфигурации/одобренного коннектора. Снять модель, OpenWrt/build, ABI, `p-86.18/seq 142`, сервисы, маршруты, firewall ruleset, хеши бинарников и копии изменяемых файлов.
2. Подготовить watchdog вне изменяемого сервиса: по таймауту/потере связи вернуть точные копии файлов, удалить только принадлежащие тесту nft rules и перезапустить исходные службы.
3. Установить unsigned candidate overlay, проверить baseline доступность SSH/WAN и сервисов; затем добавить точечный временный блок только старому VPS endpoint. Снимать и повторно проверять network baseline.

### Проверки

1. Telegram: в QEMU и, если доступно, на реальном LAN client проверить вход, текст и медиа после очистки/перезапуска; записать логи/времена и исключить обращения к VPS. WSS handshake недостаточен.
2. Fetch/update: скачать и сверить содержимое/хеши через direct/mirrors; проверить update check без production install, затем отдельный upgrade candidate.
3. WARP: проверить чистую регистрацию, лицензирование, рестарт daemon, разрешённый тестовый traffic path и сохранённое состояние при недоступном VPS.
4. Insta-IP: если OpenWrt runtime использует этот механизм, доказать refresh без endpoint и сохранность сторонних dnsmasq entries. Если механизм не установлен/не вызывается, зафиксировать packaging/runtime доказательство.
5. Проверить фактические firewall diff и endpoint counters; снять тестовый блок, дождаться watchdog confirmation и сравнить исходные hashes/config/service state.
6. Для каждого цикла вести запись reproduction → fix → build → deployment → result → restore/next iteration.

Выход этапа: timestamped QEMU/client evidence, измерения задержки/TTL/failover и результат каждой функции (pass/fail/blocked).

## Этап 5. Очистка только после приёмки

1. Удалить только те OpenWrt VPS defaults/compatibility code, чьи функции прошли реальные проверки и больше не вызываются.
2. Сохранить shared Keenetic behavior и VPS server deployment, если аудит не доказал отсутствие других клиентов.
3. Удалять transition payload и legacy references только после подтверждения clean install, upgrade и rollback на установленных устройствах.

Выход этапа: небольшой OpenWrt-ограниченный diff и сохранённая возможность восстановить предыдущую установку.

## Этап 6. Регрессии и приёмочная матрица

1. Прогнать targeted OpenWrt tests, тесты функций, release/rootfs packaging tests, весь релевантный CI и все поддерживаемые архитектуры.
2. На тестовом устройстве проверить clean install, update, rollback и uninstall, включая пользователя с существующими dnsmasq/UCI/WARP настройками.
3. Сверить upstream tag/seq/pin и выполнить полный git diff/status audit; проверить отсутствие лишних секретов и артефактов live-debug в source package.
4. Подготовить таблицу старая функция → новая реализация → evidence → архитектуры → статус; приложить E2E, CI, diffstat, остаточные ограничения и merge-readiness.
5. Оставить ветку `feat/openwrt-vps-free` изолированной. PR, merge и production release не создавать.

## Стоп-условия

- Нет доказанного безопасного router target или baseline rollback: продолжать offline аудит/сборки; live E2E остаётся незакрытым.
- Cloudflare direct registration не работает: считать опциональную WARP direct path ограниченной; она не может стать заменой базовым функциям или silent fallback к VPS.
- Для Rust TG target не собирается/не работает на ABI: явно зафиксировать ограничение и не выдавать поддержку; не отключать legacy функцию до согласованной функциональной замены.
- Неизвестен контракт Insta-IP API: не заменять его неподтверждённым публичным сервисом.
- Любая регрессия rollback/uninstall или сторонних UCI/nft правил: остановить live rollout, восстановить baseline, исправить тесты и повторить цикл.
