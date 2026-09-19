# OpenWrt foundation — state machine (freeze audit)

Единая модель install/update/upgrade/uninstall. TG/RT/WARP/Webpanel вне scope;
всё ниже — только уже реализованный foundation. Статус: FROZEN (см. отчёт аудита).

## 0. Глобальные инварианты (доказываются тестами после каждого перехода)

```text
I1: MARKER_PRESENT ⇒ PAYLOAD_VERIFIED (required set на месте, непуст)
I2: INSTALLED_TAG=V ⇒ PAYLOAD_VERSION=V (tag == share/payload.meta::tag)
I3: любая операция, заменяющая payload seed'ом, устанавливает tag=seed.meta.tag
I4: marker ставится ТОЛЬКО последним (extract → bootstrap → verify → tag → mark)
I5: package upgrade без re-seed НЕ меняет installed-tag (и вообще ничего
    updater-/user-owned)
```

Нарушение любого — fail closed (отказ + лог), никогда silent success.

## 1. Ownership graph

Классы: PACKAGE (opkg ставит, никто не перезаписывает), UPDATER (только
install_map openwrt-line + seed-извлечение при инициализации),
USER (человеческие данные), INSTALL_META (marker/tag/dirty/fails — пишет
bootstrap/updater, uninstall удаляет active), TRUST (TOFU pin — пишет updater,
переживает uninstall), DAEMON_STATE (публикует демон + правит человек),
RUNTIME (tmpfs), EXTERNAL_ZAPRET2 (чужой runtime, только вызываем).

| Путь | Writer | Updater | Deletes | Preserves |
|---|---|---|---|---|
| `/etc/init.d/z2k` | PACKAGE (opkg) | never | opkg remove | conffiles НЕТ (замена с пакетом) |
| `/etc/hotplug.d/iface/90-z2k` | PACKAGE | never | opkg remove | — (см. выше) |
| `/usr/lib/z2k/platform/openwrt/*` | PACKAGE | never | opkg remove | — |
| `/usr/lib/z2k/share/config.default` | PACKAGE | never | opkg remove | — |
| `/usr/lib/z2k/share/seed.tar.gz` | PACKAGE (build artifact) | never (только читает) | opkg remove | — |
| `/usr/lib/z2k/{lib,lua,fake,lists,extra_strats,etc,z2k-config-validator.sh}` + `strats_new2.txt`/`quic_strats.ini` (в корне payload) | UPDATER (install_map; seed — только транспорт при инициализации) | install_map / converge / steps | prerm `rm -rf $Z2K_ROOT` (opkg их не знает — извлечены, не поставлены) | package upgrade НЕ трогает (marker-правило) |
| `/usr/lib/z2k/share/seed.meta` | BUILD (внутри seed) → UPDATER (при извлечении) | never modifies | вместе с payload | — (факт о payload, не конфиг) |
| `/usr/lib/z2k/config` (symlink) | bootstrap (postinst/service) | never writes (все записи — явным путём /etc) | prerm с деревом | guard в generate.sh |
| `/etc/z2k/config` | USER (bootstrap — только если отсутствует; generator — saved_*-merge) | regen (preserving), flags-reapply | never by package/updater (только purge вручную) | upgrade/update/rollback |
| install-meta: `.payload-initialized`, `state/installed-tag`, `state/dirty-tree`, `state/au-delivery-fails` | bootstrap (marker/tag) + updater (tag/dirty/fails) | tag/dirty/fails по своим путям | uninstall (active metadata — иначе ложь о снесённом payload) | upgrade (без re-seed не трогаем) |
| trust: `.trust/pinned` | updater (pin on first verify) | never | NEVER (TOFU переживает reinstall) | — |
| daemon-state: `state.tsv`, `tcp16_*.txt` | runtime (+ человек) | never | never (кроме purge) | — |
| `/etc/z2k/user-lists/*` | USER (+ merge extra-domains: shipped ∪ user) | merge only | never | — |
| `/etc/crontabs/root` (строка `# z2k-updater`) | PACKAGE postinst/prerm (по маркеру, атомарно) | never | prerm (только своя строка) | чужие строки (byte-preserved) |
| `/tmp/z2k/*` | RUNTIME (locks/logs/update/downloads/generated) | свои подкаталоги | reboot / prerm | — (не обязан) |
| `/etc/z2k/state/fw4-offload.state` | ADAPTER (temporary ownership snapshot) | adapter only | successful stop/rollback | exact UCI presence/value restored |
| nft table/ifsets/flowtable/NFQUEUE | EXTERNAL_ZAPRET2 (apply/remove/reload) | — (z2k только вызывает) | stop/uninstall | reboot (ядро) |

Два writer на один путь = BUG. Seed — НЕ owner (транспорт UPDATER-файлов).

## 2. Состояния и переходы

```text
S0 package absent
S1 package installed, payload not initialized (нет marker)
S2 seed initialized: payload ok, tag = seed.tag, marker set
S3 normal running (payload = V, tag = V)
S4 updater patch/converge in progress (lock held)
S5 converged to Y (tag = Y, payload = Y)
S6 package adapter upgrade (adapter files replaced, payload untouched)
S7 updater failure, old payload preserved (tag = X, dirty? — см. ниже)
S8 corrupt/incomplete payload (marker+partial → ручной repair)
S9 package uninstall (payload purged, /etc/z2k preserved, cron line gone)
```

Переходы (precondition → writes → preserved → failure → retry):

- S0→S1: opkg install. Writes: package-owned + seed.tar.gz. Preserved: /etc/z2k (если был). Failure: opkg rollback. Retry: reinstall.
- S1→S2 (postinst seed_ensure → re-seed transaction): pre: tarball present. Writes: invalidate marker → extract → bootstrap → verify → tag := payload.meta (I3, ВСЕГДА, даже поверх более нового) → marker ПОСЛЕДНИМ. Preserved: /etc/z2k user-data. Failure (любой шаг): marker absent → retry сходится (extract поверх частичного идемпотентен). Crash-safe: marker ⇒ verified; tag == meta всегда после успеха.
- S1→S1 (tarball отсутствует): fail loudly, без marker.
- S2/S3→S4 (cron/manual update.sh): pre: seed_ensure-ok (marker+payload+tag==meta, иначе отказ) + lock (иначе skip). Writes: staging в $TMP, затем targets (tmp+rename), payload.meta=Y, steps, tag=Y (только в конце, после meta). Preserved: user-data, tag/meta до успеха.
- S4→S5: converge ok + steps ok + health ok → meta=Y → tag=Y. Snapshot до, rollback при провале.
- S4→S7: fail → rollback → tag=X (не двинут), meta=X (не тронута); dirty — только если rollback неполон. Retry: nightly (идемпотентно); 3 delivery-провала → reinstall-required → fail-closed.
- S3→S6 (opkg upgrade): pre: любое. Writes: только package-owned (+ новый seed.tar.gz лежит). Payload: marker+ok → skip extract (побайтово цел); marker+empty → re-seed transaction (tag := seed! никакого preserve); marker+partial → invalidate + FAIL. Preserved БЕЗ re-seed: tag/meta (I5), /etc/z2k, чужие cron-строки.
- S6→S3: postinst (seed_ensure + cron_install идемпотентно).
- S*→S8: повреждение payload при marker (payload_ok=0, не empty): invalidate marker + FAIL. Repair: следующий запуск (marker absent) делает re-seed с нуля — damage уже не verified, терять нечего. Молчаливого success нет.
- S3→S9 (prerm/uninstall): stop → cron_remove (только своя) → disable → rm ACTIVE install-meta (marker/tag/dirty/fails — иначе ложь о снесённом payload) → rm -rf $Z2K_ROOT (сироты) → rm -rf /tmp/z2k. НЕ трогает: config, user-lists/*, daemon-state, trust-pin, чужие cron. Purge = `rm -rf /etc/z2k` вручную.
- S9→S1→S2 (reinstall того же пакета): marker absent + payload empty + tag absent → re-seed: payload=X, meta=X, tag=X (I3!), marker last. Проверено сценарием S10-циклом (install X → update Y → uninstall → reinstall X → converge Y).
- sysupgrade-wipe (/etc цел, /usr/lib пуст): marker present + empty → re-seed (tag := seed, НЕ preserve!) → updater догоняет до remote. Старая модель "tag preserved" удалена здесь: она и была false-current.

## 3. Update trust chain

```text
cron/manual → update.sh (env: t0fox/z2kOW/<channel>)
→ pre-flight: seed_ensure (marker/payload/tag==meta, иначе отказ)
→ fetch UPDATES.json + .sig → verify signature (pubkey $Z2K_ROOT/etc/..., verifier $Z2K_BIN/...)
→ platform gate (platform=openwrt, без keenetic-целей) → decide(tag, history)
→ lock → snapshot → converge (sha-checked, tmp+rename) → steps (delivered code)
→ health (nfqws2 was-alive cmp + sh -n init+libs + advisory services)
→ payload.meta=Y (verify) → tag=Y (verify) → unlock
```

Инвариант: `manifest repo == payload repo == binary lineage` (один origin
`t0fox/z2kOW`; ref-резолв через RAW_BASE того же repo). Tag двигается только
после успеха; любой провал до tag-write. Unknown step/map/entry → reinstall
→ fail-closed (executor), z2k.sh не скачивается и не исполняется.

## 4. Lifecycle owner graph

```text
nfqws2 process .... z2k procd (init.d/z2k; stock zapret2-сервис DISABLED)
nft/ifsets ........ zapret2 functions (apply/remove/reload; hotplug только reload)
offload ........... zapret2 (FLOWOFFLOAD из общего конфига)
QNUM/marks/ports .. общий /etc/z2k/config (демон и firewall читают один файл)
restart ........... init.d/z2k restart (шаг restart-service через INIT_SCRIPT;
                    rollback-restart через тот же hook)
```

Double apply/remove: исключён — один procd-инстанс, firewall-операции только
из start/stop_service и шагов (тест: ровно один procd_open_instance).

## 5. Failure semantics (сводка)

| Отказ | Payload | Tag | Dirty | Next run |
|---|---|---|---|---|
| download/hash/write mid-patch | rollback из snapshot | X (стоит) | только если rollback неполон | converge доделывает (идемпотентно) |
| step fail | rollback + regen-config/restart | X | аналогично | nightly retry |
| health fail | rollback | X | аналогично | retry |
| rollback fail | partial X/Y | X (стоит!) | MARKED → только reinstall | reinstall → fail-closed |
| unknown step/map | ничего не тронуто | X | — | reinstall → fail-closed |
| wrong-platform manifest | ничего (отказ в fetch) | X | — | retry (канал чинят руками) |
| reinstall-required (любая причина) | не мутируется намеренно | X | — | opkg upgrade пакета |
| crash в любой точке seed | partial/empty | untouched-or-seed | marker НЕТ | retry сходится |
| concurrent updater | второй skip (lock) | — | — | — |
| upgrade во время update | adapter в памяти; payload не пишется (marker-skip) | — | — | — |
| DISABLED=0 везде | payload обновляется, сервис не стартует | движется | — | — |

## 6. Что проверяется только на live-роутере (PARTIAL)

Реальный nft/queue-трафик, reboot-выживание, opkg UX (зависимости,
конфликты), cron-daemon в конкретной сборке, sysupgrade с backup /etc,
часы/часовой пояс cron (02:xx), медленный NAND (тайминги rename), OOM-killer
посреди apply. Всё остальное — Level A/B/C в tests/openwrt/.
