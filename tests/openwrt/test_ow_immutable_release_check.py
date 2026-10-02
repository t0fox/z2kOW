#!/usr/bin/env python3
"""The immutable-release gate distinguishes disabled state from API failures."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/openwrt/check_immutable_releases.py"
SPEC = importlib.util.spec_from_file_location("check_immutable_releases", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class Response:
    def __init__(self, status: int, body: bytes):
        self.status = status
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return None

    def read(self) -> bytes:
        return self.body


class ImmutableReleaseCheckTests(unittest.TestCase):
    def test_enabled_response_proceeds_only_after_administration_read_probe(self) -> None:
        calls: list[str] = []

        def open_request(request, timeout=0):
            calls.append(request.full_url)
            if request.full_url.endswith("/keys?per_page=1"):
                return Response(200, b"[]")
            return Response(200, b'{"enabled":true,"enforced_by_owner":false}')

        result = CHECK.check_immutable_releases("t0fox/z2kOW", "test-token", open_request)

        self.assertEqual(result.exit_code, 0)
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[0].endswith("/repos/t0fox/z2kOW/keys?per_page=1"))
        self.assertTrue(calls[1].endswith("/repos/t0fox/z2kOW/immutable-releases"))
        self.assertIn("enabled=true", result.message)
        self.assertIn('"enforced_by_owner":false', result.message)
        self.assertIn("/keys?per_page=1 (HTTP 200)", result.message)

    def test_admin_read_denial_is_not_reported_as_disabled(self) -> None:
        def open_request(_request, timeout=0):
            return Response(403, b'{"message":"Resource not accessible by integration"}')

        result = CHECK.check_immutable_releases("t0fox/z2kOW", "test-token", open_request)

        self.assertNotEqual(result.exit_code, 0)
        self.assertIn("Administration: read", result.message)
        self.assertNotIn("disabled", result.message.lower())

    def test_admin_read_404_is_not_misclassified_as_an_immutable_setting(self) -> None:
        def open_request(_request, timeout=0):
            return Response(404, b'{"message":"Not Found"}')

        result = CHECK.check_immutable_releases("t0fox/z2kOW", "test-token", open_request)

        self.assertNotEqual(result.exit_code, 0)
        self.assertIn("Administration: read", result.message)
        self.assertNotIn("disabled", result.message.lower())

    def test_authorized_404_blocks_publication_as_disabled(self) -> None:
        def open_request(request, timeout=0):
            if request.full_url.endswith("/keys?per_page=1"):
                return Response(200, b"[]")
            return Response(404, b'{"message":"Not Found"}')

        result = CHECK.check_immutable_releases("t0fox/z2kOW", "test-token", open_request)

        self.assertNotEqual(result.exit_code, 0)
        self.assertIn("404", result.message)
        self.assertIn("disabled", result.message.lower())
        self.assertIn("Administration: read", result.message)

    def test_enabled_false_blocks_production(self) -> None:
        def open_request(request, timeout=0):
            if request.full_url.endswith("/keys?per_page=1"):
                return Response(200, b"[]")
            return Response(200, b'{"enabled":false,"enforced_by_owner":false}')

        result = CHECK.check_immutable_releases("t0fox/z2kOW", "test-token", open_request)

        self.assertNotEqual(result.exit_code, 0)
        self.assertIn("enabled=false", result.message)
        self.assertIn("HTTP 200", result.message)

    def test_unknown_api_failure_is_never_mapped_to_disabled(self) -> None:
        def open_request(request, timeout=0):
            if request.full_url.endswith("/keys?per_page=1"):
                return Response(200, b"[]")
            return Response(500, b'{"message":"internal error"}')

        result = CHECK.check_immutable_releases("t0fox/z2kOW", "test-token", open_request)

        self.assertNotEqual(result.exit_code, 0)
        self.assertIn("HTTP 500", result.message)
        self.assertIn("not treated as disabled", result.message.lower())


if __name__ == "__main__":
    unittest.main()
