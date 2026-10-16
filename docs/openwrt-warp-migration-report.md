# WARP: промежуточный отчёт миграции на Rust

Дата замеров: 2026-10-15. Проверки и сборки выполнялись в WSL Debian и OpenWrt 25.12.5 QEMU. WARP остаётся выключенным, пока пользователь его не включит; Rust-контроллер поставляется как одноразовый CLI. Go `z2k-warpd` и его транспортные протоколы не изменялись.

## Актуализация 2026-10-16: полный package lifecycle

- В изолированном OpenWrt 25.12.5 x86_64 QEMU прошёл `SUITE[ow-warp-package-lifecycle-qemu]: pass` на реальных `apk`, `procd`, `iproute2` и `nftables`: install `p-86.21`, update `p-86.22`, update `p-86.23` при занятом общем Rust lock, WARP remove и полный uninstall.
- Инсталлятор проверял подписанные локальными acceptance-ключами манифесты, размеры и SHA-256 архивов. `p-86.22` и `p-86.23` — локальные acceptance-сборки на базе официального OpenWrt rootfs; это не production-релиз. Для системных зависимостей использовались настоящие официальные OpenWrt APK-индексы и пакеты.
- Проверены сохранность `device.json`, `account.json`, лицензии, конфигурации и списка через обновления и WARP remove; полный uninstall удалил приложение, CLI и init-службы, не затронув регистрационные файлы и лицензию. После теста временный WAN удалён, `distfeeds.list` восстановлен побайтно из исходного rootfs, адрес и маршрут QEMU возвращены к baseline. Диск только изолированного QEMU увеличен для прохождения реального space guard инсталлятора.
- Активный зарегистрированный Go-туннель, Cloudflare Edge и этапные enable/disable timings в этом прогоне не запускались и не измерялись. Имеющийся list-sync benchmark выше остаётся узким замером; вывод о производительности полного WARP не делается.

## Текущий срез: удаление дублирующей Shell-логики

- `platform/openwrt/warp.sh` сокращён до OpenWrt/procd glue: загрузка путей и env, сборка команды Go-движка для procd и dispatch в одноразовый Rust CLI. Shell-бизнес-fallback удалён; без Rust-контроллера WARP-команды завершаются ошибкой, а необязательная подсистема остаётся выключенной.
- `warp-proc.sh` и `warp-domain.sh` оставлены тонкими OpenWrt entrypoints. Rust владеет lifecycle, списками, состоянием WARP, nftables, PBR, health-check и восстановлением. Go `z2k-warpd` и его протоколы не менялись.
- В WSL прошли `cargo fmt --check`, полный `cargo test --offline --locked` и Clippy с `-D warnings`. Реальный Shell-entrypoint прошёл с `ip` и `nft` в network namespace; static — 98/98, disable-guard — 11/11, lifecycle — pass. Проверка подтвердила отсутствие nft/PBR-мутаций при исправном повторном reconcile.
- OpenWrt 25.12.5 QEMU прошёл актуальный `qemu-warp-disable-remove.sh` с настоящими procd, iproute2 и nftables: отказ при неверном владении маршрутом, безопасное состояние при временной ошибке nft и сохранение registration/license/list данных после remove.
- `scripts/openwrt/build_warp_controller.sh --test` собрал все 7 вариантов из `rust-targets.tsv`; каждый статический ELF запущен через соответствующий QEMU-user. Для MIPS BE/LE использован установленный `nightly-2026-07-21` с `rust-src`; без сети пропущена только повторная проверка установки rustup, сами компиляторы, SDK, линкеры и эмуляторы реальные.
- При прежней проверке физического роутера сохранён read-only baseline: OpenWrt 25.12.5, `mediatek/filogic`, AArch64; `GAME_WARP_ENABLED=0`, PBR отсутствует, таблица 989 пуста, nft содержит штатные `fw4` и `zapret2`, процесс WARP не запущен. На тот момент штатный бинарник Rust-контроллера не был установлен; `device.json` присутствовал. Production-profile AArch64 ELF из матрицы временно запущен командой `health-observation`, вернул `UNKNOWN`, затем удалён. После проверки конфигурация, маршруты и nft совпали с baseline; откат временного файла подтверждён.
- Полный `tests/openwrt/run.sh` в WSL после обновления main завершился `4237 pass, 0 fail` (146 suites); пропущены только runtime-artifact и RT somark из-за отсутствующих внешних архивов. Текущий `qemu-warp-disable-remove.sh` отдельно прошёл на OpenWrt 25.12.5 QEMU с настоящими procd, iproute2 и nftables; после теста baseline маршрутов, nft и интерфейса восстановлен.
- В прежней 30-повторной серии list-sync использовался x86_64-musl ELF SHA-256 `99af858689fd79e80d697a16fd1b0342501295ec9086f320744127ee6c4f59cd`: Shell 2,011 с wall / 1,283 с user / 0,615 с system; Rust 0,476 / 0,165 / 0,109 с. Пиковый RSS обоих дочерних процессов — 11 452 KiB; nft-вызовы — 120 против 30. Это исторический узкий замер синхронизации списков, не полного WARP.
- В этой сессии production-profile собраны и запущены через QEMU-user все 7 Rust ABI: ARM, AArch64, MIPS BE/LE, riscv64, x86 и x86_64. Локальный `PROVENANCE` записывает базовый commit `f5d454b`; поскольку рабочее дерево содержало незакоммиченный код миграции, эти ELF использовались только для локальной проверки, не как релизные артефакты. CI должен собрать артефакты уже для итогового commit.
- Go-матрица содержит `mips64le` и `ppc64`, которых нет среди production-ready Rust-целей. По решению пользователя fallback удалён везде; WARP на этих архитектурах не поддержан до появления и проверки Rust-цели.
- Полный package install/update/WARP-remove/uninstall на текущем QEMU rootfs прошёл 2026-10-16 (см. актуализацию выше). Полный активный Go-туннель через procd, восстановление после SIGKILL/обрыва туннеля, перезапуск сети и reboot при зарегистрированном туннеле и этапные timings на роутере всё ещё не проверены; миграция не объявляется завершённой.

Записи ниже — история промежуточных снимков. Упоминания Shell fallback относятся
к состояниям до решения пользователя удалить его на всех архитектурах; они не
описывают текущий код. То же относится к отдельно помеченному отменённому
эксперименту с Go Edge-кэшем.

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
| Три Shell-entrypoint на `HEAD`: `warp.sh`, `warp-proc.sh`, `warp-domain.sh` | 185 169 байт |
| Текущие три Shell-entrypoint | 20 360 байт |
| Production-profile Rust controller ELF, AArch64 | 1 118 440 байт |
| AArch64 ELF и три текущих Shell-entrypoint | 1 138 800 байт |
| Изменение этой суммы относительно трёх старых Shell-файлов | +953 631 байт |
| Все 7 Rust ELF предыдущего многоплатформенного payload | 8 203 804 байта |
| Предыдущие 7 ELF и три текущих Shell-entrypoint | 8 224 164 байта |

В этой серии пересобран только AArch64 target — архитектура физического роутера. Остальные ABI и многоплатформенная сумма относятся к предыдущей сборочной серии и не подтверждались повторной сборкой. Три Shell-entrypoint — только OpenWrt glue; Go `z2k-warpd` в сравнении не менялся.

| Go ABI | Rust target | Размер ELF | SHA-256 | Запуск |
|---|---|---:|---|---|
| arm / GOARM=7 | armv5te-unknown-linux-musleabi (soft-float) | 1 076 000 байт | e9958a7964d345187f96fa6159a76d1e93fe1bb6582810e0124b5f7fac275b0b | QEMU-user |
| arm64 | aarch64-unknown-linux-musl | 1 118 440 байт | cb9f24e4f24c47644f7353571b6cfb469a786a5bc70bb294776ab27e0317a15c | QEMU-user |
| mips | mips-unknown-linux-musl (BE) | 1 445 260 байт | 2904d18a84775b5cd8c98a2a3cb8a000cf7ee4057b6b1e19e08b665b0ecd6ae7 | QEMU-user |
| mipsle | mipsel-unknown-linux-musl | 1 445 260 байт | b7735bed32d1cc993cb017c2e6257c9e089e5102ea990f77052ccd0ddbfc774c | QEMU-user |
| riscv64 | riscv64gc-unknown-linux-musl | 962 288 байт | e7388326f003af28d295e80044b178723fd96ef77091b5f7cec7f547848fb5bc | QEMU-user |
| 386 | i686-unknown-linux-musl | 1 088 748 байт | 29507dadc16986bd14e9a5d2bd88815d84bd1632c55204af8f39de6025e0370f | QEMU-user |
| amd64 | x86_64-unknown-linux-musl | 1 171 576 байт | d75301a4d58f7f72a64bc7ecbe2b9157fff55fe83f926b98d31fb3a4461a2992 | QEMU-user |

Go ABI `mips64le` и `ppc64` не имеют production-ready Rust-цели в текущей таблице. По решению пользователя Shell fallback удалён; WARP на этих двух ABI недоступен.

## Незакрытые acceptance-гейты

1. Повторить полный OpenWrt QEMU package install/update/disable/remove/uninstall на финальных production-артефактах. Изолированный QEMU lifecycle прошёл на локальных acceptance-сборках `p-86.21`–`p-86.23`: install, два update (включая update при занятом lock), WARP remove и полный uninstall. Это не production-релиз.
2. Проверить procd как владельца реального `z2k-warpd` и восстановление после SIGKILL Go-движка, обрыва активного туннеля, перезапуска сети и reboot. QEMU не запускал зарегистрированный Go-туннель; текущий роутер оставался в состоянии WARP off.
3. Выполнить acceptance после установки hotfix на роутер. Там уже установлен прежний AArch64 Rust ELF, но отсутствуют текущие init/hotplug-файлы; WARP выключен, поэтому новый lifecycle пока не проверен.
4. Измерить полный сценарий до/после на реальном Go-туннеле: время, CPU, RSS и размер установленного компонента. Имеющийся замер покрывает только list-sync; полного прироста производительности не заявляется.

Миграция не объявляется завершённой, пока эти проверки и пользовательские acceptance-гейты не пройдены.

## 2026-10-16: замеры lifecycle-контроллера

Для `lifecycle enable/disable/remove/restart` добавлены монотонные замеры.
Каждая операция пишет одну строку `WARP_TIMING` с operation ID и общим
временем; `Z2K_WARP_DIAGNOSTICS=1` включает времена этапов. Контроллер
измеряет блокировку, конфигурацию, регистрацию, nft list sync, domain/MARK,
procd transition, ожидание готовности Go, PBR reconcile и очистку. Детали
внутреннего Edge scan, WireGuard handshake и transit остаются в диагностике
неизменённого Go-движка; контроллер не выдаёт ожидание `ready` за эти этапы.

Проверки в WSL на этом срезе: `cargo test --offline`,
`cargo clippy --offline --all-targets -- -D warnings`,
`cargo fmt --all -- --check`, `git diff --check` и 11 тестов
`lifecycle_cli` — пройдены. Новый CLI-тест сначала упал без timing-строк,
затем прошёл с реализацией. Изоляция `WARP_OP_FILE` в фикстуре устраняет
взаимное влияние параллельных тестовых процессов.

Живой зарегистрированный туннель в этой серии не запускался. Поэтому новые
строки ещё не дали замеров Edge scan, handshake, transit, CPU/RSS полного
включения и повторного включения с кэшированным Edge. Физический роутер и
production-релиз не менялись.

## 2026-10-16: восстановление после сетевого события

В QEMU подтвердилось, что `/etc/init.d/network restart` не вызывает
`reload_service` WARP: `service_triggers` на UCI network/firewall не покрывает
обычный сетевой restart. Поэтому один только procd reload не восстанавливал
PBR сразу после подъёма Go-движка. Добавлен конечный `startup-reconcile` при
`ifup` через OpenWrt hotplug; init start/reload также запускает этот reconcile
однократно. Он ждёт готовность с ограниченным интервалом, а затем Rust
контроллер восстанавливает PBR. При активной операции WARP повторный вызов
пропускается.

WSL: статический Shell-контракт — 108/108; интеграционный запуск с настоящими
`ip` и `nft` в network namespace прошёл. Он выполнил Rust `startup-reconcile`
на исправном состоянии и подтвердил отсутствие изменений маршрутов, правил и
nft-транзакции. Три цикла enable/disable на настоящих `ip`/`nft` восстановили и
очистили принадлежащий WARP PBR. Shell-файлы прошли `sh -n`.

Дополнительно тест искусственно отклонил один вызов `nft -f -` перед запуском
реального `nft`: неудачный batch не заменил прежний адресный набор, fail-open
снял WARP PBR, а следующая сверка с настоящими `nft` и `ip` обновила набор и
восстановила принадлежащие WARP маршрут и правило.

OpenWrt QEMU с реальными procd/iproute2/nft: тест прошёл. Он проверил
отсутствие дубликата instance, procd respawn после SIGKILL тестового процесса,
вызов reconcile через init reload и сохранение процесса/ubus instance после
`network restart`; cleanup удалил тестовые nft и runtime-состояние. Отдельно
восстановлены исходные QEMU адрес и маршрут. В тесте использовался процесс-
заглушка, не зарегистрированный Go-туннель; сам network restart не является
проверкой доставки `ifup` hook в продуктовой установке.

Проверка физического роутера, живого Cloudflare Edge и времени полного
включения/выключения всё ещё не выполнена. Поэтому надёжность реального
туннельного восстановления и задержки полного сценария остаются открытыми
acceptance-гейтами.

## 2026-10-16: read-only baseline физического роутера

Подключение выполнено напрямую по SSH к `192.168.1.1`; состояние не менялось.
Роутер — OpenWrt 25.12.5, aarch64. В конфигурации `GAME_WARP_ENABLED=0`,
транспорт `wg`, `Z2K_WARP_WDTT=0`; процесса `z2k-warpd` нет. `ip rule` содержит
только системные правила, таблица маршрутизации 989 пуста. В nft присутствуют
`inet fw4` и `inet zapret2`, отдельной WARP-таблицы нет. Rust-контроллер и
Go-движок установлены; `device.json` и registration stamp сохранены.

Этот роутер пока не содержит текущую интеграцию: отсутствует
`/etc/init.d/z2k-warp`, а установленные `warp.sh` и `90-z2k` не содержат
`startup-reconcile`. Следовательно, он не может проверить новый lifecycle или
hotplug-путь. Роутер оставлен в исходном выключенном состоянии; откат не
потребовался и ни один пользовательский файл не менялся.

## 2026-10-16: текущая сборка target AArch64

Для целевой архитектуры роутера выполнена release-сборка
`aarch64-unknown-linux-musl`. Вызов без linker override выбрал host `cc`/`ld` и
завершился ошибкой; сборка с
`CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=aarch64-linux-gnu-gcc`
прошла. ELF статический, 1 118 440 байт, SHA-256
`cb9f24e4f24c47644f7353571b6cfb469a786a5bc70bb294776ab27e0317a15c`.
`qemu-aarch64` успешно запустил валидную команду
`service-plan enable 1 1 1` и вернул `reload`.

На физическом роутере установлен старый ELF размером 1 014 672 байта; текущий
кандидат туда не копировался. Полный installable hotfix, измерения живого
Go-туннеля и реальный роутерный acceptance ещё не выполнены.

## 2026-10-16: временный эксперимент с кэшем Cloudflare Edge (отменён)

Повторная проверка выявила, что отказанный кэшированный зарубежный Edge мог
снова открываться в том же полном проходе. Добавлен version 2 кэша с причиной
отказа, временем и сроком повторной проверки, привязанный к существующему WAN
fingerprint. Старый положительный кэш version 1 остаётся читаемым. Временный
TTL составляет 2 минуты для handshake/Geo и 5 минут для transit. Отказанный
candidate не исключает повторное сканирование всего набора: при отрицательном
кэше всех кандидатов запускается полный повторный проход. Сортировка и алгоритм
выбора Edge не менялись.

WSL: `go test ./...` и `go test -race ./internal/edgepick ./internal/engine -count=1`
пройдены. Проверены один проход без двойного открытия, повторный
запуск на том же WAN, истечение TTL, смена WAN, повторная проверка при полностью
отрицательном кэше и чтение положительного кэша version 1.

Дополнительно `z2k-warpd` собран для `linux/arm64` с `CGO_ENABLED=0`, тегом
`openwrt` и штатным overlay. QEMU запустил целевой ELF и команду `version`.
Это проверка запуска CLI, не проверка реального WARP-транзита.

Это покрывает поведение кэша и движка в тестах, но не измеряет реальный
зарегистрированный туннель. Время холодного/повторного включения, живой Edge,
нагрузка CPU/RSS и acceptance установленного hotfix остаются открытыми;
прирост производительности не заявляется.

Этот локальный эксперимент не входит в итоговую миграцию: по требованию
сохранить Go `z2k-warpd` неизменным четыре затронутых Go-файла возвращены к
состоянию `origin/main` до публикации. Проверка итогового дерева не показывает
разницы в `z2k-warpd`. Описанные выше Go-тесты характеризуют только отменённый
локальный эксперимент и не считаются проверкой release candidate.

Read-only проверка работающей OpenWrt QEMU-консоли на порту 4579 подтвердила,
что procd отвечает, но `z2k-warpd`, `nfqws2`, `z2k-rt-proxy` и `tg-ws-proxy`
там не запущены, а Go-бинарника нет. Образ удерживается живой QEMU-процессом;
его не менял. Это окружение не может подтвердить запуск Go под procd или
восстановление реального туннеля.

## 2026-10-16: lifecycle и восстановление в изолированном QEMU-клоне

Проверка выполнена на отдельном клоне OpenWrt с настоящими BusyBox, procd,
`iproute2` и `nftables`. В гостя временно установлен x86_64-musl release
контроллер из текущего дерева: 1 254 144 байта, SHA-256
`50a1188765a177aa5f91b1e07c4b6565aa020617bc23c4ba66efc066a93e1267`; команда
`version` вернула `0.1.0`. После проверки гостевые конфигурация, списки,
Shell/init-файлы и прежний контроллер восстановлены; регистрацию не запускал,
штамп регистрации не менялся. Клон выключен.
Физический роутер и QEMU-образы на портах 4568 и 4579 не менялись.

Использованы синтетические registration/device-файлы и loopback endpoint;
живой Cloudflare Edge и успешный handshake не проверялись. При
`WARP_READY_WAIT=1` включение заняло 1 965 мс: config 10 мс, registration
0 мс, nft list sync 47 мс, domain policy 59 мс, mark sync 133 мс, procd
transition 677 мс и readiness wait 1 006 мс. Команда вернула `code=2`:
движок запущен, но синтетический туннель остался неготовым.

Выключение после запуска заняло 988 мс: nft cleanup 303 мс, procd transition
561 мс, ожидание завершения Go 110 мс, PBR cleanup 0 мс и запись конфигурации
2 мс. Повторное выключение заняло 202 мс. Снимки `ip rule`, таблицы 989 и
полного nft ruleset до и после повторного выключения совпали; остались только
системные правила, таблица 989 пуста. Это подтверждает отсутствие лишних
маршрутных изменений в данном исправном выключенном состоянии.

QEMU воспроизвёл гонку: `procd stop` мог вернуться до выхода Go, и прежняя
немедленная проверка ошибочно считала остановку неудачной. В контроллере
добавлено ограниченное ожидание завершения процесса после возврата procd, а в
`lifecycle_cli` закреплён регрессионный тест асинхронного stop.

SIGKILL Go-процесса восстановил procd с новым PID за 5,16 с. После
`/etc/init.d/network restart` (1,86 с) Go PID и `GAME_WARP_ENABLED=1`
сохранились. При искусственной временной ошибке запуска nft disable завершился
ошибкой за 20 мс и сохранил включённую конфигурацию и работающий Go-процесс.
После восстановления запуска nft повторный disable завершился
успешно за 751 мс; Go-процесс, WARP rules и маршрутная таблица 989 очищены.

Полный `cargo test` в WSL прошёл; 2 теста пропущены согласно их требованиям:
ручной BusyBox smoke и отдельный network namespace с `CAP_NET_ADMIN`.
`cargo fmt --check` и `git diff --check` прошли. Также прошёл
`cargo clippy --locked --all-targets -- -D warnings`. Холодный старт с
ожиданием readiness 120 с ранее занял 121 472 мс на том же синтетическом
endpoint; эти значения не измеряют доступность зарубежного Edge. Повторное
включение с известным рабочим Edge, доставка трафика через реальный туннель,
CPU/RSS и сравнение производительности остаются непроверенными; прирост
производительности не заявляется.

## 2026-10-16: read-only проверка роутера после установки

Прямой SSH-снимок `192.168.1.1` не менял состояние. Роутер — OpenWrt 25.12.5,
AArch64; `GAME_WARP_ENABLED=0`, транспорт `wg`, `Z2K_WARP_WDTT=0`. Процесса
`z2k-warpd` нет, `/etc/init.d/z2k-warp` отсутствует, `ip rule` содержит только
системные правила, таблица 989 пуста; в nft есть только `inet fw4` и
`inet zapret2`.

Установленный `/usr/lib/z2k/platform/openwrt/bin/linux-arm64/z2k-warp-controller`
возвращает версию `0.1.0`, размер — 1 014 672 байта, SHA-256
`71953582ff713705d65bddc3bf1161e575bba03b81c651cf27bd70cdb189916a`. Поэтому
на роутере пока нет init-интеграции для проверки lifecycle, а фактический WARP
выключен.

Текущий исходный код отдельно собран в WSL только для AArch64:
`aarch64-unknown-linux-musl`, 1 118 440 байт, SHA-256
`a3643629a396d01cc6c41bf87c9dca2e4f6857b7fd834b34692f0312332b5a12`.
Это на 103 768 байт (10,2%) больше установленного контроллера; сравнивается
размер ELF, не полный пакет.
`qemu-aarch64` запустил `version` и чистую команду `service-plan enable 1 1 1`,
получив `reload`. Это подтверждает запуск CLI-кандидата в эмуляторе, но не
заменяет проверку на роутере; кандидат туда не копировался.

## 2026-10-16: полный OpenWrt набор в WSL

После исправления владения `/etc/init.d/z2k-warp` запуск `sh tests/openwrt/run.sh`
завершился с `OPENWRT-SYNTAX: pass=200 fail=0` и
`OPENWRT: pass=4251 fail=0`; runner выбрал 146 наборов. В ходе прогона также
проверены настоящие `iproute2` и `nftables` в network namespace, lifecycle,
PBR, отказ `nft`, повторное включение/выключение и отсутствие лишних изменений
маршрутов в исправном состоянии.

Два теста пропущены по условиям окружения: отсутствуют локальный архив zapret2
для `ow-runtime-artifact` и `Z2K_RT_TARBALL` для `ow-rt-somark`. Оба теста не
проверяют WARP.

Этот WSL прогон не заменяет незавершённые acceptance-проверки с живым
зарегистрированным Cloudflare Edge и установленной новой версией на роутере.
Read-only снимок роутера показал старый контроллер без `/etc/init.d/z2k-warp`;
его состояние не менялось.

## 2026-10-16: procd lifecycle и сохранение процессов z2k в QEMU

Отдельный чистый OpenWrt 25.12.5 x86_64 QEMU прошёл
`tests/openwrt/qemu-warp-procd-service.sh` с кодом 0. В госте использовались
настоящие procd, nftables и `iproute2-6.18.0` (проверка `ip -Version`); для
`iproute2` установлены официальные пакеты `ip-full`, `libbpf1`, `libelf1`.
SHA-256 теста совпал с переданным в гостя файлом:
`cc8d2f228ce3ce4bf136065bb72408a3f821f2bdf4256ee9be091dce4b81f5eb`.

Сценарий поднял временный procd-владелец `z2k` с тремя долгоживущими
процессами `nfqws2`, `z2k-rt-proxy`, `tg-ws-proxy` и старым вложенным
`z2k-warp`. Новый WARP init-инстанс удалил старый вложенный инстанс,
зарегистрировался отдельно, а PID всех трёх процессов `z2k` сохранились при
start/enable/disable/restart WARP. SIGKILL тестового движка привёл к запуску
нового PID под procd; reload и перезапуск сети вызвали reconcile, после stop
инстанс исчез. После теста временный `/etc/init.d/z2k`, каталог fixture и
тестовые процессы удалены; `ubus` вернул `{}` для `z2k-warp`.

Сценарий намеренно использует неготовый тестовый движок. Он подтверждает
изоляцию процессов и lifecycle procd, но не регистрацию, живой Go-туннель,
доставку трафика или зарубежный Edge. При сетевом restart в выводе было
`Command failed: Not found`; интерфейс действительно прошёл down/up, а все
проверки reconcile и PID завершились успешно. Это сообщение остаётся
диагностической оговоркой для acceptance на полноценном образе.

Дополнительно на том же изолированном QEMU прошли
`qemu-warp-controller.sh`, `qemu-warp-route.sh`,
`qemu-warp-disable-remove.sh` и `qemu-warp-list-lock.sh`. Для observer-тестов
в образ добавлен официальный `kmod-nfnetlink-log` с ABI текущего ядра; до
установки модуля QEMU не мог принять `log group`, поэтому этот первый прогон
не засчитывался. Повторные прогоны контроллера и teardown завершились `pass`.

Тест маршрутов подтвердил реальные операции `iproute2`: первая reconcile
выполнила 8 вызовов `ip`, исправное повторное состояние — 3 чтения и
`changed=0`; снимки правил и таблицы 989 совпали побайтно. Тест teardown
проверил отказ при чужом owner-файле и недоступном `nft`, затем успешное
восстановление. В QEMU disable занял 313 мс, remove — 258 мс; это измерения
синтетической конфигурации x86_64, не скорость реального туннеля или роутера.

QEMU lock-тест ранее содержал вызов отсутствующей функции `_warp_user_locked`
и ложно принимал код 127 за успешную блокировку. Он исправлен: во время
`transaction-active` теперь вызывается настоящий `warp_disable`, проверяются
причина отказа Rust, сохранение выключенного флага и освобождение lock. Новый
прогон завершился `pass` без обращения к отсутствующему procd-инстансу.

## 2026-10-16: повторный package lifecycle QEMU acceptance

Повторный полный сценарий `tests/openwrt/qemu-warp-package-lifecycle.sh` прошёл
на OpenWrt 25.12.5 x86_64 QEMU с WAN через DHCP и 512 МиБ ext4. Временный
acceptance fixture содержал текущие WARP-файлы и controller SHA-256
`50a1188765a177aa5f91b1e07c4b6565aa020617bc23c4ba66efc066a93e1267`; манифесты
подписаны отдельным тестовым ключом. Это проверяет текущий payload и путь
пакетной транзакции, но не готовый production hotfix или его ключ.

Прошли fresh install p-86.18, обновления p-86.19 и p-86.20 под конкуренцией
спискового updater, WARP remove и полный uninstall. Registration/account,
license, пользовательский список и транспорт сохранились. После uninstall тест
проверил отсутствие приложения, procd-служб, WARP nftables-правил, правил
маршрутизации и записей в таблице 989. Wall time сценария — 2 мин 55,89 с;
измеренная стадия WARP remove — 313 мс. HTTP fixture намеренно задерживал
списковые ответы на 6 секунд, поэтому wall time нельзя сравнивать с обычной
установкой или трактовать как производительность WARP.

На физическом роутере остаётся прежний controller без `/etc/init.d/z2k-warp`,
WARP выключен. Enable/disable timings, повторное включение с известным Edge,
активный Go-туннель и восстановление на этом роутере ещё не проверены; другие
архитектуры в этой сессии не собирались.

## 2026-10-16: исправление uninstall для штатной структуры nft

Code review обнаружил, что guard удаления таблицы `inet zapret2` отвергал
штатные `flowtable ft` и цепочки `flow_offload*`, из-за чего полный uninstall
оставлял payload на месте. Дефект воспроизведён на реальном OpenWrt 25.12.5
QEMU до исправления.

Parser теперь учитывает вложенные фигурные скобки, принимает только известные
имена штатных set/chain/flowtable и продолжает fail-closed для неизвестных
объектов. Тест дополнительно отказывается работать, если таблица уже существует.
`sh tests/openwrt/test_ow_uninstall_parity.sh` завершился `pass=96 fail=0`.

После исправления `tests/openwrt/test_ow_uninstall_nft_real.sh --inside` прошёл
в отдельном OpenWrt 25.12.5 QEMU с настоящими nft и BusyBox awk: создавались
реальная `flowtable ft`, штатные цепочки и наборы с элементом; таблица удалялась,
таблица `fw4` сохранялась, неизвестные set/chain и недоступный `nft` отклонялись.
Обёртка этого теста в WSL не смогла создать flowtable из-за возможностей ядра
WSL, поэтому реальную проверку выполнил OpenWrt QEMU.

На момент этой записи полный install/update/remove package acceptance выше был
завершён до точечной правки; после неё повторили только отдельный реальный nft
acceptance. Проверки живого Edge и физического роутера оставались незавершёнными.

## 2026-10-16: повторный package lifecycle после исправления nft uninstall

Полный `tests/openwrt/qemu-warp-package-lifecycle.sh` прошёл в OpenWrt 25.12.5
x86_64 QEMU на чистом 512 МиБ образе с настоящими `procd`, `apk`, `iproute2` и
`nftables`. WAN работал через DHCP на отдельном `eth1`. Проверены install
`p-86.18`, update `p-86.19`, update `p-86.20` при активной блокировке list
updater, WARP remove и полный uninstall при конкурирующем updater. Suite завершён
`SUITE[ow-warp-package-lifecycle-qemu]: pass` с кодом 0.

Для этого прогона только локальный acceptance-архив `p-86.20` включал текущий
`uninstall.sh`; его размер, SHA-256 и временная Ed25519-подпись проверены.
Системы подписи production-релиза и регистрации Cloudflare не использовались.
Временный HTTP fixture задерживал ответы списка на 12 и 25 секунд для проверки
общего mutation lock. Suite подтвердил сохранение registration/account, license,
настройки транспорта и пользовательского списка. Замер `WARP remove` составил
336 мс. Общее время этого прогона не замерялось; сравнение скорости по нему не
делается. Сообщения `FIB table does not exist` возникли в проверках уже удалённой
таблицы маршрутизации; suite всё равно подтвердил её отсутствие.

Проверки включения зарегистрированного туннеля, повторного подключения к
известному Edge и восстановления на физическом роутере остаются незавершёнными.
