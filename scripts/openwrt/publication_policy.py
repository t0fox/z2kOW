#!/usr/bin/env python3
"""Validate OpenWrt publication operations and generate release notes."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


PRODUCT_TAG_RE = re.compile(r"[pr]-[0-9]+(?:\.[0-9]+)+\Z")
SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
TECHNICAL_TAG_RE = re.compile(r"openwrt-([0-9a-f]{40})\Z")
RELEASE_BASE = "https://github.com/t0fox/z2kOW/releases/download"
ARTIFACT_NAME = "openwrt-rootfs.tar.gz"
INTERNAL_ONLY_MESSAGE = "Внутренние изменения механизма выпуска и проверки обновлений. Пользовательское поведение не изменилось."
INTERNAL_RELEASE_PATHS = {
    "scripts/openwrt/audit-upstream-docs.sh",
    "scripts/openwrt/changelog-release.py",
    "scripts/openwrt/check_immutable_releases.py",
    "scripts/openwrt/controlled_release.py",
    "scripts/openwrt/publication_policy.py",
    "scripts/openwrt/publish_release.sh",
    "scripts/openwrt/sign_release.py",
}


def _version(tag: object, seq: object, label: str) -> tuple[str, int]:
    if not isinstance(tag, str) or not PRODUCT_TAG_RE.fullmatch(tag):
        raise ValueError(f"{label} tag is missing or malformed")
    if not isinstance(seq, int) or isinstance(seq, bool) or seq < 1:
        raise ValueError(f"{label} sequence is missing or malformed")
    return tag, seq


def previous_payload_source_sha(manifest: dict[str, Any]) -> str:
    artifact = manifest.get("artifact")
    url = artifact.get("url") if isinstance(artifact, dict) else None
    prefix = f"{RELEASE_BASE}/"
    suffix = f"/{ARTIFACT_NAME}"
    if not isinstance(url, str) or not url.startswith(prefix) or not url.endswith(suffix):
        raise ValueError("production artifact URL is not a controlled OpenWrt technical release")
    tag = url[len(prefix) : -len(suffix)]
    match = TECHNICAL_TAG_RE.fullmatch(tag)
    if not match:
        raise ValueError("production artifact URL must use openwrt-<full-source-sha>")
    expected = f"{prefix}{tag}{suffix}"
    if url != expected:
        raise ValueError("production artifact URL is not canonical")
    return match.group(1)


def technical_release_tag(source_sha: str) -> str:
    if not isinstance(source_sha, str) or not SHA_RE.fullmatch(source_sha):
        raise ValueError("source commit must be a full lowercase SHA")
    return f"openwrt-{source_sha}"


def technical_release_title(source_sha: str) -> str:
    technical_release_tag(source_sha)
    return f"OpenWrt payload {source_sha[:7]}"


def plan_publication(
    *,
    operation: str,
    requested_tag: str,
    requested_seq: int,
    source_sha: str,
    upstream: dict[str, Any],
    controlled: dict[str, Any],
    upstream_commit: str,
    existing_product_release: bool = False,
    existing_technical_release: bool = False,
) -> dict[str, Any]:
    if operation not in {"upstream-release", "hotfix"}:
        raise ValueError("operation must be upstream-release or hotfix")
    if not isinstance(source_sha, str) or not SHA_RE.fullmatch(source_sha):
        raise ValueError("source commit must be a full lowercase SHA")
    if not isinstance(upstream_commit, str) or not SHA_RE.fullmatch(upstream_commit):
        raise ValueError("upstream tag commit must be a full lowercase SHA")

    upstream_tag, upstream_seq = _version(upstream.get("current"), upstream.get("seq"), "upstream")
    controlled_tag, controlled_seq = _version(controlled.get("current"), controlled.get("seq"), "controlled")
    requested_tag, requested_seq = _version(requested_tag, requested_seq, "requested")
    if (requested_tag, requested_seq) != (upstream_tag, upstream_seq):
        raise ValueError("requested tag/seq do not match the live upstream current release")

    history = upstream.get("history")
    if not isinstance(history, list) or not history or not isinstance(history[-1], dict) or history[-1].get("v") != upstream_tag:
        raise ValueError("upstream release history must end at current tag")
    previous_sha = previous_payload_source_sha(controlled)

    if operation == "upstream-release":
        if upstream_tag == controlled_tag and upstream_seq == controlled_seq:
            raise ValueError(
                f"{upstream_tag} / seq {upstream_seq} уже опубликован как пользовательская версия. "
                "Для downstream-исправлений используйте hotfix publication."
            )
        if upstream_seq < controlled_seq:
            raise ValueError("upstream sequence moved backwards")
        if upstream_seq == controlled_seq:
            raise ValueError("upstream current tag changed without a sequence advance")
        if upstream_tag == controlled_tag:
            raise ValueError("upstream tag did not change with the sequence advance")
        if existing_product_release:
            raise ValueError(f"Product Release {upstream_tag} already exists; refusing duplicate publication")
        if existing_technical_release:
            raise ValueError(f"technical release already exists for source SHA {source_sha}; use retry-publish")
        product_tag: str | None = upstream_tag
    else:
        if (upstream_tag, upstream_seq) != (controlled_tag, controlled_seq):
            if upstream_seq > controlled_seq:
                raise ValueError(
                    f"Upstream version advanced to {upstream_tag}. "
                    "Требуется новый Product Release, а не hotfix старой версии."
                )
            if upstream_seq < controlled_seq:
                raise ValueError("upstream sequence moved backwards; hotfix is refused")
            raise ValueError("upstream current tag changed without a sequence advance; hotfix is refused")
        if (requested_tag, requested_seq) != (controlled_tag, controlled_seq):
            raise ValueError("hotfix must preserve the currently published product tag and sequence")
        if existing_technical_release or source_sha == previous_sha:
            raise ValueError(f"technical release already exists for source SHA {source_sha}; use retry-publish")
        product_tag = None

    return {
        "schema": 1,
        "operation": operation,
        "tag": upstream_tag,
        "seq": upstream_seq,
        "source_sha": source_sha,
        "technical_tag": technical_release_tag(source_sha),
        "technical_title": technical_release_title(source_sha),
        "product_tag": product_tag,
        "upstream_commit": upstream_commit,
        "base_current": controlled_tag,
        "base_seq": controlled_seq,
        "base_payload_sha": previous_sha,
    }


def validate_candidate_metadata(
    candidate: dict[str, Any], *, source_sha: str, requested_tag: str, requested_seq: int
) -> dict[str, Any]:
    if candidate.get("schema") != 1:
        raise ValueError("candidate metadata schema is missing or unsupported")
    operation = candidate.get("operation")
    if operation not in {"upstream-release", "hotfix"}:
        raise ValueError("candidate operation must be upstream-release or hotfix")
    tag, seq = _version(candidate.get("tag"), candidate.get("seq"), "candidate")
    if (tag, seq) != (requested_tag, requested_seq):
        raise ValueError("requested tag/seq do not match the verified candidate")
    candidate_sha = candidate.get("source_sha")
    if candidate_sha != source_sha or not isinstance(candidate_sha, str) or not SHA_RE.fullmatch(candidate_sha):
        raise ValueError("candidate source SHA does not match its trusted workflow run")
    if candidate.get("technical_tag") != technical_release_tag(candidate_sha):
        raise ValueError("candidate technical tag is not bound to its exact source SHA")
    if candidate.get("technical_title") != technical_release_title(candidate_sha):
        raise ValueError("candidate technical title is malformed")
    product_tag = candidate.get("product_tag")
    if operation == "upstream-release" and product_tag != tag:
        raise ValueError("upstream-release candidate must carry exactly one matching Product Release tag")
    if operation == "hotfix" and product_tag is not None:
        raise ValueError("hotfix candidate must not create a Product Release")
    base_tag, base_seq = _version(candidate.get("base_current"), candidate.get("base_seq"), "candidate base")
    if operation == "hotfix" and (tag, seq) != (base_tag, base_seq):
        raise ValueError("hotfix candidate must preserve the base product tag and sequence")
    if operation == "upstream-release" and (seq <= base_seq or tag == base_tag):
        raise ValueError("upstream-release candidate must advance the product tag and sequence")
    base_sha = candidate.get("base_payload_sha")
    if not isinstance(base_sha, str) or not SHA_RE.fullmatch(base_sha):
        raise ValueError("candidate base payload SHA is missing or malformed")
    upstream_commit = candidate.get("upstream_commit")
    if not isinstance(upstream_commit, str) or not SHA_RE.fullmatch(upstream_commit):
        raise ValueError("candidate upstream tag commit is malformed")
    return candidate


def production_manifest_state(manifest: dict[str, Any], candidate: dict[str, Any]) -> str:
    """Return baseline/published; reject any manifest state that can supersede this candidate."""
    required = ("base_current", "base_seq", "base_payload_sha", "tag", "seq", "source_sha")
    if any(key not in candidate for key in required):
        raise ValueError("candidate metadata is incomplete for production manifest comparison")
    current, seq = _version(manifest.get("current"), manifest.get("seq"), "production")
    current_payload = previous_payload_source_sha(manifest)
    if (current, seq, current_payload) == (
        candidate["base_current"], candidate["base_seq"], candidate["base_payload_sha"]
    ):
        return "baseline"
    if (current, seq, current_payload) == (
        candidate["tag"], candidate["seq"], candidate["source_sha"]
    ):
        return "published"
    raise ValueError("production manifest advanced beyond the candidate baseline; refusing stale publication")


def _is_internal_path(path: str) -> bool:
    normalized = path.replace("\\", "/")
    return (
        normalized.startswith((".github/", "tests/", "docs/"))
        or normalized in INTERNAL_RELEASE_PATHS
        or normalized in {"UPDATES.json", "UPDATES.json.sig", "README.md", "CHANGELOG.md"}
    )


def _category(path: str) -> str | None:
    normalized = path.replace("\\", "/")
    if _is_internal_path(normalized):
        return None
    if normalized.startswith("webpanel/"):
        return "Обновлена веб-панель управления."
    if normalized.startswith("files/lists/"):
        return "Обновлены сетевые списки."
    if normalized.startswith(("files/ndm/", "platform/openwrt/")):
        return "Обновлена интеграция z2kOW с OpenWrt."
    if normalized.startswith(("lib/", "lua/", "files/lua/")) or normalized.startswith(("files/z2k-", "files/S")):
        return "Обновлена логика z2k и конфигурация обработки трафика."
    if normalized.startswith(("rt-proxy/", "z2k-detect/", "z2k-warpd/", "mtproxy-client/")):
        return "Обновлены сетевые компоненты OpenWrt."
    if normalized.startswith("scripts/openwrt/"):
        return "Обновлена интеграция z2kOW с OpenWrt."
    return "Изменён состав полного OpenWrt payload."


def _change_categories(paths: list[str]) -> list[str]:
    return sorted({category for path in paths if (category := _category(path)) is not None})


def _changed_paths(repository: Path, previous_sha: str, source_sha: str) -> list[str]:
    if not SHA_RE.fullmatch(previous_sha) or not SHA_RE.fullmatch(source_sha):
        raise ValueError("release-note range must use full lowercase source SHAs")
    result = subprocess.run(
        ["git", "diff", "--name-only", f"{previous_sha}..{source_sha}"],
        cwd=repository,
        check=True,
        capture_output=True,
        text=True,
    )
    return sorted({line.strip() for line in result.stdout.splitlines() if line.strip()})


def _russian_description(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    description = " ".join(value.split()).strip(" -•")
    return description if description and re.search(r"[А-Яа-яЁё]", description) else None


def hotfix_release_notes(repository: Path, controlled: dict[str, Any], source_sha: str) -> str:
    tag, seq = _version(controlled.get("current"), controlled.get("seq"), "controlled")
    previous_sha = previous_payload_source_sha(controlled)
    paths = _changed_paths(Path(repository), previous_sha, source_sha)
    changes = _change_categories(paths)
    if changes:
        change_text = "\n".join(f"- {item}" for item in changes)
    else:
        change_text = INTERNAL_ONLY_MESSAGE
    return (
        "# Техническое обновление OpenWrt\n\n"
        f"Актуальный payload z2kOW для версии {tag}.\n"
        "Пользовательская версия не меняется.\n\n"
        "## Изменения\n\n"
        f"{change_text}\n\n"
        f"Источник: `{source_sha}`\n\n"
        f"Upstream: `{tag} / seq {seq}`\n\n"
        f"Диапазон payload: `{previous_sha}..{source_sha}`\n"
    )


def product_release_notes(
    tag: str,
    seq: int,
    source_sha: str,
    upstream: dict[str, Any],
    controlled: dict[str, Any],
    repository: Path,
) -> str:
    _version(tag, seq, "product release")
    technical_release_tag(source_sha)
    history = upstream.get("history")
    if not isinstance(history, list) or not history or not isinstance(history[-1], dict) or history[-1].get("v") != tag:
        raise ValueError("upstream release history must end at the Product Release tag")
    previous_sha = previous_payload_source_sha(controlled)
    upstream_entry = history[-1]
    upstream_paths = upstream_entry.get("changed_files", [])
    if not isinstance(upstream_paths, list) or not all(isinstance(path, str) for path in upstream_paths):
        upstream_paths = []
    source_paths = _changed_paths(Path(repository), previous_sha, source_sha)
    upstream_changes = _change_categories(upstream_paths)
    source_changes = _change_categories(source_paths)
    description = _russian_description(upstream_entry.get("desc"))
    summary: list[str] = []
    if description:
        summary.append(description)
    for item in upstream_changes + source_changes:
        if item not in summary:
            summary.append(item)
    if not summary:
        summary.append("Пользовательское поведение не изменилось.")
    changes = "\n".join(f"- {item}" for item in summary)
    openwrt_note = "Адаптирован и собран полный OpenWrt payload."
    return (
        f"# z2kOW {tag}\n\n"
        f"Адаптация upstream z2k {tag} для OpenWrt.\n\n"
        f"## Что изменилось\n\n{changes}\n\n"
        f"## OpenWrt\n\n- {openwrt_note}\n\n"
        f"Основано на upstream:\n- версия: {tag}\n- seq: {seq}\n\n"
        f"Источник OpenWrt: `{source_sha}`\n"
    )


def _read_json(path: Path, description: str) -> dict[str, Any]:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {description}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{description} root must be an object")
    return value


def _write_json(path: Path, value: dict[str, Any]) -> None:
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _plan_command(args: argparse.Namespace) -> None:
    plan = plan_publication(
        operation=args.operation,
        requested_tag=args.tag,
        requested_seq=args.seq,
        source_sha=args.source_sha,
        upstream=_read_json(args.upstream, "upstream manifest"),
        controlled=_read_json(args.controlled, "production manifest"),
        upstream_commit=args.upstream_commit,
        existing_product_release=args.product_release_exists,
        existing_technical_release=args.technical_release_exists,
    )
    _write_json(args.output, plan)


def _notes_command(args: argparse.Namespace) -> None:
    candidate = _read_json(args.candidate, "candidate metadata")
    upstream = _read_json(args.upstream, "upstream manifest")
    controlled = _read_json(args.controlled, "production manifest")
    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)
    hotfix = hotfix_release_notes(Path(args.repository), controlled, candidate["source_sha"])
    (out / "technical-release-notes.md").write_text(hotfix, encoding="utf-8")
    if candidate.get("operation") == "upstream-release":
        product = product_release_notes(
            candidate["tag"], candidate["seq"], candidate["source_sha"], upstream, controlled, Path(args.repository)
        )
        (out / "product-release-notes.md").write_text(product, encoding="utf-8")


def _candidate_info_command(args: argparse.Namespace) -> None:
    requested_tag = args.tag or None
    requested_seq = args.seq
    if (requested_tag is None) != (requested_seq is None):
        raise ValueError("candidate tag and sequence must be provided together")
    raw_candidate = _read_json(args.candidate, "candidate metadata")
    candidate = validate_candidate_metadata(
        raw_candidate,
        source_sha=args.source_sha,
        requested_tag=requested_tag or str(raw_candidate.get("tag", "")),
        requested_seq=requested_seq if requested_seq is not None else raw_candidate.get("seq"),
    )
    with Path(args.output).open("w", encoding="utf-8", newline="\n") as stream:
        for key in ("operation", "tag", "seq", "source_sha", "technical_tag", "technical_title", "product_tag", "upstream_commit", "base_current", "base_seq", "base_payload_sha"):
            value = candidate.get(key)
            stream.write(f"{key}={'' if value is None else value}\n")
def validate_release_record(
    record: dict[str, Any],
    *,
    tag: str,
    title: str,
    target_commit: str,
    prerelease: bool,
    latest: bool,
    notes: str,
    require_published: bool = False,
) -> str:
    expected = {
        "tagName": tag,
        "name": title,
        "targetCommitish": target_commit,
        "isPrerelease": prerelease,
        "body": notes,
    }
    def normalized_body(value: object) -> str | None:
        if not isinstance(value, str):
            return None
        return value.replace("\r\n", "\n").rstrip()

    for field, value in expected.items():
        actual = record.get(field)
        if field == "body":
            actual = normalized_body(actual)
            value = normalized_body(value)
        if actual != value:
            raise ValueError(f"GitHub Release metadata mismatch for {tag}: {field}")
    if not isinstance(record.get("isDraft"), bool):
        raise ValueError(f"GitHub Release metadata missing isDraft for {tag}")
    if record["isDraft"]:
        if record.get("isImmutable") is True:
            raise ValueError(f"draft GitHub Release unexpectedly reports isImmutable for {tag}")
        if require_published:
            raise ValueError(f"GitHub Release {tag} is still a draft")
        return "draft"
    if record.get("isImmutable") is not True:
        raise ValueError(f"published GitHub Release {tag} is not immutable")
    if record.get("isLatest") is not latest:
        raise ValueError(f"GitHub Release Latest status mismatch for {tag}")
    return "published"


def _check_release_command(args: argparse.Namespace) -> None:
    record = _read_json(args.record, "GitHub Release")
    try:
        notes = Path(args.notes).read_text(encoding="utf-8")
    except OSError as error:
        raise ValueError(f"cannot read release notes: {error}") from error
    state = validate_release_record(
        record,
        tag=args.tag,
        title=args.title,
        target_commit=args.target_commit,
        prerelease=args.prerelease == "true",
        latest=args.latest == "true",
        notes=notes,
        require_published=args.require_published,
    )
    print(state)


def _manifest_state_command(args: argparse.Namespace) -> None:
    state = production_manifest_state(
        _read_json(args.manifest, "production manifest"),
        _read_json(args.candidate, "candidate metadata"),
    )
    print(state)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    plan = commands.add_parser("plan")
    plan.add_argument("--operation", required=True, choices=("upstream-release", "hotfix"))
    plan.add_argument("--tag", required=True)
    plan.add_argument("--seq", required=True, type=int)
    plan.add_argument("--source-sha", required=True)
    plan.add_argument("--upstream", required=True, type=Path)
    plan.add_argument("--controlled", required=True, type=Path)
    plan.add_argument("--upstream-commit", required=True)
    plan.add_argument("--product-release-exists", action="store_true")
    plan.add_argument("--technical-release-exists", action="store_true")
    plan.add_argument("--output", required=True, type=Path)
    plan.set_defaults(func=_plan_command)

    notes = commands.add_parser("notes")
    notes.add_argument("--candidate", required=True, type=Path)
    notes.add_argument("--upstream", required=True, type=Path)
    notes.add_argument("--controlled", required=True, type=Path)
    notes.add_argument("--repository", required=True, type=Path)
    notes.add_argument("--output-dir", required=True, type=Path)
    notes.set_defaults(func=_notes_command)

    candidate = commands.add_parser("candidate-info")
    candidate.add_argument("--candidate", required=True, type=Path)
    candidate.add_argument("--source-sha", required=True)
    candidate.add_argument("--tag")
    candidate.add_argument("--seq", type=int)
    candidate.add_argument("--output", required=True, type=Path)
    candidate.set_defaults(func=_candidate_info_command)

    release = commands.add_parser("check-release")
    release.add_argument("--record", required=True, type=Path)
    release.add_argument("--tag", required=True)
    release.add_argument("--title", required=True)
    release.add_argument("--target-commit", required=True)
    release.add_argument("--prerelease", required=True, choices=("true", "false"))
    release.add_argument("--latest", required=True, choices=("true", "false"))
    release.add_argument("--notes", required=True, type=Path)
    release.add_argument("--require-published", action="store_true")
    release.set_defaults(func=_check_release_command)

    manifest_state = commands.add_parser("manifest-state")
    manifest_state.add_argument("--manifest", required=True, type=Path)
    manifest_state.add_argument("--candidate", required=True, type=Path)
    manifest_state.set_defaults(func=_manifest_state_command)
    return root


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        args.func(args)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"publication policy: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
