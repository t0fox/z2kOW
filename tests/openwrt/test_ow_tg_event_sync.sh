#!/bin/sh
# Воспроизводит переходы DC snapshot/manifest/nft без Telegram и сетевого трафика.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tg-event-sync"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tgevent.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/root/bin/linux-x86_64" "$T/etc/z2k" "$T/tmp"
export PATH="$T/bin:$PATH"

cat > "$T/bin/nft" <<EOF
#!/bin/sh
echo "nft:\$*" >> "$T/nft.log"
if [ "\$1 \$2" = "list table" ]; then exit 0; fi
if [ "\$1 \$2" = "list set" ]; then
    case "\$5" in
        z2k_tg_pair4) cat "$T/pair4.list" ;;
        z2k_tg_pair6) cat "$T/pair6.list" ;;
        *) exit 1 ;;
    esac
    exit 0
fi
if [ "\$1 \$2" = "-f -" ]; then
    : > "$T/nft.batch"
    while IFS= read -r _line; do
        printf '%s\n' "\$_line" >> "$T/nft.batch"
        printf 'batch:%s\n' "\$_line" >> "$T/nft.log"
    done
    [ ! -f "$T/fail-nft-batch" ] || exit 1
    _seen4=0; _seen6=0; _pairs4=; _pairs6=
    while IFS= read -r _line; do
        case "\$_line" in
            "flush set inet zapret2 z2k_tg_pair4") _seen4=1; _pairs4= ;;
            "flush set inet zapret2 z2k_tg_pair6") _seen6=1; _pairs6= ;;
            "add element inet zapret2 z2k_tg_pair4 "*)
                _pairs4=\$(printf '%s\n' "\$_line" | sed -n 's/^.*{ \(.*\) }$/\1/p')
                _seen4=1
                ;;
            "add element inet zapret2 z2k_tg_pair6 "*)
                _pairs6=\$(printf '%s\n' "\$_line" | sed -n 's/^.*{ \(.*\) }$/\1/p')
                _seen6=1
                ;;
        esac
    done < "$T/nft.batch"
    [ "\$_seen4" = 0 ] || printf 'elements = { %s }\n' "\$_pairs4" > "$T/pair4.list"
    [ "\$_seen6" = 0 ] || printf 'elements = { %s }\n' "\$_pairs6" > "$T/pair6.list"
    exit 0
fi
exit 0
EOF
cat > "$T/bin/lock" <<EOF
#!/bin/sh
echo "lock:\$*" >> "$T/lock.log"
exit 0
EOF
cat > "$T/bin/conntrack" <<EOF
#!/bin/sh
echo "conntrack:\$*" >> "$T/conntrack.log"
exit 0
EOF
cat > "$T/root/bin/linux-x86_64/tg-ws-proxy" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/bin/nft" "$T/bin/lock" "$T/bin/conntrack" "$T/root/bin/linux-x86_64/tg-ws-proxy"
nft() { "$T/bin/nft" "$@"; }

printf 'ENABLED=1\n' > "$T/etc/z2k/config"
cat > "$T/etc/z2k/tg-policy.conf" <<'EOF'
TG_TCP_PORTS="443 5222"
EOF
printf 'elements = { 149.154.167.43 . 443 }\n' > "$T/pair4.list"
printf 'elements = { }\n' > "$T/pair6.list"
: > "$T/conntrack.log"
printf 'z2k-tg-dc-options-v1 1791796943 1791796943\n149.154.167.43 443\n' > "$T/endpoints.tsv"
printf 'tcp ESTABLISHED src=192.0.2.10 dst=149.154.167.43 sport=40000 dport=443 [DNAT]\n' > "$T/conntrack.record"

export Z2K_ROOT="$REPO" Z2K_ETC="$T/etc/z2k" Z2K_TMP="$T/tmp"
export Z2K_CONFIG="$T/etc/z2k/config" Z2K_TG_POLICY_CONFIG="$T/etc/z2k/tg-policy.conf"
export Z2K_TG_DC_MAP_ENDPOINTS_PATH="$T/endpoints.tsv" Z2K_TG_HEALTH_DIR="$T/tmp/tg-health"
export Z2K_TG_NFT_TABLE=zapret2 Z2K_TG_RUST_BIN="$T/root/bin/linux-x86_64/tg-ws-proxy"
export Z2K_ADAPTER_DIR="$REPO/platform/openwrt" Z2K_OW_ARCH=x86_64
. "$REPO/platform/openwrt/tg.sh" || exit 1
export Z2K_TG_TCP_PORTS

# S0: карта и nft содержат прежний media endpoint.
z2k_ow_tg_dc_map_sync || _t_bad "S0 event sync"
_z2k_ow_tg_pair_set_matches 4 "$Z2K_TG_PAIR4" && _t_ok || _t_bad "S0 map/nft pair agreement"

# S1: Rust-манифест удаляет endpoint и добавляет новую media-опцию.
# Без события nft продолжает перенаправлять удалённый адрес в Rust.
printf 'z2k-tg-dc-options-v1 1791802536 1791802536\n149.154.167.151 443\n' > "$T/endpoints.tsv"
_z2k_ow_tg_pair_set_matches 4 "$Z2K_TG_PAIR4" && _t_bad "S1 must expose stale nft before sync" || _t_ok
assert_contains "stale S0 pair would still redirect a new flow" "$T/pair4.list" '149.154.167.43 . 443'
assert_file "existing conntrack DNAT record is present" "$T/conntrack.record"

z2k_ow_tg_dc_map_sync || _t_bad "S1 event sync"
_z2k_ow_tg_pair_set_matches 4 "$Z2K_TG_PAIR4" && _t_ok || _t_bad "S1 map/nft pair agreement"
assert_not_contains "S1 removes the stale endpoint" "$T/pair4.list" '149\.154\.167\.43'
assert_contains "S1 installs the new exact media option" "$T/pair4.list" '149.154.167.151 . 443'
assert_file "set-only update preserves existing conntrack DNAT" "$T/conntrack.record"
assert_eq "set-only update never flushes conntrack" "0" "$(wc -l < "$T/conntrack.log" | tr -d ' ')"
assert_not_contains "event does not rewrite redirect chains" "$T/nft.log" '^nft:(add|flush) chain'
assert_contains "adapter lock acquired" "$T/lock.log" 'lock:'
assert_contains "adapter lock released" "$T/lock.log" 'lock:-u '

# nft отклоняет транзакцию наборов целиком: старые пары остаются рабочими,
# а повтор применяет новый манифест без очистки conntrack.
cp "$T/pair4.list" "$T/pair4.before-failure"
printf 'z2k-tg-dc-options-v1 1791803000 1791803000\n149.154.167.43 443\n149.154.167.151 443\n' > "$T/endpoints.tsv"
: > "$T/fail-nft-batch"
z2k_ow_tg_dc_map_sync 2>/dev/null && _t_bad "nft failure is returned to Rust" || _t_ok
cmp -s "$T/pair4.before-failure" "$T/pair4.list" && _t_ok || _t_bad "failed nft batch changed active set"
rm -f "$T/fail-nft-batch"
z2k_ow_tg_dc_map_sync || _t_bad "retry after failed nft update"
_z2k_ow_tg_pair_set_matches 4 "$Z2K_TG_PAIR4" && _t_ok || _t_bad "retry restores manifest/nft agreement"
assert_file "retry preserves existing conntrack DNAT" "$T/conntrack.record"
assert_eq "retry does not bulk-clear conntrack" "0" "$(wc -l < "$T/conntrack.log" | tr -d ' ')"

# Процесс Rust вызывает тот же entry point адаптера; команда проверяет, что
# диспетчер события возвращает ошибку синхронизации, а не скрывает её.
if ( . "$REPO/platform/openwrt/tg-check.sh" sync-dc-map ) >"$T/tg-check.log" 2>&1; then
    _t_ok
else
    _t_bad "tg-check dispatches sync-dc-map: $(cat "$T/tg-check.log" "$T/nft.log")"
fi

_t_done
