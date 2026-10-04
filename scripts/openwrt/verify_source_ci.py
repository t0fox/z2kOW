#!/usr/bin/env python3
"""Require a successful normal push CI run for an exact main source SHA."""

from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen


CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
API_ROOT = "https://api.github.com"


class VerificationError(RuntimeError):
    pass


def select_successful_run(runs: list[dict], source_sha: str) -> dict:
    exact_runs = [
        run
        for run in runs
        if run.get("head_sha") == source_sha
        and run.get("event") == "push"
        and run.get("head_branch") == "main"
        and run.get("path", "").split("@", 1)[0] == CI_WORKFLOW_PATH
    ]
    if not exact_runs:
        raise VerificationError(
            f"No normal push CI run was found for exact source SHA {source_sha} on main. "
            "Push this SHA to main and wait for .github/workflows/ci.yml to finish."
        )

    successful = [
        run for run in exact_runs
        if run.get("status") == "completed" and run.get("conclusion") == "success"
    ]
    if not successful:
        outcomes = ", ".join(
            f"run {run.get('id')}: {run.get('status')}/{run.get('conclusion')}"
            for run in exact_runs
        )
        raise VerificationError(
            f"No successful normal push CI run exists for exact source SHA {source_sha}: {outcomes}"
        )

    def created_key(run: dict) -> tuple[datetime, int]:
        created = datetime.fromisoformat(run.get("created_at", "1970-01-01T00:00:00+00:00").replace("Z", "+00:00"))
        return created, int(run.get("id", 0))

    return max(successful, key=created_key)


def _next_link(link_header: str) -> str | None:
    for part in link_header.split(","):
        match = re.match(r'\s*<([^>]+)>\s*;\s*rel="([^"]+)"', part)
        if match and match.group(2) == "next":
            next_url = match.group(1)
            parsed = urlsplit(next_url)
            if parsed.scheme != "https" or parsed.netloc != "api.github.com":
                raise VerificationError("GitHub returned an invalid Actions API pagination link")
            return next_url
    return None


def fetch_workflow_runs(repository: str, source_sha: str, token: str) -> list[dict]:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise VerificationError("GITHUB_REPOSITORY is malformed")
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise VerificationError("GITHUB_SHA must be a full 40-character lowercase commit SHA")

    query = urlencode({
        "head_sha": source_sha,
        "branch": "main",
        "event": "push",
        "per_page": 100,
    })
    url = f"{API_ROOT}/repos/{repository}/actions/workflows/ci.yml/runs?{query}"
    runs: list[dict] = []
    while url:
        request = Request(url, headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "z2kOW-release-ci-verifier",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        try:
            with urlopen(request, timeout=30) as response:
                payload = json.load(response)
                link_header = response.headers.get("Link", "")
        except HTTPError as error:
            detail = ""
            try:
                detail = json.loads(error.read()).get("message", "")
            except (ValueError, AttributeError):
                pass
            raise VerificationError(
                f"Cannot read GitHub Actions CI runs (HTTP {error.code}); "
                "check that the release job token has actions: read."
                + (f" GitHub API: {detail}" if detail else "")
            ) from error
        except URLError as error:
            raise VerificationError(f"Cannot reach the GitHub Actions API: {error.reason}") from error

        page_runs = payload.get("workflow_runs") if isinstance(payload, dict) else None
        if not isinstance(page_runs, list):
            raise VerificationError("GitHub Actions API returned an invalid workflow-runs response")
        runs.extend(page_runs)
        url = _next_link(link_header)
    return runs


def main() -> int:
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        raise VerificationError("GH_TOKEN is missing; the release job needs actions: read")
    repository = os.environ.get("REPOSITORY", "")
    source_sha = os.environ.get("SOURCE_SHA", "")
    successful_run = select_successful_run(fetch_workflow_runs(repository, source_sha, token), source_sha)
    run_id = successful_run.get("id")
    run_url = successful_run.get("html_url", "")
    message = f"Verified successful push CI for exact source SHA {source_sha}: run {run_id} ({run_url})"
    print(message)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as summary:
            summary.write(f"{message}\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except VerificationError as error:
        print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1)
