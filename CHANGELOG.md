# Changelog

Короткие заметки о пользовательских изменениях z2kOW. Внутренние CI snapshots сюда не добавляются. Текущий OpenWrt install/update contract описан в [`docs/openwrt-release-operations.md`](docs/openwrt-release-operations.md); расхождения с upstream — в [`docs/UPSTREAM-PARITY-MATRIX.md`](docs/UPSTREAM-PARITY-MATRIX.md).

## [Unreleased]

### Добавлено

- Управление product-релизами из CLI `z2kow` и карточки обновления WebPanel; история читается из controlled release manifest, состояние и журнал операции доступны через product update API.
- Единый OpenWrt rootfs candidate содержит adapter, необязательную WebPanel, закреплённый zapret2 runtime и WARP runtime; manifest связывает полный архив с его размером и SHA-256.
- Bootstrap проверяет подпись controlled manifest и устанавливает полный `openwrt-rootfs.tar.gz` через `install_release`.

### Исправлено

- В WebPanel оставлено по одному списку маршрутов; узкая desktop-граница не обрезает оболочку, а задержка локальной бренд-темы не блокирует первый маршрут.
- WebPanel продолжает запускать маршруты, если браузерный блокировщик отсекает необязательный ресурс визуальной идентичности.
- OpenWrt WebPanel использует одну lockup-композицию `z2kOW` с локальным route-ribbon знаком и HTML wordmark.
- Светлая и тёмная темы оформляют навигацию, карточки, поля, таблицы, состояния, фокус и узкие экраны общими семантическими токенами.
- Обратимый сброс стратегий показан нейтральным действием; уникальный набор стратегий отмечен как экспериментальный.
- Мобильная навигация переводит фокус в drawer, удерживает его внутри, закрывается по Escape и возвращает фокус на кнопку.

### Доступность

- Добавлены проверки контраста в обеих темах, клавиатурного фокуса, сенсорных целей 44 px, узкой ширины и viewport с масштабом 200%.
- Маршруты остаются доступны, если блокировщик скрывает необязательные identity assets или модуль идентичности.

### Совместимость и acceptance

- Заявленная совместимость включает OpenWrt 25.12.5, target `mediatek/filogic`.
- Cudy WBR3000UAX v1 и WEB-LUCI-01 остаются заблокированными до появления проверяемого live acceptance в [`docs/openwrt-release-acceptance.json`](docs/openwrt-release-acceptance.json).

Ранее подготовленные заметки о production component APK, локальном APK snapshot install и версии package revision относились к снятому release candidate flow и удалены. Они не являются инструкциями для текущего rootfs выпуска.
