# Карта вызовов и контрактов WARP для OpenWrt

Срез на 2026-10-15. Карта описывает текущий путь OpenWrt после переноса управления WARP в одноразовый Rust CLI. Go z2k-warpd по-прежнему владеет туннелем и транспортами; procd владеет процессом Go.

## Точки входа и контракты

| Вызывающая сторона | Точка входа | Контракт |
|---|---|---|
| WebPanel | webpanel/cgi/actions.sh → platform/openwrt/warp.sh | Команды install, enable, disable, restart, remove, license, ipset, migrate и status. License поступает через stdin. Ответ status сохраняет формат key=value и поля enabled/wdtt. |
| Загрузка OpenWrt | platform/openwrt/files/etc/init.d/z2k → z2k_ow_warp 1 | Shell собирает argv/env для z2k-warpd run и регистрирует команду в procd. Rust проверяет конфигурацию и готовность, затем настраивает WARP-маршрутизацию. |
| Сеть и firewall | init/hotplug → z2k_ow_warp rules, 0, cleanup | Shell передаёт событие в Rust. Повторное reconcile идемпотентен; неопределённость чтения откладывает решение, а не снимает исправный маршрут. |
| Cron | platform/openwrt/warp-check.sh check → health-check | Одноразовый вызов контроллера наблюдает состояние, восстанавливает подтверждённые объекты и оставляет fail-open при ошибках. Второй демон не запускается. |
| Обновление Go ELF | platform/openwrt/warp-proc.sh stop/start → engine-refresh | Rust использует общий mutation lock, согласует остановку/перезапуск движка с PBR и дожидается готовности в ограниченном окне. procd остаётся владельцем процесса. |
| Обновление игровых списков | files/z2k-update-lists.sh → warp.sh ipset/reload-lists | Существующие URL, конфигурацию и пути файлов сохраняет updater. Rust фильтрует и атомарно применяет наборы; общий lock согласует updater с lifecycle и release. |
| Удаление WARP или приложения | warp.sh remove; затем platform/openwrt/uninstall.sh | Rust снимает только принадлежащие WARP маршруты и nft-объекты. Регистрация, license, пользовательские списки и настройки сохраняются при обновлении и удалении WARP. |

## Граница между Shell, Rust и Go

- platform/openwrt/warp.sh загружает OpenWrt paths/env, собирает procd argv/env и диспетчеризует lifecycle, status, health и system events в z2k-warp-controller. Резервная бизнес-логика на Shell отсутствует.
- platform/openwrt/warp-domain.sh передаёт контроллеру пути domain lists и проверку procd readiness. platform/openwrt/warp-proc.sh передаёт engine-refresh. Оба остаются короткими OpenWrt entrypoints.
- z2k-warp-controller выполняет lifecycle и конечный автомат состояния, чтение настроек без source, регистрацию и управление лицензией, проверки готовности и восстановление, списки и domain observer, nftables, PBR, проверку владельца маршрутов и блокировки.
- nftables применяется пакетно через nft -f с проверкой статуса и последующим чтением фактического состояния. Маршруты изменяются только после проверки owner record; исправный reconcile не должен мутировать таблицу 989.
- procd запускает и перезапускает z2k-warpd. Go-движок сохраняет формат status/device данных, регистрацию, выбор Cloudflare Edge, WireGuard и MASQUE H2.

## Данные и архитектуры

- Пользовательская конфигурация: /etc/z2k/config. Постоянное состояние WARP: /etc/z2k/state/warp. Пользовательские списки: /etc/z2k/user-lists/warp. Временные lock и recovery markers находятся в /tmp.
- WARP полностью опционален. Отсутствие Rust ELF не включает Shell fallback; остальные подсистемы z2kOW не вызывают WARP-контроллер.
- Проверенные Rust ABI из текущей таблицы: ARM, AArch64, MIPS, MIPSel, riscv64, x86 и x86_64. Для каждого в этой рабочей сессии выполнены production-profile сборка и запуск version через соответствующий QEMU-user.
- mips64le и ppc64 присутствуют в Go build matrix, но не имеют production-ready Rust target в этой поставке. По решению пользователя fallback удалён; WARP на этих целях недоступен до отдельной поддержки и acceptance.

## Проверки и незакрытые acceptance

- WSL OpenWrt suite: 4237 проверок пройдено, 0 ошибок, 146 suites. Runtime-artifact и RT somark пропущены без внешних архивов; pinned runtime отдельно проверен: 29/29.
- Rust controller: 40 unit tests passed, 1 manual BusyBox-ip smoke test ignored; CLI/integration tests, Clippy и форматирование прошли. Все семь production-profile ABI бинарников запускались через QEMU-user.
- OpenWrt 25.12.5 QEMU с настоящими procd, iproute2 и nftables прошёл disable/remove acceptance; после теста маршруты, таблица 989, nft и интерфейс вернулись к baseline.
- Полный install/update/remove acceptance на текущем release rootfs и тестирование зарегистрированного активного туннеля с восстановлением после SIGKILL, обрыва туннеля, network restart и reboot остаются открытыми. На физическом роутере сохранён baseline; controller там ещё не установлен.
- Сравнение полного WARP по wall time, CPU, RSS и установленному размеру пока не завершено. Есть только ранее измеренный узкий list-sync замер; он не используется для заявления об ускорении полного WARP. Подробности и ограничения приведены в отчёте миграции.

Полная миграция остаётся незавершённой до прохождения QEMU install/update/remove, router tunnel recovery и регрессионных проверок.
