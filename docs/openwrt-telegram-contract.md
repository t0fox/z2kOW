# OpenWrt Telegram-tunnel contract (Stage 3)

Источник истины о поведении — текущий upstream `necronicle/z2k`
(`z2k-enhanced`), НЕ память о старых схемах. Ниже — зафиксированный
фактический contract и его отображение на OpenWrt. Foundation FROZEN:
порт строится только в `platform/openwrt/*`, `package/openwrt/*`,
`tests/openwrt/*`, `docs/*` (+ точечный COMMON_HOOK, см. §11).

## 1. Upstream: один процесс на оба порта

`files/init.d/S98tg-tunnel:179` запускает РОВНО один процесс:

```text
GODEBUG=asyncpreemptoff=1 $BIN --listen=:1443 --listen=:$CDN_PORT --timeout=15m $TUNNEL_FLAGS -v
```

- `:1443` = Telegram transparent tunnel, `:1444` = cdnbase HTTP tunnel.
- Назначение соединения берётся из `SO_ORIGINAL_DST` и от порта не зависит
  (`mtproxy-client/listen.go`, `listener.go:getOriginalDst` — только IPv4).
- `S97z2k-http-tunnel` — пустышка с 07.09.2026 (legacy-совместимость +
  добивка старых процессов в `stop()`); отдельного архитектурного owner'а
  у `:1444` больше нет.
- `GODEBUG=asyncpreemptoff=1` — фикс краша Go-рантайма на MIPS softfloat,
  безвреден на остальных архах, ставится безусловно. Сохраняем.
- `--timeout=15m` — idle timeout соединений. Сохраняем.
- `-v` — verbose. На Keenetic потребитель — CONNECT_FAIL-скан watchdog'а
  и `mark_log`. На OpenWrt log-скана нет (см. §8) — флаг НЕ переносим,
  daemon пишет errors в logd через procd stdout/stderr.

## 2. Upstream: флаги и overrides (`/opt/zapret2/config`, у нас `$Z2K_CONFIG`)

| Ключ | Семантика (upstream) |
|---|---|
| `TG_PROXY_USER_DISABLED=1` | Пара `:1443+:1444` НЕ стартует; redirect rules отсутствуют; watchdog добивает остатки и выходит (`S98:87-93`, `watchdog:128-151`). Переключатель пары целиком, отдельного enable для `:1444` нет. Регенерация конфига сохраняет ключ (`lib/config_official.sh:2011,2052,2421`, дефолт `0`) |
| `Z2K_RELAY_SECRET` / `Z2K_RELAY_URL` | Override скомпилированных дефолтов → `--tunnel-secret=` / `--tunnel-url=` (`S98:141-147`). Пусто = compiled defaults (`main.go:29`: URL-дефолт `wss://213.176.74.63.nip.io/ws`, secret вшивается `-ldflags -X`, см. §5) |
| `ENABLED=0` | Global disable: init не стартует ничего (`init.d/z2k:43`), updater продолжает работать (frozen foundation) |

Quoting: `awk -F= ... gsub(/[" ]/,"",$2)` — значения без кавычек/пробелов.
Secret НЕ появляется в логах/диагностике (см. §10).

## 3. Upstream: firewall (iptables/ipset) — НЕ портируем буквально

`files/z2k-tg-redirect.sh` — single source of truth, авторитетные списки:

- v4 DC: `149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22
  91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23
  95.161.64.0/20 185.76.151.0/24`, ipset `z2k_tg_dc`, TCP/443 →
  REDIRECT `:1443` в TOP `PREROUTING` + `OUTPUT` (forwarded + router-local).
  ВНИМАНИЕ: авторитет — ЭТОТ файл, а не `files/lists/telegram_ips.txt`
  (тот — nfqws2-desync список, пересекается частично, v6-состав другой).
- v6 DC: `2001:67c:4e8::/48 2001:b28:f23c::/47 2001:b28:f23f::/48
  2a0a:f280:203::/48`, ipset `z2k_tg_dc6`, **весь TCP (без --dport!)** →
  REJECT tcp-reset в `FORWARD` + `OUTPUT`. Намеренная асимметрия: туннель
  v4-only, v6 RST даёт клиенту мгновенный fallback вместо 8s-таймаутов ТСПУ.
- CDN: `168.119.95.238/32`, TCP/80 → REDIRECT `:1444` в
  `PREROUTING` + `OUTPUT` (правила живут в S98 с 07.09.2026).
- conntrack: `conntrack -D -d <cidr>` по каждому v4-CIDR (+ CDN IP) на
  старте и при починке правил — только TG/CDN записи, никогда весь flush.
- Удаление: идемпотентные циклы по всем копиям; ipset'ы остаются
  (дешево, переиспользуются).

OpenWrt foundation: zapret2 runtime — единственный low-level nft owner,
raw iptables/ipset запрещены, второй таблицы нет (`test_ow_ownership.sh`).
Отображение — §6.

## 4. Upstream: lifecycle и watchdog

- Supervisor loop + PIDFILE/GENFILE (`S98:127-206`) — Keenetic-специфика
  (нет procd). На OpenWrt НЕ переносим: lifecycle владеет procd (§7).
- Watchdog (`files/z2k-tg-watchdog.sh`, minute-cron), переносим СЕМАНТИКУ:
  1. CONNECT_FAIL-шторм (≥10 в последних 40 строках после маркера) → restart.
     На OpenWrt log-скана нет — НЕ переносим (нечего сканировать без `-v`).
  2. process-dead → start. НЕ переносим: это делает procd respawn.
  3. rules-missing → re-insert + conntrack flush (§1.5 скрипта).
     Переносим как есть (идемпотентная конвергенция правил).
  4. Active HTTPS probe `core.telegram.org:443` через
     `--resolve ...:149.154.167.99`, 3 провала подряд → restart с bounded
     backoff 1,2,4,8,16,30 мин (`restart_allowed`), сброс — только удачной
     пробой. Переносим: проба + счётчик + backoff; действие — НЕ restart
     супервизором, а kill демона (procd поднимет заново), правила при этом
     НЕ churn'им (дешевле upstream и безопаснее для TG14).
  5. user-disabled → добить остатки, выйти, никогда не считать failure.
     Переносим.
  6. Log cap 2MB (хвост 200 строк). Нечего капать без `-v`-файла —
     НЕ переносим.
- WAN outage ≠ повод для restart storm: backoff-потолок + kill-only +
  отсутствие churn'а правил на probe-пути.

## 5. Binary и build secret

- `mtproxy-client/builds/tg-mtproxy-client-linux-arm64` (~5.8MB) — существующий
  artifact производственной линейки (aarch64_cortex-a53 → `linux-arm64`
  через `map_arch_to_bin_arch`, `lib/utils.sh:800-802`).
- `Z2K_TUNNEL_SECRET` вшивается `-ldflags -X` (`mtproxy-client/Makefile:46`);
  сборка без него успешна, но binary требует `--tunnel-secret` в runtime.
  НЕ пересобирать production binary без секрета; секрет не логировать, не
  хардкодить в shell, второго auth-механизма не придумывать.
- Доставка/обновление — ТОЛЬКО `refresh-binaries` (`Z2K_AU_SBIN=$Z2K_BIN`
  уже выставлен в `platform/openwrt/env.sh:72` — отдельный downloader
  запрещён). Координация stop/replace/start — через COMMON_HOOK §11.
- Бинарник живёт в `$Z2K_BIN/tg-mtproxy-client`, НЕ в `/opt/sbin`.

## 6. OpenWrt firewall mapping (nft)

Всё — внутри runtime-таблицы (`$Z2K_TG_NFT_TABLE`, default `inet zapret`,
переопределяемо; таблица — EXTERNAL runtime, адаптер её НЕ создаёт и
проверяет наличие до любых записей). Свои base chains (второй таблицы нет,
свои chains внутри чужой таблицы — разрешены ownership-тестом):

```text
chain z2k_tg_dst_pre { type nat hook prerouting priority -101; }
  tcp dport 443 ip daddr @z2k_tg_dc4  redirect to :1443
  tcp dport 80  ip daddr @z2k_tg_cdn4 redirect to :1444
chain z2k_tg_dst_out { type nat hook output priority -101; }
  (те же два правила — router-local OUTPUT как upstream)
chain z2k_tg_flt_fwd { type filter hook forward priority -1; }
  tcp ip6 daddr @z2k_tg_dc6 reject with tcp reset   # весь TCP, как upstream
chain z2k_tg_flt_out { type filter hook output priority -1; }
  (то же v6-правило — router-local)
chain z2k_tg_flt_in { type filter hook input priority -1; }
  tcp dport { 1443, 1444 } ct status dnat accept
  tcp dport { 1443, 1444 } drop
set z2k_tg_dc4  { type ipv4_addr; flags interval; }  # 10 CIDR из §3
set z2k_tg_dc6  { type ipv6_addr; flags interval; }  # 4 range из §3
set z2k_tg_cdn4 { type ipv4_addr; flags interval; }  # 168.119.95.238/32
```

- Приоритеты — plain integers (`-101` перед dstnat `-100`, `-1` перед
  filter `0`): арифметика вида `dstnat - 1` зависит от парсера nft,
  числа парсятся всегда. Эквивалент iptables `-I 1`.
- INPUT-guard (прямой WAN-доступ к wildcard-портам НЕ доходит до демона):
  REDIRECTнутые пакеты (LAN/router-local) несут conntrack-статус `dnat`
  (его ставит сам DNAT на весь conntrack — Established-ответы тоже),
  их пропускаем первыми; прямой трафик без статуса — `drop`. Порядок
  accept-до-drop КРИТИЧЕН. Scope строго наши порты: blanket
  `ct status dnat accept` без портов обошёл бы fw4-input для ЧУЖОГО
  DNAT-трафика (например чужих port-forward на роутер) — запрещён тестом.
  Интерфейсные матчи (`iifname`, wanif-сеты runtime) отвергнуты осознанно:
  имён runtime-сетов репозиторий не знает, а ct-статусу они не нужны —
  различение REDIRECT/direct работает на любом интерфейсе. LAN-direct на
  :1443 режется здесь же (defense in depth к in-binary guard).
  Это и есть доказательство инварианта вместо default-fw4-policy:
  структурно (точные shapes + порядок, TG17–TG22); живой DROP — только
  на роутере (ядра здесь нет).
- Конвергенция: `flush chain` + add rules, `flush set` + add elements —
  идемпотентна, дубли невозможны по построению, с core NFQUEUE-сетами
  не пересекается (свои имена, свои chains).
- `stop`: удалить chains (правила), sets оставить (быстрый рестарт).
  `uninstall`: удалить chains И sets (не litter'ить чужую таблицу).
- Self-dial: в firewall исключений НЕТ (как upstream) — механизмом служит
  in-binary guard `isSelfDialAny` (порт-матч 1443/1444 + loopback/private/
  linklocal/unspecified, `listener.go:93-136`, покрыт Go-тестами
  `selfdial_test.go`).
- WAN exposure: порты слушают wildcard (`:1443`/`:1444` — менять bind
  нельзя, transparent REDIRECT требует), защита — fw4 default
  reject wan→input + relay-side reject + client guard (полевые данные
  upstream: 16k отказов/сутки именно такого мусора, relay их режет).
  В glue — ни одного ACCEPT/input-правила (static-тест).

## 7. OpenWrt process ownership (решение: A, без второго сервиса)

- Один lifecycle owner: `/etc/init.d/z2k`. TG glue —
  `platform/openwrt/tg.sh` (package-owned), вызывается из init напрямую
  (`z2k_ow_tg 1` после `fw_apply`, `z2k_ow_tg 0` в `stop_service` до
  `fw_remove`): две строки в init, не монолит.
- `z2k_ow_tg 1` открывает ВТОРОЙ procd instance `z2k-tg` (первый — nfqws2):
  `procd_set_param command` с точным argv §1 (минус `-v`),
  `procd_set_param respawn 3600 5 5` — EXPLICIT bounded:
  threshold 3600s (прожил дольше — счётчик сброшен, падения здорового
  демона рестартятся всегда), timeout 5s (пауза), retry 5 (больше 5
  быстрых падений подряд — procd HALT'ит instance, instance.fail в logread,
  шторма нет; восстановление — `/etc/init.d/z2k restart`).
  Доказательство семантики: `procd/service/instance.c` (`instance_exit`:
  счётчик + halt при `respawn_count > respawn_retry`; `instance_config_parse`:
  дефолты C `{3600,5,5}` — мы фиксируем их явно, контракт не зависит от
  дефолтов, `retry=0` (бесконечный шторм) запрещён тестом).
  Тест проверяет именно выставленные параметры, не комментарий.
  Process-dead — зона procd, watchdog за него НЕ конкурирует (health-check
  при мёртвом процессе только чистит счётчики).
  `pidfile` под instance, `env SSL_CERT_FILE/SSL_CERT_DIR` — только при
  существовании путей, `stdout/stderr → logd`.
- Отдельный `/etc/init.d/z2k-tg` (вариант B) ОТКЛОНЁН: два сервиса =
  расходящиеся enable/disable, двойной lifecycle; custom.d-раннер для TG
  тоже отклонён: `DISABLE_CUSTOM=1` (upstream-дефолт) гасил бы first-class
  feature (комментарий в `firewall.sh` обновлён).
- Gate'ы старта instance: `ENABLED=1` (уже в init) + бинарник `+x` +
  `TG_PROXY_USER_DISABLED!=1`. Нет бинарника → нет демона И нет правил
  (никакого dead REDIRECT — детерминированная конвергенция вместо polling).
- Firewall apply vs daemon start race: правила ставятся безусловно при
  `z2k_ow_tg 1` (идемпотентно), демон — если gate'ы прошли; health-check
  доводит расхождения без рестарта демона.

## 8. Health check (cron, не supervisor)

`platform/openwrt/tg-check.sh check` каждые 5 минут
(`# z2k-tg-health`, install/remove в `schedule.sh`, postinst/prerm рядом
с updater-строкой). Каждый тик читает конфиг заново:

1. disabled (global/user) → конвергенция к «стоп» (процесс убит, правил
   нет), выход 0 — никогда не failure (TG2/TG3/TG15).
2. Нет бинарника → тихо, выход 0 (первая updater-доставка всё починит).
3. Rules/sets converge (включая hotplug-путь, см. §9) + targeted conntrack
   flush при доустановке.
4. Probe: `curl --resolve core.telegram.org:443:149.154.167.99` (8s/15s);
   нет curl → `uclient-fetch` без resolve (деградация задокументирована);
   нет обоих → только converge. Успех сбрасывает счётчики; провал +1
   (state в `$Z2K_TMP` — как upstream RSTATE в /tmp).
5. Счётчик ≥3 И с прошлого kill прошло ≥ backoff(1,2,4,8,16,30 мин) →
   kill демона (procd respawn'ит), записать причину. Правила НЕ трогаем.
6. Никогда: endless loop, tight polling, воскрешение при user-disable,
   restart storm при WAN outage (потолок backoff + kill-only).

## 9. WAN flap / firewall reload / restart

- `hotplug.d/iface/90-z2k`: после `reload_ifsets` — TG rules reconverge
  (идемпотентно, демон НЕ трогаем → PID stable, TG5). Sets переживают flap.
- `firewall reload` (рестарт сервиса): полная конвергенция через init;
  прямое `z2k_ow_fw_apply` вне init — только с последующим TG converge
  (порядок как в `start_service`).
- `restart`: stop (chains снять, sets оставить) → start (chains+sets+daemon).
- `z2k_ow_uninstall` (prerm): best-effort TG cleanup — chains И sets
  удалить, остальное (конфиг/user-lists/trust/daemon-state) — по frozen
  uninstall-контракту.

## 10. Secret hygiene

- `Z2K_RELAY_SECRET` живёт только в `/etc/z2k/config` (user-owned) и в
  argv процесса (как upstream — задокументированный риск, НЕ ухудшаем).
- Glue: argv собирается в локальной переменной, `set -x` запрещён,
  никакого `echo $argv`, health-check argv не печатает.
- Тесты/диагностика: secret redacted; static-тест ищет утечки
  (`tunnel-secret` рядом с `echo/log`).

## 11. COMMON_HOOK (единственный): `au_service_for_binary` на OpenWrt

```text
COMMON_HOOK:
file: lib/auto_update.sh (au_service_for_binary)
reason: refresh-binaries останавливает владельцев ДО подмены бинарника
  и стартует ПОСЛЕ. На OpenWrt keenetic-пути не +x → проскакивал молча:
  бинарник менялся под живым procd-процессом без координации (TG13).
why adapter-only impossible: маппинг владельцев живёт в common-функции;
  адаптер не может перехватить её без форка.
change: platform-case возвращает /etc/init.d/z2k для tg-mtproxy-client
  (stop → atomic replace → start целиком сервисом: детерминированно,
  переиспользует init-конвергенцию; только при реальной замене).
Keenetic regression proof: keenetic-ветка функции нетронута (platform-gate
  первым); Keenetic updater-наборы re-run (converge/decide/steps/health/
  compat/upgrade_from_published).
```

Больше common-правок не планируется (бюджет: 1 функция).

## 12. Зависимости и ownership

- `DEPENDS += +conntrack` (`conntrack -D` load-bearing для UX; best-effort
  `|| true` остаётся). `ca-bundle` НЕ требуем: `z2k-roots.pem` + системный
  store, каждый — по existence-check; двух корней достаточно для relay
  (доказано upstream-тестом отпечатков).
- PACKAGE: `tg.sh`, `tg-check.sh`, правки init/hotplug/schedule/uninstall/
  Makefile/ownership.map. UPDATER: `telegram_ips.txt` (авто через
  `files/lists/*.txt`), `z2k-roots.pem` (авто через `files/etc/*`),
  `tg-mtproxy-client` (авто через refresh-binaries + `Z2K_AU_SBIN`).
  `release_map.sh` менять НЕ нужно (drift-тест подтвердит).
- Webpanel/RT/WARP/PBR/fwmark/table 989 — вне scope, не трогаем.

## 13. Отклонения от upstream (осознанные, задокументированные)

1. Нет shell-supervisor (PIDFILE/GENFILE/backoff-loop) — procd respawn.
2. Нет `-v` и файлового лога с cap/mark — logd через procd; CONNECT_FAIL-скана нет.
3. Нет S97 (legacy-пустышка не портируется вовсе).
4. Нет minute-cron watchdog'а как супервизора — 5-мин health-check (converge + probe + kill-only backoff).
5. v6 REJECT — весь TCP без dport (как upstream; шире формулировки Stage-3 §11 — подтвердить владельцем).
6. Собственные chains в чужой таблице вместо TOP-правил в общих chains (эквивалент приоритетов); приоритеты — числами.
7. INPUT-guard (прямого аналога в upstream нет — там wildcard прикрыт relay-reject + client-guard + полем; здесь — доказуемый nft-drop).
8. Crash-loop: upstream супервизор рестартит вечно (cap 30s); здесь procd halt'ит после 5 быстрых падений — чинить нечего, штормить нечем.
