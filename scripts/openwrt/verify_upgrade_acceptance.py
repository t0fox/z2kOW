#!/usr/bin/env python3
"""Проверяет квитанцию обновления, созданную предыдущим опубликованным установщиком."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"корень JSON должен быть объектом: {path}")
    return value


def archive_record(
    manifest: dict[str, Any], architecture: str, *, prefer_legacy: bool = False,
) -> dict[str, Any]:
    artifacts = manifest.get("artifacts")
    record = None if prefer_legacy else (artifacts.get(architecture) if isinstance(artifacts, dict) else None)
    if record is None:
        record = manifest.get("artifact")
    if not isinstance(record, dict):
        raise ValueError(f"в манифесте нет архива для {architecture}")
    filename, digest, size = record.get("filename"), record.get("sha256"), record.get("size_bytes")
    if not isinstance(filename, str) or Path(filename).name != filename:
        raise ValueError("неверное имя архива")
    if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise ValueError("неверный формат SHA-256 архива")
    if not isinstance(size, int) or size <= 0:
        raise ValueError("неверный размер архива")
    return record


def verify_manifest_signature(manifest_path: Path, signature_path: Path, key_id: str, key_path: Path) -> None:
    if not key_path.is_file() or key_path.is_symlink():
        raise ValueError(f"закреплённый открытый ключ отсутствует или небезопасен: {key_path}")
    der = subprocess.run(
        ["openssl", "pkey", "-pubin", "-in", str(key_path), "-outform", "DER"],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout
    if hashlib.sha256(der).hexdigest() != key_id:
        raise ValueError("отпечаток закреплённого открытого ключа не совпадает с манифестом")
    subprocess.run(
        ["openssl", "pkeyutl", "-verify", "-rawin", "-pubin", "-inkey", str(key_path),
         "-in", str(manifest_path), "-sigfile", str(signature_path)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def verify(args: argparse.Namespace) -> None:
    receipt = load_json(args.receipt)
    previous = load_json(args.previous_manifest)
    candidate = load_json(args.candidate_manifest)

    key_id = previous.get("signing", {}).get("key_id")
    if not isinstance(key_id, str) or re.fullmatch(r"[0-9a-f]{64}", key_id) is None:
        raise ValueError("в предыдущем манифесте нет корректного идентификатора ключа подписи")
    public_key = args.public_key or args.repository / "scripts/openwrt/release-keys" / f"{key_id}.pub"
    verify_manifest_signature(args.previous_manifest, args.previous_signature, key_id, public_key)

    candidate_key_id = candidate.get("signing", {}).get("key_id")
    if not isinstance(candidate_key_id, str) or re.fullmatch(r"[0-9a-f]{64}", candidate_key_id) is None:
        raise ValueError("в манифесте кандидата нет корректного идентификатора ключа подписи")
    candidate_signature = args.candidate_signature
    candidate_public_key = args.candidate_public_key or (
        args.repository / "scripts/openwrt/release-keys" / f"{candidate_key_id}.pub"
    )
    verify_manifest_signature(args.candidate_manifest, candidate_signature, candidate_key_id, candidate_public_key)

    previous_record = archive_record(previous, args.architecture)
    # В p-86.17 нет выбора архива по архитектуре. Первое обновление должно
    # использовать общий подписанный архив, даже если кандидат содержит отдельные.
    # Квитанция связывается с точными байтами; сборщик отдельно проверяет полный набор.
    legacy_transition = (
        not isinstance(previous.get("artifacts"), dict)
        and isinstance(candidate.get("artifact"), dict)
    )
    candidate_record = archive_record(candidate, args.architecture, prefer_legacy=legacy_transition)
    candidate_archive = args.candidate_dir / candidate_record["filename"]
    expected = {
        "schema": 1,
        "result": "passed",
        "environment": "previous-published-installer",
        "architecture": args.architecture,
        "previous_tag": previous.get("current"),
        "previous_seq": previous.get("seq"),
        "previous_manifest_sha256": sha256(args.previous_manifest),
        "previous_signature_sha256": sha256(args.previous_signature),
        "previous_archive_sha256": previous_record["sha256"],
        "candidate_tag": candidate.get("current"),
        "candidate_seq": candidate.get("seq"),
        "candidate_manifest_sha256": sha256(args.candidate_manifest),
        "candidate_archive_sha256": candidate_record["sha256"],
        "candidate_signature_verified_by_previous_engine": True,
        "candidate_signature_sha256": sha256(candidate_signature),
        "mem_total_kb": 131072,
    }
    for key, value in expected.items():
        if receipt.get(key) != value:
            raise ValueError(f"квитанция обновления не совпадает с полем {key}")
    if not isinstance(previous.get("seq"), int) or not isinstance(candidate.get("seq"), int):
        raise ValueError("номера последовательности предыдущей версии и кандидата должны быть целыми числами")
    if candidate["seq"] < previous["seq"]:
        raise ValueError("номер последовательности кандидата не может быть меньше опубликованного")
    if candidate["seq"] == previous["seq"]:
        if candidate.get("current") != previous.get("current"):
            raise ValueError("при равном номере последовательности тег должен совпадать с опубликованным")
        if candidate_record["sha256"] == previous_record["sha256"]:
            raise ValueError("проверка исправления той же версии должна содержать изменённый архив архитектуры")
    available = receipt.get("mem_available_kb")
    if not isinstance(available, int) or not 20_000 <= available <= 25_000:
        raise ValueError("показатель свободной памяти квитанции вне диапазона приёмки малой памяти")
    previous_stage_default = receipt.get("previous_stage_default")
    if previous_stage_default not in ("tmpfs", "persistent"):
        raise ValueError("квитанция не указывает файловую систему временных данных предыдущей установки")
    scenarios = receipt.get("scenarios")
    required_scenarios = (
        "insufficient_persistent_space",
        "rollback_after_service_stop",
        "panel_update_default_persistent",
        "successful_upgrade",
        "user_configuration_preserved",
        "services_running_after_upgrade",
    )
    if not isinstance(scenarios, dict) or any(scenarios.get(name) is not True for name in required_scenarios):
        raise ValueError("в квитанции отсутствует обязательный сценарий при малом объёме памяти")
    if previous_stage_default == "tmpfs" and scenarios.get("legacy_tmpfs_refusal") is not True:
        raise ValueError("до перехода с tmpfs нужно подтвердить, что предыдущий установщик отказывается от установки в RAM")
    if not candidate_archive.is_file() or candidate_archive.is_symlink():
        raise ValueError("архив кандидата отсутствует или является символической ссылкой")
    if candidate_archive.stat().st_size != candidate_record["size_bytes"] or sha256(candidate_archive) != candidate_record["sha256"]:
        raise ValueError("содержимое архива кандидата не совпадает с его манифестом")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--previous-manifest", type=Path, required=True)
    parser.add_argument("--previous-signature", type=Path, required=True)
    parser.add_argument("--candidate-manifest", type=Path, required=True)
    parser.add_argument("--candidate-signature", type=Path, required=True)
    parser.add_argument("--candidate-dir", type=Path, required=True)
    parser.add_argument("--architecture", required=True)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--public-key", type=Path)
    parser.add_argument("--candidate-public-key", type=Path)
    args = parser.parse_args()
    try:
        verify(args)
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"квитанция приёмки обновления отклонена: {error}", file=sys.stderr)
        return 1
    print("квитанция приёмки привязана к подписанному предыдущему релизу и точному архиву кандидата")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
