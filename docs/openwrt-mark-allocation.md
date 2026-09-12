# OpenWrt mark/table/pref allocation audit (Stage 5)

Keenetic `WARP_MARK=0x989` (mask `0x989`) на OpenWrt НЕ переносим.
Метод: факты из исходников + runtime conflict detection как backstop
для всего, что знает только живой роутер.

## Таблица

```text
owner                              mark / mask              purpose
---------------------------------- ------------------------ ------------------------
z2k WARP (adapter, ЭТОТ ДОКУМЕНТ)  0x80000000 / 0x80000000  PBR game/src → table 989
zapret2 DESYNC packet mark         0x40000000 / 0x40000000  desync selected traffic
                                                          (NFQUEUE rules match
                                                           !mark — runtime fns)
zapret2 DESYNC_POSTNAT             0x20000000 / 0x20000000  postnat mark
mwan3 (default mmx_mask)           id-dependent / 0x3F00    multiwan policy
                                                          (биты 8-13; prefs
                                                           1001-3999; tables=id)
fw4                                none by default          (user `option mark`
                                                           возможен → ловит
                                                           runtime detection)
pbr package                        none by default          (user policies →
                                                           runtime detection)
qosify/sqm, user custom            low bits typically       (bit31 свободен;
                                                           runtime detection —
                                                           наш rule exact-match)
```

Источники: `init.d/openwrt/functions` runtime (`DESYNC_MARK=0x40000000`,
`DESYNC_MARK_POSTNAT=0x20000000`); mwan3 `common.sh` (`mmx_mask '0x3F00'`,
prefs `id+1000/2000/3000`, `MM_BLACKHOLE/UNREACHABLE` внутри маски);
fw4/pbr — дефолтных меток нет (пользовательские возможны).

## Почему bit31

- `0x989` = `0x900 | 0x89`: биты 8-11 лежат ВНУТРИ mwan3-маски `0x3F00`
  (9-й mwan3-интерфейс получил бы `0x900` — прямое пересечение). Доказано,
  не предположено.
- bit31 (`0x80000000`) не пересекает: DESYNC биты 29-30, mwan3 биты 8-13,
  low-биты пользовательских/qosify-меток. `ip rule fwmark`/`nft meta mark` —
  полный u32, знаковость не мешает.
- Операция всегда masked (чужие биты живут):
  `meta mark set mark & 0x7fffffff ^ 0x80000000`
  (masked-mark идиома; blind `--set-mark` запрещён тестом).
  Равносильно `(m & ~MASK) | MARK` при MASK==MARK (один бит).

## Table / pref

```text
Z2K_WARP_TABLE=989   (как upstream; ownership доказывается runtime —
                      таблица обязана быть пуста, иначе FAIL)
Z2K_WARP_PREF=500    (вне mwan3-диапазона 1001-3999 — их churn по паттерну
                      не заденет; вне дефолтов 0/32766/32767; чужое на 500 —
                      FAIL, не замена)
```

Правила:

- enable/PBR: точное наше правило есть → ok (идемпотентность); чужое
  пересечение по fwmark (формальный overlap-тест в коде), занятые table 989
  или pref 500 → FAIL LOUDLY, PBR down, fail open.
- Чужие rules/routes НЕ удаляем/не перезаписываем никогда.
- PBR-down удаляет ТОЛЬКО наш default (`ip route del default ... table 989`)
  и наши exact-правила; `flush table` запрещён.
- mwan3 может удалить/пересоздать СВОИ правила (паттерн не покрывает 500) —
  наши целы; наоборот — мы mwan3 не трогаем.

## Backstop

Всё, что знает только живой роутер (пользовательские fw4/pbr/qosify-метки,
нестандартные mmx_mask), ловит runtime detection (`ip rule show` overlap +
table/pref occupancy) ПЕРЕД enable и каждой PBR-конвергенцией. Тесты
доказывают детекцию на фикстурах обоих исходов.
