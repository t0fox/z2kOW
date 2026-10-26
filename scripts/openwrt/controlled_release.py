#!/usr/bin/env python3
"""Build the controlled UPDATES.json and attach its rootfs transport checksum."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import tarfile
from pathlib import Path


TAG_RE = re.compile(r"(?:p-[0-9]+(?:\.[0-9]+)+|r-[0-9]+(?:\.[0-9]+)*)\Z")
ARTIFACT_NAME = "openwrt-rootfs.tar.gz"
ARCHITECTURES = ("arm64", "arm", "x86_64", "x86", "mips", "mipsel", "riscv64")
ARCHIVE_NAME_TEMPLATE = "openwrt-rootfs-{arch}.tar.gz"
RELEASE_BASE = "https://github.com/t0fox/z2kOW/releases/download"
TECHNICAL_RELEASE_TAG_RE = re.compile(r"openwrt-[0-9a-f]{40}\Z")
UPSTREAM_REPOSITORY = "necronicle/z2k"
UPSTREAM_BRANCH = "z2k-enhanced"
COMMIT_RE = re.compile(r"[0-9a-f]{40}\Z")
RELEASE_KEY_ID_RE = re.compile(r"[0-9a-f]{64}\Z")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def unpacked_size(path: Path) -> int:
    """Return the payload byte count without expanding the archive to disk."""
    try:
        with tarfile.open(path, "r:gz") as archive:
            return sum(member.size for member in archive.getmembers())
    except (OSError, tarfile.TarError) as error:
        raise ValueError(f"artifact is not a readable gzip tar archive: {path.name}") from error


def migration_fallback_required(production_manifest: dict[str, object]) -> bool:
    """Keep a full bundle while any checked published baseline offers one."""
    return "artifacts" not in production_manifest or "artifact" in production_manifest


def _validate_controlled_manifest(manifest: dict[str, object]) -> tuple[str, str]:
    if manifest.get("platform") != "openwrt":
        raise ValueError("controlled artifact can only be attached to an OpenWrt manifest")
    if manifest.get("schema") != 1 or manifest.get("branch") != "main":
        raise ValueError("controlled manifest must use schema 1 on main")
    tag = manifest.get("current")
    if not isinstance(tag, str) or not TAG_RE.fullmatch(tag):
        raise ValueError("manifest current tag is missing or malformed")
    seq = manifest.get("seq")
    if not isinstance(seq, int) or isinstance(seq, bool) or seq < 1:
        raise ValueError("manifest current sequence is missing or malformed")
    upstream = manifest.get("upstream")
    if not isinstance(upstream, dict):
        raise ValueError("controlled manifest upstream provenance is missing or malformed")
    if (
        upstream.get("repository") != UPSTREAM_REPOSITORY
        or upstream.get("branch") != UPSTREAM_BRANCH
        or upstream.get("tag") != tag
        or not isinstance(upstream.get("commit"), str)
        or not COMMIT_RE.fullmatch(upstream["commit"])
    ):
        raise ValueError("controlled manifest upstream provenance is missing or malformed")
    history = manifest.get("history")
    if (
        not isinstance(history, list)
        or not history
        or not all(isinstance(entry, dict) for entry in history)
        or history[-1].get("v") != tag
    ):
        raise ValueError("controlled release history must end at current tag")
    forbidden = {"adapter", "payload", "bundle", "components", "package_versions", "openwrt_release_artifact"}
    if forbidden.intersection(manifest):
        raise ValueError("secondary component release metadata is forbidden")
    return tag, str(manifest["seq"])


def _release_url(source_sha: str, filename: str) -> str:
    if not COMMIT_RE.fullmatch(source_sha):
        raise ValueError("source commit must be a full lowercase SHA")
    return f"{RELEASE_BASE}/openwrt-{source_sha}/{filename}"


def artifact_record(path: Path, filename: str, url: str, *, per_arch: bool) -> dict[str, object]:
    path = Path(path)
    if not path.is_file() or path.name != filename:
        raise ValueError(f"artifact must be an existing {filename} file")
    record: dict[str, object] = {
        "filename": filename,
        "url": url,
        "sha256": sha256(path),
        "size_bytes": path.stat().st_size,
    }
    if per_arch:
        record["unpacked_size_bytes"] = unpacked_size(path)
    return record


def validate_architecture_assets(
    manifest: dict[str, object], artifact_dir: Path, source_sha: str | None = None
) -> list[str]:
    """Verify every recorded archive against its exact local file and return release asset names."""
    records = manifest.get("artifacts")
    if not isinstance(records, dict) or set(records) != set(ARCHITECTURES):
        raise ValueError("manifest artifacts must contain exactly the seven supported architectures")
    artifact_dir = Path(artifact_dir)
    asset_names: list[str] = []
    seen_release_tags: set[str] = set()
    for arch in ARCHITECTURES:
        record = records[arch]
        filename = ARCHIVE_NAME_TEMPLATE.format(arch=arch)
        if not isinstance(record, dict) or set(record) != {
            "filename", "url", "sha256", "size_bytes", "unpacked_size_bytes"
        }:
            raise ValueError(f"artifact record for {arch} is malformed")
        if record.get("filename") != filename:
            raise ValueError(f"artifact filename for {arch} is not canonical")
        url = record.get("url")
        prefix = f"{RELEASE_BASE}/"
        suffix = f"/{filename}"
        if not isinstance(url, str) or not url.startswith(prefix) or not url.endswith(suffix):
            raise ValueError(f"artifact URL for {arch} is not a controlled immutable release URL")
        release_tag = url[len(prefix):-len(suffix)]
        if not TECHNICAL_RELEASE_TAG_RE.fullmatch(release_tag) or url != f"{prefix}{release_tag}{suffix}":
            raise ValueError(f"artifact URL for {arch} is not canonical")
        if source_sha is not None and release_tag != f"openwrt-{source_sha}":
            raise ValueError(f"artifact URL for {arch} is not bound to its exact source commit")
        seen_release_tags.add(release_tag)
        if not isinstance(record.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", record["sha256"]):
            raise ValueError(f"artifact SHA-256 for {arch} is malformed")
        for field in ("size_bytes", "unpacked_size_bytes"):
            value = record.get(field)
            if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
                raise ValueError(f"artifact {field} for {arch} is malformed")
        path = artifact_dir / filename
        expected = artifact_record(path, filename, url, per_arch=True)
        if expected != record:
            raise ValueError(f"artifact size, SHA-256, or unpacked size for {arch} does not match")
        asset_names.append(filename)
    if len(seen_release_tags) != 1:
        raise ValueError("architecture artifacts must refer to one immutable technical release")

    legacy = manifest.get("artifact")
    if legacy is not None:
        if not isinstance(legacy, dict) or set(legacy) != {"filename", "url", "sha256", "size_bytes"}:
            raise ValueError("legacy fallback artifact record is malformed")
        legacy_url = legacy.get("url")
        if not isinstance(legacy_url, str) or not legacy_url.endswith(f"/{ARTIFACT_NAME}"):
            raise ValueError("legacy fallback URL is malformed")
        legacy_tag = legacy_url[:-len(f"/{ARTIFACT_NAME}")].rsplit("/", 1)[-1]
        if not TECHNICAL_RELEASE_TAG_RE.fullmatch(legacy_tag) or legacy_url != f"{RELEASE_BASE}/{legacy_tag}/{ARTIFACT_NAME}":
            raise ValueError("legacy fallback URL is not canonical")
        if source_sha is not None and legacy_tag != f"openwrt-{source_sha}":
            raise ValueError("legacy fallback URL is not bound to its exact source commit")
        expected = artifact_record(artifact_dir / ARTIFACT_NAME, ARTIFACT_NAME, legacy_url, per_arch=False)
        if expected != legacy:
            raise ValueError("legacy fallback size or SHA-256 does not match")
        asset_names.append(ARTIFACT_NAME)

    expected_names = set(asset_names)
    present_names = {
        path.name for path in artifact_dir.iterdir()
        if path.is_file() and (path.name == ARTIFACT_NAME or path.name.startswith("openwrt-rootfs-"))
    }
    if present_names != expected_names:
        raise ValueError("candidate directory has missing or extra rootfs archive assets")
    return asset_names


def controlled_from_upstream(upstream: dict[str, object], commit: str) -> dict[str, object]:
    """Adapt one live upstream release manifest into the sole OpenWrt authority."""
    if upstream.get("branch") != UPSTREAM_BRANCH:
        raise ValueError("манифест должен происходить из официальной ветки upstream z2k-enhanced")
    if not COMMIT_RE.fullmatch(commit):
        raise ValueError("upstream commit must be a full 40-character SHA")
    tag = upstream.get("current")
    seq = upstream.get("seq")
    history = upstream.get("history")
    if not isinstance(tag, str) or not TAG_RE.fullmatch(tag):
        raise ValueError("upstream current tag is missing or malformed")
    if not isinstance(seq, int) or isinstance(seq, bool) or seq < 1:
        raise ValueError("upstream current sequence is missing or malformed")
    if (
        not isinstance(history, list)
        or not history
        or not all(isinstance(entry, dict) for entry in history)
        or history[-1].get("v") != tag
    ):
        raise ValueError("upstream release history must end at current tag")
    # Keep the upstream release records byte-for-byte in meaning. Upstream
    # does not assign a seq to each history item; seq belongs to current.
    return {
        "schema": 1,
        "branch": "main",
        "platform": "openwrt",
        "seq": seq,
        "current": tag,
        "upstream": {
            "repository": UPSTREAM_REPOSITORY,
            "branch": UPSTREAM_BRANCH,
            "tag": tag,
            "commit": commit,
        },
        "history": [dict(entry) for entry in history],
    }


def _validated_skip_records(
    upstream: dict[str, object], skip_registry: dict[str, object] | None
) -> list[dict[str, object]]:
    if skip_registry is None:
        return []
    if set(skip_registry) != {"schema", "skips"}:
        raise ValueError("реестр пропусков upstream содержит неизвестные поля")
    schema = skip_registry.get("schema")
    records = skip_registry.get("skips")
    if not isinstance(schema, int) or isinstance(schema, bool) or schema != 1:
        raise ValueError("версия схемы реестра пропусков upstream не поддерживается")
    if not isinstance(records, list):
        raise ValueError("список пропусков upstream повреждён")
    latest_seq = upstream.get("seq")
    history = upstream.get("history")
    if (
        not isinstance(latest_seq, int)
        or isinstance(latest_seq, bool)
        or latest_seq < 1
        or not isinstance(history, list)
        or not all(isinstance(entry, dict) for entry in history)
    ):
        raise ValueError("актуальный манифест upstream не позволяет проверить реестр пропусков")
    history_tags = {
        entry.get("v") for entry in history if isinstance(entry.get("v"), str)
    }
    skips: list[dict[str, object]] = []
    seen_tags: set[str] = set()
    seen_seqs: set[int] = set()
    for record in records:
        if not isinstance(record, dict) or set(record) != {"tag", "seq", "status", "reason"}:
            raise ValueError("запись реестра пропусков upstream повреждена")
        tag = record.get("tag")
        seq = record.get("seq")
        status = record.get("status")
        reason = record.get("reason")
        if not isinstance(tag, str) or not TAG_RE.fullmatch(tag):
            raise ValueError("тег в реестре пропусков upstream повреждён")
        if not isinstance(seq, int) or isinstance(seq, bool) or seq < 1 or seq > latest_seq:
            raise ValueError("seq в реестре пропусков upstream не подтверждён текущим манифестом")
        if status != "not applicable" or not isinstance(reason, str) or not reason.strip():
            raise ValueError("пропуск upstream должен иметь статус not applicable и причину")
        if tag not in history_tags:
            raise ValueError(f"пропущенный выпуск {tag} отсутствует в актуальной истории upstream")
        if tag in seen_tags or seq in seen_seqs:
            raise ValueError("реестр пропусков upstream содержит повторный тег или seq")
        seen_tags.add(tag)
        seen_seqs.add(seq)
        skips.append({"tag": tag, "seq": seq, "status": status, "reason": reason.strip()})
    return skips


def verify_upstream_tag(
    upstream: dict[str, object],
    pinned: dict[str, object],
    refs_text: str,
    tag: str,
    seq: int,
    skip_registry: dict[str, object] | None = None,
) -> str:
    """Проверить манифесты и точный Git-тег официального выпуска."""
    if not isinstance(tag, str) or not TAG_RE.fullmatch(tag):
        raise ValueError("запрошен некорректный тег upstream")
    if not isinstance(seq, int) or isinstance(seq, bool) or seq < 1:
        raise ValueError("запрошен некорректный номер upstream seq")

    if upstream.get("branch") != UPSTREAM_BRANCH or pinned.get("branch") != UPSTREAM_BRANCH:
        raise ValueError("манифест не принадлежит ветке upstream z2k-enhanced")
    live_tag = upstream.get("current")
    live_seq = upstream.get("seq")
    live_history = upstream.get("history")
    if (
        not isinstance(live_tag, str)
        or not TAG_RE.fullmatch(live_tag)
        or not isinstance(live_seq, int)
        or isinstance(live_seq, bool)
        or live_seq < seq
        or not isinstance(live_history, list)
        or not live_history
        or not all(isinstance(entry, dict) for entry in live_history)
        or live_history[-1].get("v") != live_tag
    ):
        raise ValueError("текущая история upstream повреждена или отстала от проверяемого выпуска")
    pinned_history = pinned.get("history")
    if (
        pinned.get("current") != tag
        or not isinstance(pinned.get("seq"), int)
        or isinstance(pinned.get("seq"), bool)
        or pinned.get("seq") != seq
        or not isinstance(pinned_history, list)
        or not pinned_history
        or not all(isinstance(entry, dict) for entry in pinned_history)
        or pinned_history[-1].get("v") != tag
    ):
        raise ValueError("закреплённый Git-тег: current/seq не совпадают с проверяемым выпуском")

    target_indexes = [
        index for index, entry in enumerate(live_history) if entry.get("v") == tag
    ]
    if len(target_indexes) != 1:
        raise ValueError("проверяемый выпуск отсутствует или повторяется в истории upstream")
    target_index = target_indexes[0]
    newer_entries = live_history[target_index + 1 :]
    if live_seq - seq != len(newer_entries):
        raise ValueError("между проверяемым выпуском и live upstream есть неучтённые версии")
    skips = _validated_skip_records(upstream, skip_registry)
    skips_by_tag = {entry["tag"]: entry for entry in skips}
    for offset, entry in enumerate(newer_entries, start=1):
        newer_tag = entry.get("v")
        newer_seq = seq + offset
        if not isinstance(newer_tag, str) or not TAG_RE.fullmatch(newer_tag):
            raise ValueError("в актуальной истории upstream найден некорректный тег")
        skip = skips_by_tag.get(newer_tag)
        if (
            skip is None
            or skip.get("seq") != newer_seq
            or skip.get("status") != "not applicable"
        ):
            raise ValueError(
                f"после {tag} найден применимый или неучтённый выпуск upstream "
                f"{newer_tag} (seq {newer_seq})"
            )
    if any(entry["tag"] == tag or entry["seq"] == seq for entry in skips):
        raise ValueError("целевой выпуск upstream отмечен неприменимым")

    refs: dict[str, list[str]] = {}
    for line in refs_text.splitlines():
        parts = line.split()
        if len(parts) != 2 or not COMMIT_RE.fullmatch(parts[0]):
            raise ValueError("список Git-ссылок upstream повреждён")
        refs.setdefault(parts[1], []).append(parts[0])

    branch_refs = refs.get(f"refs/heads/{UPSTREAM_BRANCH}", [])
    tag_ref = f"refs/tags/{tag}"
    direct_refs = refs.get(tag_ref, [])
    peeled_refs = refs.get(f"{tag_ref}^{{}}", [])
    if len(branch_refs) != 1:
        raise ValueError("не удалось однозначно проверить официальную ветку upstream")
    if len(direct_refs) != 1 or len(peeled_refs) > 1:
        raise ValueError("проверенный Git-тег upstream отсутствует или неоднозначен")
    return peeled_refs[0] if peeled_refs else direct_refs[0]


def compare_upstream(
    upstream: dict[str, object],
    controlled: dict[str, object],
    commit: str,
    skip_registry: dict[str, object] | None = None,
) -> dict[str, object]:
    """Сопоставить upstream-релиз с выпуском OpenWrt и учесть отмеченные пропуски."""
    latest = controlled_from_upstream(upstream, commit)
    approved_seq = controlled.get("seq")
    if not isinstance(approved_seq, int) or isinstance(approved_seq, bool) or approved_seq < 1:
        raise ValueError("controlled current sequence is missing or malformed")
    latest_seq = latest["seq"]
    if latest_seq < approved_seq:
        raise ValueError("upstream sequence moved backwards")
    approved_tag = controlled.get("current")
    latest_tag = latest["current"]
    if latest_seq == approved_seq and latest_tag != approved_tag:
        raise ValueError("upstream current tag changed without a sequence advance")

    skips = _validated_skip_records(upstream, skip_registry)

    accounted_seq = max([approved_seq, *(entry["seq"] for entry in skips)])
    not_applicable = [entry for entry in skips if entry["seq"] > approved_seq]
    approved_provenance = controlled.get("upstream")
    approved_commit = approved_provenance.get("commit") if isinstance(approved_provenance, dict) else None
    return {
        "latest_tag": latest_tag,
        "latest_seq": latest_seq,
        "latest_commit": commit,
        "approved_tag": approved_tag,
        "approved_seq": approved_seq,
        "accounted_seq": accounted_seq,
        "source_changed": commit != approved_commit,
        "not_applicable": not_applicable,
        "update_available": latest_seq > accounted_seq,
    }


def attach_rootfs_artifact(
    manifest: dict[str, object], artifact: Path, url: str | None = None
) -> None:
    _validate_controlled_manifest(manifest)
    if not isinstance(url, str):
        raise ValueError("a technical release URL is required when attaching the artifact")
    expected_prefix = f"{RELEASE_BASE}/"
    suffix = f"/{ARTIFACT_NAME}"
    if not url.startswith(expected_prefix) or not url.endswith(suffix):
        raise ValueError("artifact URL must point to a controlled immutable OpenWrt release")
    release_tag = url[len(expected_prefix) : -len(suffix)]
    if not TECHNICAL_RELEASE_TAG_RE.fullmatch(release_tag):
        raise ValueError("artifact URL must point to a controlled immutable OpenWrt release")
    expected_url = f"{expected_prefix}{release_tag}{suffix}"
    if url != expected_url:
        raise ValueError("artifact URL must point to a controlled immutable OpenWrt release")
    artifact = Path(artifact)
    if not artifact.is_file() or artifact.name != ARTIFACT_NAME:
        raise ValueError(f"artifact must be an existing {ARTIFACT_NAME} file")
    record = {
        "filename": ARTIFACT_NAME,
        "url": expected_url,
        "sha256": sha256(artifact),
        "size_bytes": artifact.stat().st_size,
    }
    previous = manifest.get("artifact")
    if previous is not None and previous != record:
        raise ValueError("manifest already contains a different OpenWrt release artifact")
    manifest["artifact"] = record


def attach_architecture_artifacts(
    manifest: dict[str, object],
    artifact_dir: Path,
    source_sha: str,
    production_baseline: dict[str, object],
    key_id: str | None = None,
) -> bool:
    """Attach seven verified target bundles and the migration-only full archive."""
    _validate_controlled_manifest(manifest)
    include_legacy = migration_fallback_required(production_baseline)
    artifact_dir = Path(artifact_dir)
    manifest.pop("artifact", None)
    manifest.pop("artifacts", None)
    manifest.pop("signing", None)
    records: dict[str, dict[str, object]] = {}
    for arch in ARCHITECTURES:
        filename = ARCHIVE_NAME_TEMPLATE.format(arch=arch)
        records[arch] = artifact_record(
            artifact_dir / filename, filename, _release_url(source_sha, filename), per_arch=True
        )
    manifest["artifacts"] = records
    if include_legacy:
        manifest["artifact"] = artifact_record(
            artifact_dir / ARTIFACT_NAME, ARTIFACT_NAME, _release_url(source_sha, ARTIFACT_NAME), per_arch=False
        )
    if key_id is not None:
        if not RELEASE_KEY_ID_RE.fullmatch(key_id):
            raise ValueError("signing key id must be a lowercase SHA-256 fingerprint")
        manifest["signing"] = {"key_id": key_id}
    validate_architecture_assets(manifest, artifact_dir, source_sha)
    return include_legacy


def attach_architecture_file(
    manifest_path: Path,
    artifact_dir: Path,
    source_sha: str,
    production_baseline_path: Path,
    key_id: str | None = None,
) -> bool:
    manifest = read_json_object(manifest_path, "controlled manifest")
    production_baseline = read_json_object(production_baseline_path, "checked production baseline")
    include_legacy = attach_architecture_artifacts(
        manifest, artifact_dir, source_sha, production_baseline, key_id
    )
    write_manifest(manifest_path, manifest)
    return include_legacy


def render_manifest(manifest: dict[str, object]) -> str:
    """Serialize while preserving one-line history objects for shell readers."""
    lines = ["{"]
    keys = list(manifest)
    for index, key in enumerate(keys):
        comma = "," if index < len(keys) - 1 else ""
        if key == "history":
            entries = manifest[key]
            if not isinstance(entries, list):
                raise ValueError("controlled release history must be a list")
            lines.append('  "history": [')
            lines.extend(
                "    " + json.dumps(entry, ensure_ascii=False) + ("," if entry_index < len(entries) - 1 else "")
                for entry_index, entry in enumerate(entries)
            )
            lines.append("  ]" + comma)
            continue
        value_lines = json.dumps(manifest[key], indent=2, ensure_ascii=False).splitlines()
        lines.append(f"  {json.dumps(key, ensure_ascii=False)}: {value_lines[0]}")
        lines.extend("  " + value_line for value_line in value_lines[1:-1])
        if len(value_lines) > 1:
            lines.append("  " + value_lines[-1] + comma)
        else:
            lines[-1] += comma
    return "\n".join(lines) + "\n}\n"


def attach_file(
    manifest_path: Path,
    artifact_path: Path,
    url: str | None = None,
    key_id: str | None = None,
) -> None:
    manifest_path = Path(manifest_path)
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read controlled manifest: {error}") from error
    if not isinstance(manifest, dict):
        raise ValueError("controlled manifest root must be an object")
    attach_rootfs_artifact(manifest, artifact_path, url)
    manifest.pop("signing", None)
    if key_id is not None:
        if not RELEASE_KEY_ID_RE.fullmatch(key_id):
            raise ValueError("signing key id must be a lowercase SHA-256 fingerprint")
        manifest["signing"] = {"key_id": key_id}
    encoded = render_manifest(manifest)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", newline="\n", dir=manifest_path.parent,
            prefix=manifest_path.name + ".", suffix=".tmp", delete=False,
        ) as stream:
            temporary = stream.name
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, manifest_path)
        temporary = None
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def read_json_object(path: Path, description: str) -> dict[str, object]:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {description}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{description} root must be an object")
    return value


def write_manifest(path: Path, manifest: dict[str, object]) -> None:
    path = Path(path)
    encoded = render_manifest(manifest)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", newline="\n", dir=path.parent,
            prefix=path.name + ".", suffix=".tmp", delete=False,
        ) as stream:
            temporary = stream.name
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def copy_unsigned_candidate_manifest(source: Path, destination: Path) -> None:
    """Copy the controlled release metadata for a build candidate, without its published artifact."""
    source = Path(source)
    destination = Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError("candidate manifest must be separate from the controlled source manifest")
    manifest = read_json_object(source, "controlled manifest")
    manifest.pop("artifact", None)
    manifest.pop("artifacts", None)
    manifest.pop("signing", None)
    write_manifest(destination, manifest)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    attach = subparsers.add_parser("attach")
    attach.add_argument("--manifest", required=True, type=Path)
    attach.add_argument("--artifact", type=Path, help="legacy single archive compatibility")
    attach.add_argument("--artifact-dir", type=Path)
    attach.add_argument("--source-sha")
    attach.add_argument("--production-baseline", type=Path)
    attach.add_argument("--url")
    attach.add_argument("--key-id")
    sync = subparsers.add_parser("sync")
    sync.add_argument("--upstream", required=True, type=Path)
    sync.add_argument("--commit", required=True)
    sync.add_argument("--output", required=True, type=Path)
    check = subparsers.add_parser("check-upstream")
    check.add_argument("--upstream", required=True, type=Path)
    check.add_argument("--commit", required=True)
    check.add_argument("--controlled", required=True, type=Path)
    check.add_argument("--skip-registry", required=True, type=Path)
    verify_tag = subparsers.add_parser("verify-upstream-tag")
    verify_tag.add_argument("--upstream", required=True, type=Path)
    verify_tag.add_argument("--pinned", required=True, type=Path)
    verify_tag.add_argument("--refs", required=True, type=Path)
    verify_tag.add_argument("--tag", required=True)
    verify_tag.add_argument("--seq", required=True, type=int)
    verify_tag.add_argument("--skip-registry", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "attach":
            if args.artifact_dir is not None:
                if args.artifact is not None or args.url is not None or args.source_sha is None or args.production_baseline is None:
                    raise ValueError("per-architecture attach requires --artifact-dir, --source-sha, and --production-baseline")
                include_legacy = attach_architecture_file(
                    args.manifest, args.artifact_dir, args.source_sha, args.production_baseline, args.key_id
                )
                print(f"attached seven architecture assets; legacy fallback: {'yes' if include_legacy else 'no'}")
            else:
                if args.artifact is None or args.url is None:
                    raise ValueError("legacy attach requires --artifact and --url")
                attach_file(args.manifest, args.artifact, args.url, args.key_id)
        elif args.command == "sync":
            upstream = read_json_object(args.upstream, "upstream manifest")
            write_manifest(args.output, controlled_from_upstream(upstream, args.commit))
        elif args.command == "verify-upstream-tag":
            upstream = read_json_object(args.upstream, "live upstream manifest")
            pinned = read_json_object(args.pinned, "tag-pinned upstream manifest")
            refs = args.refs.read_text(encoding="utf-8")
            skip_registry = (
                read_json_object(args.skip_registry, "реестр пропусков upstream")
                if args.skip_registry is not None
                else None
            )
            print(verify_upstream_tag(upstream, pinned, refs, args.tag, args.seq, skip_registry))
        else:
            upstream = read_json_object(args.upstream, "upstream manifest")
            controlled = read_json_object(args.controlled, "controlled manifest")
            skip_registry = read_json_object(args.skip_registry, "реестр пропусков upstream")
            result = compare_upstream(upstream, controlled, args.commit, skip_registry)
            print(json.dumps(result, sort_keys=True))
            if result["update_available"]:
                print(
                    f"новый применимый upstream-выпуск {result['latest_tag']} "
                    f"(seq {result['latest_seq']}); учёт синхронизации до seq {result['accounted_seq']}",
                    file=sys.stderr,
                )
                return 3
            if result["not_applicable"]:
                skipped = max(result["not_applicable"], key=lambda entry: entry["seq"])
                print(
                    f"upstream-выпуск {skipped['tag']} (seq {skipped['seq']}) отмечен как неприменимый; "
                    f"учёт синхронизации до seq {result['accounted_seq']}"
                )
            else:
                print(f"новых применимых upstream-выпусков нет; учёт до seq {result['accounted_seq']}")
    except (OSError, ValueError) as error:
        print(f"выпуск z2kOW: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
