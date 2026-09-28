#!/usr/bin/env python3
"""Promote accumulated Unreleased notes into a dated product release section."""

from __future__ import annotations

import argparse
import os
import re
import stat
import sys
import tempfile
from datetime import date
from pathlib import Path


SEMVER_RE = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
RELEASE_HEADING_RE = re.compile(
    r"^## \[((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\](?: - (\d{4}-\d{2}-\d{2}))?$"
)


class ChangelogError(Exception):
    pass


def semver_tuple(version: str) -> tuple[int, int, int]:
    return tuple(int(part) for part in version.split("."))  # type: ignore[return-value]


def validate_date(value: str) -> str:
    try:
        parsed = date.fromisoformat(value)
    except ValueError as exc:
        raise ChangelogError("date must be a valid YYYY-MM-DD calendar date") from exc
    if parsed.isoformat() != value:
        raise ChangelogError("date must use the exact YYYY-MM-DD format")
    return value


def release_versions(lines: list[str]) -> list[tuple[str, int]]:
    versions: list[tuple[str, int]] = []
    for line_number, line in enumerate(lines, start=1):
        if not line.startswith("## [") or line == "## [Unreleased]":
            continue
        match = RELEASE_HEADING_RE.fullmatch(line)
        if not match:
            raise ChangelogError(
                f"invalid release heading at line {line_number}: {line}"
            )
        if match.group(2):
            validate_date(match.group(2))
        versions.append((match.group(1), line_number))
    return versions


def promote(changelog: Path, version: str, release_date: str) -> None:
    if not SEMVER_RE.fullmatch(version):
        raise ChangelogError("version must be SemVer X.Y.Z without leading zeroes")
    validate_date(release_date)

    try:
        original = changelog.read_text(encoding="utf-8")
        mode = stat.S_IMODE(changelog.stat().st_mode)
    except OSError as exc:
        raise ChangelogError(f"cannot read changelog {changelog}: {exc}") from exc

    lines = original.splitlines()
    unreleased_indexes = [
        index for index, line in enumerate(lines) if line == "## [Unreleased]"
    ]
    if len(unreleased_indexes) != 1:
        raise ChangelogError("CHANGELOG.md must contain exactly one '## [Unreleased]' section")
    start = unreleased_indexes[0]
    end = next(
        (index for index in range(start + 1, len(lines)) if lines[index].startswith("## ")),
        len(lines),
    )
    notes = lines[start + 1 : end]
    while notes and not notes[0].strip():
        notes.pop(0)
    while notes and not notes[-1].strip():
        notes.pop()
    if not notes or not any(line.strip() for line in notes):
        raise ChangelogError("Unreleased has no user-facing changes to promote")

    versions = release_versions(lines)
    if any(line_number - 1 < start for _existing, line_number in versions):
        raise ChangelogError("the Unreleased section must precede all dated release sections")
    if any(existing == version for existing, _line in versions):
        raise ChangelogError(f"CHANGELOG.md already has a section for [{version}]")
    if versions:
        latest = max((existing for existing, _line in versions), key=semver_tuple)
        if semver_tuple(version) <= semver_tuple(latest):
            raise ChangelogError(f"version {version} must be newer than the latest changelog version {latest}")

    result = [
        *lines[:start],
        "## [Unreleased]",
        "",
        f"## [{version}] - {release_date}",
        "",
        *notes,
        "",
        *lines[end:],
    ]
    content = "\n".join(result).rstrip() + "\n"

    temporary: str | None = None
    try:
        descriptor, temporary = tempfile.mkstemp(
            prefix=f".{changelog.name}.", suffix=".tmp", dir=changelog.parent
        )
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
        os.chmod(temporary, mode)
        os.replace(temporary, changelog)
    except OSError as exc:
        if temporary:
            try:
                os.unlink(temporary)
            except OSError:
                pass
        raise ChangelogError(f"cannot update changelog {changelog}: {exc}") from exc

    print(f"prepared_release={version}")
    print(f"release_date={release_date}")
    print(f"changelog={changelog}")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    command = commands.add_parser(
        "promote", help="move Unreleased notes under a dated SemVer heading"
    )
    command.add_argument("--changelog", type=Path, default=Path("CHANGELOG.md"))
    command.add_argument("--version", required=True)
    command.add_argument("--date", required=True, help="release date in YYYY-MM-DD")
    command.set_defaults(func=promote)
    return root


def main() -> int:
    args = parser().parse_args()
    args.func(args.changelog, args.version, args.date)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ChangelogError as exc:
        print(f"changelog-release: {exc}", file=sys.stderr)
        raise SystemExit(1)
