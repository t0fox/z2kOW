from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts" / "openwrt" / "fetch_upstream_tg.py"
SPEC = importlib.util.spec_from_file_location("fetch_upstream_tg", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class FakeResponse:
    def __init__(self, body: bytes) -> None:
        self.body = body

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def read(self) -> bytes:
        return self.body


class UpstreamTelegramArtifactTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.commit = "a" * 40
        self.files: dict[str, bytes] = {}
        self.hashes: dict[str, str] = {}
        for goarch in MODULE.SUPPORTED_UPSTREAM_ARCHES:
            path = f"mtproxy-client/builds/tg-mtproxy-client-linux-{goarch}"
            body = f"official-{goarch}".encode()
            self.files[path] = body
            self.hashes[path] = hashlib.sha256(body).hexdigest()
        self.upstream = {
            "current": "p-86.11",
            "seq": 134,
            "files_sha256": self.hashes,
        }
        self.controlled = self.root / "UPDATES.json"
        self.controlled.write_text(
            json.dumps(
                {
                    "current": "p-86.11",
                    "seq": 134,
                    "upstream": {"commit": self.commit},
                }
            ),
            encoding="utf-8",
        )
        self.output = self.root / "tg"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def opener(self, request, timeout=30):
        url = request.full_url
        if url.endswith("/UPDATES.json") or "/UPDATES.json?" in url:
            return FakeResponse(json.dumps(self.upstream).encode())
        path = url.split(f"/{self.commit}/", 1)[1].split("?", 1)[0]
        return FakeResponse(self.files[path])

    def test_downloads_exact_commit_binaries_and_places_them_in_payload_arch_dirs(self) -> None:
        with patch.object(MODULE.urllib.request, "urlopen", side_effect=self.opener):
            MODULE.fetch_binaries(self.controlled, self.output)

        self.assertEqual(
            {path.name for path in (self.output).glob("linux-*/tg-mtproxy-client")},
            {"tg-mtproxy-client"},
        )
        for upstream_arch, target_arch in MODULE.TARGET_ARCHES.items():
            path = self.output / f"linux-{target_arch}" / "tg-mtproxy-client"
            self.assertEqual(path.read_bytes(), self.files[
                f"mtproxy-client/builds/tg-mtproxy-client-linux-{upstream_arch}"
            ])
            if os.name == "posix":
                self.assertTrue(path.stat().st_mode & 0o111)

    def test_rejects_a_commit_manifest_that_does_not_match_the_controlled_release(self) -> None:
        self.upstream["current"] = "p-86.13"
        with patch.object(MODULE.urllib.request, "urlopen", side_effect=self.opener):
            with self.assertRaisesRegex(ValueError, "pinned upstream release mismatch"):
                MODULE.fetch_binaries(self.controlled, self.output)
        self.assertFalse(self.output.exists())

    def test_rejects_a_binary_whose_digest_differs_from_upstream_manifest(self) -> None:
        self.hashes[next(iter(self.hashes))] = "0" * 64
        with patch.object(MODULE.urllib.request, "urlopen", side_effect=self.opener):
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                MODULE.fetch_binaries(self.controlled, self.output)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
