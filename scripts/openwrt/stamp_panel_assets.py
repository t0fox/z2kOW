#!/usr/bin/env python3
"""Stamp staged WebPanel cache-busters from the controlled release manifest."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


TAG_RE = re.compile(r"[pr]-[0-9]+(?:\.[0-9]+)+\Z")
ASSET_RE = re.compile(rb"([?&]v=)(?:[pr]-[0-9]+(?:\.[0-9]+)+)")
ASSET_SUFFIXES = {".css", ".html", ".js"}


def stamp_assets(root: Path, manifest_path: Path) -> int:
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read controlled release manifest: {error}") from error
    if not isinstance(manifest, dict):
        raise ValueError("controlled release manifest root must be an object")
    tag = manifest.get("current")
    if not isinstance(tag, str) or not TAG_RE.fullmatch(tag):
        raise ValueError("controlled release manifest current tag is invalid")
    if not root.is_dir():
        raise ValueError(f"staged WebPanel directory is missing: {root}")

    replacement = rb"\1" + tag.encode("ascii")
    count = 0
    for path in sorted(root.rglob("*")):
        if path.suffix not in ASSET_SUFFIXES or not path.is_file():
            continue
        content = path.read_bytes()
        stamped, matches = ASSET_RE.subn(replacement, content)
        if matches:
            path.write_bytes(stamped)
            count += matches
    if count == 0:
        raise ValueError("no release-tagged WebPanel asset cache-busters were found")
    return count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    args = parser.parse_args()
    try:
        count = stamp_assets(args.root, args.manifest)
    except ValueError as error:
        print(f"stamp_panel_assets: {error}", file=sys.stderr)
        return 1
    print(f"stamped {count} WebPanel asset cache-busters for the controlled release")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
