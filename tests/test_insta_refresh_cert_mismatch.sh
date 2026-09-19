#!/bin/sh
# p-85.1 regression: c10r Instagram host may need an explicit TLS exception,
# but reachability and all other hosts must remain strict.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
R="$ROOT/files/z2k-insta-ip-refresh.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

[ -f "$R" ] || { printf '[FAIL] нет %s\n' "$R"; exit 1; }
SB=$(mktemp -d /tmp/instacert.XXXXXX) || exit 1
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/z2k/lists"
cp "$ROOT/files/lists/meta-ranges.txt" "$SB/z2k/lists/meta-ranges.txt"

DEAD=157.240.214.63
LIVE1=57.144.222.192

cat > "$SB/bin/ndmc" <<EOF
#!/bin/sh
_cmd=""
while [ \$# -gt 0 ]; do
    if [ "\$1" = "-c" ]; then shift; _cmd="\$1"; fi
    shift
done
case "\$_cmd" in
    "show running-config") cat "$SB/records" ;;
    "no ip host "*) _rec=\$(printf '%s' "\$_cmd" | sed 's/^no //')
        grep -vF "\$_rec" "$SB/records" > "$SB/records.new" 2>/dev/null
        mv "$SB/records.new" "$SB/records"
        echo "\$_cmd" >> "$SB/ndmc.log" ;;
    *) echo "\$_cmd" >> "$SB/ndmc.log"
       case "\$_cmd" in "ip host "*) echo "\$_cmd" >> "$SB/records" ;; esac ;;
esac
exit 0
EOF
cat > "$SB/bin/openssl" <<'EOF'
#!/bin/sh
cat >/dev/null; echo "(stdin)= 00ff"
EOF
cat > "$SB/bin/curl" <<EOF
#!/bin/sh
case "\$*" in
    */resolve*) printf '%s' '{"results":{"instagram.c10r.instagram.com":["$LIVE1"]}}'; exit 0 ;;
esac
_k=0; _res=""; _prev=""
for _a in "\$@"; do
    [ "\$_a" = "-k" ] && _k=1
    [ "\$_prev" = "--resolve" ] && _res="\$_a"
    _prev="\$_a"
done
echo "\$_res k=\$_k" >> "$SB/probe.log"
_ip=\$(printf '%s' "\$_res" | sed 's/.*://')
[ "\$_ip" = "$DEAD" ] && { printf '000'; exit 0; }
printf '404'
exit 0
EOF
chmod +x "$SB/bin/ndmc" "$SB/bin/openssl" "$SB/bin/curl"

printf 'Z2K_INSTA_DNS=1\nZ2K_RESOLVE_SECRET=test\n' > "$SB/z2k/config"
printf 'ip host instagram.c10r.instagram.com %s\n' "$DEAD" > "$SB/records"
: > "$SB/ndmc.log"; : > "$SB/probe.log"
Z2K_STUB_PATH="$SB/bin" ZAPRET2_DIR="$SB/z2k" CONFIG_FILE="$SB/z2k/config" \
    LOG_FILE="$SB/refresh.log" sh "$R" >/dev/null 2>&1

eq "мёртвая запись снята" "1" \
    "$(grep -c "^no ip host instagram.c10r.instagram.com $DEAD\$" "$SB/ndmc.log")"
eq "живой адрес прописан" "1" \
    "$(grep -c "^ip host instagram.c10r.instagram.com $LIVE1\$" "$SB/ndmc.log")"
eq "в состоянии роутера мёртвого адреса больше нет" "0" \
    "$(grep -c "$DEAD" "$SB/records")"
eq "изменение сохранено в конфигурацию" "1" \
    "$(grep -c '^system configuration save$' "$SB/ndmc.log")"
eq "проба идёт с -k" "0" "$(grep -c 'k=0' "$SB/probe.log")"

# The source must not regress the installation seed.
eq "в затравке install.sh мёртвого адреса нет" "0" \
    "$(grep -c "ip host instagram.c10r.instagram.com $DEAD" "$ROOT/lib/install.sh")"

eval "$(sed -n '/^probe_ip_alive()/,/^}/p' "$R")"
META_RANGES="$SB/z2k/lists/meta-ranges.txt"
PROBE_TIMEOUT=1
curl() { printf '%s\n' "$*" > "$SB/probe-args"; printf '200'; }
probe_ip_alive www.instagram.com "$LIVE1"
case "$(cat "$SB/probe-args")" in *' -k '*) no "обычные имена проверяют сертификат" strict insecure ;; *) ok "обычные имена проверяют сертификат" ;; esac
probe_ip_alive instagram.c10r.instagram.com "$LIVE1"
case "$(cat "$SB/probe-args")" in *' -k '*) ok "c10r с ranges допускает несовпадение сертификата" ;; *) no "c10r exception" insecure strict ;; esac
META_RANGES=/tmp/instacert-missing
probe_ip_alive instagram.c10r.instagram.com "$LIVE1"
case "$(cat "$SB/probe-args")" in *' -k '*) no "без ranges исключение запрещено" strict insecure ;; *) ok "без ranges исключение запрещено" ;; esac

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
