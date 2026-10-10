# План установки отдельных архивов OpenWrt для каждой архитектуры

Работа выполняется в существующей ветке `main`. Не создавать отдельную рабочую копию и не менять пользовательские файлы в `output/playwright/`.

**Цель:** установка и обновление OpenWrt должны загружать архив только для своей архитектуры и безопасно работать при 128 МиБ ОЗУ. Сохраняются один подписанный манифест и действующая модель транзакций.

**Устройство:** из одного подготовленного корня собираются семь воспроизводимых архивов с общими файлами и бинарниками одной архитектуры. Подписанные записи хранятся в `UPDATES.json`; полный архив остаётся только в переходном выпуске для старых установщиков. Выбор архива и SHA-256 централизованы. Сжатый архив и проверенная распаковка размещаются во временном каталоге постоянного раздела, а в `/tmp` остаются ограниченные по размеру установочный код и списки файлов. До распаковки и остановки служб проверяются свободное место каждого раздела, текущее `MemAvailable` и запас для отката.

**Средства:** оболочка POSIX и BusyBox `ash`/`tar`, стандартная библиотека Python 3, сборка Go, Ed25519/OpenSSL, GitHub Actions, QEMU/KVM с OpenWrt x86_64.

**Спецификация:** `docs/superpowers/specs/2026-10-10-openwrt-arch-artifacts-design.md`

## Global Constraints

- Keep one schema-1 signed `UPDATES.json` as the only release metadata authority.
- Support `arm64`, `arm`, `x86_64`, `x86`, `mips`, `mipsel`, and `riscv64`; each archive contains common files plus only its target binaries in all three binary trees.
- Use the full legacy `artifact` only in the first migration release; new clients use it only when `artifacts` is entirely absent, and fail closed for an incomplete per-arch map.
- Preserve the one `install_release(tag)` path, OpenWrt adapters, upstream z2k update model, config paths, ownership, signature verification, rollback, and boot recovery; do not introduce APKs or a second installer.
- Проверять подпись, размер и SHA-256 до распаковки. До остановки служб или изменения установленной версии проверять текущее `MemAvailable`, временное хранилище и постоянный раздел.
- В основной схеме архив и распаковка находятся на постоянном разделе и учитываются в его общем бюджете вместе с местом для отката. Временную память занимают только установочный код, списки файлов и запас; если рабочий путь оказался на `tmpfs`, в расчёт добавляется весь фактически размещённый там архив и распаковка.
- Проверять профили 64/128/256 МиБ по текущей свободной памяти, а не по заявленному объёму ОЗУ. При нехватке любого ресурса завершать установку до изменения действующей версии.
- Keep tar handling and shell interfaces compatible with BusyBox/OpenWrt; avoid a stateful cross-process tar-index cache.

## Review Focus

1. A present but incomplete `artifacts` map must fail closed instead of selecting the legacy archive — pin in the manifest-selection tests.
2. Malformed URL, filename, size, digest, or unsupported architecture must not start a download/extraction — pin in manifest and bootstrap tests.
3. Legacy-only, transition, and per-arch-only signed documents must select exactly the intended asset — pin in signing and bootstrap tests.
4. Архив, распаковка, установочный код, списки и резерв должны одновременно помещаться в выбранных файловых системах и текущей свободной памяти. При нехватке места в рабочем пути `tmpfs` установка должна остановиться до загрузки; нехватка постоянного раздела должна обнаруживаться до распаковки или остановки служб. Закрепить обе проверки тестами бюджета памяти и общей транзакции.
5. Interrupted downloads, wrong hashes, Dashboard reinstall, and transaction/boot failures must preserve the active release, receipt, configuration, and ownership — pin in bootstrap, Dashboard, rollback, and recovery tests.

---

## File ownership and interfaces

- **Build artifacts:** `scripts/openwrt/rootfs_bundle.py` and `build-release.sh` own deterministic archive contents and names. `stage-rootfs.sh` continues to provide the complete seven-architecture input tree; change it only if implementation proves the input layout requires it.
- **Release metadata/publication:** `controlled_release.py`, `sign_release.py`, `publication_policy.py`, `publish_release.sh`, `accept_release_candidate.py`, and release/CI workflows own the seven records, optional bridge record, signatures, and uploaded assets.
- **Installed selection:** `platform/openwrt/manifest.sh` owns selected-record validation and digest compatibility. It provides `z2k_ow_manifest_select_artifact <manifest> <arch>`, setting validated globals `Z2K_OW_ARTIFACT_MODE`, `Z2K_OW_ARTIFACT_FILENAME`, `Z2K_OW_ARTIFACT_URL`, `Z2K_OW_ARTIFACT_SHA256`, `Z2K_OW_ARTIFACT_SIZE_BYTES`, and (when available) `Z2K_OW_ARTIFACT_UNPACKED_SIZE_BYTES`. It also owns the validated hotfix digest accessor. `release.sh` and `release_state.sh` consume these helpers and do not parse `artifact.sha256` directly.
- **Bootstrap:** `scripts/openwrt/install.sh` must resolve the same canonical architecture, enforce the same map/fallback rule and validate the selected fields before download. It necessarily has a standalone pre-engine parser; tests pin its behavior to the manifest library contract.
- **Installer budgets/transaction:** bootstrap and `platform/openwrt/release.sh` own checks for combined live tmpfs/RAM and overlay. They reuse the one downloaded archive and preserve existing transaction and recovery functions.
- **Измерения:** временные гости OpenWrt 25.12.5 x86_64 с 128 и 256 МиБ проверяют настоящий установщик BusyBox. Это запущенные гости OpenWrt, не физические роутеры. Отдельно записать результат и ограничение гостя с 64 МиБ.

**Порядок:** сначала согласовать состав архивов и выбор записи в манифесте, затем завершить публикацию, установщик, восстановление и замеры. Все изменения остаются в текущей ветке `main`; пользовательские результаты из `output/playwright/` сохраняются.

## Tasks

### Task 1: Build one deterministic rootfs archive per architecture

**Files:**
- Modify: `scripts/openwrt/rootfs_bundle.py`
- Modify: `scripts/openwrt/build-release.sh`
- Test: `tests/openwrt/test_ow_payload_bundle.py`
- Test: `tests/openwrt/test_ow_unified_architecture.py`

**Interface:** extend `build_rootfs_bundle(staged_root: Path, output: Path, arch: str | None = None)`. With an architecture, retain common entries and filter every `linux-*` payload under the three specified binary roots to exactly `linux-<arch>`; with no architecture, preserve legacy full-bundle behavior for transition builds.

- [x] Add fixtures for all seven architecture names, shared files, and binaries in all three roots. Assert each per-arch tar has common files, its own binaries, no other `linux-*` entries, and remains deterministic.
- [x] Run `python3 tests/openwrt/test_ow_payload_bundle.py`; confirm the new assertions fail against the current all-arch bundle.
- [x] Implement the optional architecture filter without changing metadata normalization, user-data exclusions, safe symlink rules, or existing default behavior.
- [x] Update `build-release.sh` to emit `openwrt-rootfs-<arch>.tar.gz` for all seven keys from the single staged root; emit `openwrt-rootfs.tar.gz` only when the migration caller requests the transition fallback.
- [x] Run `python3 tests/openwrt/test_ow_payload_bundle.py` and `python3 tests/openwrt/test_ow_unified_architecture.py`; confirm every required target executable appears in its own archive.
- [x] Return the builder and test changes for integration; do not stage or commit from the worker.

### Task 2: Normalize per-arch manifest selection and digest consumers

**Files:**
- Modify: `platform/openwrt/manifest.sh`
- Modify: `platform/openwrt/release_state.sh`
- Modify: `platform/openwrt/release.sh`
- Test: `tests/openwrt/test_ow_manifest_signing.sh`
- Test: `tests/openwrt/test_ow_hotfix_panel.sh`
- Test: `tests/openwrt/test_ow_unified_release.sh`

**Interfaces:** implement the selector/global contract in “File ownership and interfaces.” When `artifacts` is absent, it validates and returns legacy `artifact`; when `artifacts` exists, it requires the requested key and never falls back. Provide a dedicated manifest-library hotfix digest accessor so `release_state.sh` keeps its current hotfix meaning without reading JSON paths itself.

- [x] Add tests for legacy-only, transition, and per-arch-only manifests; check the exact returned URL/SHA/size and that an invalid or missing per-arch key fails despite a valid legacy `artifact`.
- [x] Add hotfix digest tests and a source-level assertion that `release.sh`/`release_state.sh` do not parse `artifact.sha256` directly; reserve receipt comparison for Task 4’s unified installer test.
- [x] Run `sh tests/openwrt/test_ow_manifest_signing.sh`, `sh tests/openwrt/test_ow_hotfix_panel.sh`, and `sh tests/openwrt/test_ow_unified_release.sh`; confirm failures identify the missing selected-record behavior.
- [x] Implement the central accessors in `manifest.sh`; route release validation, download metadata, receipt comparison, and hotfix digest reads through those accessors. Preserve strict URL validation and schema-1 legacy behavior.
- [x] Run the same tests plus `python3 tests/openwrt/test_ow_unified_architecture.py`; confirm legacy and per-arch manifest/digest paths pass.
- [x] Return the manifest/runtime changes for integration; do not stage or commit from the worker.

### Task 3: Make signatures and candidate publication cover every archive

**Files:**
- Modify: `scripts/openwrt/controlled_release.py`
- Modify: `scripts/openwrt/sign_release.py`
- Modify: `scripts/openwrt/publication_policy.py`
- Modify: `scripts/openwrt/publish_release.sh`
- Modify: `tests/openwrt/accept_release_candidate.py`
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release-openwrt.yml`
- Test: `tests/openwrt/test_ow_release_signing.py`
- Test: `tests/openwrt/test_ow_publication_policy.py`
- Test: `tests/openwrt/test_ow_release_workflow.py`

**Interface:** records under `artifacts.<arch>` use `filename`, immutable release `url`, lowercase `sha256`, `size_bytes`, and `unpacked_size_bytes`. Before replacing workspace `UPDATES.json` with a new upstream manifest, the workflow derives `include_legacy_fallback` from `RUNNER_TEMP/production-UPDATES.json`: true only when that checked baseline has no `artifacts`; candidate validation rejects a fallback in later releases and requires it for the transition candidate. Retries reuse the exact candidate and the same decision.

- [ ] Add Python tests attaching seven records, validating actual size/SHA for each, signing/verifying the complete JSON, rejecting altered/missing/extra/mismatched assets, and covering both migration baseline states.
- [ ] Run `python3 tests/openwrt/test_ow_release_signing.py`, `python3 tests/openwrt/test_ow_publication_policy.py`, and `python3 tests/openwrt/test_ow_release_workflow.py`; confirm the new per-arch cases fail.
- [ ] Update candidate acceptance and release workflow receipts to enumerate/verify all seven per-arch files plus the optional transition archive; sign one `UPDATES.json` after all asset records are attached.
- [ ] Update publisher upload, re-download, compare, and public-URL verification for the exact asset set; keep the manifest/signature and immutable release checks unchanged.
- [ ] Change candidate acceptance to take `UPDATES.json` and an artifact directory, then run it against a synthetic signed candidate containing all seven per-arch assets and the optional transition archive.
- [ ] Return candidate/signing/publication changes for integration; do not stage or commit from the worker.

### Task 4: Select the architecture in bootstrap and budget the combined live peak

**Files:**
- Modify: `scripts/openwrt/install.sh`
- Modify: `platform/openwrt/release.sh`
- Modify: `tests/openwrt/test_ow_memory_budget.sh`
- Modify: `tests/openwrt/test_ow_bootstrap_engine.sh`
- Modify: `tests/openwrt/test_ow_unified_release.sh`

**Интерфейс:** оба пути определяют одинаковые архитектуру и запись архива. Перед загрузкой сравнить потребность установочного кода, списков и резерва с текущими `MemAvailable` и свободным местом временного хранилища. Архив и проверенная распаковка находятся на постоянном разделе; до загрузки и распаковки сравнить их общий размер с местом этого раздела и резервом отката. После выделения временных файлов повторить проверку до начала транзакции и остановки служб.

- [ ] Add fixtures with 128 MiB and 256 MiB `MemTotal` plus varied current `MemAvailable`; assert an archive that fits alone but not the combined peak fails before download/mutation as appropriate, and a post-download reservation failure leaves active files/services/receipt unchanged.
- [ ] Add bootstrap cases for each manifest generation, target-arch URL selection, truncated transfer, wrong SHA, and no extraction before checksum success. Assert the fake server observes one selected-arch URL only.
- [ ] Run `sh tests/openwrt/test_ow_memory_budget.sh`, `sh tests/openwrt/test_ow_bootstrap_engine.sh`, and `sh tests/openwrt/test_ow_unified_release.sh`; confirm the new assertions fail against current behavior.
- [ ] Implement checked target selection, exact compressed-size/SHA verification before extraction, combined budget checks against current memory/tmpfs, and cleanup of partial downloads; avoid a second full archive copy.
- [ ] Verify after extraction that all three binary roots contain only the target architecture and every required target executable is present; keep existing tar safety checks and BusyBox-compatible behavior.
- [ ] Run the focused tests plus `sh tests/openwrt/test_ow_archive_validation.sh`; confirm invalid archive data still fails before active installation changes.
- [ ] Return bootstrap, budget, and extraction changes for integration; do not stage or commit from the worker.

### Task 5: Preserve Dashboard reinstall, rollback, and boot recovery on selected records

**Files:**
- Modify: `tests/openwrt/test_ow_webpanel_cgi.sh`
- Modify: `tests/openwrt/test_ow_transaction_faults.sh`
- Modify: `tests/openwrt/test_ow_boot_recovery.sh`
- Modify: `tests/openwrt/test_ow_unified_architecture.py`
- Modify production code only if these flows expose a gap: `platform/openwrt/release.sh`, `platform/openwrt/webpanel.sh`

- [ ] Add regression cases that route Dashboard reinstall and ordinary update through the selected artifact for the same tag, preserve configuration/ownership, and update the digest receipt only at transaction commit.
- [ ] Add fault-injection cases for power-loss boundaries with a per-arch receipt; after recovery require either the old complete release or the new complete release, never a mixed tree.
- [ ] Run `sh tests/openwrt/test_ow_webpanel_cgi.sh`, `sh tests/openwrt/test_ow_transaction_faults.sh`, and `sh tests/openwrt/test_ow_boot_recovery.sh`; confirm the per-arch cases fail or show any missing route.
- [ ] Make only the narrow runtime fix required by a failing test; keep one `install_release(tag)` entry point and existing recovery ordering.
- [ ] Run those tests plus `python3 tests/openwrt/test_ow_unified_architecture.py`; verify all adapter entry points remain present and route to the shared release installer.
- [ ] Return regression coverage and any targeted compatibility fix for integration; do not stage or commit from the worker.

### Task 6: Measure the built artifacts and run full OpenWrt QEMU installs

**Files:**
- Create only if needed for repeatability: `tests/openwrt/run_qemu_install_measurement.sh`
- Create: `docs/superpowers/plans/openwrt-arch-artifacts-measurements.md` or a test artifact report adjacent to the plan

- [x] Собрать семь архитектурных архивов и проверить их подписи/контрольные суммы, состав распакованных файлов и отсутствие чужих архитектур во всех трёх деревьях бинарников.
- [x] Сравнить полный архив и новые архивы по размеру; использовать временный ключ только для локального проверочного кандидата, не меняя производственный `UPDATES.json`.
- [x] Выполнить установку на гостях OpenWrt 25.12.5 x86_64 с 128 и 256 МиБ. Записать исходную и минимальную свободную память, пик `/tmp`, занятое место постоянного раздела, время установки и состояние выпуска.
- [x] Проверить, что оба гостя запрашивают только `openwrt-rootfs-x86_64.tar.gz`, а в трёх установленных деревьях бинарников остаётся только `linux-x86_64`.
- [x] Проверить повторную установку на заполненном разделе: отказ до остановки служб и без изменения файлов установленного выпуска. Маршрут переустановки из Dashboard, обновление, прерванную загрузку, неверный SHA-256, откат и загрузочное восстановление покрывают приёмочные и регрессионные тесты.
- [x] Выполнить итоговый `sh tests/openwrt/run.sh` и сохранить сводку в отчёте измерений: `OPENWRT: pass=4585 fail=0`, Python — 103 проверки. Два необязательных локальных теста пропущены из-за отсутствующих зависимостей. Гость с 64 МиБ исчерпал память до запуска установщика; успешная установка на 64 МиБ этим прогоном не подтверждена.
- [ ] Просмотреть полный diff на `main`; не менять производственный `UPDATES.json` и не публиковать архивы без защищённого ключа выпуска.
