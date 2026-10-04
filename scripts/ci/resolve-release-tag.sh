#!/usr/bin/env bash
set -euo pipefail

repo_root="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
tag="${INPUT_CANDIDATE:-}"

if [[ -z "$tag" ]]; then
  [[ "${GITHUB_REF:-}" == refs/heads/main ]] || exit 0
  tag="$(python3 - "$repo_root/UPDATES.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as manifest_file:
    manifest = json.load(manifest_file)
tag = manifest.get("current")
if not isinstance(tag, str) or not tag:
    raise SystemExit("UPDATES.json has no current release tag")
print(tag)
PY
)"
fi

if [[ ! "$tag" =~ ^[pr]-[0-9]+(\.[0-9]+)+$ ]]; then
  printf 'invalid release candidate tag: %s\n' "$tag" >&2
  exit 1
fi

: "${GITHUB_ENV:?GITHUB_ENV is required}"
printf 'Z2K_RELEASE_CANDIDATE_VERSION=%s\n' "$tag" >> "$GITHUB_ENV"
