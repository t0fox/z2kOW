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
from pathlib import Path


TAG_RE = re.compile(r"[pr]-[0-9]+(?:\.[0-9]+)+\Z")
ARTIFACT_NAME = "openwrt-rootfs.tar.gz"
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


def controlled_from_upstream(upstream: dict[str, object], commit: str) -> dict[str, object]:
    """Adapt one live upstream release manifest into the sole OpenWrt authority."""
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


def compare_upstream(
    upstream: dict[str, object], controlled: dict[str, object], commit: str
) -> dict[str, object]:
    """Compare live upstream with the controlled OpenWrt release without version ordering."""
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
    approved_provenance = controlled.get("upstream")
    approved_commit = approved_provenance.get("commit") if isinstance(approved_provenance, dict) else None
    return {
        "latest_tag": latest_tag,
        "latest_seq": latest_seq,
        "latest_commit": commit,
        "approved_tag": approved_tag,
        "approved_seq": approved_seq,
        "source_changed": commit != approved_commit,
        "update_available": latest_seq > approved_seq,
    }


def attach_rootfs_artifact(
    manifest: dict[str, object], artifact: Path, url: str | None = None
) -> None:
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
    manifest.pop("signing", None)
    write_manifest(destination, manifest)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    attach = subparsers.add_parser("attach")
    attach.add_argument("--manifest", required=True, type=Path)
    attach.add_argument("--artifact", required=True, type=Path)
    attach.add_argument("--url", required=True)
    attach.add_argument("--key-id")
    sync = subparsers.add_parser("sync")
    sync.add_argument("--upstream", required=True, type=Path)
    sync.add_argument("--commit", required=True)
    sync.add_argument("--output", required=True, type=Path)
    check = subparsers.add_parser("check-upstream")
    check.add_argument("--upstream", required=True, type=Path)
    check.add_argument("--commit", required=True)
    check.add_argument("--controlled", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "attach":
            attach_file(args.manifest, args.artifact, args.url, args.key_id)
        elif args.command == "sync":
            upstream = read_json_object(args.upstream, "upstream manifest")
            write_manifest(args.output, controlled_from_upstream(upstream, args.commit))
        else:
            upstream = read_json_object(args.upstream, "upstream manifest")
            controlled = read_json_object(args.controlled, "controlled manifest")
            result = compare_upstream(upstream, controlled, args.commit)
            print(json.dumps(result, sort_keys=True))
            if result["update_available"]:
                print(
                    f"new upstream release {result['latest_tag']} (seq {result['latest_seq']}) "
                    f"is newer than controlled {result['approved_tag']} (seq {result['approved_seq']})",
                    file=sys.stderr,
                )
                return 3
            print("no newer upstream release")
    except (OSError, ValueError) as error:
        print(f"controlled release: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
