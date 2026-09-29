#!/usr/bin/env python3
"""Contract tests for the canonical product release history."""
from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts/openwrt/release-assets.py"
spec = importlib.util.spec_from_file_location("release_assets", MODULE_PATH)
assert spec and spec.loader
release_assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_assets)


def parse(text: str):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "CHANGELOG.md"
        path.write_text(text, encoding="utf-8")
        return release_assets.parse_changelog_history(path)


def main() -> int:
    history = parse("""# Changelog

## [Unreleased]

### Добавлено
- ещё не выпущено

## [0.1.4] - 2026-09-30

### Новое
- Поддержка cumulative release history.

### Исправлено
- Ошибка установки.

### Изменено
- Карточка обновлений.

### Важно
- Нужен подписанный пакет.

## [0.1.3] - 2026-09-20

### Добавлено
- Предыдущая версия.

## [0.1.2] - 2026-09-01

### Исправлено
- Более старая версия.
""")
    assert [item["version"] for item in history] == ["0.1.4", "0.1.3", "0.1.2"], history
    assert history[0]["tag"] == "v0.1.4"
    assert history[0]["published_at"] == "2026-09-30"
    assert history[0]["changelog"] == {
        "new": ["Поддержка cumulative release history."],
        "fixed": ["Ошибка установки."],
        "changed": ["Карточка обновлений."],
        "important": ["Нужен подписанный пакет."],
    }, history[0]
    assert history[1]["changelog"]["new"] == ["Предыдущая версия."]
    assert history[2]["changelog"]["fixed"] == ["Более старая версия."]

    try:
        parse("## [0.1.4] - 2026-09-30\n\n### Новое\n- note\n\n## [0.1.4] - 2026-09-29\n\n### Новое\n- duplicate\n")
    except release_assets.AssetError:
        pass
    else:
        raise AssertionError("duplicate release versions must be rejected")

    try:
        parse("## [0.1.4] - 2026-99-30\n\n### Новое\n- note\n")
    except release_assets.AssetError:
        pass
    else:
        raise AssertionError("invalid release dates must be rejected")

    try:
        release_assets.validate_product_history(history, "0.1.3")
    except release_assets.AssetError:
        pass
    else:
        raise AssertionError("candidate version must be newest changelog release")

    release_assets.validate_product_history(history, "0.1.4")
    print("PRODUCT-MANIFEST: history, Russian categories, date and release-order checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
