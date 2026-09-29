#!/bin/sh
# tests/openwrt/test_ow_release_flow.sh - production release preflight contract.
# Exercise the preflight through a fake gh executable: no network or GitHub writes.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-release-flow"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO" || exit 1
PREFLIGHT="$REPO/scripts/openwrt/release-preflight.py"
WORKFLOW="$REPO/.github/workflows/release-openwrt.yml"
CI_WORKFLOW="$REPO/.github/workflows/ci.yml"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-rflow.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin"
GH_LOG="$T/gh.log"
_TARGET_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
_OTHER_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
_VERSION=0.1.1
_VERSION_RE="$(printf '%s' "$_VERSION" | sed 's/\\./\\\\./g')"

# This fake models only the read endpoints needed by preflight. It logs the
# method and route so every case can prove that validation is read-only.
cat > "$T/bin/gh" <<'FAKE_GH'
#!/bin/sh
[ "$1" = api ] || { echo "unexpected gh command: $*" >&2; exit 64; }
shift
method=GET
endpoint=
skip_next=0
for arg in "$@"; do
    if [ "$skip_next" -eq 1 ]; then
        case "$skip_kind" in
            method) method="$arg" ;;
        esac
        skip_next=0
        continue
    fi
    case "$arg" in
        -X|--method) skip_next=1; skip_kind=method ;;
        -X?*) method="${arg#-X}" ;;
        --method=*) method="${arg#--method=}" ;;
        -f|-F|-H|--field|--raw-field|--header) skip_next=1; skip_kind=other ;;
        repos/*) [ -n "$endpoint" ] || endpoint="$arg" ;;
    esac
done
printf '%s %s\n' "$method" "$endpoint" >> "$GH_CALL_LOG"
case "$method" in
    GET) ;;
    POST|PATCH|PUT|DELETE) echo "fake gh refuses mutation: $method $endpoint" >&2; exit 90 ;;
    *) echo "unexpected method: $method" >&2; exit 64 ;;
esac
case "$endpoint" in
    */git/ref/heads/main|*/git/refs/heads/main)
        printf '{"ref":"refs/heads/main","object":{"sha":"%s","type":"commit"}}\n' "$GH_MAIN_SHA"
        ;;
    */commits/main|*/branches/main)
        printf '{"sha":"%s"}\n' "$GH_MAIN_SHA"
        ;;
    */actions/runs*)
        case "$GH_CI_STATE" in
            success)
                printf '{"total_count":1,"workflow_runs":[{"id":42,"name":"CI","path":".github/workflows/ci.yml","head_branch":"%s","head_sha":"%s","status":"completed","conclusion":"success"}]}\n' "$GH_CI_BRANCH" "$GH_CI_SHA"
                ;;
            failure)
                printf '{"total_count":1,"workflow_runs":[{"id":42,"name":"CI","path":".github/workflows/ci.yml","head_branch":"%s","head_sha":"%s","status":"completed","conclusion":"failure"}]}\n' "$GH_CI_BRANCH" "$GH_CI_SHA"
                ;;
            absent)
                printf '{"total_count":0,"workflow_runs":[]}\n'
                ;;
            *) echo "unknown CI fixture: $GH_CI_STATE" >&2; exit 64 ;;
        esac
        ;;
    */git/ref/tags/v*|*/git/refs/tags/v*)
        case "$GH_TAG_STATE" in
            present) printf '{"ref":"refs/tags/v%s","object":{"sha":"%s","type":"commit"}}\n' "$GH_VERSION" "$GH_TAG_SHA" ;;
            absent) echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest"}' >&2; exit 1 ;;
            *) echo "unknown tag fixture: $GH_TAG_STATE" >&2; exit 64 ;;
        esac
        ;;
    */releases/tags/v*)
        case "$GH_RELEASE_STATE" in
            present) printf '{"tag_name":"v%s","draft":false,"prerelease":false}\n' "$GH_VERSION" ;;
            absent) echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest"}' >&2; exit 1 ;;
            *) echo "unknown release fixture: $GH_RELEASE_STATE" >&2; exit 64 ;;
        esac
        ;;
    *) echo "unexpected gh api endpoint: $endpoint" >&2; exit 42 ;;
esac
FAKE_GH
chmod +x "$T/bin/gh"

_reset_fixture() {
    : > "$GH_LOG"
    export GH_CALL_LOG="$GH_LOG"
    export GH_MAIN_SHA="$_TARGET_SHA"
    export GH_CI_SHA="$_TARGET_SHA"
    export GH_CI_BRANCH=main
    export GH_CI_STATE=success
    export GH_TAG_STATE=absent
    export GH_RELEASE_STATE=absent
    export GH_VERSION="$_VERSION"
    export PATH="$T/bin:$PATH"
}
_run_preflight() {
    _reset_fixture
    python3 "$PREFLIGHT" --version "$_VERSION" --target-sha "$_TARGET_SHA" \
        --confirm "RELEASE v$_VERSION" --repository owner/repo --dry-run true \
        >"$T/output" 2>&1
    _RUN_RC=$?
}
_write_count() {
    awk '$1 == "POST" || $1 == "PATCH" || $1 == "PUT" || $1 == "DELETE" { n++ } END { print n+0 }' "$GH_LOG"
}

# Valid source: release target equals current main and has a successful CI run
# for that exact full SHA. Dry-run must complete without any mutation request.
_run_preflight
assert_eq "current main exact SHA preflight succeeds" "0" "$_RUN_RC"
assert_eq "successful preflight is read-only" "0" "$(_write_count)"
grep -Eq '^GET repos/owner/repo/(git/ref/heads/main|git/refs/heads/main|commits/main|branches/main)(\?|$)' "$GH_LOG" \
    && _t_ok || _t_bad "preflight did not read current main SHA through GitHub API"
grep -Eq '^GET repos/owner/repo/actions/runs\?' "$GH_LOG" \
    && _t_ok || _t_bad "preflight did not query CI runs through GitHub API"
grep -Eq "^GET repos/owner/repo/git/refs?/tags/v${_VERSION_RE}$" "$GH_LOG" \
    && _t_ok || _t_bad "preflight did not check the version tag through GitHub API"
grep -Eq "^GET repos/owner/repo/releases/tags/v${_VERSION_RE}$" "$GH_LOG" \
    && _t_ok || _t_bad "preflight did not check the version release through GitHub API"

# Input validation must reject malformed product versions and confirmation
# typos before any GitHub mutation can be attempted.
_reset_fixture
python3 "$PREFLIGHT" --version 1.2 --target-sha "$_TARGET_SHA" \
    --confirm 'RELEASE v1.2' --repository owner/repo --dry-run true >"$T/output" 2>&1
_rc=$?
assert_eq "malformed SemVer rejected" "1" "$( [ "$_rc" -ne 0 ] && echo 1 || echo 0 )"
assert_eq "malformed SemVer cannot write" "0" "$(_write_count)"
_reset_fixture
python3 "$PREFLIGHT" --version 0.1.0 --target-sha "$_TARGET_SHA" \
    --confirm 'RELEASE v0.1.0' --repository owner/repo --dry-run true >"$T/output" 2>&1
_rc=$?
assert_eq "legacy 0.1.0 release rejected before CI or tag checks" "1" "$( [ "$_rc" -ne 0 ] && echo 1 || echo 0 )"
if grep -Fq "must be newer than legacy package baseline 0.1.0" "$T/output"; then
    _t_ok
else
    _t_bad "legacy version rejection must explain r79-to-r1 upgrade safety"
fi
assert_eq "legacy SemVer release rejection performs no GitHub API reads" "" "$(cat "$GH_LOG")"
assert_eq "legacy SemVer release rejection cannot write" "0" "$(_write_count)"
_reset_fixture
python3 "$PREFLIGHT" --version 01.2.3 --target-sha "$_TARGET_SHA" \
    --confirm 'RELEASE v01.2.3' --repository owner/repo --dry-run true >"$T/output" 2>&1
_rc=$?
assert_eq "SemVer leading zero rejected" "1" "$( [ "$_rc" -ne 0 ] && echo 1 || echo 0 )"
assert_eq "leading-zero SemVer cannot write" "0" "$(_write_count)"
_reset_fixture
python3 "$PREFLIGHT" --version "$_VERSION" --target-sha "$_TARGET_SHA" \
    --confirm 'RELEASE v9.9.9' --repository owner/repo --dry-run true >"$T/output" 2>&1
_rc=$?
assert_eq "wrong release confirmation rejected" "1" "$( [ "$_rc" -ne 0 ] && echo 1 || echo 0 )"
assert_eq "wrong confirmation cannot write" "0" "$(_write_count)"

# A release can target only the current main SHA and only after a completed,
# successful CI run whose head_sha equals that exact SHA.
_reset_fixture
GH_MAIN_SHA="$_TARGET_SHA" GH_CI_SHA="$_TARGET_SHA" python3 "$PREFLIGHT" \
    --version "$_VERSION" --target-sha "$_OTHER_SHA" --confirm "RELEASE v$_VERSION" \
    --repository owner/repo --dry-run true >"$T/output" 2>&1
_rc=$?
assert_eq "non-current target SHA rejected" "1" "$( [ "$_rc" -ne 0 ] && echo 1 || echo 0 )"
assert_eq "non-current SHA cannot write" "0" "$(_write_count)"
_reset_fixture
GH_CI_STATE=absent python3 "$PREFLIGHT" --version "$_VERSION" --target-sha "$_TARGET_SHA" \
    --confirm "RELEASE v$_VERSION" --repository owner/repo --dry-run true >"$T/output" 2>&1
_rc=$?
assert_eq "missing exact-SHA CI run rejected" "1" "$( [ "$_rc" -ne 0 ] && echo 1 || echo 0 )"
assert_eq "missing CI cannot write" "0" "$(_write_count)"
_reset_fixture
GH_CI_STATE=failure python3 "$PREFLIGHT" --version "$_VERSION" --target-sha "$_TARGET_SHA" \
    --confirm "RELEASE v$_VERSION" --repository owner/repo --dry-run true >"$T/output" 2>&1
_rc=$?
assert_eq "failed exact-SHA CI run rejected" "1" "$( [ "$_rc" -ne 0 ] && echo 1 || echo 0 )"
assert_eq "failed CI cannot write" "0" "$(_write_count)"
_reset_fixture
GH_CI_SHA="$_OTHER_SHA" python3 "$PREFLIGHT" --version "$_VERSION" --target-sha "$_TARGET_SHA" \
    --confirm "RELEASE v$_VERSION" --repository owner/repo --dry-run true >"$T/output" 2>&1
_rc=$?
assert_eq "successful CI run for a different SHA rejected" "1" "$( [ "$_rc" -ne 0 ] && echo 1 || echo 0 )"
_reset_fixture
GH_CI_BRANCH=feature/release python3 "$PREFLIGHT" --version "$_VERSION" --target-sha "$_TARGET_SHA" \
    --confirm "RELEASE v$_VERSION" --repository owner/repo --dry-run true >"$T/output" 2>&1
_rc=$?
assert_eq "successful CI run on a non-main ref rejected" "1" "$( [ "$_rc" -ne 0 ] && echo 1 || echo 0 )"
assert_eq "mismatched CI SHA cannot write" "0" "$(_write_count)"

# Existing immutable names must block reuse, whether the tag or release is
# already present. Exercise each separately so both checks are observable.
_reset_fixture
GH_TAG_STATE=present python3 "$PREFLIGHT" --version "$_VERSION" --target-sha "$_TARGET_SHA" \
    --confirm "RELEASE v$_VERSION" --repository owner/repo --dry-run true >"$T/output" 2>&1
_rc=$?
assert_eq "existing version tag rejected" "1" "$( [ "$_rc" -ne 0 ] && echo 1 || echo 0 )"
assert_eq "existing tag cannot write" "0" "$(_write_count)"
_reset_fixture
GH_RELEASE_STATE=present python3 "$PREFLIGHT" --version "$_VERSION" --target-sha "$_TARGET_SHA" \
    --confirm "RELEASE v$_VERSION" --repository owner/repo --dry-run true >"$T/output" 2>&1
_rc=$?
assert_eq "existing GitHub Release rejected" "1" "$( [ "$_rc" -ne 0 ] && echo 1 || echo 0 )"
assert_eq "existing release cannot write" "0" "$(_write_count)"

# A real release (dry-run false) must stop while either live acceptance gate
# is pending, emit a clear diagnostic, and leave GitHub untouched.
_acceptance="$REPO/docs/openwrt-release-acceptance.json"
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); sys.exit(0 if d["cudy_live_acceptance"]["status"] == "pending" and d["web_luci_01"]["status"] == "pending" else 1)' \
    "$_acceptance" >/dev/null 2>&1; then
    _t_ok
else
    _t_bad "live-gate fixture must have pending Cudy and WEB-LUCI-01 acceptance"
fi
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); r=d["immutable_releases"]; sys.exit(0 if r["status"] == "pass" and any("enabled=true" in x for x in r["evidence"]) else 1)' \
    "$_acceptance" >/dev/null 2>&1; then
    _t_ok
else
    _t_bad "repository immutability must be pass only after enabled=true evidence"
fi
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); sys.exit(0 if d["web_blocker_01"]["status"] == "pending" and any("Chromium" in x for x in d["web_blocker_01"]["evidence"]) else 1)' \
    "$_acceptance" >/dev/null 2>&1; then
    _t_ok
else
    _t_bad "blocker compatibility gate must remain pending until blocker-enabled browser evidence is recorded"
fi
_reset_fixture
python3 "$PREFLIGHT" --version "$_VERSION" --target-sha "$_TARGET_SHA" \
    --confirm "RELEASE v$_VERSION" --repository owner/repo --dry-run false --require-live-gates \
    >"$T/output" 2>&1
_rc=$?
assert_eq "pending live acceptance blocks non-dry-run release" "1" "$( [ "$_rc" -ne 0 ] && echo 1 || echo 0 )"
if grep -Eiq 'pending[-_[:space:]]*live[-_[:space:]]*acceptance' "$T/output"; then
    _t_ok
else
    _t_bad "pending live-gate rejection lacks a clear pending-live-acceptance diagnostic"
fi
grep -q 'WEB-BLOCKER-01 needs evidence' "$PREFLIGHT" \
    && _t_ok || _t_bad "production gate requires WEB-BLOCKER-01 blocker-profile evidence"
assert_eq "pending live acceptance rejection is read-only" "0" "$(_write_count)"

# The production entrypoint is dispatch-only; push, tag, schedule, and other
# automatic event triggers would create an alternate release path.
if [ ! -s "$WORKFLOW" ]; then
    _t_bad "production release workflow is missing: $WORKFLOW"
else
    awk '
        /^on:[[:space:]]*$/ { in_on=1; seen_on=1; next }
        in_on && /^[^[:space:]#][^:]*:/ { in_on=0 }
        in_on && /^  workflow_dispatch:[[:space:]]*(#.*)?$/ { dispatch=1; next }
        in_on && /^  [A-Za-z0-9_-]+:[[:space:]]*/ {
            key=$1; sub(/:$/, "", key); if (key != "workflow_dispatch") bad=1
        }
        END { exit !(seen_on && dispatch && !bad) }
    ' "$WORKFLOW" && _t_ok || _t_bad "release workflow triggers must contain only workflow_dispatch"
fi

# The agent is the API dispatcher. A protected GitHub Environment can add a
# reviewer hold after every valid dispatch, reintroducing routine UI approval.
if grep -Eq '^[[:space:]]*environment:' "$WORKFLOW"; then
    _t_bad "agent-driven production dispatch must not pause for environment reviewer approval"
else
    _t_ok
fi

# The ordinary CI workflow can only publish versioned snapshots. Stable package
# identity belongs to the separate, gated release workflow.
if grep -Fq 'sh scripts/openwrt/build-release.sh --ci-snapshot' "$CI_WORKFLOW" \
    && grep -Fq 'name: z2k-openwrt-snapshot-${{ github.sha }}' "$CI_WORKFLOW" \
    && ! grep -Eq 'router-update|inputs\.package_mode|PACKAGE_MODE' "$CI_WORKFLOW"; then
    _t_ok
else
    _t_bad "CI must build only SHA-named snapshots, with no stable router-update mode"
fi

if grep -Fq 'release-assets.py verify-remote' "$WORKFLOW" \
    && grep -Fq -- "--jq '.assets'" "$WORKFLOW"; then
    _t_ok
else
    _t_bad "production release must compare every uploaded asset digest with the verified candidate"
fi

_candidate_and_release_asset_refs="$(grep -Fc '"$candidate/provenance.json" "$candidate/install.sh"' "$WORKFLOW")"
if grep -Fq -- '--installer-template scripts/openwrt/install.sh' "$WORKFLOW" \
    && grep -Fq -- '--public-key package/openwrt/keys/z2k-feed.pem' "$WORKFLOW" \
    && [ "$_candidate_and_release_asset_refs" -ge 2 ]; then
    _t_ok
else
    _t_bad "candidate and GitHub Release must carry the pinned installer and builder provenance"
fi

_preflight_gate_line="$(grep -n 'Recheck live gates, exact main, CI, and unused release names' "$WORKFLOW" | cut -d: -f1)"
_tag_creation_line="$(grep -n 'Create immutable version tag at the requested commit' "$WORKFLOW" | cut -d: -f1)"
if [ -n "$_preflight_gate_line" ] && [ -n "$_tag_creation_line" ] \
    && [ "$_preflight_gate_line" -lt "$_tag_creation_line" ] \
    && grep -Fq 'immutable Releases setting needs evidence' "$REPO/scripts/openwrt/release-preflight.py" \
    && grep -Fq -- "--jq '.immutable'" "$WORKFLOW"; then
    _t_ok
else
    _t_bad "immutable Releases must be enabled before tag creation and verified after publication"
fi

_t_done
