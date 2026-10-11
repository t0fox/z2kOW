# План работ: независимость OpenWrt от старого VPS

Рабочая ветка: `feat/vps-independence`. Основа: одобренная спецификация `docs/superpowers/specs/2026-10-12-vps-independence-design.md`.

## Защитные условия

- Перед каждым этапом сверять текущую ветку и статус; все новые изменения делать только в feature worktree.
- Не включать исходные unstaged/untracked изменения TG-прототипа в сторонние коммиты. Считать их входной базой и продолжать поверх неё.
- Не менять `UPDATES.json`, upstream tag `p-86.18`, `seq 142`, pinned Rust version или подписи.
- Не удалять Keenetic и relay server-side код, пока статический и packaging аудит не докажет, что это безопасно.
- Live-router действия запрещены до подтверждения адреса через существующий доверенный SSH alias/коннектор и фиксации baseline/rollback. Не угадывать адрес.
- Endpoint block должен совпадать только с подтверждённым VPS IP/именем, быть ограничен тестовым traffic path и автоматически сниматься watchdog-ом.

## Этап 1. Закрыть аудит runtime и packaging

1. Инвентаризировать все ссылочные пути VPS: GitHub fetch layers, WARP API proxy, Telegram relay, Insta-IP resolver, диагностика, DNS pins и server-side компоненты.
2. Проследить OpenWrt rootfs staging от source-файлов до установленных путей и служб; подтвердить, какие общие скрипты source-ятся OpenWrt runtime, а какие принадлежат только Keenetic.
3. Проверить `install_release` install/update/rollback/uninstall ownership и сохранение пользовательских UCI/dnsmasq/WARP данных.
4. Составить фактическую матрицу ABI из `build-release.sh`, `arch.sh` и runtime artifact tests. Для Telegram отдельно проверить Rust toolchains/targets и текущие staged binaries.
5. Добавить в локальную evidence-запись выводы, команды, результаты и неразрешённые вопросы; секреты не сохранять.

Выход этапа: перечень допустимых OpenWrt точек изменения, полный inventory VPS-функций и проверенная матрица архитектур.

## Этап 2. Реализовать независимые OpenWrt замены тест-first

Для каждой функции сначала добавить минимальный падающий тест, затем исправление и пройти относящиеся тесты.

1. Fetch: на стороне OpenWrt отключить VPS слой во всех entry points (`z2k.sh`, `utils.sh`, updater/list/geosite/install) единым адаптерным механизмом. Проверить прямой GitHub, каждое настроенное зеркало, hash verification, ETag и честную ошибку, когда все источники недоступны. Не менять общий Keenetic default.
2. WARP: убрать OpenWrt VPS proxy fallback из нового запуска, default config и миграции. Проверить, что новая установка использует direct control plane и старые пользовательские настройки не интерпретируются как обязательный relay. Решение о миграции существующего proxy-за значения принять только после тестов совместимости/rollback.
3. Insta-IP: установить, входит ли общий `z2k-insta-ip-refresh.sh` в OpenWrt rootfs и вызывается ли его OpenWrt cron/update/diagnostics. Если входит, не отключать resolver до определения API-контракта и независимого источника. Доступный dnsmasq backend должен сохранять чужие `addnhosts` записи и откатывать только собственную регистрацию.
4. Telegram: продолжить существующий Rust prototype, сохраняя его тесты/патчи. Проверить port/CIDR policy, оригинальный dst, runtime fallback и graceful rollback. Legacy заглушку/переходный архив сохранять до клиентской E2E приёмки.
5. После каждого самостоятельного изменения создать атомарный commit из явно выбранных файлов; перед commit проверить status и полный staged diff.

Выход этапа: воспроизводимые тесты и минимальные OpenWrt-only изменения для каждой заменяемой функции.

## Этап 3. Сборка и архитектурное подтверждение

1. Собрать полный OpenWrt release rootfs по штатному `scripts/openwrt/build-release.sh` без изменения production manifest.
2. Для `arm64`, `arm`, `x86_64`, `x86`, `mips`, `mipsel`, `riscv64` проверить staging, ABI selection, install и наличие штатных функций.
3. Для Rust Telegram отдельно зафиксировать target, toolchain, build result, ELF ABI, dynamic dependencies, минимальный запуск и причину отказа, если архитектура не поддержана. Нельзя засчитывать заглушку как реализацию.
4. Сверить размеры/hash кандидатов и сохранить отдельные локальные unsigned artifacts с provenance; ничего не публиковать.

Выход этапа: таблица по каждой архитектуре и воспроизводимые локальные кандидаты.

## Этап 4. Реальный E2E на OpenWrt с точечной блокировкой VPS

### Подготовка

1. Подтвердить целевой тестовый router из существующей SSH конфигурации/одобренного коннектора. Снять модель, OpenWrt/build, ABI, `p-86.18/seq 142`, сервисы, маршруты, firewall ruleset, хеши бинарников и копии изменяемых файлов.
2. Подготовить watchdog вне изменяемого сервиса: по таймауту/потере связи вернуть точные копии файлов, удалить только принадлежащие тесту nft rules и перезапустить исходные службы.
3. Установить unsigned candidate overlay, проверить baseline доступность SSH/WAN и сервисов; затем добавить точечный временный блок только старому VPS endpoint. Снимать и повторно проверять network baseline.

### Проверки

1. Telegram: через реальное клиентское устройство проверить соединение после очистки/перезапуска, вход, отправку/получение текста и медиа; записать логи/времена и убедиться, что нет соединений к VPS. Handshake Rust теста сам по себе недостаточен.
2. Fetch/update: скачать и сверить содержимое/хеши через direct/mirrors; проверить update check без production install, затем отдельный upgrade candidate.
3. WARP: проверить чистую регистрацию, лицензирование, рестарт daemon, разрешённый тестовый traffic path и сохранённое состояние при недоступном VPS.
4. Insta-IP: если OpenWrt runtime использует этот механизм, доказать refresh без endpoint и сохранность сторонних dnsmasq entries. Если механизм не установлен/не вызывается, зафиксировать packaging/runtime доказательство.
5. Проверить фактические firewall diff и endpoint counters; снять тестовый блок, дождаться watchdog confirmation и сравнить исходные hashes/config/service state.
6. Для каждого цикла вести запись reproduction → fix → build → deployment → result → restore/next iteration.

Выход этапа: подписанные локально timestamped evidence-записи и результат каждой функции (pass/fail/blocked).

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
5. Оставить ветку `feat/vps-independence` изолированной. PR, merge и production release не создавать.

## Стоп-условия

- Нет доказанного безопасного router target или baseline rollback: продолжать offline аудит/сборки; live E2E остаётся незакрытым.
- Cloudflare direct registration не работает: считать WARP замену не принятой и выяснить сетевое ограничение, не оставлять silent fallback к VPS.
- Для Rust TG target не собирается/не работает на ABI: явно зафиксировать ограничение и не выдавать поддержку; не отключать legacy функцию до согласованной функциональной замены.
- Неизвестен контракт Insta-IP API: не заменять его неподтверждённым публичным сервисом.
- Любая регрессия rollback/uninstall или сторонних UCI/nft правил: остановить live rollout, восстановить baseline, исправить тесты и повторить цикл.
