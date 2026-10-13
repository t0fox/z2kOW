#!/usr/bin/env python3
"""Проверить и подготовить hotfix-кандидат из доверенного push-CI."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from controlled_release import (
    ARCHITECTURES,
    attach_architecture_artifacts,
    migration_fallback_required,
    read_json_object,
    render_manifest,
    validate_architecture_assets,
    write_manifest,
)


API_ROOT = "https://api.github.com"
WORKFLOW_PATH = ".github/workflows/ci.yml"
ARTIFACT_PREFIX = "z2kow-openwrt-unsigned-"
ACCEPTANCE_FILES = ("candidate-acceptance.json", "upgrade-acceptance.json")
MAX_ARTIFACT_SIZE = 512 * 1024 * 1024
COMMIT_RE = re.compile(r"[0-9a-f]{40}\Z")
HEX_RE = re.compile(r"[0-9a-f]{64}\Z")


class FastPathVerificationError(RuntimeError):
    """Происхождение, целостность или приёмка CI-кандидата не подтверждены."""


class CandidateNotReusable(RuntimeError):
    """Кандидат достоверен, но не подходит этой версии hotfix."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _manifest_base(manifest: dict[str, object]) -> dict[str, object]:
    return {key: value for key, value in manifest.items() if key not in {"artifact", "artifacts", "signing"}}


def verify_ci_run(
    run: dict[str, object], jobs: list[dict[str, object]], source_sha: str, run_id: int, repository: str
) -> dict[str, object]:
    if not COMMIT_RE.fullmatch(source_sha):
        raise FastPathVerificationError("source SHA должен быть полным lowercase SHA-1")
    if run.get("id") != run_id or run.get("head_sha") != source_sha:
        raise FastPathVerificationError("CI run не относится к запрошенному source SHA")
    if (run.get("event"), run.get("head_branch"), run.get("path")) != ("push", "main", WORKFLOW_PATH):
        raise FastPathVerificationError("кандидат должен происходить из push workflow ci.yml ветки main")
    if (run.get("status"), run.get("conclusion")) != ("completed", "success"):
        raise FastPathVerificationError("весь push-CI для source SHA должен завершиться успешно")
    head_repository = run.get("head_repository")
    if not isinstance(head_repository, dict) or head_repository.get("full_name") != repository:
        raise FastPathVerificationError("CI run должен происходить из основного репозитория, а не из fork")
    if not jobs:
        raise FastPathVerificationError("GitHub не вернул список обязательных CI jobs")
    incomplete = [
        str(job.get("name", "<без имени>"))
        for job in jobs
        if job.get("status") != "completed" or job.get("conclusion") != "success"
    ]
    if incomplete:
        raise FastPathVerificationError(f"есть неуспешные или пропущенные CI jobs: {incomplete}")
    if not any(job.get("name") == "OpenWrt full-payload release" for job in jobs):
        raise FastPathVerificationError("успешный OpenWrt full-payload job отсутствует в CI")
    return run


def verify_artifact_record(artifact: dict[str, object], run_id: int, source_sha: str) -> dict[str, object]:
    expected_name = ARTIFACT_PREFIX + source_sha
    digest = artifact.get("digest")
    workflow_run = artifact.get("workflow_run")
    if artifact.get("name") != expected_name or artifact.get("expired") is not False:
        raise CandidateNotReusable("в точном CI run нет действующего OpenWrt candidate artifact")
    if not isinstance(workflow_run, dict) or workflow_run.get("id") != run_id or workflow_run.get("head_sha") != source_sha:
        raise FastPathVerificationError("candidate artifact не привязан к проверенному CI run и source SHA")
    if not isinstance(artifact.get("id"), int) or artifact["id"] <= 0:
        raise FastPathVerificationError("GitHub вернул неверный ID CI artifact")
    if (
        not isinstance(artifact.get("size_in_bytes"), int)
        or artifact["size_in_bytes"] <= 0
        or artifact["size_in_bytes"] > MAX_ARTIFACT_SIZE
    ):
        raise FastPathVerificationError("GitHub вернул неверный размер CI artifact")
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise FastPathVerificationError("GitHub не предоставил проверяемый SHA-256 CI artifact")
    return artifact


def verify_downloaded_archive(path: Path, artifact: dict[str, object]) -> None:
    digest = artifact.get("digest")
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise FastPathVerificationError("CI artifact не содержит SHA-256 digest")
    if Path(path).stat().st_size != artifact.get("size_in_bytes"):
        raise FastPathVerificationError("размер скачанного CI artifact не совпадает с GitHub API")
    if sha256_file(path) != digest.removeprefix("sha256:"):
        raise FastPathVerificationError("SHA-256 скачанного CI artifact не совпадает с GitHub API")


def _read_json(path: Path, description: str) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FastPathVerificationError(f"не удалось прочитать {description}: {error}") from error
    if not isinstance(value, dict):
        raise FastPathVerificationError(f"{description} должен содержать JSON-объект")
    return value


def _asset_hashes(manifest: dict[str, object], directory: Path, source_sha: str) -> dict[str, str]:
    try:
        validate_architecture_assets(manifest, directory, source_sha)
    except (OSError, ValueError) as error:
        raise FastPathVerificationError(f"архитектурный payload не прошёл проверку: {error}") from error
    records = manifest.get("artifacts")
    if not isinstance(records, dict):
        raise FastPathVerificationError("кандидат не содержит семь записей архитектурных payload")
    names = [record["filename"] for record in records.values() if isinstance(record, dict)]
    legacy = manifest.get("artifact")
    if isinstance(legacy, dict):
        names.append(legacy["filename"])
    return {str(name): sha256_file(directory / str(name)) for name in names}


def _verify_receipts(
    directory: Path,
    manifest: dict[str, object],
    manifest_path: Path,
    baseline_path: Path,
    signature_path: Path,
    hashes: dict[str, str],
) -> dict[str, str]:
    for name in ACCEPTANCE_FILES:
        if not (directory / name).is_file():
            raise FastPathVerificationError(f"в CI candidate отсутствует квитанция {name}")
    candidate_receipt = _read_json(directory / "candidate-acceptance.json", "квитанция install acceptance")
    expected_candidate = {
        "schema": 1,
        "result": "passed",
        "environment": "staged-linux-rootfs",
        "router_verified": False,
        "architectures": sorted(ARCHITECTURES),
        "tag": manifest.get("current"),
        "seq": manifest.get("seq"),
        "manifest_sha256": sha256_file(manifest_path),
        "artifact_sha256": hashes.get("openwrt-rootfs-x86_64.tar.gz"),
        "asset_sha256": hashes,
    }
    if candidate_receipt != expected_candidate:
        raise FastPathVerificationError("install acceptance не подтверждает эти семь payload и этот manifest")

    upgrade = _read_json(directory / "upgrade-acceptance.json", "квитанция upgrade acceptance")
    baseline = _read_json(baseline_path, "production baseline")
    expected_upgrade = {
        "schema": 1,
        "result": "passed",
        "environment": "previous-published-installer",
        "architecture": "x86_64",
        "previous_tag": baseline.get("current"),
        "previous_seq": baseline.get("seq"),
        "previous_manifest_sha256": sha256_file(baseline_path),
        "previous_signature_sha256": sha256_file(signature_path),
        "candidate_tag": manifest.get("current"),
        "candidate_seq": manifest.get("seq"),
        "candidate_manifest_sha256": sha256_file(manifest_path),
        "candidate_archive_sha256": hashes.get("openwrt-rootfs-x86_64.tar.gz"),
        "candidate_signature_verified_by_previous_engine": False,
        "candidate_test_signature_verified_by_previous_engine": True,
    }
    for key, value in expected_upgrade.items():
        if upgrade.get(key) != value:
            raise FastPathVerificationError(f"upgrade acceptance не подтверждает поле {key}")
    scenario_results = upgrade.get("scenarios")
    required_scenarios = (
        "panel_update_default_persistent",
        "insufficient_persistent_space",
        "rollback_after_service_stop",
        "successful_upgrade",
        "user_configuration_preserved",
        "services_running_after_upgrade",
    )
    if not isinstance(scenario_results, dict) or any(scenario_results.get(name) is not True for name in required_scenarios):
        raise FastPathVerificationError("upgrade acceptance не подтверждает обязательные upgrade сценарии")

    hashes_out = {name: sha256_file(directory / name) for name in ACCEPTANCE_FILES}
    transition = directory / "p8617-transition-acceptance.json"
    if transition.exists():
        receipt = _read_json(transition, "квитанция миграционного перехода")
        if (
            receipt.get("schema") != 1
            or receipt.get("result") != "passed"
            or receipt.get("candidate_tag") != manifest.get("current")
            or receipt.get("candidate_seq") != manifest.get("seq")
            or receipt.get("candidate_manifest_sha256") != sha256_file(manifest_path)
        ):
            raise FastPathVerificationError("миграционная квитанция относится к другому кандидату")
        hashes_out[transition.name] = sha256_file(transition)
    return hashes_out


def verify_candidate_directory(
    directory: Path,
    baseline_path: Path,
    signature_path: Path,
    source_sha: str,
    expected_tag: str,
    expected_seq: int,
    *,
    manifest_name: str = "UPDATES.json",
) -> dict[str, object]:
    directory = Path(directory)
    baseline_path = Path(baseline_path)
    signature_path = Path(signature_path)
    if not directory.is_dir() or not baseline_path.is_file() or not signature_path.is_file():
        raise FastPathVerificationError("candidate, production baseline или подпись baseline отсутствуют")
    manifest_path = directory / manifest_name
    manifest = _read_json(manifest_path, "unsigned CI candidate manifest")
    baseline = _read_json(baseline_path, "production baseline")
    if manifest.get("signing") is not None:
        raise FastPathVerificationError("CI candidate должен быть неподписанным; ключ подписи добавляет trusted job")
    if manifest.get("current") != expected_tag or manifest.get("seq") != expected_seq:
        raise CandidateNotReusable("CI candidate tag/seq не совпадает с проверяемым hotfix")
    if (baseline.get("current"), baseline.get("seq")) != (expected_tag, expected_seq):
        raise CandidateNotReusable("hotfix изменяет production tag/seq; нужен обычный полный build")
    if _manifest_base(manifest) != _manifest_base(baseline):
        raise CandidateNotReusable("CI candidate собран не из точного production baseline")
    expected_legacy = migration_fallback_required(baseline)
    if ("artifact" in manifest) != expected_legacy:
        raise FastPathVerificationError("legacy fallback CI candidate не соответствует production policy")
    hashes = _asset_hashes(manifest, directory, source_sha)
    receipts = _verify_receipts(directory, manifest, manifest_path, baseline_path, signature_path, hashes)
    return {
        "manifest": manifest,
        "manifest_path": manifest_path,
        "manifest_sha256": sha256_file(manifest_path),
        "production_baseline_sha256": sha256_file(baseline_path),
        "production_signature_sha256": sha256_file(signature_path),
        "tag": expected_tag,
        "seq": expected_seq,
        "assets": hashes,
        "receipts": receipts,
        "include_legacy_fallback": expected_legacy,
    }


def _verify_baseline_signature(baseline_path: Path, signature_path: Path, release_keys_dir: Path) -> str:
    baseline = _read_json(baseline_path, "production baseline")
    signing = baseline.get("signing")
    key_id = signing.get("key_id") if isinstance(signing, dict) else None
    if not isinstance(key_id, str) or not HEX_RE.fullmatch(key_id):
        raise FastPathVerificationError("production baseline не содержит отпечаток подписи")
    public_key = Path(release_keys_dir) / f"{key_id}.pub"
    if not public_key.is_file():
        raise FastPathVerificationError("публичный ключ production baseline отсутствует")
    try:
        fingerprint = subprocess.run(
            ["openssl", "pkey", "-pubin", "-in", str(public_key), "-outform", "DER"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise FastPathVerificationError("не удалось прочитать public key production baseline") from error
    if hashlib.sha256(fingerprint).hexdigest() != key_id:
        raise FastPathVerificationError("отпечаток production public key не совпадает с baseline")
    try:
        result = subprocess.run(
            [
                "openssl", "pkeyutl", "-verify", "-rawin", "-pubin", "-inkey", str(public_key),
                "-in", str(baseline_path), "-sigfile", str(signature_path),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError as error:
        raise FastPathVerificationError("не удалось запустить проверку production подписи") from error
    if result.returncode:
        raise FastPathVerificationError("production baseline не прошёл проверку Ed25519-подписи")
    return key_id


def prepare_release_candidate(
    ci_directory: Path,
    output_directory: Path,
    baseline_path: Path,
    signature_path: Path,
    source_sha: str,
    ci_run_id: int,
    artifact_id: int,
    artifact_digest: str,
    artifact_size: int,
    release_key_id: str,
) -> dict[str, object]:
    output_directory = Path(output_directory)
    if output_directory.exists():
        raise FastPathVerificationError("каталог release candidate уже существует")
    proof = verify_candidate_directory(
        ci_directory,
        baseline_path,
        signature_path,
        source_sha,
        str(_read_json(baseline_path, "production baseline")["current"]),
        int(_read_json(baseline_path, "production baseline")["seq"]),
    )
    if not HEX_RE.fullmatch(release_key_id) or not re.fullmatch(r"sha256:[0-9a-f]{64}", artifact_digest):
        raise FastPathVerificationError("release key id или CI artifact digest повреждён")
    output_directory.mkdir(parents=True)
    try:
        for source in Path(ci_directory).iterdir():
            if source.is_file() and not source.is_symlink():
                shutil.copyfile(source, output_directory / source.name)
        shutil.copyfile(Path(ci_directory) / "UPDATES.json", output_directory / "ci-candidate-UPDATES.json")
        shutil.copyfile(baseline_path, output_directory / "ci-production-UPDATES.json")
        shutil.copyfile(signature_path, output_directory / "ci-production-UPDATES.json.sig")

        manifest = _read_json(baseline_path, "production baseline")
        attach_architecture_artifacts(manifest, output_directory, source_sha, manifest, release_key_id)
        write_manifest(output_directory / "UPDATES.json", manifest)
        final_manifest = _read_json(output_directory / "UPDATES.json", "подготовленный release manifest")
        original_ci_manifest = _read_json(output_directory / "ci-candidate-UPDATES.json", "исходный CI manifest")
        original_ci_manifest.pop("signing", None)
        final_unsigned = dict(final_manifest)
        final_unsigned.pop("signing", None)
        if original_ci_manifest != final_unsigned:
            raise FastPathVerificationError("release metadata отличается от CI manifest не только signing.key_id")

        assets = _asset_hashes(final_manifest, output_directory, source_sha)
        attestation: dict[str, object] = {
            "schema": 1,
            "mode": "verified-ci-hotfix",
            "source_sha": source_sha,
            "source_ci_run_id": ci_run_id,
            "source_ci_artifact_id": artifact_id,
            "source_ci_artifact_name": ARTIFACT_PREFIX + source_sha,
            "source_ci_artifact_digest": artifact_digest,
            "source_ci_artifact_size_bytes": artifact_size,
            "ci_candidate_manifest_sha256": sha256_file(output_directory / "ci-candidate-UPDATES.json"),
            "final_manifest_sha256": sha256_file(output_directory / "UPDATES.json"),
            "production_baseline_sha256": sha256_file(output_directory / "ci-production-UPDATES.json"),
            "production_signature_sha256": sha256_file(output_directory / "ci-production-UPDATES.json.sig"),
            "tag": final_manifest.get("current"),
            "seq": final_manifest.get("seq"),
            "release_key_id": release_key_id,
            "release_metadata_delta": ["signing.key_id"],
            "assets": assets,
            "acceptance_receipts": proof["receipts"],
            "include_legacy_fallback": proof["include_legacy_fallback"],
        }
        (output_directory / "ci-fastpath-attestation.json").write_text(
            json.dumps(attestation, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8"
        )
        verify_final_candidate(output_directory, source_sha, ci_run_id, release_key_id)
        return attestation
    except Exception:
        shutil.rmtree(output_directory, ignore_errors=True)
        raise


def verify_final_candidate(
    directory: Path, source_sha: str, ci_run_id: int | None = None, release_key_id: str | None = None
) -> dict[str, object]:
    directory = Path(directory)
    attestation = _read_json(directory / "ci-fastpath-attestation.json", "fast-path attestation")
    if attestation.get("schema") != 1 or attestation.get("mode") != "verified-ci-hotfix":
        raise FastPathVerificationError("схема fast-path attestation не поддерживается")
    if attestation.get("source_sha") != source_sha or (ci_run_id is not None and attestation.get("source_ci_run_id") != ci_run_id):
        raise FastPathVerificationError("fast-path attestation относится к другому source SHA или CI run")
    if release_key_id is not None and attestation.get("release_key_id") != release_key_id:
        raise FastPathVerificationError("fast-path attestation привязана к другому ключу подписи")
    if attestation.get("release_metadata_delta") != ["signing.key_id"]:
        raise FastPathVerificationError("изменения release metadata выходят за пределы signing.key_id")
    if (
        not isinstance(attestation.get("source_ci_run_id"), int)
        or attestation["source_ci_run_id"] <= 0
        or not isinstance(attestation.get("source_ci_artifact_id"), int)
        or attestation["source_ci_artifact_id"] <= 0
        or attestation.get("source_ci_artifact_name") != ARTIFACT_PREFIX + source_sha
        or not isinstance(attestation.get("source_ci_artifact_digest"), str)
        or not re.fullmatch(r"sha256:[0-9a-f]{64}", attestation["source_ci_artifact_digest"])
        or not isinstance(attestation.get("source_ci_artifact_size_bytes"), int)
        or attestation["source_ci_artifact_size_bytes"] <= 0
    ):
        raise FastPathVerificationError("attestation не содержит точные реквизиты CI artifact")
    baseline_path = directory / "ci-production-UPDATES.json"
    signature_path = directory / "ci-production-UPDATES.json.sig"
    ci_manifest_path = directory / "ci-candidate-UPDATES.json"
    final_manifest_path = directory / "UPDATES.json"
    expected_hashes = {
        "ci_candidate_manifest_sha256": sha256_file(ci_manifest_path),
        "final_manifest_sha256": sha256_file(final_manifest_path),
        "production_baseline_sha256": sha256_file(baseline_path),
        "production_signature_sha256": sha256_file(signature_path),
    }
    if any(attestation.get(key) != value for key, value in expected_hashes.items()):
        raise FastPathVerificationError("fast-path attestation не совпадает с сохранёнными manifest/подписью")
    ci_manifest = _read_json(ci_manifest_path, "исходный CI manifest")
    final_manifest = _read_json(final_manifest_path, "release manifest")
    if (ci_manifest.get("current"), ci_manifest.get("seq")) != (attestation.get("tag"), attestation.get("seq")):
        raise FastPathVerificationError("версия исходного CI manifest не совпадает с attestation")
    if final_manifest.get("signing") != {"key_id": attestation.get("release_key_id")}:
        raise FastPathVerificationError("release manifest не содержит ожидаемый production key id")
    unsigned_final = dict(final_manifest)
    unsigned_final.pop("signing", None)
    if ci_manifest != unsigned_final:
        raise FastPathVerificationError("final manifest отличается от принятого CI manifest за пределами подписи")
    if _manifest_base(ci_manifest) != _manifest_base(_read_json(baseline_path, "production baseline")):
        raise FastPathVerificationError("CI manifest не происходит из сохранённого production baseline")
    ci_proof = verify_candidate_directory(
        directory,
        baseline_path,
        signature_path,
        source_sha,
        str(attestation.get("tag")),
        int(attestation.get("seq", 0)),
        manifest_name="ci-candidate-UPDATES.json",
    )
    final_hashes = _asset_hashes(final_manifest, directory, source_sha)
    if attestation.get("assets") != final_hashes or ci_proof.get("assets") != final_hashes:
        raise FastPathVerificationError("fast-path candidate payload SHA-256 изменился после CI acceptance")
    if attestation.get("acceptance_receipts") != ci_proof.get("receipts"):
        raise FastPathVerificationError("fast-path attestation не совпадает с CI acceptance receipts")
    _verify_baseline_signature(baseline_path, signature_path, Path(__file__).resolve().parent / "release-keys")
    return attestation


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):  # type: ignore[no-untyped-def]
        return None


def _api_json(url: str, token: str) -> tuple[dict[str, object], str]:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or parsed.netloc != "api.github.com":
        raise FastPathVerificationError("GitHub API вернул недоверенный URL")
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "z2kow-ci-candidate-verifier",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            value = json.load(response)
            return value, response.headers.get("Link", "")
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
        raise FastPathVerificationError(f"не удалось проверить GitHub Actions API: {error}") from error


def _api_pages(url: str, token: str) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    while url:
        payload, link = _api_json(url, token)
        values = payload.get("jobs", payload.get("artifacts"))
        if not isinstance(values, list):
            raise FastPathVerificationError("GitHub Actions API вернул неверный список")
        result.extend(item for item in values if isinstance(item, dict))
        next_url = ""
        for part in link.split(","):
            match = re.match(r'\s*<([^>]+)>\s*;\s*rel="next"', part)
            if match:
                next_url = match.group(1)
                break
        if next_url:
            next_parts = urllib.parse.urlsplit(next_url)
            if next_parts.scheme != "https" or next_parts.netloc != "api.github.com":
                raise FastPathVerificationError("GitHub Actions API вернул неверную ссылку пагинации")
        url = next_url
    return result


def _download_verified_zip(artifact: dict[str, object], token: str, destination: Path) -> None:
    artifact_id = artifact["id"]
    api_url = str(artifact.get("archive_download_url", ""))
    parsed = urllib.parse.urlsplit(api_url)
    if (
        parsed.scheme != "https"
        or parsed.netloc != "api.github.com"
        or not parsed.path.endswith(f"/actions/artifacts/{artifact_id}/zip")
    ):
        raise FastPathVerificationError("GitHub вернул неверную ссылку CI artifact")
    request = urllib.request.Request(
        api_url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "z2kow-ci-candidate-verifier",
        },
    )
    opener = urllib.request.build_opener(_NoRedirect())
    def save_and_verify(response: object) -> None:
        with Path(destination).open("wb") as output:
            while block := response.read(1024 * 1024):  # type: ignore[attr-defined]
                output.write(block)
        verify_downloaded_archive(Path(destination), artifact)

    try:
        with opener.open(request, timeout=30) as response:
            if response.status == 200:
                save_and_verify(response)
                return
            download_url = response.geturl()
    except urllib.error.HTTPError as error:
        if error.code not in {301, 302, 303, 307, 308}:
            raise FastPathVerificationError(f"GitHub не выдал CI artifact (HTTP {error.code})") from error
        download_url = error.headers.get("Location", "")
    except OSError as error:
        raise FastPathVerificationError(f"не удалось запросить CI artifact: {error}") from error
    parsed_download = urllib.parse.urlsplit(download_url)
    if parsed_download.scheme != "https" or not parsed_download.hostname:
        raise FastPathVerificationError("ссылка на архив CI artifact небезопасна")
    try:
        with urllib.request.urlopen(
            urllib.request.Request(download_url, headers={"User-Agent": "z2kow-ci-candidate-verifier"}), timeout=120
        ) as response:
            save_and_verify(response)
    except OSError as error:
        raise FastPathVerificationError(f"не удалось скачать CI artifact: {error}") from error


def _extract_candidate(archive_path: Path, destination: Path, artifact_name: str) -> None:
    destination.mkdir(parents=True)
    try:
        with zipfile.ZipFile(archive_path) as archive:
            files: list[tuple[zipfile.ZipInfo, PurePosixPath]] = []
            prefixes: set[str] = set()
            for info in archive.infolist():
                if info.is_dir():
                    continue
                raw = info.filename
                path = PurePosixPath(raw)
                if "\\" in raw or path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
                    raise FastPathVerificationError("CI artifact содержит небезопасный путь")
                mode = info.external_attr >> 16
                if stat.S_ISLNK(mode):
                    raise FastPathVerificationError("CI artifact содержит символическую ссылку")
                if len(path.parts) == 2 and path.parts[0] == artifact_name:
                    prefixes.add(path.parts[0])
                    path = PurePosixPath(path.parts[1])
                elif len(path.parts) != 1:
                    raise FastPathVerificationError("CI artifact имеет неожиданный уровень каталогов")
                files.append((info, path))
            if len(prefixes) > 1 or not files:
                raise FastPathVerificationError("CI artifact имеет некорректное дерево файлов")
            names: set[str] = set()
            for info, path in files:
                if path.name in names:
                    raise FastPathVerificationError("CI artifact содержит повторное имя файла")
                names.add(path.name)
                with archive.open(info) as source, (destination / path.name).open("wb") as output:
                    shutil.copyfileobj(source, output)
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        if isinstance(error, FastPathVerificationError):
            raise
        raise FastPathVerificationError(f"CI artifact не является корректным ZIP: {error}") from error


def fetch_and_prepare(args: argparse.Namespace) -> tuple[int, float]:
    started = time.perf_counter()
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        raise FastPathVerificationError("GH_TOKEN отсутствует; release job требует actions: read")
    repository = args.repository
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise FastPathVerificationError("GITHUB_REPOSITORY имеет неверный формат")
    base = f"{API_ROOT}/repos/{repository}/actions"
    run_url = f"{base}/runs/{args.run_id}"
    run, _ = _api_json(run_url, token)
    jobs = _api_pages(f"{base}/runs/{args.run_id}/jobs?per_page=100", token)
    verify_ci_run(run, jobs, args.source_sha, args.run_id, repository)
    artifacts = _api_pages(f"{base}/runs/{args.run_id}/artifacts?per_page=100", token)
    candidates = [item for item in artifacts if item.get("name") == ARTIFACT_PREFIX + args.source_sha]
    if not candidates:
        raise CandidateNotReusable("точный push-CI не сохранил unsigned OpenWrt candidate artifact")
    if len(candidates) != 1:
        raise FastPathVerificationError("точный CI run содержит несколько одноимённых candidate artifacts")
    artifact = verify_artifact_record(candidates[0], args.run_id, args.source_sha)

    baseline = _read_json(args.baseline, "production baseline")
    _verify_baseline_signature(args.baseline, args.baseline_signature, args.release_keys_dir)

    with tempfile.TemporaryDirectory(prefix="z2kow-ci-candidate-") as temp_name:
        temp = Path(temp_name)
        archive_path = temp / "candidate.zip"
        extracted = temp / "candidate"
        _download_verified_zip(artifact, token, archive_path)
        _extract_candidate(archive_path, extracted, str(artifact["name"]))
        try:
            verify_candidate_directory(
                extracted,
                args.baseline,
                args.baseline_signature,
                args.source_sha,
                args.tag,
                args.seq,
            )
        except CandidateNotReusable:
            raise
        prepare_release_candidate(
            extracted,
            args.output,
            args.baseline,
            args.baseline_signature,
            args.source_sha,
            args.run_id,
            int(artifact["id"]),
            str(artifact["digest"]),
            int(artifact["size_in_bytes"]),
            args.key_id,
        )
    elapsed = time.perf_counter() - started
    return int(artifact["size_in_bytes"]), elapsed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    fetch = commands.add_parser("fetch")
    fetch.add_argument("--repository", required=True)
    fetch.add_argument("--run-id", required=True, type=int)
    fetch.add_argument("--source-sha", required=True)
    fetch.add_argument("--tag", required=True)
    fetch.add_argument("--seq", required=True, type=int)
    fetch.add_argument("--key-id", required=True)
    fetch.add_argument("--baseline", required=True, type=Path)
    fetch.add_argument("--baseline-signature", required=True, type=Path)
    fetch.add_argument("--release-keys-dir", type=Path, default=Path("scripts/openwrt/release-keys"))
    fetch.add_argument("--output", required=True, type=Path)
    fetch.add_argument("--github-output", type=Path)
    verify = commands.add_parser("verify-final")
    verify.add_argument("--directory", required=True, type=Path)
    verify.add_argument("--source-sha", required=True)
    verify.add_argument("--key-id", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "verify-final":
            attestation = verify_final_candidate(args.directory, args.source_sha, release_key_id=args.key_id)
            print(
                "Проверена CI-приёмка release candidate: "
                f"source {attestation['source_sha']}, CI run {attestation['source_ci_run_id']}, "
                f"artifact {attestation['source_ci_artifact_digest']}"
            )
            return 0
        size, elapsed = fetch_and_prepare(args)
        print(f"Переиспользован проверенный CI candidate: {size} байт; проверка и подготовка заняли {elapsed:.2f} с")
        if args.github_output:
            with args.github_output.open("a", encoding="utf-8") as stream:
                stream.write(f"fast_path=true\nartifact_bytes={size}\nelapsed_seconds={elapsed:.3f}\n")
        return 0
    except CandidateNotReusable as error:
        print(f"Fast-path недоступен; используется полная проверенная сборка: {error}", file=sys.stderr)
        if args.github_output:
            with args.github_output.open("a", encoding="utf-8") as stream:
                stream.write("fast_path=false\n")
        return 3
    except (FastPathVerificationError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"::error::Проверка CI candidate отклонена: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
