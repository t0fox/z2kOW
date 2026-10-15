# WARP: промежуточный отчёт миграции на Rust

Дата замеров: 2026-10-15. Проверки и сборки выполнялись в WSL Debian и OpenWrt 25.12.5 QEMU. WARP остаётся выключенным, пока пользователь его не включит; Rust-контроллер поставляется как одноразовый CLI. Go `z2k-warpd` и его транспортные протоколы не изменялись.

## Последний этап: tri-state procd и cooldown регистрации в Rust

- Конечный автомат `service-plan` выбирает `rebuild`, `reload`, `none` или `defer` для `enable`, `disable` и `restart`. Ошибка `ubus service list` больше не считается подтверждением остановленной службы: Rust откладывает переход, Shell не вызывает procd без достоверного состояния. procd и фактический service action остаются OpenWrt-интеграцией.
- Rust `register-due` теперь решает `due`, `wait` или `defer` по attempt stamp; при ошибке чтения повторная регистрация не запускается. Shell оставляет вызов `z2k-warpd register` без изменений. Missing и malformed stamp сохраняют прежнее решение `due`; Shell fallback также откладывает попытку при ошибке чтения.
- TDD: CLI-тесты сначала завершились ожидаемым отказом на отсутствующей команде; после реализации прошли `cargo test --locked` (24 unit-теста и все integration-тесты), `cargo fmt` и Clippy с `-D warnings`. `registration_due_cli` прошёл 5/5. WSL Shell-entry проверил active/inactive/error для `ubus`, cooldown missing/fresh/unreadable и отсутствие procd-действий при unreadable; nft/iproute2 были настоящими.
- Повторная сборка текущего source в WSL сделана только для проверяемого `x86_64`: build script завершил `--test`, ELF запущен через QEMU-user. После неё отдельно прошли `cargo fmt -- --check`, Clippy `--all-targets -- -D warnings`, `test_ow_warp_controller_shell_entry_real.sh`, `test_ow_warp_controller_nft_real.sh`, `test_ow_warp_controller_ip_real.sh` и `test_ow_warp_controller_panel_lists_real.sh`.
- Тот же текущий ELF прошёл OpenWrt 25.12.5 QEMU с реальным `procd` PID 1: `register-due` вернул `due`/`wait`/`defer` для missing/fresh/unreadable stamp, `service-plan` отложил действие при unreadable procd-состоянии, команда `version` запустилась. Успешный package lifecycle из этого не следует.
- На отдельном OpenWrt QEMU overlay тот же ELF прошёл `qemu-warp-controller.sh`, `qemu-warp-route.sh` и `qemu-warp-disable-remove.sh`. Гость использовал настоящие `procd`, `nftables`, `iproute2`, UCI и `/proc`; проверки подтвердили восстановление lock после SIGKILL, атомарные nft-операции, точное владение маршрутами, повторный reconcile без мутаций и disable/remove с сохранением registration/license/list sentinels.
- После последнего модуля в WSL повторно прошли lifecycle 440/440, missing-instance 12/12, functional 160/160, static 92/92, status 23/23 и parity 39/39. Более ранний полный прогон включал остальные `test_ow_warp_*.sh`, controller artifacts 4/4 и `tests/test_warp_games.sh` 41/41.
- Для OpenWrt 25.12.5 QEMU acceptance использован ABI x86_64 (variants=x86_64); ELF запущен через QEMU-user и в госте с procd PID 1. Он вернул ожидаемые due/wait/defer для stamp, defer для неизвестного состояния службы и version 0.1.0. Размер и SHA-256 этого ELF приведены в таблице ниже.
- Полный `qemu-warp-package-lifecycle.sh` прошёл одним запуском на свежем OpenWrt QEMU overlay с текущими `warp.sh`, `warp-domain.sh`, release/uninstall/list/WebPanel glue и ELF `a7506cd1…`: initial install `p-86.18`, update через `p-86.19` до `p-86.20`, проверка updater lock, WARP remove и uninstall. Suite подтвердил сохранение `device.json`, synthetic account sentinel, license, config и пользовательского списка. Тест создал account sentinel только при отсутствии, с правами `0600`; Cloudflare registration и реальный туннель не запускались. Использовались одноразовые acceptance key и snapshot; production signing key не применялся.
- По уточнению пользователя, во время итераций собиралась только тестируемая архитектура (x86_64). После фиксации Rust-исходников полная ABI-матрица (arm, arm64, mips, mipsel, riscv64, x86, x86_64) была собрана ровно один раз; каждый ELF прошёл version через соответствующий QEMU-user. Размеры и SHA-256 этих артефактов приведены ниже. Повторных сборок матрицы не было.
- Активный зарегистрированный Go-туннель не запускался: проверка восстановления после SIGKILL, обрыва туннеля, перезапуска сети и перезагрузки остаётся открытой. По указанию пользователя, live-tunnel acceptance проводится после hotfix на его роутере; перед изменением роутера нужно снять baseline и подготовить проверенный откат. На текущем ELF повторён только list-sync benchmark; он не измеряет полный WARP.

## Предыдущая проверка: перенос teardown в Rust и OpenWrt QEMU

- Финальный `build_warp_controller.sh --test` собрал все семь Rust ABI и запустил каждый через QEMU-user; unit/integration tests, fmt и Clippy прошли. `PROVENANCE` записал source SHA `8626cec5852b51ea4b1585215908f4ef2438f5e3`. Статический x86_64 ELF размером 921 640 байт, SHA-256 `e72c342bae892f03faec3e2dea7bdc19f44ca3e82e9f14242af4f9677175f2d4` также установлен и запущен в OpenWrt QEMU.
- Гостевая система — изолированный клон OpenWrt 25.12.5 в QEMU с `snapshot=on`. В исходный образ и общий QEMU-гость изменений не вносил. В клоне работают настоящий iproute2 6.18.0, nftables 1.1.6, UCI, procfs и `procd` PID 1.
- Тот же свежий ELF прошёл `qemu-warp-controller.sh`, `qemu-warp-route.sh`, `qemu-warp-disable-remove.sh` и `qemu-warp-benchmark.sh`. Реальный route acceptance подтвердил точное владение PBR и отсутствие изменений `ip rule`/таблицы на исправном повторном reconcile; controller acceptance проверил восстановление lock после SIGKILL и реальные nft-транзакции.
- Новая команда Rust `disable-state` под общим WARP lock снимает только принадлежащие маршруты по owner records, удаляет принадлежащее runtime-правило fw4, атомарно очищает WARP nft-цепи, сбрасывает domain-error marker и записывает `GAME_WARP_ENABLED=0`. Shell сохраняет OpenWrt/procd cleanup и проверку, что процесс остановлен; при отсутствии ELF остаётся прежняя реализация.
- `qemu-warp-disable-remove.sh` создал реальный PBR и WARP nft/fw4-объекты на тестовом интерфейсе, вызвал `disable-state`, повторный Shell `disable` и `remove`, затем проверил fail-open и сохранение sentinel `device.json`, license и пользовательского списка. Сценарий завершился `pass`; после него `procd` остался PID 1, nft содержал только штатную `inet fw4`, правила были стандартными, таблица 989 и UCI changes пусты, `eth0` восстановлен с `LOWER_UP`. Go-движок не регистрировался и не запускался.
- В WSL прошли форматирование и компиляция, 19 unit-тестов и все integration-тесты контроллера, Clippy с `-D warnings`, 15 WARP-регрессионных скриптов (lifecycle 440/440, functional 160/160), WebPanel UI 53/53, проверка синтаксиса Shell и `git diff --check`. Исправлена также коллизия имён временных status-файлов в параллельных тестах.
- На этой же VM выполнен один сравнительный прогон `qemu-warp-benchmark.sh` по 30 вызовов list-sync: Shell — 7,00 с wall, 4,02 с user CPU, 3,61 с system CPU, 109% CPU и 3 076 KiB RSS; Rust — 0,96 с wall, 0,55 с user CPU, 0,43 с system CPU, 102% CPU и 2 568 KiB RSS. Это измерение только `nft-sync`, а не полного WARP; подробности и ограничения ниже.
- На этом ELF подписанный install/update/WARP-remove/uninstall lifecycle прошёл на клоне OpenWrt QEMU: `p-86.18` обновлён через `p-86.19` до `p-86.20`. Во время второго обновления настоящий `z2k-update-lists.sh warp-games` удерживал общий Rust lock, а installer дождался его освобождения; список был обновлён. Проверены SHA-256 контроллера и сохранность `device.json`, `account.json`, license, конфигурации и пользовательского списка после обновлений и WARP-remove. Затем общий uninstaller удалил приложение, а регистрационные файлы сохранили SHA-256. Тест использовал настоящие `procd`, `iproute2`, `nftables`, `apk` и локально подписанные acceptance-манифесты.
- Повторный `qemu-warp-package-lifecycle.sh` завершился `SUITE[ow-warp-package-lifecycle-qemu]: pass` с кодом 0. Во время полного uninstall game-list updater удерживал общий lock на задержанном 25-секундном HTTP-ответе; suite подтвердил, что uninstall завершился после освобождения lease (при `mutation lock busy` предусмотрены отказ без удаления payload и повтор после updater). Обновлённый список проверен, приложение удалено, SHA-256 `device.json`, `account.json` и license сохранены. Активный зарегистрированный Go WARP-туннель и восстановление после SIGKILL, обрыва туннеля, перезапуска сети или перезагрузки роутера ещё не проверялись. Для Go WARP-целей `mips64le` и `ppc64` без production-ready Rust target сохранён Shell fallback.

## Последний этап: вычисление MARK-политики внутри Rust

- `nft-mark-apply` и `nft-mark-verify` теперь получают пути к спискам, выбранным устройствам и конфигурации. Под общим WARP lock Rust сам вычисляет scope, наличие доменов, фактическое заполнение destination set и WDTT. Ошибка чтения nft или конфигурации возвращается как ошибка проверки; она не трактуется как пустой список или `ready=0`.
- Shell на Rust-пути больше не вычисляет `list_active`/`wdtt_active` через отдельные pipeline. Он остаётся OpenWrt glue: определяет нужные LAN/WireGuard интерфейсы, готовит domain set/observer и передаёт их Rust. Legacy-реализация сохраняется как fallback без контроллера.
- В WSL прошли 141 Rust-тест, Clippy с `-D warnings`, реальная nft-интеграция и все 15 `test_ow_warp_*.sh` наборов; lifecycle — 440/440, functional — 160/160, status — 23/23. nft-тест проверил `all`, `full`, `devices`, `lists`, идемпотентность MARK-цепи, ошибки nft и нечитаемый config.
- После этого этапа проверены все семь ABI из актуальной таблицы контроллера: сборка и запуск `version` через QEMU-user прошли для ARM, AArch64, x86, x86_64, MIPS, MIPSel и riscv64. Артефакты повторно сверены с `PROVENANCE` для source SHA `99cf3cfb431be3e3d60b4ef73a6a197ea825e77c`; пересборка для проверки не выполнялась.
- Свежий x86_64 ELF прошёл `qemu-warp-controller.sh` в OpenWrt 25.12.5 QEMU с настоящими `procd`, `nftables`, `iproute2`, UCI и procfs. После теста PID 1 — `procd`, UCI clean, в nft осталась штатная `inet fw4`, правила стандартные, таблица 989 пуста.
- ELF этого среза: 900 256 байт, SHA-256 `5f1e6aa2faba4f68f8f5f85b6a3b21cd997c05ba4ce9edd65901fc5cf7150e9a`. Отдельный замер полного WARP для этого среза не запускался; выводов о приросте производительности всего WARP нет. Цикл установки и обновления со свежим ELF и сценарии с реальным зарегистрированным Go-туннелем ещё не подтверждены.

## Последний этап: проверка свежести во время ожидания WARP

- `_warp_wait_ready` на Rust-пути вызывает `ready-observe-since`: Rust проверяет живой `z2k-warpd run`, Go `status.json`, его mtime относительно начала ожидания и наличие status-интерфейса через настоящий `ip -j link show`. Старый `ready` остаётся `not-ready`; ошибка чтения остаётся `unreadable` и не снимает PBR. Shell сохраняет цикл, probe-route, supersession и вызовы procd; путь без Rust ELF не менялся.
- JSON и mtime читаются с одного открытого inode; если файл изменился во время чтения, результат `unreadable` откладывает решение. Тест заменяет status-файл между `open` и чтением и проверяет, что старый JSON не получает mtime нового файла.
- Добавлены unit-проверки свежего, устаревшего и нечитаемого наблюдений, а также CLI-проверки stale `ready`, повреждённого JSON, атомарной замены файла и отказа при неизвестном времени начала (`0`).
- В WSL прошли `cargo test`, `cargo fmt -- --check`, `cargo clippy --all-targets -- -D warnings` и все 15 `test_ow_warp_*.sh` регрессионных наборов: parity `39/39`, lifecycle `440/440`, functional `160/160`, status `23/23`. Реальный Shell entrypoint проверил `iproute2`/`nft`; сценарий сбоя `date` подтвердил, что epoch `0` не принимается и PBR не меняется.
- Свежая статическая сборка `x86_64` сделана отдельно от остальных ABI через `Z2K_WARP_CONTROLLER_VARIANTS=x86_64 ... --test`; ELF запущен через QEMU-user. Размер — 903 920 байт, SHA-256 `ab3a745c710f3de40315dfa7373d10283ac45175c8d62d86b35f9b181688eee5`.
- Этот новый ELF ещё не прошёл OpenWrt QEMU acceptance. Активный Go-туннель и полный performance benchmark для этого среза не запускались; миграция остаётся незавершённой.

## Последний этап: boot-план без ложного teardown

- Rust `boot-plan` принимает четыре наблюдения: `ENABLED` (последнее значение), `GAME_WARP_ENABLED` (первое значение), исполняемость `z2k-warpd` и непустую регистрацию. Он возвращает `wanted`, `unwanted` или `defer`.
- При transient read/stat ошибке Shell откладывает boot/hotplug без удаления правил. OpenWrt остаётся владельцем procd-вызова; старый Shell-путь сохранён для сборок без ELF.
- WSL-проверка с настоящими nft/iproute2 подготовила исправный tunnel/PBR state, затем сделала config путём-каталогом. `rules` вернул defer; снимки nft table, `ip rule` и route table 989 совпали побайтно.
- В WSL прошли 136 Rust-тестов, Clippy с `-D warnings` и все 15 `test_ow_warp_*.sh` наборов; lifecycle — 440/440, functional — 160/160, status — 23/23. Только x86_64 собран через `Z2K_WARP_CONTROLLER_VARIANTS=x86_64 ... --test`.
- Свежий ELF прошёл QEMU-user и OpenWrt 25.12.5 QEMU `qemu-warp-controller.sh`, включая `wanted`, `defer` при нечитаемой конфигурации и `unwanted` при отсутствующем бинарнике. После теста PID 1 — `procd`, UCI clean, в nft осталась штатная `inet fw4`, правила стандартные, таблица 989 пуста.
- ELF этого среза: 898 144 байта, SHA-256 `b70b27de2659b01596306e3a93d2f3faef8d905944d148b6071be3bb69c24a2a`. Изменений Go-движка нет.

## Последний этап: отметка одноразового восстановления procd

- Rust-команды `procd-recovery-claim` и `procd-recovery-clear` владеют маркером попытки. Claim атомарно сохраняет прежний формат `attempted <epoch>`, сериализует claim/clear отдельной pid/start-time lock и возвращает `claimed` только одному конкурентному вызову. Shell оставляет procd-запрос и перезапуск сервиса у OpenWrt.
- `_warp_health_process_absent` делает восстановление только после успешного claim; повторный тик видит существующую отметку и не запускает вторую попытку. Enable, restart, disable и регистрация procd очищают отметку через Rust, с прежним Shell fallback без ELF.
- В WSL прошли 132 Rust-теста, Clippy с `-D warnings`, настоящий Shell entrypoint и все 15 `test_ow_warp_*.sh` наборов; lifecycle — 440/440, functional — 160/160, status — 23/23.
- Собран только ABI `x86_64`. ELF прошёл QEMU-user и `qemu-warp-controller.sh` в OpenWrt 25.12.5 QEMU, включая одноразовый claim, повторный claim без замены inode и clear. В госте после теста PID 1 — `procd`, `uci changes` пуст, осталась только `inet fw4`, правила стандартные, таблица 989 пуста.
- ELF этого среза: 896 272 байта, SHA-256 `c4c7cad9c0f03bba77a2dccd58c028fd760c7a7be36e30e049cea50aece86a01`. Реальное восстановление Go-движка через procd после SIGKILL/потери туннеля ещё не проверено.

## Последний этап: запись пользовательского флага

- `warp_set_flag` делегирует запись `GAME_WARP_ENABLED` команде Rust `warp-flag-set`; без контроллера остаётся прежний Shell `set_flag`.
- Rust принимает только `0`/`1`, использует общий `.z2k-flaglock` контракт `set_flag`, атомарно заменяет все дубли ключа или добавляет отсутствующий, сохраняет остальные настройки и не переписывает уже исправный файл. Занятая блокировка не меняет конфигурацию.
- В WSL прошли 130 Rust-тестов, `cargo fmt --all -- --check`, Clippy с `-D warnings`, настоящий Shell entrypoint и все 15 WARP Shell-наборов; lifecycle — 440/440, functional — 160/160, status — 23/23.
- Собран и запущен только проверяемый `x86_64` вариант через `Z2K_WARP_CONTROLLER_VARIANTS=x86_64 ... --test`. Свежий ELF прошёл QEMU-user и `qemu-warp-controller.sh` в OpenWrt 25.12.5 QEMU с настоящими `procd`, `nftables`, `iproute2`, UCI и procfs. Скрипт проверил запись флага и отказ при занятой общей блокировке. После очистки PID 1 — `procd`, `uci changes` пуст, nft содержит только штатную `inet fw4`, остались стандартные `ip rule`, таблица 989 пуста.
- ELF этого среза: 890 672 байта, SHA-256 `74caaa9a7e916b210559669d45f7c5613494dd6ec436f8538a470c1e39180f1c`. Прочие ABI на этом этапе не собирались; полная матрица остаётся финальным compile-гейтом.

## Последний этап: сериализация пользовательских действий

- Shell `warp_op_begin`, `warp_op_current` и очистка op marker делегируют в Rust `op-begin`, `op-current`, `op-clear`. Rust сериализует короткие чтения/записи отдельной блокировкой, не удерживая её во время ожидания общего WARP lock.
- Запись marker атомарная. `op-clear` удаляет только PID текущей операции. Ошибка чтения возвращает `unreadable`, а Shell продолжает текущий шаг, поскольку повреждённый snapshot не доказывает supersede. Если новую операцию не удалось опубликовать, пользовательское действие завершается до входа в общий lock.
- Rust CLI-тесты проверили текущую/перебитую операцию, очистку только владельцем, кратковременную ошибку чтения и два конкурентных `op-begin`; настоящий Shell entrypoint проверил begin/current/clear и сохранение нового маркера после завершения старой операции.
- Повторно прошли `cargo fmt --all -- --check`, все 126 Rust-тестов, Clippy с `-D warnings` и все 15 `test_ow_warp_*.sh` наборов: lifecycle — 440/440, functional — 160/160, status — 23/23.
- Собран и запущен только проверяемый `x86_64` вариант: `Z2K_WARP_CONTROLLER_VARIANTS=x86_64 ... --test`. ELF прошёл QEMU-user и `qemu-warp-controller.sh` внутри OpenWrt 25.12.5 QEMU с реальными `procd`, `nftables`, `iproute2`, UCI и procfs. После теста PID 1 — `procd`, `uci changes` пуст, nft содержит только штатную `inet fw4`, в `ip rule` остались стандартные правила, таблица 989 пуста.
- ELF этого среза: 885 256 байт, SHA-256 `c248db4382f09f6746761708054e29870479083333c7f6e2958fcb11ee478f17`. Другие ABI на этом этапе не собирались.

## Предыдущий этап: route error marker

- `_warp_route_error_set` и `_warp_route_error_clear` делегируют в одноразовые команды Rust `route-error-set`/`route-error-clear`; при отсутствии ELF остаётся прежний Shell-путь.
- Контроллер сериализует операции общим WARP lock, атомарно записывает `reason timestamp` с режимом `0600`, сохраняет первый непустой маркер и удаляет оставшиеся временные файлы. Очистка отсутствующего каталога идемпотентна.
- Rust CLI-тесты проверяют формат, права, сохранение первого сбоя, удаление временных файлов, неверный ввод и повторную очистку отсутствующего пути. Shell entrypoint проверен с настоящими nft/iproute2 в WSL.
- После сборки только варианта `x86_64` актуальный static musl ELF прошёл запуск QEMU-user и `qemu-warp-controller.sh` в OpenWrt 25.12.5 QEMU. В госте настоящий `procd` остался PID 1; после теста `uci changes` пуст, в nft осталась только штатная `inet fw4`, ip rules стандартные, table 989 пуста. Реального Go-туннеля сценарий не запускал.
- В WSL прошли `cargo fmt --all -- --check`, `cargo test --locked` (123 теста), Clippy с `-D warnings` и все 15 WARP Shell-наборов; lifecycle — 440/440, functional — 160/160, status — 23/23.
- ELF этого среза: 877 384 байта, SHA-256 `2417df271e073e1bdfef72edd76194f0aa7ebdf8742d8e87e38da53fdc30a90c`. Проверен только x86_64; другие варианты не пересобирались.

## Предыдущий этап: LAN runtime, domain marker и списки

- `warp_domain_lan_devices` делегирует обнаружение в `interfaces lan`. Rust читает UCI, предпочитает актуальное `device` из `ubus network.interface.<name> status` и использует UCI `device`/`ifname`, если runtime-устройство недоступно. Явный тестовый override и Shell fallback без ELF сохранены.
- Rust unit-тест проверяет runtime-приоритет, прямые интерфейсы firewall-зоны и UCI fallback. Тест Shell entrypoint проверяет реальную передачу вызова Rust-контроллеру.
- `domains-error` перенёс запись и очистку domain error marker в Rust. Контроллер атомарно публикует строку с режимом `0600`, не заменяет файл при том же коде и удаляет marker при очистке; Shell делегирует вызов с прежним fallback.
- `warp_nft_sets_reload_if_changed` на Rust-архитектурах проверяет целевые наборы через `nft-sets-verify`; при расхождении вызывает атомарный `nft-sync`. Shell hash-гейт остаётся только в fallback без ELF. Реальный nft-тест подтвердил noop при исправных наборах и обновление после изменения списка.
- В OpenWrt 25.12.5 QEMU новый ELF запущен с настоящими `uci`, `ubus`, `procd` (PID 1), `iproute2` 6.18.0 и `nftables` 1.1.6. При временном несохранённом `network.lan.device=not-active` контроллер вернул активный `br-lan`; `uci revert network.lan` восстановил значение `br-lan`, после проверки `uci changes` пуст.
- Для этого среза в WSL прошли `cargo fmt`, `cargo test --locked` (120 тестов), Clippy с `-D warnings`, все 15 WARP Shell-наборов, включая lifecycle 440/440 и functional 160/160. В OpenWrt QEMU прошли `qemu-warp-controller.sh` и `qemu-warp-route.sh`; после них остались только таблица `inet fw4`, стандартные правила маршрутизации и пустая таблица 989.
- Проверен только ABI `x86_64`: сборка `Z2K_WARP_CONTROLLER_VARIANTS=x86_64 ... --test`, запуск через QEMU-user и гостевой запуск прошли. Размер ELF — 871 512 байт, SHA-256 `8800797515851c1faec12f7d4e7b40090f6720c91dcf242fbd267962fa9125c3`.
- Benchmark не повторялся: предыдущая серия измеряла явный `warp_nft_sets_load`; она не включает новый verify-first путь cron reload. Измерение относится к ELF 869 128 байт с SHA-256 `8b9fecbeee1fc068475ab694c5e13c41c242a67b888becc1477d64c3f3253405`.

## Предыдущий этап: чтение конфигурации

- `config-read` перенёс в Rust чтение ключей `GAME_WARP_ENABLED`, `ENABLED` и WARP-параметров. CLI сохраняет first/last-match, значение по умолчанию, прежнюю обработку кавычек и пробелов; конфигурация не исполняется как Shell.
- `health-plan` в Rust выбирает переход `disabled`, `binary-missing`, `device-missing`, `process-absent`, `not-ready`, `ready` или `defer` по конфигурации, регистрации, `/proc`, Go status и реальному `ip -j link show`. Health-check Shell использует этот переход; только OpenWrt/procd-действия и mutation calls остаются в glue. На готовом пути интерфейс передаётся одним снимком status.
- Shell entrypoint-тест проверяет все три чтения через Rust CLI и реальную ошибку чтения (путь-каталог). Health check при такой ошибке откладывается без изменений nft и маршрутов; Shell fallback остаётся для платформ без ELF.
- В WSL прошли `cargo fmt --check`, `cargo test --locked` (118 тестов), Clippy с `-D warnings` и все 15 `test_ow_warp_*.sh` наборов после интеграции `health-plan`. Lifecycle — 440/440, functional — 160/160.
- Актуальный x86_64-musl ELF: 869 128 байт, SHA-256 `8b9fecbeee1fc068475ab694c5e13c41c242a67b888becc1477d64c3f3253405`. Свежий ELF прошёл `qemu-warp-controller.sh` (включая реальные OpenWrt config/proc observations для `health-plan`) и `qemu-warp-route.sh`.
- QEMU benchmark на этих байтах: Shell fallback — 4,80 с user CPU, 6,55 с system CPU, 9,93 с wall и 3 072 KiB peak RSS; Shell→Rust `nft-sync` — 0,63 с, 0,96 с, 1,55 с и 2 568 KiB. Это одна серия по 30 повторов только для list-sync.
- Свежий ELF прошёл `qemu-warp-controller.sh`, `qemu-warp-route.sh` и benchmark на OpenWrt 25.12.5 QEMU. В госте осталась только штатная `inet fw4`, `uci changes` пуст, WARP rules и table 989 отсутствуют.

## Предыдущий этап: атомарные nft-операции и FW4

- `nft-chain-clear` читает реальную таблицу и отправляет одной nft-транзакцией только `flush chain` для существующих непустых цепей. OpenWrt `_warp_tun_clear` и `_warp_mark_clear` делегируют эту операцию.
- В WSL прошли Rust-тесты batch-renderer, реальный nft namespace-тест и полный Shell entrypoint с настоящими nft/iproute2. Проверены сохранение чужой цепи, отсутствие повторных мутаций и явный отказ при ошибке чтения nft.
- Для этого изменения собран только ABI `x86_64` через `Z2K_WARP_CONTROLLER_VARIANTS=x86_64 ... --test`; Rust-тесты, Clippy и форматирование прошли. Остальные ABI оставлены до финального прохода полной матрицы.
- Свежий x86_64 ELF прошёл `qemu-warp-controller.sh` и `qemu-warp-route.sh` на OpenWrt 25.12.5 с настоящими `procd` (PID 1), `iproute2` 6.18.0 и `nftables` 1.1.6. Полный controller-сценарий проверил атомарную очистку, сохранение foreign chain, SIGKILL lock recovery и last-good состояние; route-сценарий подтвердил apply/verify/remove и отсутствие мутаций при повторном apply.
- Rust-команды `nft-fw4-forward-apply`, `nft-fw4-forward-verify` и `nft-fw4-forward-remove` теперь владеют runtime admission rules в fw4. Проверены атомарная вставка/удаление, noop при уже исправном состоянии, отказ при чужом marker и сохранение пакетного wildcard include; OpenWrt Shell остаётся только точкой вызова и fallback без ELF.
- `nft-warp-remove` удаляет только WARP-цепи и, при полном удалении, IP-наборы одной транзакцией. Проверены частичное/полное удаление, повторный noop и сохранение чужой цепи; Shell teardown делегирует контроллеру.
- Свежий x86_64 ELF прошёл расширенный `qemu-warp-controller.sh` (включая FW4 conflict/noop/wildcard и nft teardown) и `qemu-warp-route.sh` на OpenWrt 25.12.5; после восстановления bridge-port успешен ping шлюза.
- На том же QEMU запущен замер 30 вызовов `warp_nft_sets_load` для Shell fallback и Shell→Rust `nft-sync`: соответственно 7,34 с / 3 080 KiB и 1,37 с / 2 568 KiB peak RSS. Это только измерение list-sync на TCG; оно не характеризует полный WARP.
- После текущих изменений device resolution собран и проверен только x86_64 ABI. Полную матрицу ABI, включая запуск, оставил финальной приёмке по просьбе не пересобирать все архитектуры на каждом этапе; предыдущий полный прогон относится к более раннему срезу исходников.
- Полная миграция остаётся незавершённой: lifecycle state machine, procd recovery, domain orchestration, тонкие Shell entrypoints, обновление/удаление текущего кандидата и acceptance с реальным туннелем ещё требуют переноса или проверки.

## Предыдущий этап: выбор устройств WARP

- Выбор источников перенесён из `warp_devices_ips` в Rust `device-ips`: прямые private/CGNAT IPv4, JSON-таблица `ip -4 -j neigh`, active+authorized hostapd association и текущие dnsmasq leases. Rust проверяет ошибки чтения и не подменяет их пустым списком; проверены приоритет kernel neighbor над lease, срок аренды и фильтрация публичных адресов.
- В WSL прошли unit/CLI-проверки, полный `cargo test --locked`, Clippy, форматирование, реальный Shell entrypoint и все 15 `test_ow_warp_*.sh` regression suites.
- После устранения дублирующего MAC/lease-парсера и переноса lock lease обновлённый x86_64-musl ELF (862 408 байт, SHA-256 `7a6eaaf3327f73cd8eb780c389d1d93b25f18ca2a74c4244e2b978e946ecd940`) собран только для тестируемого ABI. В OpenWrt 25.12.5 QEMU проверены `lock-acquire`/`lock-release`, отказ снять чужой lock, восстановление после SIGKILL владельца, `device-ips` и `nft-sync` по реальному JSON iproute2 neighbor (`10.0.2.2` в source set), а также route suite. После controller/route/benchmark прогонов `uci changes` пуст, осталась штатная таблица `inet fw4`, WARP rules/routes и таблица 989 отсутствовали.

## Предыдущий этап: Rust lock lease

- Shell lifecycle и `warp-proc.sh` теперь используют `lock-acquire`/`lock-release` в Rust CLI. Rust проверяет PID вместе со временем запуска, сохраняет общий `mutate.lock` контракт и восстанавливает lock после завершения владельца; Shell mkdir-lock остался только fallback без controller ELF.
- WSL проверил прямой acquire/release, отказ release для чужого PID, эксклюзивность и восстановление после SIGKILL владельца. `warp.sh` Shell entrypoint проходит lock commands через установленный controller; lifecycle regression прошёл 440/440.
- Lock CLI и shell entrypoint прошли WSL-проверки; x86_64 сборка и QEMU OpenWrt 25.12.5 проверили PID lease, отказ чужому PID и восстановление после SIGKILL.

## Проверенные результаты

- Карта вызовов и контрактов записана в [`openwrt-warp-shell-map.md`](openwrt-warp-shell-map.md).
- Текущий `build_warp_controller.sh --test` собрал и запустил через QEMU-user все 7 ABI: ARMv5te soft-float, AArch64, x86_64, i686, MIPS BE, MIPS LE и riscv64. Проверка provenance после сборки подтвердила SHA-256 артефактов, target table и build script для source SHA `99cf3cfb431be3e3d60b4ef73a6a197ea825e77c`.
- В WSL прошли реальные интеграционные тесты Rust с `iproute2` и `nft` в Linux network namespace, Shell entrypoint и проверка release-артефактов.
- После перехода чтения PBR на JSON-вывод `ip -4 -j rule show` и `ip -4 -j route show table all` в WSL прошёл полный `cargo test --locked` (включая реальный iproute2 network namespace), `cargo clippy --all-targets -- -D warnings` и `cargo fmt --check`. Текущий x86_64-musl ELF запущен в OpenWrt 25.12.5 QEMU; route apply/verify/remove, проверка owner и отсутствие мутаций при повторном apply прошли на гостевом iproute2 6.18.0.
- После подключения Rust `runtime-observe` и `nft-tun-verify` в WSL повторно прошли `cargo fmt --check`, все Rust-тесты, Clippy с `-D warnings`, реальные nft/iproute2-тесты и Shell entrypoint. `runtime-observe` одним вызовом различает живой процесс, Go status и интерфейс через `ip -j link show`; временные ошибки остаются `unreadable`. Исправное состояние policy вернуло `noop` без изменения `ip rule` и таблицы 989; ошибки чтения конфигурации, status, `/proc`, iproute2 и nft откладывали проверку без мутаций.
- Legacy-миграция WARP-списков перенесена в CLI-команду `list-migrate`: Rust удаляет только известные старые агрегаты до установки маркера, сохраняет пользовательские файлы и нормализует права `.txt`; Shell оставляет fallback для систем без Rust ELF. Unit-, CLI- и реальный Shell entrypoint-тесты прошли в WSL.
- `nft-domain-verify` проверяет read-only владение доменным набором и observer-цепями. Реальный nft namespace-тест и Shell entrypoint-тест подтверждают `ready=1`, отказ при неправильном NFLOG group и отказ проверки при временной ошибке чтения `nft`.
- WSL-регрессии после runtime-readiness прошли для WARP archmap, domain paths, функциональности, fw4, games flow, lifecycle (440/440), manifest, missing instance, parity, static, status, seed релиза и реальных controller IP, nft, panel-list и Shell entrypoint проверок.
- Свежий x86_64 ELF прошёл OpenWrt 25.12.5 QEMU на клоне образа: PID 1 — настоящий `procd`, `iproute2` 6.18.0, `nftables` 1.1.6. `runtime-observe` прочитал гостевой `/proc` и корректно вернул `not-ready absent`, когда Go-процесс не запущен. `qemu-warp-controller.sh` подтвердил атомарность nft, отказ при ошибке чтения, SIGKILL восстановление одноразового контроллера и last-good состояние; `qemu-warp-route.sh` подтвердил route apply/verify/remove, отсутствие мутаций при повторном apply и отказ при чужом owner.
- WSL acceptance упаковки и release прошла после добавления controller в требуемые пути: `test_ow_stage_rootfs.sh` 362/362, `test_ow_payload_gate.sh` 7/7, `test_ow_payload_bundle.py` 10/10, `test_ow_unified_release.sh` 71/71 и `test_ow_transaction_faults.sh` 22/22. Workflow/artifact проверки: 33 release-workflow теста и 4 проверки provenance.
- В WSL прошли проверки упаковки: `test_ow_stage_rootfs.sh` 362/362, `test_ow_payload_gate.sh` 7/7, `test_ow_payload_bundle.py` 10/10, `test_ow_unified_release.sh` 71/71 и `test_ow_transaction_faults.sh` 22/22, а также 33 release-workflow теста и 4 проверки provenance. Эти проверки не заменяют повторную упаковку текущего среза и QEMU install/update lifecycle.
- После переноса `device-ips` в WSL прошли `cargo fmt --all -- --check`, все Rust-тесты, `cargo clippy --locked --all-targets -- -D warnings` и все 15 `test_ow_warp_*.sh`; shell regression включает lifecycle 440/440, functional 160/160 и реальные nft/iproute2 tests. Новый CLI также прошёл реальный Shell entrypoint.
- В OpenWrt 25.12.5 QEMU свежий x86_64 ELF прошёл `qemu-warp-route.sh` на iproute2 6.18.0 и полный `qemu-warp-controller.sh`: настоящие nft операции, атомарность, запрет при ошибке nft, SIGKILL восстановления lock с сохранением last-good `domains.v1`, а также MARK/domain observer. Отдельный сценарий проверил sets sync/verify, восстановление удалённого элемента, domain-only очистку IP sets и отличие `ready=0` от ошибки чтения nft. В госте настоящий `procd` остаётся PID 1. Текущий QEMU прогон не запускал `z2k-warpd` и не является повторным install/update lifecycle.

## Lifecycle свежего WARP-кандидата в OpenWrt QEMU

Этот цикл выполнен после переноса MARK-политики и использовал актуальный x86_64 controller ELF. Гость — отдельный OpenWrt 25.12.5 qcow2 overlay с настоящими `procd`, `apk`, `nftables`, `iproute2` и `lighttpd`; базовый raw-образ не менялся. Локальные тестовые манифесты были подписаны отдельным acceptance-ключом.

- Штатный `scripts/openwrt/install.sh` установил `p-86.18` (seq 142), затем обновил его до текущего кандидата `p-86.21` (seq 145). Гость проверил подпись, размер и SHA-256 релизного архива, распаковал и применил x86_64 payload через release engine, перезапустил службы и дождался настоящей HTTP-панели. Установленный `z2k-warp-controller` совпал с текущим ELF SHA-256 `5f1e6aa2faba4f68f8f5f85b6a3b21cd997c05ba4ce9edd65901fc5cf7150e9a`.
- До обновления записаны синтетические sentinel-файлы. После обновления сохранились `GAME_WARP_ENABLED=0` и `Z2K_WARP_TRANSPORT=h2`, пользовательский список `acceptance.txt` SHA-256 `5e19368d7638b605e3b666a45153f150cfa320ee6ef998805f995a1d06f1ce37`, `device.json` SHA-256 `728a7c936410d08706e54df07e8b86c7b2a64dc67d99dbe588712d2f25aae07f` и license SHA-256 `3570658ee560df8d7e913e3d0e7091bc6a232efa04dcb3d8fe7cfb2498300a5c`.
- `warp.sh disable` завершился с кодом 0. После него не было процесса `z2k-warpd`, WARP policy rules или таблицы маршрутов 989. Штатные правила `inet fw4` и общая таблица `inet zapret2` не изменялись этой операцией.
- Полное `Z2K_UNINSTALL_CONFIRMED=1 /usr/bin/z2kow uninstall` завершилось с кодом 0; `/usr/lib/z2k`, CLI и обе procd-службы удалены. WARP `device.json` и license сохранили исходные SHA-256, процесс и PBR отсутствовали.
- После полного удаления осталась таблица `inet zapret2` с общими наборами z2kOW и без цепей/правил. Это выявило пропущенную очистку общей таблицы.
- Список, регистрация и лицензия были synthetic sentinels. Cloudflare registration, реальный Go-туннель и обмен трафиком не запускались.

### Исправление остатка nft при удалении

- Uninstaller теперь рассматривает `inet zapret2` только после успешной очистки всех подсистем. Он удаляет таблицу одним вызовом nft, только если в ней остались известные runtime sets zapret2; неизвестный set, chain или ошибка чтения останавливает удаление и сохраняет файлы для повтора. Таблица `inet fw4` не затрагивается. Контроллер Rust для этого общего uninstall шага не нужен.
- В WSL прошли `test_ow_uninstall_parity.sh` (93/93), `test_ow_stop_verify.sh` (10/10) и `test_ow_uninstall_nft_real.sh` с настоящим nft в network namespace. Проверены удаление принадлежащей таблицы, сохранение чужих объектов и отказ при ошибке чтения.
- Production helper запущен в отдельном OpenWrt 25.12.5 QEMU overlay с реальными BusyBox `awk` и nftables 1.1.6: известные sets удалены, `inet fw4` сохранена; неизвестная цепочка осталась на месте. Базовый raw-образ не изменён.
- После исправления полный install/update/disable/uninstall цикл повторён в отдельном x86_64 QEMU overlay; подробности ниже.

### Повторный lifecycle после исправления

- 15.10.2026 свежий статический x86_64 ELF размером 900 256 байт, SHA-256 `5f1e6aa2faba4f68f8f5f85b6a3b21cd997c05ba4ce9edd65901fc5cf7150e9a`, собран и запущен через закреплённый build script только для проверяемой архитектуры. `--test` прошёл unit/CLI-тесты и Clippy; остальные ABI повторно не собирались.
- На клоне OpenWrt 25.12.5 установлены `p-86.18`, затем обновлены до `p-86.19`. Второй x86_64 payload содержал свежий ELF и текущий `uninstall.sh`; гостевые `procd` (PID 1), `apk-tools` 3.0.5, `iproute2` 6.18.0 и `nftables` 1.1.6 работали без mocks. Тестовые манифесты подписаны временным локальным acceptance-ключом; ключ удалён после теста.
- После обновления `GAME_WARP_ENABLED=0`, `Z2K_WARP_TRANSPORT=h2` и sentinel-файлы сохранились. SHA-256 списка `a41afcf39791863e5327be87f497788a17873810da02a7cc725435c777735985`, `device.json` `d73c5d8e418c77de42bec0d729116e2087a362cfb3027b852c48e6d2edba5276` и license `560eb1252c63ffba8b1981ec399eface06f97adb2ab0a4355cab56c0f66ec620` совпали до и после update.
- `warp.sh disable` и полное удаление завершились с кодом 0. После удаления отсутствовали приложение и обе procd-службы, WARP-процесс, policy rules и маршруты таблицы 989; `inet zapret2` удалена, штатная `inet fw4` сохранена. `device.json` и license сохранили SHA-256 после uninstall; `uci changes` пуст.
- Исходный raw-образ QEMU остался неизменным: SHA-256 `596b70c53dec461f363d1e443567265d870c55e46076a6d93089a7bc1226a19d`. Регистрация и файлы состояния были синтетическими, Go-движок и активный WARP-туннель не запускались.

## WSL: полный OpenWrt regression run

- Полный запуск обнаружил 147 наборов. Он вывел `5199 pass / 13 fail`; четыре отказа оказались ошибкой учёта runner-а для скриптов с успешным exit-кодом, но без формата `pass=N fail=M`. `tests/openwrt/run.sh` исправлен: без счётчика результат определяется exit-кодом, а ненулевой exit остаётся провалом.
- После исправления отдельные shards прошли для реальных uninstall nft, controller IP/nft, panel-list и Shell entrypoint acceptance; ownership — 38/38 за 6,9 с. Статический скан ownership исключает сгенерированные `target/`, но сохраняет весь исходный код.
- `webpanel-unit` в общем WSL namespace не прошёл проверку свободного порта 18099: его занимал посторонний HTTP-сервер. Тот же набор в отдельном network namespace прошёл 37/37.
- Остаются три несвязанных с WARP результата: `bootstrap-engine` — 7 проверок остановились на gate совместимости OpenWrt/памяти в WSL; `webpanel-static` — лимит `actions.sh` превышен на одну строку (15/14); эти тесты не исправлялись в рамках WARP.

## Ранее выполненный lifecycle OpenWrt QEMU

Этот прогон проверял предыдущий собранный payload. Он не заменяет приёмку нового rootfs-кандидата после текущих изменений упаковки.

- OpenWrt 25.12.5 запускался с настоящим `procd` как PID 1, `iproute2` 6.18.0 и `nftables` 1.1.6. Первый install через штатный `install.sh` применил подписанный локальным тестовым ключом выпуск `p-86.18`; штатный `install_release p-86.19` завершил update с seq 143. В манифестах были настоящие rootfs-архивы предыдущей acceptance-сборки. Архивы v1/v2 имели одинаковые байты, поэтому проверен транзакционный путь обновления и смена версии, но не замена на другой payload. Новейший ELF после policy-изменений проверен в гостевой OpenWrt отдельным запуском, однако полный installer/update lifecycle для него пока не повторён.
- Контрольный пользовательский список сохранил SHA-256 `ec254b175ccff8e04c575255a74c6a15b1bc8754007060af46ac1e37fffc0e41`; тестовые `device.json` и license сохранили SHA-256 `bde71bfe152f3706f35315e723660f727f35fd706a6bd329d579b7d16990ec49` и `fa29959f0b7028ba448fd5a30b418ab7c61b725b95b112a802ff1eaba84ae7ad` соответственно после установки и обновления. Проверенные значения `GAME_WARP_ENABLED=0` и `Z2K_WARP_TRANSPORT=h2` пережили обновление. Установщик расширил минимальный тестовый `/etc/z2k/config` до полного шаблона, поэтому хэш файла изменился.
- `warp.sh disable` завершился успешно. После него не было процесса `z2k-warpd`, правил WARP в nftables, правила с mark `0x80000000` или таблицы PBR 989.
- `z2kow uninstall` с тестовым подтверждением завершился с кодом 0. Проверено отсутствие `/usr/lib/z2k`, `/usr/bin/z2kow`, `/usr/sbin/install_release` и `/etc/init.d/z2k`; WARP `device.json` и license остались с прежними SHA-256, WARP nftables/PBR-правила отсутствовали.
- Значения `device.json` и license были синтетическими sentinel-файлами. Регистрацию Cloudflare, реальный WARP-туннель и обмен трафиком этот сценарий не создавал и не проверял.

## Lifecycle прежнего release-кандидата в OpenWrt QEMU

Этот lifecycle выполнен настоящими OpenWrt-командами для x86_64 rootfs-кандидата до переноса последней политики MARK; он подтверждает контракт установщика, но не является приёмкой свежего ELF. Активного WARP-туннеля в госте не было.

- На клоне OpenWrt 25.12.5 с 2 ГиБ ext4 выполнена установка `p-86.18` штатным `scripts/openwrt/install.sh` с настоящими `apk`, `procd`, `iproute2`, `nftables` и локальной acceptance-подписью.
- Обновление `p-86.18` → `p-86.19` использовало другой x86_64 rootfs payload: v2 добавлял тестовый marker-файл. Bootstrap проверил подпись, размер и SHA-256, затем установил payload через гостевой `apk`. После update проверены marker, настройки `GAME_WARP_ENABLED=0` и `Z2K_WARP_TRANSPORT=h2`, а также неизменность SHA-256 пользовательского списка `eb6036d2cd5f5612435dbd89f423df381f2688dd1756015e3e3c6f36a35ee239`, `device.json` `bde71bfe152f3706f35315e723660f727f35fd706a6bd329d579b7d16990ec49` и license `fa29959f0b7028ba448fd5a30b418ab7c61b725b95b112a802ff1eaba84ae7ad`.
- `warp.sh disable` завершился с кодом 0; процесса `z2k-warpd`, WARP nft-объектов, PBR rules и маршрутов таблицы 989 не осталось. `Z2K_UNINSTALL_CONFIRMED=1 z2kow uninstall` удалил приложение, CLI, updater и init-службы; после него WARP runtime-объекты отсутствовали, а sentinel `device.json` и license сохранили SHA-256. Удаление приложения удалило пользовательскую конфигурацию и списки, как предусмотрено контрактом полного uninstall.
- Тестовый ключ и значения регистрации были синтетическими. Полный lifecycle не запускал Go-движок через procd, не регистрировался в Cloudflare и не проверял активный туннель.

## Проверка текущего маршрутизатора в OpenWrt QEMU

- После обновления route parser собран свежий статический x86_64-musl ELF и запущен на клоне OpenWrt 25.12.5. `qemu-warp-route.sh` использовал настоящий iproute2 6.18.0: временно переименовал `eth0` в тестовый интерфейс `z2ktun0`, добавил probe/PBR, проверил точное владение, повторный apply без изменений, отказ при чужом owner, remove и чистое восстановление интерфейса.
- В этом тесте использовался тестовый Ethernet-интерфейс без Go WARP-туннеля. Он подтверждает формат JSON iproute2 и поведение маршрутов, но не восстановление активного туннеля или procd-событий.

## Замер list-sync в OpenWrt QEMU

Одна свежая серия на каждом пути: 30 повторов `warp_nft_sets_load` с одинаковым содержимым списков и настоящим OpenWrt `nft`. Она выполнена через `/usr/bin/time -v` на OpenWrt QEMU под TCG, 2 vCPU и 2048 MiB RAM, с текущими Shell-файлами и x86_64 ELF `a7506cd1…`; в госте работал iproute2 6.18.0. Это узкий замер синхронизации наборов; он не характеризует полный WARP или сетевую пропускную способность.

| Путь | User CPU | System CPU | Wall time | CPU из `time` | Peak RSS |
|---|---:|---:|---:|---:|---:|
| Shell fallback | 3,92 с | 3,86 с | 7,08 с | 110% | 3 080 KiB |
| Shell → Rust `nft-sync` | 0,45 с | 0,51 с | 0,94 с | 102% | 2 568 KiB |

В этой единственной серии wall time Rust-пути составил 0,94 с против 7,08 с, peak RSS — 2 568 KiB против 3 080 KiB. Замер не включает Go-туннель, регистрацию, DNS-транспорт, восстановление procd и сетевую нагрузку. Одной серии недостаточно для вывода о производительности полного WARP.

## Размер компонентов

| Состав | Размер |
|---|---:|
| Shell-only на `HEAD`: `warp.sh`, `warp-domain.sh`, list filter | 149 090 байт |
| Текущие три Shell-файла | 181 928 байт |
| Rust controller ELF, x86_64 | 925 032 байта |
| Текущая сумма этих Shell-файлов и x86_64 ELF | 1 106 960 байт |

Итоговая полная ABI-сборка зафиксированного в рабочем дереве Rust-контроллера: build script собрал семь вариантов и запустил каждый с version через соответствующий QEMU-user. PROVENANCE.source_sha=8626cec5852b51ea4b1585215908f4ef2438f5e3 обозначает Git HEAD и не является хэшем незакоммиченных изменений исходников; ниже указаны также hashes бинарников и закреплённых build inputs.

| Go ABI | Rust target | Размер ELF | SHA-256 |
|---|---|---:|---|
| arm / GOARM=7 | armv5te-unknown-linux-musleabi (soft-float; qemu-arm) | 867 056 байт | 2b1416fbbf749b0a341400c8810cecbe873ecd978a44e7d555e2fad53a125e74 |
| arm64 | aarch64-unknown-linux-musl | 810 608 байт | ffdbc4730a0e0543748447546427cc213bae2787dfc760f81e520ea2bc0ebb21 |
| mips | mips-unknown-linux-musl (BE) | 1 117 408 байт | f106af566b0d70c72b43bdf990ac5494488e8e35e1a8f9df9205bc69ac407ebe |
| mipsle | mipsel-unknown-linux-musl | 1 117 408 байт | 9515ffdf954248b1e8cb9fd1dcc4fa243fa97491f7aa8a472bd5a751aa204028 |
| riscv64 | riscv64gc-unknown-linux-musl | 779 064 байта | c5ad7f40548cae636a47ff06c382b0987542f7bbedcf3e7024bb7382754c7b61 |
| 386 | i686-unknown-linux-musl | 867 384 байта | 236ae102bf1e854e4588e48c80872cbe0add637a02d8ef4d919461147885d0e9 |
| amd64 | x86_64-unknown-linux-musl | 925 032 байта | a7506cd1f7d871ad07d28e44aafa2da4e375d21fc57956c34ce032da85a8f5d7 |

PROVENANCE фиксирует Cargo.lock SHA-256 6caadf1435846cbbd353faedde1133fe009dc84a178ee3b18b394688719fb350, таблицу targets 9821d2c0e59505e4c4f006c818ad08f1485e2e6a8b29bfdb5d86a71830c23be1, build script 060c178df3f13fcc557e27bc958dd30b3f218df52254197e080770bfd27d86ac и все toolchain hashes. Для Go ABI mips64le и ppc64 production-ready Rust target не заявлен; там остаётся Shell fallback. ARM артефакт собран для ARMv5te soft-float и успешно запущен через qemu-arm; отдельный запуск полного OpenWrt guest на ARMv7 не выполнялся.

Shell-only baseline на `HEAD` — 149 090 байт. Текущая сумма трёх Shell-файлов и x86_64 ELF — 1 106 960 байт; она не включает Go-движок, общую OpenWrt платформу, библиотеки или данные списков. Размер компонента вырос, сокращение Shell ещё не достигнуто.

## Незакрытые acceptance-гейты

1. Завершить перенос оставшейся lifecycle-координации и сократить OpenWrt glue после прохождения остальных acceptance-гейтов. Планировщик `enable/disable/restart`, service observation и cooldown решения теперь в Rust, но Shell всё ещё координирует часть регистрации, DNS observer и procd; три текущих Shell-файла занимают 181 928 байт. Для `mips64le` и `ppc64` Rust target отсутствует, поэтому Shell fallback остаётся обязательным.
2. Текущий x86_64 ELF прошёл полный OpenWrt QEMU install/update/WARP-remove/uninstall и updater overlap: p-86.18 → p-86.19 → p-86.20; проверено сохранение регистрационных файлов, license, config и списка. Применялись одноразовый acceptance key и синтетический account sentinel; реальная регистрация Cloudflare и Go-туннель не запускались.
3. Проверить procd как владельца реального `z2k-warpd` и восстановление после SIGKILL Go-движка, обрыва активного туннеля, перезапуска сети и перезагрузки роутера. В QEMU не было настоящей регистрации Cloudflare и работающего WARP-туннеля.
4. Измерить полный сценарий до/после с реальным Go-туннелем, включая CPU, RSS, время и установленный размер. Текущий замер охватывает только list-sync; выводов об ускорении всего WARP нет.
5. Сверка всей build-matrix.tsv завершена. Семь поддерживаемых Rust-вариантов (arm, AArch64, MIPS BE/LE, riscv64, i686 и x86_64) собраны из текущего рабочего дерева и каждый запущен через соответствующий QEMU-user; таблица размеров и SHA-256 приведена выше. Для mips64le и ppc64 production-ready Rust target отсутствует, поэтому Shell fallback сохранён. ARM-вариант — ARMv5te soft-float: он собран и запущен, но отдельный OpenWrt system-QEMU запуск на ARMv7 не выполнялся.

Миграция не объявляется завершённой, пока эти проверки и пользовательские acceptance-гейты не пройдены.
