#!/bin/sh
# Контракт OpenWrt для очереди подмены адресов Googlevideo.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-gvsub"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-gvsub.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/tmp" "$T/run"
export PATH="$T/bin:/usr/bin:/bin"
export Z2K_TMP="$T/tmp" Z2K_RUN="$T/run" Z2K_CONFIG="$T/config"
export Z2K_GVSUB_IPS="$T/tmp/gv-ips.txt" Z2K_GVSUB_STATUS="$T/tmp/gvsub.json"
export Z2K_GVSUB_PID="$T/run/gvsub.pid" Z2K_NFQUEUE_PROC="$T/nfqueue"

cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NFT_CALLS"
case "$*" in
    "-a list chain inet zapret2 postnat")
        printf 'ct mark & 0x10000000 == 0x10000000 return comment "z2k-openwrt: gvsub core queue guard" # handle 17\n'
        ;;
    "list chain inet zapret2 postnat"|"list table inet z2k_gvsub") exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/bin/nft"
export NFT_CALLS="$T/nft.calls"
touch "$NFT_CALLS"
. "$REPO/platform/openwrt/paths.sh"
. "$REPO/platform/openwrt/gvsub.sh"

Z2K_GV_SUBST=0 Z2K_CATEGORY_YOUTUBE=1
export Z2K_GV_SUBST Z2K_CATEGORY_YOUTUBE INIT_APPLY_FW=1
z2k_ow_gvsub_wanted && _t_bad "выключенный режим считается активным" || _t_ok
z2k_ow_gvsub rules
assert_not_contains "режим по умолчанию не ставит nft guard" "$NFT_CALLS" 'insert rule'

: > "$NFT_CALLS"
Z2K_GV_SUBST=1; export Z2K_GV_SUBST
z2k_ow_gvsub_guard_apply && _t_ok || _t_bad "guard для активного режима"
assert_contains "старый guard удаляется по своему handle" "$NFT_CALLS" \
    'delete rule inet zapret2 postnat handle 17'
assert_contains "guard вставляется до очереди ядра" "$NFT_CALLS" \
    'insert rule inet zapret2 postnat ct mark & 0x10000000 == 0x10000000 return'
assert_contains "guard имеет отдельный маркер владения" "$NFT_CALLS" \
    'comment "z2k-openwrt: gvsub core queue guard"'

: > "$NFT_CALLS"
z2k_ow_gvsub_guard_remove && _t_ok || _t_bad "удаление guard"
assert_contains "снимается только правило с handle guard" "$NFT_CALLS" \
    'delete rule inet zapret2 postnat handle 17'
assert_not_contains "не удаляется таблица firewall" "$NFT_CALLS" 'delete table'

Z2K_DETECT_BIN="$T/z2k-detect"
printf '#!/bin/sh\n' > "$Z2K_DETECT_BIN"
chmod +x "$Z2K_DETECT_BIN"
Z2K_LISTS_DIR="$T/lists"; DISABLE_IPV6=1; QNUM=200
export Z2K_DETECT_BIN Z2K_LISTS_DIR DISABLE_IPV6 QNUM
procd_open_instance() { printf 'open:%s\n' "$1" >> "$T/procd.calls"; }
procd_set_param() { printf 'param:%s\n' "$*" >> "$T/procd.calls"; }
procd_close_instance() { printf 'close\n' >> "$T/procd.calls"; }
z2k_ow_gvsub_start_instance && _t_ok || _t_bad "procd instance"
assert_contains "procd регистрирует очередь DNS и очередь ядра" "$T/procd.calls" \
    "$Z2K_DETECT_BIN gvsub -queue=210 -engine-queue=200"
assert_contains "procd передаёт общий config и собственный ipfile" "$T/procd.calls" \
    "-config=$Z2K_CONFIG -ipfile=$Z2K_GVSUB_IPS"
assert_contains "IPv6 флаг передаётся в сервис" "$T/procd.calls" '-no-ipv6'

_t_done
