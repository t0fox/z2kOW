#!/usr/bin/env python3
"""Fail-closed GitHub preflight for an explicit z2kOW production release."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote


SHA_RE = re.compile(r"[0-9a-fA-F]{40}\Z")
SEMVER_RE = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z"
)
CI_PATH = ".github/workflows/ci.yml"
ROOT = Path(__file__).resolve().parents[2]


def legacy_package_version() -> str:
    path = ROOT / "package/openwrt/Makefile"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise PreflightError(f"cannot read legacy package version baseline: {exc}") from exc
    match = re.search(r"(?m)^PKG_VERSION:=([^\s]+)\s*$", text)
    if not match or not SEMVER_RE.fullmatch(match.group(1)):
        raise PreflightError("legacy package version baseline is missing or malformed")
    return match.group(1)


def semver_tuple(version: str) -> tuple[int, int, int]:
    major, minor, patch = (int(part) for part in version.split("."))
    return major, minor, patch


class PreflightError(Exception):
    pass


def _response_status_and_json(output: str) -> tuple[int | None, object | None]:
    status_match = re.search(r"(?m)^HTTP/\S+\s+(\d{3})\b", output)
    status = int(status_match.group(1)) if status_match else None
    body = output
    if status_match:
        separator = re.search(r"\r?\n\r?\n", output[status_match.end() :])
        if not separator:
            return status, None
        body = output[status_match.end() + separator.end() :]
    body = body.strip()
    if not body:
        return status, None
    try:
        return status, json.loads(body)
    except json.JSONDecodeError:
        # The API's --include output can contain a proxy's extra status/header
        # block. Decode the final JSON object without trusting header text.
        decoder = json.JSONDecoder()
        for index, char in enumerate(body):
            if char in "[{":
                try:
                    value, _ = decoder.raw_decode(body[index:])
                    return status, value
                except json.JSONDecodeError:
                    continue
    return status, None


def gh_get(endpoint: str) -> tuple[int, object | None, str]:
    try:
        proc = subprocess.run(
            ["gh", "api", "--include", endpoint],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
    except OSError as exc:
        raise PreflightError(f"cannot run GitHub CLI: {exc}") from exc

    combined = proc.stdout
    status, value = _response_status_and_json(combined)
    detail = proc.stderr.strip()
    if status is None:
        # `gh api` reports REST 404 as a nonzero exit. Accept only the explicit
        # Not Found response as absence; auth/network/server errors stay fatal.
        error_value = None
        try:
            error_value = json.loads(proc.stdout.strip() or proc.stderr.strip())
        except json.JSONDecodeError:
            pass
        if isinstance(error_value, dict) and error_value.get("message") == "Not Found":
            status, value = 404, error_value
        elif proc.returncode == 0:
            status = 200
            if value is None:
                try:
                    value = json.loads(proc.stdout)
                except json.JSONDecodeError as exc:
                    raise PreflightError(f"invalid JSON from GitHub API {endpoint}") from exc
        elif re.search(r"\bHTTP\s+404\b|\bNot Found\b", detail):
            status = 404
        else:
            raise PreflightError(
                f"GitHub API request failed ({endpoint}): {detail or proc.stdout.strip()}"
            )

    if status == 200:
        if value is None:
            try:
                value = json.loads(proc.stdout)
            except json.JSONDecodeError as exc:
                raise PreflightError(f"invalid JSON from GitHub API {endpoint}") from exc
        return status, value, detail
    if status == 404:
        return status, value, detail
    raise PreflightError(
        f"GitHub API returned HTTP {status} for {endpoint}: {detail or proc.stdout.strip()}"
    )


def require_absent(endpoint: str, label: str) -> None:
    status, _value, _detail = gh_get(endpoint)
    if status == 200:
        raise PreflightError(f"{label} already exists; release names are immutable")
    if status != 404:
        raise PreflightError(f"could not verify that {label} is absent")


def latest_exact_ci_run(repository: str, target_sha: str) -> dict[str, object]:
    endpoint = (
        f"repos/{repository}/actions/runs?head_sha={quote(target_sha)}&per_page=100"
    )
    status, payload, _detail = gh_get(endpoint)
    if status != 200 or not isinstance(payload, dict):
        raise PreflightError("could not read GitHub Actions runs for exact target SHA")
    runs = payload.get("workflow_runs")
    if not isinstance(runs, list):
        raise PreflightError("GitHub Actions API response has no workflow_runs list")

    matches = [
        run
        for run in runs
        if isinstance(run, dict)
        and run.get("path") == CI_PATH
        and run.get("head_branch") == "main"
        and isinstance(run.get("head_sha"), str)
        and run["head_sha"].lower() == target_sha.lower()
    ]
    if not matches:
        raise PreflightError(f"no {CI_PATH} run exists for target SHA {target_sha}")

    # GitHub returns runs newest first. Refuse an active or failed latest run,
    # even if an older run for this SHA happened to pass.
    latest = matches[0]
    if latest.get("status") != "completed" or latest.get("conclusion") != "success":
        raise PreflightError(
            "latest exact-SHA CI run must be status=completed and conclusion=success"
        )
    return latest


def require_live_acceptance() -> None:
    path = ROOT / "docs/openwrt-release-acceptance.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PreflightError(f"cannot read live acceptance record: {exc}") from exc

    cudy = data.get("cudy_live_acceptance", {}) if isinstance(data, dict) else {}
    web = data.get("web_luci_01", {}) if isinstance(data, dict) else {}
    cudy_status = cudy.get("status") if isinstance(cudy, dict) else None
    cudy_evidence = cudy.get("evidence") if isinstance(cudy, dict) else None
    limitations = cudy.get("accepted_limitations") if isinstance(cudy, dict) else None
    if cudy_status not in ("pass", "accepted_limitation") or not cudy_evidence:
        raise PreflightError("pending live acceptance: Cudy router gate needs evidence")
    if cudy_status == "accepted_limitation" and not limitations:
        raise PreflightError(
            "pending live acceptance: accepted Cudy limitations must be recorded"
        )
    web_status = web.get("status") if isinstance(web, dict) else None
    web_evidence = web.get("evidence") if isinstance(web, dict) else None
    if web_status != "pass" or not web_evidence:
        raise PreflightError("pending live acceptance: WEB-LUCI-01 needs evidence")

    blocker = data.get("web_blocker_01", {}) if isinstance(data, dict) else {}
    blocker_status = blocker.get("status") if isinstance(blocker, dict) else None
    blocker_evidence = blocker.get("evidence") if isinstance(blocker, dict) else None
    if blocker_status != "pass" or not blocker_evidence:
        raise PreflightError("pending live acceptance: WEB-BLOCKER-01 needs evidence")

    immutable = data.get("immutable_releases", {}) if isinstance(data, dict) else {}
    immutable_status = immutable.get("status") if isinstance(immutable, dict) else None
    immutable_evidence = immutable.get("evidence") if isinstance(immutable, dict) else None
    if immutable_status != "pass" or not immutable_evidence:
        raise PreflightError("pending live acceptance: GitHub immutable Releases setting needs evidence")

    pinned_key = ROOT / "package/openwrt/keys/z2k-feed.pem"
    if not pinned_key.is_file():
        raise PreflightError(
            "offline production APK public key is not pinned at "
            "package/openwrt/keys/z2k-feed.pem"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--target-sha", required=True)
    parser.add_argument("--confirm", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--dry-run", choices=("true", "false"), default="true")
    parser.add_argument("--require-live-gates", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not SEMVER_RE.fullmatch(args.version):
        raise PreflightError("version must be SemVer X.Y.Z without leading zeroes")
    legacy_version = legacy_package_version()
    if semver_tuple(args.version) <= semver_tuple(legacy_version):
        raise PreflightError(
            f"release version must be newer than legacy package baseline {legacy_version}"
        )
    if not SHA_RE.fullmatch(args.target_sha):
        raise PreflightError("target_sha must be a full 40-character commit SHA")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        raise PreflightError("repository must be OWNER/REPO")
    expected_confirmation = f"RELEASE v{args.version}"
    if args.confirm != expected_confirmation:
        raise PreflightError(f"confirm must exactly equal: {expected_confirmation}")
    if args.dry_run == "false" or args.require_live_gates:
        require_live_acceptance()

    target_sha = args.target_sha.lower()
    repo = args.repository
    main_endpoint = f"repos/{repo}/git/ref/heads/main"
    main_status, main_ref, _detail = gh_get(main_endpoint)
    if main_status != 200 or not isinstance(main_ref, dict):
        raise PreflightError("could not resolve refs/heads/main through GitHub API")
    main_sha = main_ref.get("object", {}).get("sha") if isinstance(main_ref.get("object"), dict) else None
    if not isinstance(main_sha, str) or not SHA_RE.fullmatch(main_sha):
        raise PreflightError("GitHub main ref did not return a full commit SHA")
    if main_sha.lower() != target_sha:
        raise PreflightError(
            f"target SHA is not current main: target={target_sha}, main={main_sha.lower()}"
        )

    ci_run = latest_exact_ci_run(repo, target_sha)
    tag = f"v{args.version}"
    encoded_tag = quote(tag, safe="")
    require_absent(f"repos/{repo}/git/ref/tags/{encoded_tag}", f"tag {tag}")
    require_absent(f"repos/{repo}/releases/tags/{encoded_tag}", f"GitHub Release {tag}")

    run_id = ci_run.get("id", "unknown")
    print(f"preflight=passed")
    print(f"version={args.version}")
    print(f"target_sha={target_sha}")
    print(f"ci_run_id={run_id}")
    print(f"dry_run={args.dry_run}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PreflightError as exc:
        print(f"release-preflight: {exc}", file=sys.stderr)
        raise SystemExit(1)
