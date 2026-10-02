#!/usr/bin/env python3
"""Fetch the pinned upstream Telegram executables into one payload staging tree."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import tempfile
import time
import urllib.request
from pathlib import Path


COMMIT_RE = re.compile(r"[0-9a-f]{40}\Z")
SUPPORTED_UPSTREAM_ARCHES = ("386", "amd64", "arm", "arm64", "mips", "mipsle", "riscv64")
TARGET_ARCHES = {
    "386": "x86",
    "amd64": "x86_64",
    "arm": "arm",
    "arm64": "arm64",
    "mips": "mips",
    "mipsle": "mipsel",
    "riscv64": "riscv64",
}
UPSTREAM_RAW = "https://raw.githubusercontent.com/necronicle/z2k"


def _read_json(path: Path, description: str) -> dict[str, object]:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {description}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{description} root must be an object")
    return value


def _fetch(url: str) -> bytes:
    request = urllib.request.Request(
        f"{url}?codex_nocache={time.time_ns()}",
        headers={"Cache-Control": "no-cache, no-store", "Pragma": "no-cache", "User-Agent": "z2kOW-release-builder"},
    )
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            return response.read()
    except OSError as error:
        raise ValueError(f"cannot fetch pinned upstream artifact: {error}") from error


def fetch_binaries(controlled_manifest: Path, output_dir: Path) -> None:
    """Fetch and verify all OpenWrt Telegram binaries from the manifest's exact commit."""
    controlled = _read_json(controlled_manifest, "controlled UPDATES.json")
    tag = controlled.get("current")
    seq = controlled.get("seq")
    provenance = controlled.get("upstream")
    commit = provenance.get("commit") if isinstance(provenance, dict) else None
    if not isinstance(tag, str) or not isinstance(seq, int) or isinstance(seq, bool):
        raise ValueError("controlled current tag/sequence is missing")
    if not isinstance(commit, str) or not COMMIT_RE.fullmatch(commit):
        raise ValueError("controlled upstream commit is missing or malformed")

    raw_base = f"{UPSTREAM_RAW}/{commit}"
    try:
        upstream = json.loads(_fetch(f"{raw_base}/UPDATES.json"))
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise ValueError(f"pinned upstream UPDATES.json is invalid: {error}") from error
    if not isinstance(upstream, dict) or upstream.get("current") != tag or upstream.get("seq") != seq:
        raise ValueError("pinned upstream release mismatch with controlled UPDATES.json")
    hashes = upstream.get("files_sha256")
    if not isinstance(hashes, dict):
        raise ValueError("pinned upstream UPDATES.json has no files_sha256 map")

    output_dir = Path(output_dir)
    if output_dir.exists() and any(output_dir.iterdir()):
        raise ValueError(f"output directory must be absent or empty: {output_dir}")
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=f".{output_dir.name}.", dir=output_dir.parent))
    try:
        for upstream_arch, target_arch in TARGET_ARCHES.items():
            relative = f"mtproxy-client/builds/tg-mtproxy-client-linux-{upstream_arch}"
            expected = hashes.get(relative)
            if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
                raise ValueError(f"pinned upstream manifest has no valid SHA-256 for {relative}")
            body = _fetch(f"{raw_base}/{relative}")
            actual = hashlib.sha256(body).hexdigest()
            if actual != expected:
                raise ValueError(f"upstream TG binary SHA-256 mismatch: {relative}")
            target = stage / f"linux-{target_arch}" / "tg-mtproxy-client"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(body)
            target.chmod(0o755)

        if output_dir.exists():
            output_dir.rmdir()
        os.replace(stage, output_dir)
    finally:
        if stage.exists():
            shutil.rmtree(stage, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        fetch_binaries(args.manifest, args.output)
    except (OSError, ValueError) as error:
        parser.exit(1, f"fetch upstream TG: {error}\n")
    print(f"verified upstream TG binaries staged for {len(TARGET_ARCHES)} OpenWrt architectures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
