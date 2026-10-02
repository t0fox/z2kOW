#!/usr/bin/env python3
"""Sign or verify the exact controlled manifest for one complete OpenWrt release."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from controlled_release import attach_rootfs_artifact, read_json_object


KEY_ID_RE = re.compile(r"[0-9a-f]{64}\Z")


def _openssl(*args: str) -> bytes:
    result = subprocess.run(["openssl", *args], capture_output=True, check=False)
    if result.returncode != 0:
        raise ValueError("OpenSSL could not process the Ed25519 key or signature")
    return result.stdout


def _fingerprint(public_key: Path) -> str:
    der = _openssl("pkey", "-pubin", "-in", str(public_key), "-outform", "DER")
    return hashlib.sha256(der).hexdigest()


def _validate_release(manifest_path: Path, artifact_path: Path) -> dict[str, object]:
    manifest = read_json_object(manifest_path, "controlled UPDATES.json")
    key_meta = manifest.get("signing")
    key_id = key_meta.get("key_id") if isinstance(key_meta, dict) else None
    if not isinstance(key_id, str) or not KEY_ID_RE.fullmatch(key_id):
        raise ValueError("controlled manifest has no valid signing.key_id fingerprint")
    artifact = manifest.get("artifact")
    if not isinstance(artifact, dict):
        raise ValueError("controlled manifest has no complete rootfs artifact record")
    candidate = dict(manifest)
    candidate.pop("artifact", None)
    attach_rootfs_artifact(candidate, artifact_path)
    if candidate.get("artifact") != artifact:
        raise ValueError("controlled artifact size or SHA-256 does not match the complete rootfs")
    return manifest


def _verify(manifest_path: Path, artifact_path: Path, signature_path: Path, public_key: Path) -> None:
    manifest = _validate_release(manifest_path, artifact_path)
    if not signature_path.is_file() or signature_path.stat().st_size == 0:
        raise ValueError("controlled manifest signature is missing")
    key_meta = manifest["signing"]
    key_id = key_meta["key_id"]
    if _fingerprint(public_key) != key_id:
        raise ValueError("public key fingerprint does not match signing.key_id")
    result = subprocess.run(
        [
            "openssl", "pkeyutl", "-verify", "-rawin", "-pubin", "-inkey", str(public_key),
            "-in", str(manifest_path), "-sigfile", str(signature_path),
        ],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise ValueError("controlled manifest signature verification failed")


def sign(manifest_path: Path, artifact_path: Path, signature_path: Path, private_key: Path) -> None:
    manifest = _validate_release(manifest_path, artifact_path)
    if not private_key.is_file() or private_key.stat().st_size == 0:
        raise ValueError("production signing key is missing")
    key_meta = manifest["signing"]
    key_id = key_meta["key_id"]
    signature_path.parent.mkdir(parents=True, exist_ok=True)
    temp_path: Path | None = None
    try:
        with tempfile.TemporaryDirectory(prefix="z2kow-sign-") as directory:
            public_key = Path(directory) / "derived-public.pem"
            public_key.write_bytes(_openssl("pkey", "-in", str(private_key), "-pubout"))
            public_key.chmod(0o644)
            if _fingerprint(public_key) != key_id:
                raise ValueError("private key fingerprint does not match signing.key_id")
            fd, raw_temp = tempfile.mkstemp(prefix=signature_path.name + ".", suffix=".tmp", dir=signature_path.parent)
            os.close(fd)
            temp_path = Path(raw_temp)
            result = subprocess.run(
                ["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(private_key),
                 "-in", str(manifest_path), "-out", str(temp_path)],
                capture_output=True,
                check=False,
            )
            if result.returncode != 0 or temp_path.stat().st_size == 0:
                raise ValueError("OpenSSL could not sign the controlled manifest")
            temp_path.chmod(0o644)
            _verify(manifest_path, artifact_path, temp_path, public_key)
            os.replace(temp_path, signature_path)
            temp_path = None
    finally:
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("sign", "verify"):
        command = subparsers.add_parser(name)
        command.add_argument("--manifest", required=True, type=Path)
        command.add_argument("--artifact", required=True, type=Path)
        command.add_argument("--signature", required=True, type=Path)
        command.add_argument("--private-key", type=Path)
        command.add_argument("--public-key", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "sign":
            if args.private_key is None:
                raise ValueError("sign requires --private-key")
            sign(args.manifest, args.artifact, args.signature, args.private_key)
            print("controlled manifest signature created and verified")
        else:
            if args.public_key is None:
                raise ValueError("verify requires --public-key")
            _verify(args.manifest, args.artifact, args.signature, args.public_key)
            print("controlled manifest signature verified")
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"release signing: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
