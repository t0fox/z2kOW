# Changelog

Короткие заметки о пользовательских изменениях z2kOW. Snapshot и внутренние
изменения package revision сюда не добавляются. Production release workflow
берёт release notes только из секции соответствующей SemVer-версии.

## [Unreleased]

### Исправлено

- Webpanel продолжает запускать маршруты, если браузерный блокировщик
  отсекает необязательный ресурс визуальной идентичности.
- CI snapshot webpanel требует ту же версию adapter, которую выбрал canonical
  builder.

### Изменено

- Сборщик release отказывает при любых незакоммиченных изменениях, включая
  staged-файлы.
- Product package version проверяется как SemVer без ведущих нулей.
- Canonical builder больше не выдаёт legacy stable package revision `rXX`;
  сборке требуется явно выбрать CI snapshot или product release.
- CI snapshot использует следующую patch prerelease-версию и revision `r1`:
  она обновляет установленный `0.1.0-r79`, а production `0.1.1-r1`
  остаётся новее snapshot.
- OpenWrt webpanel использует одну lockup-композицию `z2kOW` с локальным
  route-ribbon знаком и HTML wordmark.
- Светлая и тёмная темы оформляют навигацию, карточки, поля, таблицы,
  состояния, фокус и узкие экраны общими семантическими токенами.
- Обратимый сброс стратегий показан нейтральным действием; уникальный набор
  стратегий отмечен как экспериментальный.
- Мобильная навигация переводит фокус в drawer, удерживает его внутри,
  закрывается по Escape и возвращает фокус на кнопку.
- Минимальная версия adapter для webpanel следует версии, выбранной
  canonical builder для snapshot или production release.

### Доступность

- Добавлены проверки контраста в обеих темах, клавиатурного фокуса,
  сенсорных целей 44 px, узкой ширины и viewport с масштабом 200%.
- Маршруты остаются доступны, если блокировщик скрывает необязательные
  identity assets или модуль идентичности.

## [0.1.1]

### Добавлено

- Первый самостоятельный OpenWrt bundle z2kOW: adapter, необязательная
  webpanel, zapret2 runtime и WARP runtime.
- Provenance и checksums для неизменяемого набора package assets.

### Обновление с предыдущих сборок

- Версия первого production-релиза повышена до `0.1.1`: на роутере уже
  установлены `z2k-adapter-0.1.0-r79` и `z2k-webpanel-0.1.0-r79`, а новый
  production bundle начинает с package revision `r1`.

### Совместимость

- OpenWrt 25.12.5, target `mediatek/filogic`.
- Cudy WBR3000UAX v1 и WEB-LUCI-01 остаются заблокированными до появления
  проверяемого live acceptance в `docs/openwrt-release-acceptance.json`.
