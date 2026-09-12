# OpenWrt WARP contract (Stage 5)

Источник истины — текущий upstream `necronicle/z2k` (`z2k-enhanced`),
НЕ память и НЕ usque-архитектура. Foundation FROZEN; порт только в
`platform/openwrt/*`, `package/openwrt/*`, `tests/openwrt/*`, `docs/*`
(+ точечный COMMON_HOOK §27 и Go platform seam §4).

## 1. Upstream: цепочка и состояния

```text
exact game hostname/IP → (nfqws2 desync as usual; game IPs are NOT in
  desync hostlists — no fight by construction, §14)
selected (dst set ∪ src set) → nft mark → policy route table 989
  → z2ktunN → Cloudflare WARP (WireGuard → MASQUE-h2 ladder)
```

WARP — OPTIONAL: fresh install = бинаря нет, `GAME_WARP_ENABLED=0`
(дефолт генератора, переживает регенерацию), нет туннеля, нет PBR.

`install` = verified binary + register device; НЕ стартует, НЕ ставит флаг,
НЕ роутит. `enable` = флаг=1 + sets + engine + wait ready (≤120s, rc 2 если
не поднялся, флаг остаётся) + только потом PBR. `disable` = PBR снять
ПЕРВЫМ, потом stop, потом флаг=0. `remove` = disable + бинарь удалён;
`device.json` (1 КБ) остаётся — переустановка не заводит новое устройство.

`selfheal` (~25s upstream; у нас 60s cron, честно): flag=0 → PBR down;
binary absent → PBR down; device absent → bounded register recovery
(не чаще 10 мин), PBR down до ready; daemon dead → procd owns process,
PBR down; ready + iface valid → sets + PBR up; иначе PBR down (fail open).

## 2. Домены/списки: ownership разделён физически

Upstream layout (`files/z2k-warp.sh:105-121`):

```text
$WARP_LISTS_DIR/*.txt (+devices.txt)  — USER, только пользователь пишет
$WARP_LISTS_DIR/games/*.txt           — UPDATER, wholesale refresh
$WARP_ENABLED_FILE (.enabled)         — выбор пользователя (файл, а не
                                        переименование: refresh пересоздаёт
                                        файлы и молча включил бы обратно)
```

OpenWrt mapping:

```text
/etc/z2k/user-lists/warp/*.txt, devices.txt, .enabled   USER (пакет/updater
                                                          не поставляют/не пишут)
/usr/lib/z2k/lists/warp/games/*.txt                     UPDATER (converge;
                                                          на практике пусто,
                                                          пока update-lists
                                                          не портирован —
                                                          пользователь может
                                                          класть файлы сам)
```

Загружается: каждый user-*.txt (кроме devices.txt) + каждый games/<name>.txt
с именем из .enabled (имя без файла — скип). Fresh = всё пусто = валидно
(пустые сеты, route-all невозможен). Legacy aggregate `game-warp-ips.txt`
НЕ засеиваем (его нет и в репо); one-shot purge адаптирован
(маркер `user-lists/warp/.legacy-aggregate-purged`).

Валидация — канонические awk-фильтры upstream БАЙТ-В-БАЙТ (копии:
`files/z2k-warp.sh`, `webpanel/cgi/actions.sh`, `files/z2k-update-lists.sh`
+ наша `platform/openwrt/warp.sh`; parity-тест расширен на 4-ю копию):
- dst: valid public IPv4 host/CIDR, без /0, без octal-ambiguity, без
  private/loopback/link-local/CGNAT/multicast/reserved/documentation;
  широкие легитимные (`/8` Amazon) разрешены, минимального префикса нет.
- src: IPv4 из LAN/private/CGNAT-классов ровно (публичный → reject:
  MARK-правило без `-i` метило бы входящий WAN-трафик); MAC через
  `ip -4 neigh` (офлайн — скип сейчас, подхват позже).

Atomic reload: validate-first (битая строка никогда не доходит до nft),
flush+add; правило W19: источник непуст, а валидных ноль → reload
ОТКАЗАН, live set цел (намеренная очистка = пустые файлы = разрешена).

## 3. Go platform seam (единственный common/Go diff, §27)

`z2k-warpd/internal/nat` дёргает `iptables` через инжектированный `Runner`
(`nat.Ensure(nat.Runner(cfg.Run), ...)` в `engine.Run`) — наружу торчит
ровно seam: добавляем `Config.SkipNetSetup bool` + CLI
`--net-backend=` (`""` = Keenetic iptables как сейчас побайтово;
`"external"` = TUN/create/address/transport/health/status как раньше,
НО без `nat.Ensure`/`nat.Remove`; неизвестное значение — fatal).
Keenetic default не меняется ни байтом (доказывает существующий
`engine_test.go` — он ассёртит iptables-команды; новый тест ассёртит их
ОТСУТСТВИЕ при seam + присутствие TUN-команд).

OpenWrt invocation включает external mode. Бинарь НЕ пересобирается под
Stage 5 (флаг runtime — существующий `z2k-warpd-linux-arm64` артефакт;
build secret не затрагивается).

## 4. Process ownership — procd (без supervisor)

Один instance `z2k-warp` в существующем `/etc/init.d/z2k` (второго сервиса
нет). Wanted = `GAME_WARP_ENABLED=1` + бинарь +x + `device.json` -s.
Нет бинарника/флага/ключа: НЕТ процесса, НЕТ nft, НЕТ ip rule, НЕТ мутаций
таблицы. Argv:

```text
GODEBUG=asyncpreemptoff=1 $Z2K_BIN/z2k-warpd run \
  --device /etc/z2k/state/warp/device.json \
  --status /tmp/z2k/warp/status.json \
  --log /tmp/z2k/warp/warpd.log \
  --endpoints $Z2K_ROOT/lists/warp-endpoints.txt \
  --net-backend=external
```

(`--endpoints`: дефолт бинарника — Keenetic-путь; proxy — через env
`Z2K_WARP_VPS_PROXY` как S51: из конфига или дефолт, parity-тест держит
равенство трёх копий; секрет релей НЕ логируем.)
`--timeout`/лимиты — скомпилированы (не дублируем). `respawn 3600 5 5`
bounded (как TG/RT; доказательство — `procd/service/instance.c`).
stdout/stderr → logd (файловый лог ведёт сам движок через logrot).

Разделение stop_proxy/stop (upstream S96-контракт): `proc-bounce` (только
kill, procd поднимает; DNS-н/д, nft/rules целы) vs `0` (полный teardown).

## 5. State paths

Persistent (FEATURE_STATE, переживает disable/remove-binary/upgrade/update/
reinstall; purge — только вручную):

```text
/etc/z2k/state/warp/device.json   mode 600 (restrictive)
```

Transient:

```text
/tmp/z2k/warp/status.json   (пишет демон, atomic tmp+rename)
/tmp/z2k/warp/warpd.log     (logrot движка)
/tmp/z2k/warp/*.hash        (наши отпечатки загруженного)
/tmp/z2k/warp/register.stamp (bounded register retry)
```

Device identity удаляется только отдельной explicit операцией (не `remove`).

## 6. Mark/mask/table/pref (аудит — `docs/openwrt-mark-allocation.md`)

Keenetic `0x989/0x989` НЕ переносим (биты 8-11 пересекаются с mwan3
`0x3F00`). Выбрано:

```text
Z2K_WARP_MARK=0x80000000  Z2K_WARP_MASK=0x80000000
Z2K_WARP_TABLE=989  Z2K_WARP_PREF=500
```

- bit31 свободен от всех известных владельцев (DESYNC биты 29-30, mwan3
  биты 8-13, fw4 по умолчанию меток не ставит, low-биты отданы
  пользователю/qosify).
- Операция ТОЛЬКО битами маски, чужие биты живут:
  `meta mark set mark & 0x7fffffff ^ 0x80000000` (masked-mark идиома,
  как upstream `--set-xmark MARK/MASK`; blind `--set-mark` запрещён тестом).
- Runtime conflict detection ПЕРЕД enable/PBR: точное наше правило → ok
  (идемпотентность); чужое пересечение по mark/mask, занятые table/pref →
  FAIL LOUDLY, PBR down, fail open. Чужие rules/routes никогда не удаляем/
  не перезаписываем (`replace` только после proof; `flush table` запрещён).
- `ip route replace default dev $iface table 989` — только валидный
  `^z2ktun[0-9]+$` + exists (up доказывает ready=true движка).

## 7. nft объекты (в `inet zapret`, второй таблицы нет)

```text
chain z2k_warp_mark { type filter hook prerouting priority -150; }  # mangle
  ip daddr @z2k_warp_dst4 meta mark set mark & 0x7fffffff ^ 0x80000000
  ip saddr @z2k_warp_src4 meta mark set mark & 0x7fffffff ^ 0x80000000
chain z2k_warp_mss { type filter hook forward priority -150; }
  oifname $iface tcp flags syn tcp option maxseg size set rt mtu
  iifname $iface tcp flags syn tcp option maxseg size set 1240
chain z2k_warp_fwd { type filter hook forward priority -1; }
  oifname $iface accept
chain z2k_warp_nat { type nat hook postrouting priority 100; }
  oifname $iface masquerade
set z2k_warp_dst4 { type ipv4_addr; flags interval; }
set z2k_warp_src4 { type ipv4_addr; flags interval; }
```

- Mark ТОЛЬКО PREROUTING (router-local никогда в WARP — upstream инвариант
  после удаления OUTPUT; тесты запрещают OUTPUT-mark).
- MSS 1240 = engine.MTU(1280)-40, тест держит coupling с Go-константой;
  outbound — clamp-to-PMTU, inbound — explicit (НЕ зеркальный PMTU-clamp:
  дал бы 1460 с LAN-моста; полевое измерение upstream).
- MASQUERADE только `oifname <валидированный iface>`; FORWARD только
  `oifname` (никакого generic accept, никакого WAN-ingress bypass).
- Offload exemption правилом НЕ добавляем — и вот честное обоснование.
  Runtime exemption-контракт — iptables-цепочка `forwarding_rule_zapret`
  (`-j RETURN` перед `-j FLOWOFFLOAD`), которую runtime пересоздаёт внутри
  своего apply: вклинить туда наше правило в верной позиции из адаптера
  невозможно, а правило после enable-правила бесполезно. `-j PPE` на
  OpenWrt отсутствует как класс; второй flowtable-фреймворк запрещён.
  Смягчающее (не доказательство): flow-ключ софтового flowtable включает
  mark, а наш марк стабилен в пределах соединения — корректный offload
  маркированного трафика не ломает (в отличие от Keenetic PPE-драйвера).
  HFO под нагрузкой MediaTek — live-check роутера (честный PARTIAL).

## 8. Policy route — только при ready (fail-open invariant)

```text
WARP_ROUTE_PRESENT ⇒ ENGINE_READY=true ∧ iface exists ∧ iface==status.iface
```

- До ready: НЕТ ip rule (даже при flag=1 — W4).
- `ip rule add pref 500 fwmark 0x80000000/0x80000000 table 989`
  (check-then-add; чужой конфликт → fail).
- Pref ownership строгий (W33): если pref 500 существует, ВСЕ его записи
  обязаны быть нашей exact-спецификацией; сосед-чужак = CONFLICT, fail loudly.
- `ip route replace default dev $iface table 989` (после proof; только
  наш default правим).
- Down снимает rule ТОЛЬКО exact delete с pref (defect 4); legacy
  unmasked-форм нет (наше правило всегда ставилось с pref+masked mark).
- Pref cardinality (W39): pref 500 — 0 или ровно 1 exact ours; дубликат
  exact или чужак = conflict; verify требует ровно 1 exact; teardown
  bounded-delete гарантирует ноль exact (только этот tuple, чужое не трогаем).
- Route удаляется ТОЛЬКО при доказанном ownership (defect 5, подход A):
  owner-record `$TMP/warp/pbr.owner` (mark/mask/pref/table/iface успешного
  up, пишется temp→chmod→mv) + текущий default таблицы в точности наш;
  mismatch/drift/нет записи — foreign route НЕ трогаем (без нашего rule он
  mark-трафик не ведёт), owner стирается после teardown. Покрыто W34–W37.
- Owner write failure откатывает PBR целиком (defect 3/W38): exact rule
  снять, route — только если текущий default в точности только что
  ставленный наш, owner-огрызок удалить; возврат — failure (fail open).
- Любой переход в не-ready: **сначала снять route/rule**, трафик — direct.
  Никаких mark + dead table.
- `enable`/`warp-proc.sh start` ждут ready с правилом свежести: status.json
  обязан быть новее старта wait'а (anti-corpse после kill -9 — defer Remove
  не выполняется; W4b). Живой движок переписывает статус каждый тик serve,
  поэтому у здорового демона статус всегда свежий; протухший wait даёт
  rc 2 (флаг сохраняется, cron доведёт), а не молчаливый PBR.

## 9. Selfheal (60s cron, честно, не 25s)

`# z2k-warp-health` `*/1 * * * *` (cron-абстракция — минуты; ложную 25s
гарантию не даём). Тик (в порядке):

```text
flag=0 → PBR down, return (converge-to-off)
binary absent → PBR down, return
device absent → bounded register (stamp 600s); PBR down до ready;
  после УСПЕШНОЙ регистрации — service restart (halted instance иначе
  не оживить; редкий путь, документирован)
daemon dead → procd owns (НЕ стартуем); PBR down
ready + iface valid → sets reload-if-changed + PBR converge (route+rule)
else → PBR down
```

Death-note (OOM/SIGKILL след в лог движка) — портирован упрощённо.
Watchdog за process-dead НЕ конкурирует с procd (только PBR-конвергенция).

## 10. Install/security/refresh/remove/uninstall

- `install`: manifest+sig fetch (z2k_fetch) → `au_manifest_verify`
  (z2k-verify/openssl; НЕТ verifier → FAIL, никакого TOFU) → sha из
  манифеста → fetch binary → compare → ELF → `version`-run → atomic
  install в `$Z2K_BIN` → register (direct, затем VPS-proxy fallback;
  proxy credentials НЕ логируем; существующий device — verify only,
  новый identity только если старого нет/инвалид) → migrate lists.
  WARP_FETCH_STUB — тестам.
- Updater: absent → НЕ ставит (existing refresh-логика: не-базовый
  пропускается; W28-тест). Present → refresh через `warp-proc.sh`
  (COMMON_HOOK): PBR down → kill → atomic replace → kill (новый inode) →
  wait-ready ≤60s → ready? PBR up : оставить down (cron доведёт);
  возврат всегда 0 (fail-open; тег не зависит от погоды на реле).
- `remove`: disable + бинарь удалён (+`.new.*`); device.json, user lists,
  `.enabled` — СОХРАНЕНЫ.
- Uninstall пакета: teardown + снять warp-cron; device/lists/флаг —
  по frozen uninstall-контракту (/etc живёт).
- `ENABLED=0`: PBR/process/nft down; user-флаги/identity/lists сохранены
  (desired state вернётся при re-enable).
- Game lists refresh: updater доставляет файлы (когда появятся в манифесте;
  сейчас `games/` пуст — пользователь кладёт сам); `.enabled`/devices/user
  не трогаем никогда; по mtime/hash — atomic set reload без рестарта;
  битый refresh (источник непуст, валидных ноль) → live set цел (W19).
- Set reload атомарен (defect 2/W19b): валидация ДО live state, затем ОДИН
  `nft -f -` batch (flush обоих + add обоих) — всё или ничего; mid-failure
  оставляет OLD dst/src целыми; пустые входы валидны (оба сета пустеют).
- Dynamic TUN (MSS/FWD/NAT) — convergence одной `nft -f -` транзакцией
  (ensure+flush+add ровно 4 правил): повторный tick не копит дубликаты
  (W40: mss=2/fwd=1/nat=1 после 10 check). При no-ready dynamic chains
  пустые. Base MARK rules — отдельный слой.
- Firewall recreate (`rules`, defect 6/W41): sets-ensure (перезалив при сносе
  таблицы) + base chains + dynamic TUN при proven-ready (+PBR converge);
  иначе dynamic пуст + PBR down. Одного route/rule мало для «восстановлено».
- Disable converge-to-off (defect 7/W42): PBR down → dynamic+MARK flush
  (маркировки нет) → flag 0 → reconcile; sets живут как cache.
- Not-ready (desired on, tunnel down) держит MARK как инертный desired-слой
  (defect 4/W49): правила match'ят dst/src-сеты и ставят bit31, но
  потребляет mark ТОЛЬКО WARP ip-rule (pref 500 → table 989); без него
  пакеты идут по main table — direct, route не меняется. MARK смывается
  только полным off (disabled/flag 0/ENABLED 0 — W50) и remove/stop.
- Owner write failure откатывает PBR целиком (defect 3/W38): exact rule
  снять, route — только если текущий default в точности только что
  ставленный наш, owner-огрызок удалить; возврат — failure (fail open).
  Owner пишется temp→chmod 600→mv; chmod failure = rollback (W52:
  temp удалён, публикации нет).
- MASQUE endpoint НЕ исключаем из desync (измерено upstream: ломает
  transit); наши mark-правила match'ят только сеты (W32-тест).
- CLI: `warp install/enable/disable/remove/status/selfheal/reload-lists`
  (+`migrate` one-shot) — будущая панель просто вызывает.

## 11. Disable order, service state, mutation lock (defects 1/2/8, W43–W47)

- Disable: PBR down → tun/mark clears → `GAME_WARP_ENABLED=0` → reconcile
  → verify процесса. Reload при flag=1 пересоздал бы instance. Инвариант:
  успех disable ⇒ flag=0 + нет PBR + нет процесса. `remove` сначала
  доводит этот инвариант, затем удаляет бинарь.
- Service state — только procd (`_z2k_ow_service_running`: прямой ubus
  `service list` first, `init running` fallback; `Z2K_INIT` переопределимо).
  `pidof nfqws2` как proxy запрещён (мёртвый nfqws2 при живом сервисе).
  Сервис остановлен намеренно ⇒ только desired state, весь z2k не стартуем
  (W46: enable пишет flag, reload нет; следующий start поднимает WARP).
- Mutation lock: mkdir-атомарный `$TMP/warp/mutate.lock` (flock не
  требуется), берут только verb entry-points (+warp-proc.sh); внутренние
  вызовы — никогда; `status` — без лока. Fail-safe: bounded wait
  (`WARP_LOCK_WAIT`, default 30), stale recovery (мёртвый PID — сразу,
  без PID — по возрасту 300s), holder crash не вешает навсегда; unlock —
  только свой. W43 (disable под локом не мутирует, после release — OFF),
  W44 (updater-stop под локом rc 1 без мутаций и порчи owner).

## 11. Отклонения от upstream (осознанные)

1. Нет shell-supervisor (procd + bounded respawn 3600 5 5).
2. Нет `-v` файлового лога движка в /tmp? — есть: движок сам ведёт
   logrot-лог (флаг --log), procd stdout/stderr → logd.
3. ipset → nft sets (swap → validate-first + flush+add; инвариант «битая
   строка не обнуляет live» сохранён механизмом W19).
4. `-j PPE` → нет (движок offload OpenWrt — см. §7, честный PARTIAL).
5. `0x989` → `0x80000000/0x80000000` (mwan3-коллизия доказана).
6. table 989/pref 90→500 + runtime ownership proof (вместо blind reuse).
7. `ip route flush table` → только `del default` нашего (чужое не трогаем).
8. Selfheal 25s → 60s cron (честная cadence platform).
9. usque-migrate пропущен (на OpenWrt наследия нет); aggregate-purge
   адаптирован.
10. GODEBUG — как S51: только mips* (faithful; движок тот же Go-рантайм).
11. NDM-хук → hotplug/rules-конвергенция (нет NDM на OpenWrt).
12. `--endpoints` передаём явно (дефолт бинарника — Keenetic-путь).
