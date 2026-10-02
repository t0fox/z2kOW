#!/usr/bin/env python3
"""Fail closed unless GitHub confirms immutable releases are enabled."""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Callable, NamedTuple


API_URL = "https://api.github.com"
API_VERSION = "2022-11-28"


class CheckResult(NamedTuple):
    exit_code: int
    message: str


def _get_response(
    url: str,
    token: str,
    opener: Callable[..., object],
) -> tuple[int, bytes]:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": API_VERSION,
        },
        method="GET",
    )
    try:
        response = opener(request, timeout=20)
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    with response:
        return response.status, response.read()


def _body_summary(body: bytes) -> str:
    text = body.decode("utf-8", errors="replace").strip()
    try:
        text = json.dumps(json.loads(text), sort_keys=True, separators=(",", ":"))
    except (json.JSONDecodeError, TypeError):
        pass
    if len(text) > 500:
        text = text[:497] + "..."
    return text or "<empty response body>"


def check_immutable_releases(
    repository: str,
    token: str,
    opener: Callable[..., object] = urllib.request.urlopen,
    api_url: str = API_URL,
) -> CheckResult:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        return CheckResult(2, "Invalid GitHub repository name; expected owner/repository.")
    if not token:
        return CheckResult(
            2,
            "Z2KOW_IMMUTABILITY_TOKEN is missing; configure a GitHub App or fine-grained token with repository Administration: read.",
        )

    encoded_repository = urllib.parse.quote(repository, safe="/")
    keys_url = f"{api_url}/repos/{encoded_repository}/keys?per_page=1"
    try:
        keys_status, keys_body = _get_response(keys_url, token, opener)
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        return CheckResult(
            2,
            f"Could not reach the GitHub Administration: read probe: {error}; "
            "this network/API failure is not treated as disabled. Refusing publication.",
        )
    if keys_status != 200:
        body = _body_summary(keys_body)
        if keys_status in (401, 403):
            return CheckResult(
                2,
                f"Immutable-release check lacks required repository Administration: read permission: "
                f"GET /repos/{repository}/keys returned HTTP {keys_status}; GitHub body: {body}. "
                "Refusing production publication.",
            )
        return CheckResult(
            2,
            f"Could not verify repository Administration: read permission: GET /repos/{repository}/keys "
            f"returned HTTP {keys_status}; GitHub body: {body}. Refusing production publication.",
        )
    try:
        keys_payload = json.loads(keys_body)
    except (json.JSONDecodeError, TypeError):
        return CheckResult(2, "Administration: read probe returned invalid JSON; refusing production publication.")
    if not isinstance(keys_payload, list):
        return CheckResult(2, "Administration: read probe returned an unexpected response; refusing production publication.")

    immutable_url = f"{api_url}/repos/{encoded_repository}/immutable-releases"
    try:
        status, body = _get_response(immutable_url, token, opener)
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        return CheckResult(
            2,
            f"Could not reach the immutable-release endpoint: {error}; "
            "this network/API failure is not treated as disabled. Refusing publication.",
        )
    summary = _body_summary(body)
    if status == 200:
        try:
            payload = json.loads(body)
        except (json.JSONDecodeError, TypeError):
            return CheckResult(2, f"Immutable-release API returned invalid JSON (HTTP 200): {summary}. Refusing publication.")
        if not isinstance(payload, dict) or not isinstance(payload.get("enabled"), bool):
            return CheckResult(2, f"Immutable-release API omitted a boolean enabled field (HTTP 200): {summary}. Refusing publication.")
        if payload["enabled"]:
            return CheckResult(
                0,
                f"Administration: read verified by GET /repos/{repository}/keys?per_page=1 (HTTP 200). "
                f"Immutable release protection verified: GET immutable-releases returned HTTP 200; "
                f"body: {summary}; enabled=true.",
            )
        return CheckResult(
            1,
            f"Repository immutable releases are disabled (HTTP 200; enabled=false); "
            f"GitHub body: {summary}. Refusing production publication.",
        )
    if status == 404:
        return CheckResult(
            1,
            f"Repository immutable releases are disabled (HTTP 404) after the same token passed the "
            f"Administration: read probe at GET /repos/{repository}/keys (HTTP 200); GitHub body: {summary}. "
            "Refusing production publication.",
        )
    if status in (401, 403):
        return CheckResult(
            2,
            f"Immutable-release endpoint authorization failed (HTTP {status}) despite the Administration: read "
            f"probe succeeding; this is not treated as disabled. GitHub body: {summary}. Refusing publication.",
        )
    return CheckResult(
        2,
        f"Could not verify immutable-release setting: GET immutable-releases returned HTTP {status}; "
        f"GitHub body: {summary}. This API failure is not treated as disabled; refusing publication.",
    )


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} OWNER/REPOSITORY", file=sys.stderr)
        return 2
    result = check_immutable_releases(
        sys.argv[1], os.environ.get("Z2KOW_IMMUTABILITY_TOKEN", "")
    )
    print(result.message, file=sys.stdout if result.exit_code == 0 else sys.stderr)
    return result.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
