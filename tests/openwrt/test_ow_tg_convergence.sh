#!/bin/sh
# Healthy TG checks are read-only; a broken owned rule is repaired and then
# verified before the tick returns.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tg-convergence"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tgconv.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/root/bin" "$T/root/etc" "$T/etc" "$T/tmp"
export PATH="$T/bin:$PATH"
cat > "$T/root/bin/tg-mtproxy-client" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/root/bin/tg-mtproxy-client"
printf 'ENABLED=1\n' > "$T/etc/config"

cat > "$T/bin/nft" <<EOF
#!/bin/sh
echo "nft:\$*" >> "$T/nft.log"
case "\$1 \$2" in
  "list table") exit 0 ;;
  "list set")
    case "\$5" in
      z2k_tg_dc6) printf 'set \$5 { type ipv6_addr; elements = { 2001:67c:4e8::/48, 2001:b28:f23c::/47, 2001:b28:f23f::/48, 2a0a:f280:203::/48 } }\n' ;;
      z2k_tg_cdn4) printf 'set \$5 { type ipv4_addr; elements = { 168.119.95.238 } }\n' ;;
      *) printf 'set \$5 { type ipv4_addr; elements = { 149.154.160.0/20, 91.108.4.0/22, 91.108.8.0/22, 91.108.12.0/22, 91.108.16.0/22, 91.108.20.0/22, 91.108.56.0/22, 91.105.192.0/23, 95.161.64.0/20, 185.76.151.0/24 } }\n' ;;
    esac
    exit 0 ;;
  "list chain")
    if [ -f "$T/drift" ] && [ "\$5" = z2k_tg_dst_pre ]; then exit 0; fi
    case "\$5" in
      z2k_tg_dst_pre|z2k_tg_dst_out) printf 'tcp dport 443 ip daddr @z2k_tg_dc4 redirect to :1443\ntcp dport 80 ip daddr @z2k_tg_cdn4 redirect to :1444\n' ;;
      z2k_tg_flt_fwd|z2k_tg_flt_out) printf 'ip6 daddr @z2k_tg_dc6 tcp dport { 80, 443 } reject with icmpv6 port-unreachable\n' ;;
      z2k_tg_flt_in) printf 'tcp dport { 1443, 1444 } ct status dnat accept\ntcp dport { 1443, 1444 } drop\n' ;;
    esac
    exit 0 ;;
esac
case "\$1" in
  add|flush|delete|replace|-f) [ -f "$T/drift" ] && rm -f "$T/drift" ;;
esac
exit 0
EOF
chmod +x "$T/bin/nft"
cat > "$T/bin/conntrack" <<EOF
#!/bin/sh
echo "conntrack:\$*" >> "$T/conntrack.log"
exit 0
EOF
chmod +x "$T/bin/conntrack"
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/bin/curl"

export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_BIN="$T/root/bin" Z2K_CONFIG="$T/etc/config"
export Z2K_TG_HEALTH_DIR="$T/tmp/tg-health"
. "$REPO/platform/openwrt/tg.sh" || exit 1
z2k_ow_tg_running() { return 0; }

: > "$T/nft.log"; : > "$T/conntrack.log"
z2k_ow_tg check >/dev/null 2>&1 || _t_bad "healthy TG rc"
assert_eq "healthy TG nft mutations" "0" "$(grep -Ec '^nft:(add|flush|delete|replace|-f)' "$T/nft.log" 2>/dev/null || true)"
assert_eq "healthy TG conntrack mutations" "0" "$(wc -l < "$T/conntrack.log" | tr -d ' ')"

: > "$T/nft.log"; : > "$T/conntrack.log"; : > "$T/drift"
z2k_ow_tg check >/dev/null 2>&1 || _t_bad "drift TG rc"
assert_eq "drift TG repaired" "1" "$([ ! -f "$T/drift" ] && echo 1 || echo 0)"
[ "$(grep -Ec '^nft:(add|flush)' "$T/nft.log" 2>/dev/null || true)" -gt 0 ] && _t_ok || _t_bad "drift TG no nft repair"
[ "$(wc -l < "$T/conntrack.log" | tr -d ' ')" -gt 0 ] && _t_ok || _t_bad "drift TG no conntrack repair"

_t_done
