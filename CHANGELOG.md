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

## [0.1.0]

### Добавлено

- Первый самостоятельный OpenWrt bundle z2kOW: adapter, необязательная
  webpanel, zapret2 runtime и WARP runtime.
- Provenance и checksums для неизменяемого набора package assets.

### Совместимость

- OpenWrt 25.12.5, target `mediatek/filogic`.
- Cudy WBR3000UAX v1 и WEB-LUCI-01 остаются заблокированными до появления
  проверяемого live acceptance в `docs/openwrt-release-acceptance.json`.
