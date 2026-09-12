# OpenWrt RT-proxy contract (Stage 4)

Источник истины — текущий upstream `necronicle/z2k` (`z2k-enhanced`),
НЕ память. Foundation FROZEN; порт только в `platform/openwrt/*`,
`package/openwrt/*`, `tests/openwrt/*`, `docs/*` (+ точечный COMMON_HOOK §13).

> Target: OpenWrt 25.12.5 ships dnsmasq 2.93.
> Do NOT assume an IPv4-only host-record suppresses AAAA forwarding:
> A-only `--host-record` перекрывает A локально, но отсутствующий RR-type
> (AAAA) 2.93 может отправить upstream — клиент уйдёт напрямую по IPv6
> в обход прокси (доказанный баг, лечится dual-record ниже). Если будущий
> dnsmasq поменяет behavior, dual-схема остаётся детерминированной
> (оба типа отвечают локально при любом поведении forwarding).

## 1. Upstream: цепочка и argv

```text
exact RuTracker hostname → ndmc DNS-override → 10.171.171.171
→ iptables TCP/443 REDIRECT → localhost :1445
→ z2k-rt-proxy → ps1.blockme.site HTTPS CONNECT pool
```

Daemon argv (`files/init.d/S96z2k-rt-proxy:160`):

```text
GODEBUG=asyncpreemptoff=1 $BIN --listen=:1445 --timeout=15m
```

Без `-v`, без секретов. Дефолты прокси/здоровья/резолвера — скомпилированы
в Go (`rt-proxy/main.go:37-80`, НЕ дублировать в shell):
proxy `ps1.blockme.site:443`, health каждые 90s (CONNECT `rutracker.org:443`
+ GET `/forum/index.php` ≥8192B), direct resolver `1.1.1.1:53` (мимо
router-DNS, иначе sentinel-петля), `direct-fallback=true`,
`direct-fallback-hosts=rutracker.org,rutracker.wiki,rutracker.cc,t-ru.org`.

## 2. Домены: ровно 5 active + 2 legacy cleanup-only

ACTIVE (exact match, как у официального расширения, `S96:40`):

```text
rutracker.org rutracker.wiki api.rutracker.cc rep.rutracker.cc static.rutracker.cc
```

LEGACY (cleanup-only, `S96:45`; оба измеренно мертвы через прокси —
`rutracker.cc` не имеет A-записи вовсе):

```text
www.rutracker.org rutracker.cc
```

Invariant: `ACTIVE == official five`,
`CLEANUP == five ∪ legacy` (тест `test_rt_proxy_domains.sh` — образец).

## 3. Upstream security contract (Go, НЕ переписываем, НЕ дублируем тестами)

- SNI peek из ClientHello (`peekSNI`/`parseSNI`, покрыты `main_test.go`).
- Upstream решает, что обслуживать; direct-fallback gate:
  `directHostAllowed` (exact или dot-suffix по `--direct-fallback-hosts`).
- `routableUnicast` режет loopback/private/link-local/multicast/unspecified —
  покрывает sentinel `10.171.171.171` (10/8 — private) и любую петлю назад.
- Direct resolver `1.1.1.1:53` обходит router-DNS (sentinel не отравляет fallback).
- OpenWrt-слой не ломает `SO_ORIGINAL_DST`/redirected-flow assumptions
  (никаких исключений в firewall для self-dial — in-binary guard + relay).

## 4. Upstream lifecycle: stop_proxy ≠ stop (load-bearing)

`S96:194-223`: `stop_proxy` (только процесс; DNS+REDIRECT остаются) vs
`stop` (полный teardown); `restart` = stop_proxy+start. Причина: снятый DNS
pin во время рестарта → клиент кеширует настоящий CloudFlare IP → обход RT
до протухания кеша. На OpenWrt то же разделение (§8).

## 5. DNS на OpenWrt: exact DUAL hostrecord (НЕ ndmc, НЕ suffix)

`ndmc`/`list address` не портируются (суффикс-стиль противоречит
exact-контракту). Механизм — OpenWrt UCI `config hostrecord` с ОБОИМИ
адресами в одной `option ip` (генератор `dhcp_hostrecord_add` из
dnsmasq.init склеивает space-списки name+ip в `--host-record=name,v4,v6` —
проверено чтением генератора, не предположением):

```text
config hostrecord 'z2k_rt_rutracker_org'
    option name 'rutracker.org'
    option ip '10.171.171.171 2001:db8::1:1445'
```

×5. Фактическая generated запись эквивалентна
`--host-record=rutracker.org,10.171.171.171,2001:db8::1:1445`.

IPv6 sentinel `2001:db8::1:1445`: `2001:db8::/32` — RFC 3849 documentation
(гарантированно не реален); НЕ ULA (OpenWrt LAN живёт в случайном
`fd00::/8` — коллизия); НЕ `::1` (бил бы в localhost КЛИЕНТА); НЕ discard
`100::/64` (чужая silent-drop семантика — наш механизм это nft reject
ниже). Суффикс `:1:1445` привязывает адрес к feature-порту.

RT proxy остаётся IPv4-only: sentinel НЕ redirect'им, а deterministic
fast-reject (см. nft ниже) — AAAA не висит в timeout, клиент сразу
fallback'ится на tunneled IPv4.

## 6. DNS ownership и конфликты

- Namespace `z2k_rt_*` — только наши секции. Cleanup удаляет только их
  (active + legacy + любые будущие `z2k_rt_*`-hostrecord вне active set).
- Чужие секции НЕ трогаем никогда. Конфликт (чужая секция с тем же именем,
  ПРОВЕРЯЮТСЯ ОБА family: чужой A-only pin без v6 — тоже конфликт, дописать
  в чужую секцию нельзя) → **fail loudly**, без перезаписи. Причина
  в сообщении. Своя устаревшая (v4-only) секция — не конфликт, лечится
  stage-fix в dual.
- dnsmasq instances: секций типа `dnsmasq` в `dhcp` обязана быть ровно одна;
  иначе — явный отказ (не пишем в случайный instance).

## 7. DNS transaction

```text
prepare (set/delete наших секций) → uci commit dhcp
→ /etc/init.d/dnsmasq reload → verify (uci-readback всех 5 dual +
  best-effort nslookup 127.0.0.1: A строго v4-sentinel, AAAA строго
  v6-sentinel, никакого публичного AAAA)
→ если reload недостаточен/упал: один restart → re-verify
```

Провал на любом шаге → RT НЕ ready (fail-closed, без частичных заявлений).
Удаление: только наши секции → commit → reload. Чужие настройки dnsmasq
не трогаем. Reload (не reboot/network restart); если reload недостаточен —
доказать и перейти на restart (пока доказательств нет — reload).

## 8. Process ownership — procd (без supervisor)

Один instance `z2k-rt` в существующем `/etc/init.d/z2k`
(`z2k_ow_rt 1` после TG; `z2k_ow_rt 0` в `stop_service`):

```text
$Z2K_BIN/z2k-rt-proxy --listen=:1445 --timeout=15m
GODEBUG=asyncpreemptoff=1, respawn 3600 5 5 (bounded, как TG),
stdout/stderr → logd, pidfile под instance.
```

Gate'ы: `ENABLED=1` + бинарник `+x`. Отдельного user-флага нет (upstream:
autostart-компонент, флага не было — не изобретаем). Нет бинарника → нет
демона И нет DNS/правил (никакого dead REDIRECT/blackhole при старте).

Разделение (§4): `proc-bounce` (только kill процесса, procd поднимет;
DNS/rules/exclusion не трогаем) vs `0` (полный teardown).

## 9. Binary

`z2k-rt-proxy-linux-arm64` из производственной линейки
(`aarch64_cortex-a53 → arm64` через `map_arch_to_bin_arch`;
binary-drift guard уже сторожит). Runtime `$Z2K_BIN/z2k-rt-proxy`.
Доставка/обновление — ТОЛЬКО frozen `refresh-binaries`
(`Z2K_AU_SBIN=$Z2K_BIN` уже выставлен). Второго downloader нет.

## 10. Binary refresh без DNS gap (COMMON_HOOK §13)

Frozen `au_service_for_binary` возвращал бы `/etc/init.d/z2k` (полный
stop/start снимает DNS → клиенты кешируют реальный IP → обход RT).
Нужен process-only bounce:

```text
rt-proc.sh stop   = kill RT pids (DNS/rules/exclusion целы)
atomic replace      (updater, как раньше)
rt-proc.sh start  = kill RT pids снова (гарантированно новый inode;
                    procd поднимает сам; DNS/rules/exclusion целы)
```

`stop`/`start` оба kill-only осознанно: procd владеет (ре)стартом.
Регрессия: `DNS stays + redirect stays + offload-exclusion stays`
проверяется снимками состояния до/после в lifecycle-тесте (RT7).

## 11. nft REDIRECT (в `inet zapret`, второй таблицы нет)

Upstream: `-d SENTINEL -p tcp --dport 443 -j REDIRECT --to-port 1445`
в TOP PREROUTING + OUTPUT. Порт 1-в-1 (свои chains, numeric priorities
как TG, `-101`):

```text
chain z2k_rt_dst_pre { type nat hook prerouting priority -101; }
  tcp dport 443 ip daddr 10.171.171.171 redirect to :1445
chain z2k_rt_dst_out { type nat hook output priority -101; }
  (то же — router-local)
```

Без sets (один /32 — set избыточен). Idempotent flush+add.
IPv6: ничего (sentinel v4-only).

## 12. :1445 input guard (hardening Stage 3, повтор)

```text
chain z2k_rt_flt_in { type filter hook input priority -1; }
  tcp dport 1445 ct status dnat accept
  tcp dport 1445 drop
```

Scope строго порт; blanket `ct status dnat accept` запрещён тестом.

## 13. Offload exemption: структурная (без -j PPE, без flowtable)

Факты (проверены чтением runtime `init.d/openwrt/functions`):
- Runtime exemption-контракт — iptables-цепочка `forwarding_rule_zapret`
  (`-j RETURN` перед `-j FLOWOFFLOAD`), действует ТОЛЬКО на FORWARD-трафик.
- Наш sentinel-трафик после REDIRECT — local-delivery (INPUT/OUTPUT),
  FORWARD не проходит никогда → в offload-путь (software flowtable И
  enable-цепочку) попасть не может по построению.
- Поэтому exemption-правило НЕ добавляем (было бы театром: selective
  RETURN в чужой цепочке, которую наш трафик не посещает). `-j PPE` —
  Keenetic/MediaTek-специфика, на OpenWrt отсутствует как класс.
- Тесты доказывают: наши chains не содержат flowtable/flow-add/offload;
  redirect-цели — локальные порты (local-delivery ⇒ forward-offload
  неприменим). HFO-поведение MediaTek под нагрузкой — live-check роутера
  (честно PARTIAL).
- `FLOWOFFLOAD` на OpenWrt по умолчанию `none` (генератор) — runtime
  offload-цепочки при этом вообще не строит.

## 14. nfqws2 exclusion (RT20): effective-whitelist ensure

Факты: runtime перехватывает в mangle PREROUTING (раньше nat REDIRECT) —
fight реален; исключение только на уровне nfqws2 `--hostlist-exclude`
(= `$Z2K_LISTS_DIR/whitelist.txt` → симлинк на user-файл; updater-owned
RKN-лист править нельзя — сломает converge-идемпотентность; geosite-subtract
на OpenWrt не бегает — его файл не доставляется).

Механизм `z2k_ow_rt_desync_exclude` (adapter-owned, updater-proof):
- ensure: ровно 5 exact-строк присутствуют в effective whitelist
  (append недостающих; чужие строки и порядок — никогда не трогаем,
  ничего не удаляем).
- exact-line matching (НЕ suffix: `foo.rutracker.org` не покрывает
  `rutracker.org`).
- провал записи → RT НЕ ready (fail-closed, как DNS).
- Перегенерация конфига подхватывает исключение штатно через `wl_excl`
  (перезапуск демона не нужен — движок перечитывает по mtime, но тестовый
  контракт этого не требует).
- Доказательство RT20: (a) shipped RKN-лист содержит домены (фиктива? нет —
  реальный grep), (b) ensure кладёт 5 в effective файл, (c) effective файл
  == читаемый генератором (`$Z2K_LISTS_DIR/whitelist.txt`), (d)wl_excl
  в RKN-профиле сгенерированного конфига указывает туда же.

## 15. No-blackhole и halt-teardown

- Transient restart (procd respawn ≤5s, proc-bounce, binary refresh):
  DNS/rules/exclusion никто не снимает — чёрной дыры нет по построению.
- Persistent failure (procd halt после crash-loop): демон мёртв + пины
  стоят = blackhole. Health-check считает мёртвые тики; ≥3 подряд
  (~15 мин — procd-рестарт идёт секундами, живого там быть не может) →
  **согласованный teardown**: redirect снять + DNS снять (ОБЕ стороны,
  никакого flap: removals только здесь/0/cleanup) + latch
  (`$Z2K_TMP/rt-halted`) + громкий лог. Пока latch стоит — reconverge
  не чиним (не flap'аем DNS). Latch снимают: рестарт сервиса, живой
  процесс, смена бинарника.
- Быстрый flap DNS при кратком respawn исключён: wanted-путь только
  добавляет/проверяет, никогда не удаляет.

## 16. WAN flap / firewall reload / restart / uninstall

- Hotplug: `z2k_ow_rt rules` — nft+whitelist converge, DNS без commit/reload
  (только verify), PID untouched.
- Restart сервиса: полная конвергенция (DNS re-assert идемпотентно, gap нет).
- Full stop (`0`): process + redirect + v6-reject + guard + DNS (ОБЕ семьи).
  Daemon-only bounce: только процесс.
- Uninstall: всё выше + legacy-DNS cleanup + снять rt-health cron;
  user-DNS не трогаем. Purge — вручную (frozen).

## 17. Cron: один, обоснованный

`# z2k-rt-health` каждые 5 мин (`rt-check.sh`): покрывает halt-blackhole
(§15) и reconverge. Procd + hotplug покрывают остальное; отдельного
watchdog/supervisor нет (`z2k-rt-proxy` сам health-check'ит upstream-пул
внутри). §26-spec выполнен: cron допустим, т.к. состояние «alive, но
интеграция сломана» иначе не ловится.

## 18. Зависимости и ownership

- Новых DEPENDS нет (uci/dnsmasq/nft — base OpenWrt; conntrack RT не
  использует — в upstream его нет; curl для RT-check не нужен).
- PACKAGE: `rt.sh`, `rt-proc.sh`, `rt-check.sh`, проводка
  init/hotplug/schedule/uninstall. UPDATER: `z2k-rt-proxy` (refresh-binaries),
  fp-лист и RKN-лист (existing). DNS (UCI) — neither (состояние системы,
  владеем namespace). Whitelist-строки — append-only в user-файл, never delete.
- `release_map.sh` НЕ меняется (все RT-ассеты уже маппятся: binary через
  builds→refresh-binaries, списки через lists).

## 19. Отклонения от upstream (осознанные)

1. Нет shell-supervisor (procd + bounded respawn).
2. Нет `-v`/файлового лога (logd).
3. DNS через UCI hostrecord вместо ndmc (exact-семантика сохранена).
4. Offload: структурное освобождение вместо `-j PPE` (другой движок offload).
5. Desync-exclusion через effective-whitelist ensure вместо geosite-subtract
   (geosite не бегает на OpenWrt).
6. Halt-teardown через latch (в upstream супервизор не сдаётся никогда —
   здесь сдача явная и согласованная, иначе вечный blackhole).
7. IPv6: dual exact hostrecord (A + `2001:db8::1:1445`) + nft fast-reject
   вместо допущения «A-only подавляет AAAA» (неверно для dnsmasq 2.93 —
   найденный DNS correctness bug; см. шапку про target-версию).
