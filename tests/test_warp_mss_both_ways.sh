#!/bin/sh
# Execute the real NDM hook against isolated iptables/ipset stubs and assert
# that the packet-direction behavior matches the WARP engine contract.
#
# The original field regression was asymmetric: client SYNs into the TUN were
# clamped, but SYN-ACKs returning from it retained an MSS of 1460. The client
# then sent segments larger than the 1280-byte tunnel MTU. The two directions
# need different rules: PMTU clamp into the TUN and explicit MTU-40 on return.
#
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/files/ndm/93-z2k-warp.sh"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT INT TERM
mkdir -p "$SB/bin" "$SB/root"
printf 'GAME_WARP_ENABLED=1\n' > "$SB/config"
printf '{"iface":"z2ktun0"}\n' > "$SB/device.json"
cat > "$SB/bin/iptables" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$SB/iptables.log"
case " \$* " in *' -C '*) exit 1 ;; esac
exit 0
EOF
cat > "$SB/bin/ipset" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$SB/bin/iptables" "$SB/bin/ipset"

# The hook and engine use separate languages, so keep this scalar coherence
# guard while testing the shell hook's actual output through the stub boundary.
MTU=$(sed -n 's/^[[:space:]]*MTU[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' \
      "$ROOT/z2k-warpd/internal/engine/engine.go" | head -1)
case "$MTU" in ''|*[!0-9]*) no "MTU туннеля числовой" "целое число" "$MTU"; MTU=0 ;; esac
_mss=$((MTU - 40))
assert_eq "MTU туннеля задаёт ожидаемый MSS" "1240" "$_mss"

table=mangle type=ip4tables Z2K_STUB_PATH="$SB/bin" \
    ZAPRET2_DIR="$SB/root" CONFIG_FILE="$SB/config" DEVICE_JSON="$SB/device.json" \
    sh "$HOOK" >/dev/null 2>&1
_rc=$?
assert_eq "NDM hook завершился успешно" "0" "$_rc"

_out_rule='-w -t mangle -A FORWARD -o z2ktun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
_in_rule="-w -t mangle -A FORWARD -i z2ktun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $_mss"
if grep -Fxq -- "$_out_rule" "$SB/iptables.log"; then
    ok "SYN клиента получает MSS clamp при выходе в туннель"
else
    no "SYN клиента получает MSS clamp при выходе в туннель" "$_out_rule" "не вызвано"
fi
if grep -Fxq -- "$_in_rule" "$SB/iptables.log"; then
    ok "SYN-ACK из туннеля получает MSS туннеля"
else
    no "SYN-ACK из туннеля получает MSS туннеля" "$_in_rule" "не вызвано"
fi
_bad_reverse='-w -t mangle -A FORWARD -i z2ktun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
if grep -Fxq -- "$_bad_reverse" "$SB/iptables.log"; then
    no "ответ не использует PMTU моста" "нет обратного clamp" "обратный clamp вызван"
else
    ok "обратный SYN-ACK не использует PMTU моста"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
