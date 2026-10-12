#!/bin/sh
# Проверяет dynamic nft verification точных пар и CIDR fallback.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tg-nft-verify-dynamic"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tgverify.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/root/bin/linux-x86_64" "$T/etc/z2k" "$T/tmp"
export PATH="$T/bin:$PATH"

cat > "$T/bin/nft" <<EOF
#!/bin/sh
if [ "\$1 \$2" = "list table" ]; then exit 0; fi
if [ "\$1 \$2" = "list set" ]; then
    case "\$5" in
        z2k_tg_pair4) printf 'elements = { 149.154.167.43 . 443 }\\n' ;;
        z2k_tg_pair6) printf 'elements = { }\\n' ;;
        z2k_tg_dc4)
            if [ -f "$T/missing-dc4" ]; then printf 'elements = { 149.154.160.0/20 }\\n'
            elif [ -f "$T/extra-dc4" ]; then printf 'elements = { 149.154.160.0/20, 91.108.4.0/22, 91.108.8.0/22, 91.108.12.0/22, 91.108.16.0/22, 91.108.20.0/22, 91.108.56.0/22, 91.105.192.0/23, 95.161.64.0/20, 185.76.151.0/24, 192.0.2.0/24 }\\n'
            else printf 'elements = { 149.154.160.0/20, 91.108.4.0/22, 91.108.8.0/22, 91.108.12.0/22, 91.108.16.0/22, 91.108.20.0/22, 91.108.56.0/22, 91.105.192.0/23, 95.161.64.0/20, 185.76.151.0/24 }\\n'; fi
            ;;
        z2k_tg_dc6)
            if [ -f "$T/missing-dc6" ]; then printf 'elements = { 2001:67c:4e8::/48 }\\n'
            else printf 'elements = { 2001:67c:4e8::/48, 2001:b28:f23c::/47, 2001:b28:f23f::/48, 2a0a:f280:203::/48 }\\n'; fi
            ;;
        *) exit 1 ;;
    esac
    exit 0
fi
if [ "\$1 \$2" = "list chain" ]; then
    case "\$5" in
        z2k_tg_dst_pre|z2k_tg_dst_out)
            [ "\$5" != z2k_tg_dst_out ] || printf 'meta mark 0x40000000 return\\n'
            printf 'ip daddr . tcp dport @z2k_tg_pair4 counter packets 0 bytes 0 redirect to :1443\\n'
            printf 'ip6 daddr . tcp dport @z2k_tg_pair6 counter packets 0 bytes 0 redirect to :1443\\n'
            if [ "\$5" = z2k_tg_dst_pre ]; then
                if [ ! -f "$T/missing-pre-fallback-v4" ]; then
                    printf 'tcp dport 443 ip daddr @z2k_tg_dc4 counter packets 0 bytes 0 redirect to :1443\\n'
                    printf 'tcp dport 5222 ip daddr @z2k_tg_dc4 counter packets 0 bytes 0 redirect to :1443\\n'
                fi
                if [ ! -f "$T/missing-pre-fallback-v6" ]; then
                    printf 'tcp dport 443 ip6 daddr @z2k_tg_dc6 counter packets 0 bytes 0 redirect to :1443\\n'
                    printf 'tcp dport 5222 ip6 daddr @z2k_tg_dc6 counter packets 0 bytes 0 redirect to :1443\\n'
                fi
            elif [ "\$5" = z2k_tg_dst_out ]; then
                if [ ! -f "$T/missing-out-fallback-v4" ]; then
                    printf 'tcp dport 443 ip daddr @z2k_tg_dc4 counter packets 0 bytes 0 redirect to :1443\\n'
                    printf 'tcp dport 5222 ip daddr @z2k_tg_dc4 counter packets 0 bytes 0 redirect to :1443\\n'
                fi
                if [ ! -f "$T/missing-out-fallback-v6" ]; then
                    printf 'tcp dport 443 ip6 daddr @z2k_tg_dc6 counter packets 0 bytes 0 redirect to :1443\\n'
                    printf 'tcp dport 5222 ip6 daddr @z2k_tg_dc6 counter packets 0 bytes 0 redirect to :1443\\n'
                fi
            fi
            ;;
        z2k_tg_flt_in) printf 'tcp dport 1443 ct status dnat accept\\ntcp dport 1443 drop\\n' ;;
        *) exit 1 ;;
    esac
    exit 0
fi
exit 0
EOF
chmod +x "$T/bin/nft"
cat > "$T/root/bin/linux-x86_64/tg-ws-proxy" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/root/bin/linux-x86_64/tg-ws-proxy"
printf 'ENABLED=1\n' > "$T/etc/z2k/config"
printf 'TG_TCP_PORTS="443 5222"\n' > "$T/etc/z2k/tg-policy.conf"
printf 'z2k-tg-dc-options-v1 1791782348 1791782348\n149.154.167.43 443\n' > "$T/endpoints.tsv"

export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc/z2k" Z2K_TMP="$T/tmp"
export Z2K_CONFIG="$T/etc/z2k/config" Z2K_TG_POLICY_CONFIG="$T/etc/z2k/tg-policy.conf"
export Z2K_TG_DC_MAP_ENDPOINTS_PATH="$T/endpoints.tsv" Z2K_TG_HEALTH_DIR="$T/tmp/tg-health"
export Z2K_TG_RUST_BIN="$T/root/bin/linux-x86_64/tg-ws-proxy"
export Z2K_ADAPTER_DIR="$REPO/platform/openwrt" Z2K_OW_ARCH=x86_64
. "$REPO/platform/openwrt/tg.sh" || exit 1

z2k_ow_tg_nft_verify && _t_ok || _t_bad "полный dynamic dataplane считается исправным"
touch "$T/missing-dc4"
z2k_ow_tg_nft_verify && _t_bad "отсутствующий IPv4 CIDR fallback обнаружен" || _t_ok
[ "${Z2K_TG_NFT_DRIFT_REDIRECT:-0}" = 1 ] && _t_ok || _t_bad "CIDR drift помечен как redirect drift"
rm -f "$T/missing-dc4"
touch "$T/missing-dc6"
z2k_ow_tg_nft_verify && _t_bad "отсутствующий IPv6 CIDR fallback обнаружен" || _t_ok
rm -f "$T/missing-dc6"
touch "$T/extra-dc4"
z2k_ow_tg_nft_verify && _t_bad "лишний недоверенный IPv4 CIDR обнаружен" || _t_ok
rm -f "$T/extra-dc4"
touch "$T/missing-pre-fallback-v6"
z2k_ow_tg_nft_verify && _t_bad "отсутствующий prerouting IPv6 CIDR redirect обнаружен" || _t_ok
rm -f "$T/missing-pre-fallback-v6"
touch "$T/missing-out-fallback-v4"
z2k_ow_tg_nft_verify && _t_bad "отсутствующий output IPv4 CIDR redirect обнаружен" || _t_ok

_t_done
