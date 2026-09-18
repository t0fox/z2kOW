#!/bin/sh
# Contract test for the domain picker timeout/result boundary.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"; rm -f /tmp/z2k-strategy-pick-*.$$' EXIT
mkdir -p "$SB/bin"
cat > "$SB/bin/z2k-detect" <<'STUB'
#!/bin/sh
progress=
prev=
for arg in "$@"; do
    [ "$prev" = progress ] && progress="$arg"
    [ "$arg" = -progress-file ] && prev=progress || prev=
done
if [ -n "$progress" ]; then
    printf '%s\n' 'stage=poison candidate=poison:badsum candidates=7 probes=21 elapsed_ms=118000 pass=0 fail=3' >> "$progress"
fi
printf '%s\n' '{"target":"discord.com:443","verdict":"opaque","reason":"deadline","error_code":"GLOBAL_TIMEOUT","failure_stage":"candidate-search","candidates_tested":7,"last_candidate":"poison:badsum","duration_ms":118000,"trace":[]}'
exit 4
STUB
chmod +x "$SB/bin/z2k-detect"
export Z2K_DETECT_BIN="$SB/bin/z2k-detect"
export STRATEGY_PICK_OUT="$SB/result.json"
eval "$(awk '/^strategy_pick_run\(\)/,/^}/' "$ROOT/webpanel/cgi/actions.sh")"

set +e
log=$(strategy_pick_run discord.com tcp13 2>&1)
rc=$?
set -e

[ "$rc" = 4 ] || { echo "wrong rc: $rc"; exit 1; }
grep -q 'GLOBAL_TIMEOUT' "$STRATEGY_PICK_OUT" || { echo "typed timeout absent"; exit 1; }
grep -q '"candidates_tested":7' "$STRATEGY_PICK_OUT" || { echo "candidate count absent"; exit 1; }
grep -q 'Итог: причина=GLOBAL_TIMEOUT' <<EOF || { echo "typed job summary absent"; exit 1; }
$log
EOF

if ls /tmp/z2k-strategy-pick-*.$$ >/dev/null 2>&1; then
    echo "picker scratch leaked"
    exit 1
fi
printf 'PASS: typed timeout, partial result, summary, and scratch cleanup\n'
