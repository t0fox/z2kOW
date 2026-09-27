#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_URL="https://github.com/necronicle/z2k.git"
UPSTREAM_BRANCH="z2k-enhanced"
PRODUCT_BRANCH="main"
MANIFEST="UPSTREAM.json"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || die "not inside a Git repository"
}

require_clean_worktree() {
  [ -z "$(git status --porcelain)" ] || die "working tree is not clean"
}

ensure_upstream_remote() {
  if git remote get-url upstream >/dev/null 2>&1; then
    git remote set-url upstream "$UPSTREAM_URL"
  else
    git remote add upstream "$UPSTREAM_URL"
  fi
}

fetch_upstream() {
  ensure_upstream_remote
  git fetch --prune upstream "$UPSTREAM_BRANCH" --tags
}

upstream_sha() {
  git rev-parse "refs/remotes/upstream/$UPSTREAM_BRANCH"
}

upstream_version() {
  local sha="$1"
  git show "$sha:UPDATES.json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["current"])'
}

manifest_sha() {
  python3 - "$MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    print(json.load(fh)["upstream"]["commit"])
PY
}

manifest_version() {
  python3 - "$MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    print(json.load(fh)["upstream"]["version"])
PY
}

update_manifest() {
  local sha="$1"
  local version="$2"
  python3 - "$MANIFEST" "$sha" "$version" <<'PY'
import datetime
import json
import sys

path, sha, version = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)

data["upstream"]["commit"] = sha
data["upstream"]["version"] = version
data["updated_at"] = datetime.datetime.now(datetime.timezone.utc).date().isoformat()

with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
}

show_status() {
  local old_sha="$1"
  local old_version="$2"
  local new_sha="$3"
  local new_version="$4"

  printf 'Recorded upstream: %s (%s)\n' "$old_version" "$old_sha"
  printf 'Remote upstream:   %s (%s)\n' "$new_version" "$new_sha"

  if [ "$old_sha" = "$new_sha" ]; then
    printf 'Status: up to date\n'
    return 0
  fi

  printf 'Status: update available\n'
  printf '\nChanged upstream files:\n'
  git diff --name-status "$old_sha" "$new_sha" || true
}

cmd="${1:-check}"

need git
need python3
cd "$(repo_root)"

[ -f "$MANIFEST" ] || die "$MANIFEST is missing"

case "$cmd" in
  check)
    fetch_upstream
    old_sha="$(manifest_sha)"
    old_version="$(manifest_version)"
    new_sha="$(upstream_sha)"
    new_version="$(upstream_version "$new_sha")"
    show_status "$old_sha" "$old_version" "$new_sha" "$new_version"
    ;;

  prepare)
    require_clean_worktree
    fetch_upstream

    old_sha="$(manifest_sha)"
    old_version="$(manifest_version)"
    new_sha="$(upstream_sha)"
    new_version="$(upstream_version "$new_sha")"

    show_status "$old_sha" "$old_version" "$new_sha" "$new_version"

    if [ "$old_sha" = "$new_sha" ]; then
      exit 0
    fi

    git fetch origin "$PRODUCT_BRANCH"
    git switch "$PRODUCT_BRANCH"
    git pull --ff-only origin "$PRODUCT_BRANCH"

    sync_branch="sync/$new_version"
    if git show-ref --verify --quiet "refs/heads/$sync_branch"; then
      die "local branch already exists: $sync_branch"
    fi
    if git ls-remote --exit-code --heads origin "$sync_branch" >/dev/null 2>&1; then
      die "remote branch already exists: $sync_branch"
    fi

    git switch -c "$sync_branch"

    set +e
    git merge --no-ff --no-commit "$new_sha"
    merge_rc=$?
    set -e

    if [ "$merge_rc" -ne 0 ]; then
      printf '\nMerge conflicts detected. Resolve them in %s, run the required tests, then use:\n' "$sync_branch" >&2
      printf '  ./tools/sync-upstream.sh finish\n' >&2
      printf '\nConflicting files:\n' >&2
      git diff --name-only --diff-filter=U >&2 || true
      exit "$merge_rc"
    fi

    update_manifest "$new_sha" "$new_version"
    git add "$MANIFEST"

    printf '\nPrepared %s. No commit was created.\n' "$sync_branch"
    printf 'Review the merge and run the required tests. Then run:\n'
    printf '  ./tools/sync-upstream.sh finish\n'
    ;;

  finish)
    current_branch="$(git branch --show-current)"
    case "$current_branch" in
      sync/*) ;;
      *) die "finish must be run from a sync/* branch" ;;
    esac

    if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
      die "unresolved merge conflicts remain"
    fi

    git rev-parse -q --verify MERGE_HEAD >/dev/null || die "no pending merge to finish"

    version="$(manifest_version)"
    git add "$MANIFEST"
    git commit -m "sync: upstream z2k $version"
    git push -u origin "$current_branch"

    printf 'Pushed %s. CI and review remain the authority before merging into %s.\n' \
      "$current_branch" "$PRODUCT_BRANCH"
    ;;

  *)
    die "usage: $0 {check|prepare|finish}"
    ;;
esac
