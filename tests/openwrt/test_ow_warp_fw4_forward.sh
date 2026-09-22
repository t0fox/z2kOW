#!/bin/sh
# Regression for the live WARP dataplane defect: zapret2's own forward hook
# accepted the packet, but the later fw4 forward chain still reached
# handle_reject. Verify the narrow fw4 admission, idempotence, ownership
# conflict handling and teardown without touching a real ruleset.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-warp-fw4-forward"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-warpfw4.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/root" "$T/etc" "$T/tmp"
export PATH="$T/bin:$PATH"

cat > "$T/bin/nft" <<EOF
#!/bin/sh
echo "nft:\$*" >> "$T/nft.log"
if [ "\$1" = "-a" ]; then
    shift
    if [ "\$1" = "list" ] && [ "\$2" = "chain" ]; then
        cat "$T/fw4-forward" 2>/dev/null
        exit 0
    fi
fi
if [ "\$1" = "list" ] && [ "\$2" = "chain" ]; then
    [ -f "$T/fw4-forward" ] || exit 1
    cat "$T/fw4-forward"
    exit 0
fi
if [ "\$1" = "insert" ] && [ "\$2" = "rule" ]; then
    _prev=""; _iface=""; _comment=""
    for _arg in "\$@"; do
        [ "\$_prev" = oifname ] && _iface="\$_arg"
        [ "\$_prev" = comment ] && _comment="\$_arg"
        _prev="\$_arg"
    done
    [ "\$_comment" = '"!z2k: WARP forwarded traffic"' ] || {
        echo "unquoted comment" >&2
        exit 1
    }
    {
        printf 'meta mark & %s == %s oifname "%s" accept comment "!z2k: WARP forwarded traffic" # handle 91\n' \\
            "0x80000000" "0x80000000" "\$_iface"
        cat "$T/fw4-forward" 2>/dev/null
    } > "$T/fw4-forward.new"
    mv -f "$T/fw4-forward.new" "$T/fw4-forward"
    exit 0
fi
if [ "\$1" = "delete" ] && [ "\$2" = "rule" ]; then
    # The only runtime line in this fixture has handle 91.
    sed -i '/!z2k: WARP forwarded traffic.*handle 91/d' "$T/fw4-forward"
    exit 0
fi
exit 0
EOF
chmod +x "$T/bin/nft"

export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_WARP_SOURCE_ONLY=1 WARP_STATUS="$T/status.json"
printf '{"ready":true,"iface":"z2ktun0"}\n' > "$T/status.json"
. "$REPO/platform/openwrt/warp.sh" || { _t_bad "warp.sh source"; _t_done; exit $?; }

# Reproduce the original route: fw4 has a normal reject path, with no WARP
# admission yet.
printf 'tcp reject comment "!fw4: handle_reject" # handle 77\n' > "$T/fw4-forward"
_warp_fw4_forward_apply z2ktun0 || _t_bad "fw4 admission applied"
assert_contains "admission passes marked routed traffic" "$T/fw4-forward" \
    'meta mark & 0x80000000 == 0x80000000 oifname "z2ktun0" accept comment "!z2k: WARP forwarded traffic"'
_warp_fw4_forward_verify z2ktun0 && _t_ok || _t_bad "fw4 admission verifies"

# Reconciliation must not stack another exact rule.
_warp_fw4_forward_apply z2ktun0 || _t_bad "idempotent apply"
assert_eq "exact runtime rule has one copy" "1" \
    "$(grep -c 'oifname \"z2ktun0\" accept comment \"!z2k: WARP forwarded traffic\"' "$T/fw4-forward")"

# Package-owned wildcard include is accepted without a runtime duplicate.
printf 'meta mark & 0x80000000 == 0x80000000 oifname "z2ktun*" accept comment "!z2k: WARP forwarded traffic" # handle 88\n' > "$T/fw4-forward"
: > "$T/nft.log"
_warp_fw4_forward_apply z2ktun0 || _t_bad "wildcard include accepted"
if grep -q '^nft:insert rule' "$T/nft.log"; then _t_bad "wildcard include duplicated"; else _t_ok; fi

# Foreign expression under our marker is a hard conflict, never overwritten.
printf 'oifname "z2ktun0" accept comment "!z2k: WARP forwarded traffic" # handle 89\n' > "$T/fw4-forward"
_warp_fw4_forward_apply z2ktun0 >/dev/null 2>&1 && _t_bad "foreign owner accepted" || _t_ok
assert_contains "foreign rule preserved" "$T/fw4-forward" 'oifname "z2ktun0" accept comment "!z2k: WARP forwarded traffic"'

# Teardown removes only the exact runtime fallback and leaves fw4's own rule.
printf 'tcp reject comment "!fw4: handle_reject" # handle 77\nmeta mark & 0x80000000 == 0x80000000 oifname "z2ktun0" accept comment "!z2k: WARP forwarded traffic" # handle 91\n' > "$T/fw4-forward"
_warp_fw4_forward_remove_runtime
assert_contains "fw4 reject rule preserved" "$T/fw4-forward" 'handle_reject'
if grep -q '!z2k: WARP forwarded traffic.*handle 91' "$T/fw4-forward"; then
    _t_bad "runtime WARP rule not removed"
else
    _t_ok
fi

_t_done
